"""Build LEN5 firmware with SPIKE_CHECK and capture its Spike instruction trace."""

from copy import deepcopy
from dataclasses import dataclass
from itertools import combinations_with_replacement, product
import os
from pathlib import Path
import re
import subprocess

from .spike import records

# Follow the stock LEN5 benchmark runner's minver exclusion.
SUITE_EXCLUSIONS = {"embench": {"minver"}}
SPIKE_MEMORY = "-m0xf000:0x100000,0x20000000:0x1000"


def name_component(name: str) -> str:
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", name):
        raise ValueError(f"invalid name {name!r}; use letters, digits, dots, underscores or hyphens")
    return name


def list_benchmarks(root: Path, suite: str) -> list[str]:
    suite_dir = root / "sw" / "benchmarks" / name_component(suite) / "src"
    if not suite_dir.is_dir():
        raise ValueError(f"benchmark suite {suite!r} does not exist in sw/benchmarks")
    return sorted(entry.name for entry in suite_dir.iterdir() if entry.is_dir()
                  and any(file.suffix in (".c", ".S") for file in entry.iterdir())
                  and entry.name not in SUITE_EXCLUSIONS.get(suite, ()))


def select_benchmarks(root: Path, suite: str, selection: str) -> list[str]:
    available = list_benchmarks(root, suite)
    names = list(dict.fromkeys(selection.split())) or available
    if not names:
        raise ValueError(f"no benchmarks available in suite {suite!r}")
    invalid = set(names).difference(available)
    if invalid:
        raise ValueError(f"{suite}: unavailable benchmark(s) {', '.join(sorted(invalid))}; use sim-list-benchmarks")
    return names


def select_benchmark_pairs(root: Path, suite: str, selection: str, pairs: list[list[str]],
                           override: str | None = None, *, pair_mode: str = "same") -> list[tuple[str, str]]:
    if override is not None:
        pairs = [token.split(":") for token in override.split()]
        if not pairs or any(len(pair) != 2 or not all(pair) for pair in pairs):
            raise ValueError("BENCHMARK_PAIRS must contain space-separated A:B pairs")
    if not pairs:
        names = select_benchmarks(root, suite, selection)
        if pair_mode == "all":
            return list(combinations_with_replacement(names, 2))
        if pair_mode == "ordered":
            return list(product(names, repeat=2))
        return [(name, name) for name in names]
    select_benchmarks(root, suite, " ".join(name for pair in pairs for name in pair))
    return list(dict.fromkeys(tuple(pair) for pair in pairs))


def csr_free_window(trace: Path, start_pc: int, skip: int, limit: int) -> dict | None:
    """Select the longest contiguous CSR-free region within the requested benchmark prefix."""
    started, scanned = False, 0
    current = best = (0, 0, 0)
    csrs = []
    for index, (pc, word, _, _, _) in enumerate(records(trace, 0)):
        if index < skip or (not started and pc != start_pc):
            continue
        started = True
        if scanned == limit or word == 0x0000006f:
            break
        scanned += 1
        if word & 127 == 0x73 and (word >> 12) & 7 in (1, 2, 3, 5, 6, 7):
            csrs.append({"index": index, "pc": pc, "encoding": word})
            current = (0, 0, 0)
        else:
            length, offset, address = current if current[0] else (0, index, pc)
            current = length + 1, offset, address
            if current[0] > best[0]:
                best = current
    if not csrs:
        return None
    length, offset, address = best
    if not length:
        raise ValueError(f"{trace}: requested benchmark window contains only CSR instructions")
    return {"instructions": length, "trace_skip": offset, "trace_start_pc": address,
            "requested_instructions": limit, "excluded_csrs": csrs}


@dataclass(frozen=True)
class SpikeTools:
    root: Path
    make: str
    spike: str
    riscv_prefix: str
    timeout: int

    def run(self, command: list[str], log: Path) -> None:
        # Forward explicit environment overrides, independent of recursive Make's flags and jobserver.
        env = {key: value for key, value in os.environ.items() if key not in
               ("MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES", "GNUMAKEFLAGS")}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        try:
            with log.open("w") as stream:
                subprocess.run(command, cwd=self.root, env=env, stdout=stream, stderr=subprocess.STDOUT,
                               check=True, timeout=self.timeout)
        except subprocess.CalledProcessError as error:
            raise RuntimeError(f"{command[0]} exited with status {error.returncode}; see {log}") from error
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"{command[0]} exceeded {self.timeout}s; see {log}") from error
        except FileNotFoundError as error:
            raise RuntimeError(f"{command[0]} was not found; check tool paths") from error

    def workload(self, config: dict, directory: Path, *, project: str | None = None,
                 suite: str = "embench", benchmark: str | None = None) -> tuple[dict, dict | None]:
        if any(char.isspace() for char in str(directory)):
            raise ValueError("LEN5 firmware Make targets require a BUILD_DIR without spaces for Spike runs")
        if project is not None:
            name_component(project)
            if not (self.root / "sw" / "applications" / project).is_dir():
                raise ValueError(f"unknown LEN5 application {project!r}")
            target = ["app-spike", f"PROJECT={project}"]
        else:
            target = ["benchmark-spike", f"SUITE={name_component(suite)}",
                      f"BENCHMARK={name_component(benchmark)}"]
        directory.mkdir(parents=True)
        self.run([self.make, "--no-print-directory", *target, f"BUILD_DIR={directory}",
                  f"RISCV_EXE_PREFIX={self.riscv_prefix}"], directory / "build.log")
        elf = directory / "spike" / "main.elf"
        workload = deepcopy(config)
        settings = workload["workload"]
        pc = settings["trace_start_pc"]
        automatic_window = pc is None and benchmark is not None and settings["trace_hart"] == 0
        if pc is None:
            symbols = directory / "symbols.txt"
            self.run([self.riscv_prefix + "-nm", "--defined-only", str(elf)], symbols)
            for line in symbols.read_text().splitlines():
                fields = line.split()
                if len(fields) == 3 and fields[-1] == "main":
                    pc = int(fields[0], 16)
                    break
            if pc is None:
                raise ValueError(f"no main symbol in {elf}; set workload.trace_start_pc")

        trace = directory / "spike-trace.log"
        options = [self.spike, SPIKE_MEMORY]
        count = settings["instructions"]
        if count is not None:
            # Check firmware completion at full speed, then log only the requested sampling window.
            self.run([*options, str(elf)], directory / "spike-verify.log")
            script = directory / "spike-debug.txt"
            steps = count + 1
            # The debug replay starts at the region PC. An explicit trace_skip is applied before
            # searching that PC by the parser, so let Spike log normally when it is specified.
            if not settings["trace_skip"] and settings["trace_hart"] == 0:
                script.write_text(f"until pc 0 {pc:x}\nrs {steps}\nq\n")
                options += ["-d", f"--debug-cmd={script}"]
        self.run([*options, "--log-commits", f"--log={trace}", "-l", str(elf)], directory / "spike.log")
        settings.update(type="spike", trace=str(trace), trace_start_pc=pc, trace_stop_at_self_jump=True,
                        elf=str(elf))
        window = csr_free_window(trace, pc, settings["trace_skip"], count) if automatic_window and count else None
        if window:
            for key in ("instructions", "trace_skip", "trace_start_pc"):
                settings[key] = window[key]
        return workload, window
