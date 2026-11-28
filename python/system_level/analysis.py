"""Paired trials, configuration grids, and portable CSV/JSON reports."""

from collections import Counter, defaultdict
from contextlib import contextmanager, nullcontext
from copy import deepcopy
from dataclasses import dataclass
from functools import lru_cache
import csv
from itertools import product
import json
import os
from pathlib import Path
from random import Random
from statistics import fmean, stdev
from tempfile import NamedTemporaryFile

from .config import (BRANCH_FORWARDING_ARCHITECTURES, BRANCH_FORWARDING_SUFFIX, DEFAULT_ARCHITECTURES,
                     IDEAL, IDEAL_OOO, SEPARATE_ARCHITECTURES, UNIFIED_ARCHITECTURES,
                     UNIFIED_SUFFIX, VARIANT_SEPARATOR, backend_name, configure, fixed, frontend_variant, overlay,
                     variant_config)
from .instruction import Instruction
from .parallel import Progress, process_pool, run_jobs, worker_count
from .simulator import Simulator
from .smt import SMT, paired_performance
from .storage import estimate
from .workload import Timing, load_program, sample_timing, validate_program

NORMAL, LEN5, BLOCKS = DEFAULT_ARCHITECTURES
SEPARATE_PAIRS = ((LEN5, NORMAL), (BLOCKS, LEN5), (BLOCKS, NORMAL),
         (IDEAL, NORMAL), (IDEAL, LEN5), (IDEAL, BLOCKS),
         (IDEAL_OOO, NORMAL), (IDEAL_OOO, LEN5), (IDEAL_OOO, BLOCKS), (IDEAL_OOO, IDEAL))
UNIFIED_PAIRS = tuple((name + UNIFIED_SUFFIX, name) for name in SEPARATE_ARCHITECTURES)
BRANCH_FORWARDING_PAIRS = tuple(zip(BRANCH_FORWARDING_ARCHITECTURES, UNIFIED_ARCHITECTURES))
PAIRS = (*SEPARATE_PAIRS,
         *((arch + UNIFIED_SUFFIX, baseline + UNIFIED_SUFFIX) for arch, baseline in SEPARATE_PAIRS),
         *UNIFIED_PAIRS,
         *((arch + BRANCH_FORWARDING_SUFFIX, baseline + BRANCH_FORWARDING_SUFFIX)
           for arch, baseline in SEPARATE_PAIRS),
         *BRANCH_FORWARDING_PAIRS)


def pairs_for(architectures: list[str]) -> list[tuple[str, str]]:
    """Comparison pairs among enabled names: backend pairs within each frontend variant, plus each
    variant against the first enabled variant (or the plain backend) of the same backend."""
    enabled = set(architectures)
    result = [pair for pair in PAIRS if set(pair) <= enabled]
    variants = dict.fromkeys(frontend_variant(name) for name in architectures)
    for variant in variants:
        if variant is None:
            continue
        suffix = VARIANT_SEPARATOR + variant
        result += [(a + suffix, b + suffix) for a, b in PAIRS if {a + suffix, b + suffix} <= enabled]
    for name in architectures:
        reference = next(other for other in architectures if backend_name(other) == backend_name(name))
        if reference != name:
            result.append((name, reference))
    return result


PRESETS = {
    "merge-width": {"basic_block.merging.width": [1, 2, 4, 8]},
    "flush-width": {"basic_block.flushing.width": [1, 2, 4, 8]},
    "block-count": {"basic_block.max_active_blocks": [4, 8, 16, 32]},
    "branch-flush": {"branch.misprediction_probability": [0, .05, .15, .30],
                     "basic_block.flushing.width": [1, 2, 4]},
    "physical-registers": {"basic_block.registers.integer_physical+basic_block.registers.fp_physical":
                           [40, 48, 64, 96, 128]},
    "rob-size": {"simulation.rob_size": [8, 16, 32, 64, 96]},
    "frontend-predictor": {"frontend.predictor": ["l0_only", "l1_bim", "gshare", "tage", "len5", "ideal"]},
    "fetch-fifo": {"frontend.memory_fifo.depth": [1, 2, 4, 8, 16, "unlimited"]},
    "issue-queue": {"frontend.issue_queue.capacity": [8, 16, 32, 64, "unlimited"]},
    "btq-capacity": {"frontend.btq.capacity": [0, 4, 8, 16, 32, "unlimited"]},
    "ras-depth": {"frontend.ras.depth": [2, 4, 8, 16, 32, "unlimited"]},
}
BOOTSTRAP_DRAWS = 3000


def setting(config: dict, path: str, value: object) -> None:
    keys = path.split(".")
    parent = config
    for key in keys[:-1]:
        if not isinstance(parent, dict) or key not in parent:
            raise ValueError(f"unknown sweep parameter {path}")
        parent = parent[key]
    leaf = keys[-1]
    if not isinstance(parent, dict) or leaf not in parent:
        raise ValueError(f"unknown sweep parameter {path}")
    current = parent[leaf]
    parent[leaf] = fixed(value) if isinstance(current, dict) and "type" in current and type(value) is int else value


@lru_cache(maxsize=4)
def bootstrap_groups(n: int) -> Counter:
    # Small seed sets draw the same multisets thousands of times.
    rng = Random(0)
    return Counter(tuple(sorted(rng.choices(range(n), k=n))) for _ in range(BOOTSTRAP_DRAWS))


def bootstrap_interval(values: list[float], confidence: float) -> list[float]:
    n = len(values)
    if n <= 5:
        groups = sorted((fmean(values[i] for i in indices), count)
                        for indices, count in bootstrap_groups(n).items())
        def at(rank: int) -> float:
            for mean, count in groups:
                if rank < count:
                    return mean
                rank -= count
            raise IndexError("bootstrap quantile outside sample")
    else:
        rng = Random(0)
        means = sorted(fmean(rng.choices(values, k=n)) for _ in range(BOOTSTRAP_DRAWS))
        at = means.__getitem__
    tail = (1 - confidence) / 2
    interval = []
    for probability in (tail, 1 - tail):
        position = probability * (BOOTSTRAP_DRAWS - 1)
        lo = int(position)
        a, b = at(lo), at(min(lo + 1, BOOTSTRAP_DRAWS - 1))
        interval.append(a + (position - lo) * (b - a))
    return interval


def summarize(values: list[float], confidence: float) -> dict:
    n = len(values)
    center = fmean(values)
    interval = [None, None]
    if n > 1:
        interval = [center, center]
        if min(values) != max(values):
            interval = bootstrap_interval(values, confidence)
    return {"trials": n, "mean": center, "stddev": stdev(values) if n > 1 else None,
            "ci_low": interval[0], "ci_high": interval[1], "confidence": confidence}


@dataclass(frozen=True)
class Program:
    settings: str
    seed: int
    sample_name: str | None


@dataclass(frozen=True)
class WorkItem:
    benchmark: str
    point: int
    seed: int
    architecture: str
    config: dict
    programs: tuple[Program, ...]
    thread: int = 0
    names: tuple[str, str] | None = None
    reference: int | None = None
    calibration: bool = False

    def __str__(self) -> str:
        phase = "calibration" if self.calibration else "isolated"
        mode = "enabled" if self.reference is not None else "disabled"
        if self.reference is not None:
            phase = "joint"
        return (f"{self.benchmark!r}, {self.architecture}, SMT {mode}, seed {self.seed}, "
                f"point {self.point} ({phase}, thread {self.thread})")


@lru_cache(maxsize=4)
def program_for(settings: str, seed: int) -> list[Instruction]:
    return load_program(json.loads(settings), seed)


@lru_cache(maxsize=8)
def timings_for(program: Program, settings: str, seed: int, tid: int) -> list[Timing]:
    return sample_timing(program_for(program.settings, program.seed), json.loads(settings), seed, tid,
                         benchmark=program.sample_name)


def execute(item: WorkItem) -> dict:
    config = variant_config(item.config, item.architecture)
    programs = [program_for(program.settings, program.seed) for program in item.programs]
    for program in programs:
        validate_program(program, config["execution"])
    settings = json.dumps({key: config[key] for key in ("execution", "memory", "branch")}, sort_keys=True)
    timings = [timings_for(program, settings, item.seed, tid)
               for tid, program in enumerate(item.programs, item.thread)]
    elfs = tuple(json.loads(program.settings).get("elf") for program in item.programs)
    if item.reference is not None:
        return SMT(item.architecture, config, programs[0], tuple(timings), other_program=programs[1],
                   names=item.names, sample_names=tuple(program.sample_name for program in item.programs),
                   seed=item.seed, reference_thread=item.reference, elfs=elfs).run()
    run = Simulator(item.architecture, config, programs[0], timings[0], seed=item.seed, elf=elfs[0]).run()
    return {"cycles": run["cycles"]} if item.calibration else run


@dataclass
class Trial:
    benchmark: str
    point: dict
    programs: tuple[Program, Program]
    names: tuple[str, str]
    mixed: bool
    modes: tuple[str, ...]
    calibration: tuple[tuple, ...]
    isolated: dict[tuple, tuple]
    seed: int

    def reference(self, completed: dict) -> tuple[int | str, list[int] | None]:
        selection = self.point["config"]["smt"]["measurement"]["reference_thread"]
        if not self.calibration:
            return selection, None
        cycles = [completed[key]["cycles"] for key in self.calibration]
        return int(cycles[1] > cycles[0]), cycles


def workload_pair(config: dict) -> tuple[list[dict], tuple[str, str], list[str | None], bool]:
    assignments = config["smt"]["workloads"] if config["smt"]["mode"] != "disabled" else {}
    settings, names, sample_names = [], [], []
    for tid in range(2):
        assignment = assignments.get(f"thread_{tid}")
        if isinstance(assignment, str):
            raise ValueError(f"workload {assignment!r} requires benchmark trace resolution by the CLI")
        spec = dict(assignment or {})
        name = spec.pop("name", None)
        workload = overlay(config["workload"], spec)
        settings.append(workload)
        names.append(name or (Path(workload["trace"]).stem if workload["type"] == "spike" else "random"))
        sample_names.append(names[-1] if assignment is not None else None)
    mixed = names[0] != names[1] or settings[0] != settings[1]
    if mixed and names[0] == names[1]:
        names = [f"{name} (T{tid})" for tid, name in enumerate(names)]
    return settings, tuple(names), sample_names, mixed


def grid_points(config: dict, grid: dict[str, list]):
    if any(not isinstance(values, list) or not values for values in grid.values()):
        raise ValueError("each sweep parameter requires a nonempty list of settings")
    paths = [path for axis in grid for path in axis.split("+")]
    if len(set(paths)) != len(paths):
        raise ValueError("a parameter may occur in only one sweep dimension")
    for point, values in enumerate(product(*grid.values())):
        parameters = dict(zip(grid, values))
        trial = deepcopy(config)
        for axis, value in parameters.items():
            for path in axis.split("+"):
                setting(trial, path, value)
        if any(path.startswith("frontend.") for path in paths):
            trial["frontend"]["enabled"] = True  # Sweeping frontend parameters implies modeling the frontend.
        yield {"point": point, "parameters": parameters, "config": configure(trial)}


def plan(requests: dict, seeds: list[int]):
    baseline = configure()
    reports, trials, jobs = {}, [], {}
    for label, (config, grid) in requests.items():
        points = list(grid_points(config, grid))
        reports[label] = {"seeds": seeds, "sweep": grid, "points": points, "runs": [],
                          "ipc_summary": [], "paired_ipc_improvement": []}
        for point in points:
            cfg = point["config"]
            archs = cfg["architectures"]["enabled"]
            mode = cfg["smt"]["mode"]
            modes = ("disabled", "enabled") if mode == "both" else (mode,)
            paired = "enabled" in modes
            options, names, sample_names, mixed = workload_pair(cfg)

            def programs(seed: int) -> tuple[Program, Program]:
                return tuple(Program(json.dumps(spec), seed if spec["type"] == "random" else 0,
                                     name) for spec, name in zip(options, sample_names))

            calibration = ()
            if paired and cfg["smt"]["measurement"]["reference_thread"] == "auto":
                calibration = tuple(("calibration", program) for program in programs(seeds[0]))
                for tid, key in enumerate(calibration):
                    jobs.setdefault(key, WorkItem(f"{label} [{names[tid]}]", point["point"], 42, NORMAL,
                                                  baseline, (key[1],), calibration=True))
            # Isolated runs share a cache only when the workload, sampling, and timing configuration match.
            effective = {k: v for k, v in cfg.items()
                         if k in ("simulation", "execution", "basic_block", "branch", "memory", "frontend")}
            effective["simulation"] = {k: v for k, v in cfg["simulation"].items() if k != "parallel"}
            fingerprint = json.dumps(effective, sort_keys=True)
            for seed in seeds:
                pair = programs(seed)
                isolated = {}
                for arch in archs:
                    for tid in range(2 if paired else 1):
                        key = ("isolated", arch, fingerprint, paired, pair[tid], seed, tid)
                        jobs.setdefault(key, WorkItem(f"{label} [{names[tid]}]", point["point"], seed, arch,
                                                      cfg, (pair[tid],), thread=tid))
                        isolated[arch, tid] = key
                trials.append(Trial(label, point, pair, names, mixed, modes, calibration, isolated, seed))
    return reports, trials, jobs


def summarize_runs(report: dict) -> None:
    grouped = defaultdict(list)
    for run in report["runs"]:
        grouped[run["point"], run["architecture"], run["smt_mode"], run.get("isolated_thread")].append(run)
    for point in report["points"]:
        confidence = point["config"]["analysis"]["confidence"]
        archs = point["config"]["architectures"]["enabled"]
        index = point["point"]
        for mode in ("disabled", "enabled"):
            for tid in (None, 0, 1):
                variant = {"isolated_thread": tid} if tid is not None else {}
                metadata = {"point": index, "parameters": point["parameters"], "smt_mode": mode, **variant}
                for arch in archs:
                    runs = grouped.get((index, arch, mode, tid))
                    if runs:
                        report["ipc_summary"].append(dict(metadata, architecture=arch,
                            storage_bits=runs[0]["storage"]["total_bits"],
                            **summarize([r["ipc"] for r in runs], confidence)))
                for faster, baseline in pairs_for(archs):
                    a = grouped.get((index, faster, mode, tid))
                    b = grouped.get((index, baseline, mode, tid))
                    if a and b:
                        base = {row["seed"]: row["ipc"] for row in b}
                        gain = [(row["ipc"] / base[row["seed"]] - 1) * 100 for row in a if base.get(row["seed"])]
                        if gain:
                            report["paired_ipc_improvement"].append(dict(metadata, architecture=faster,
                                baseline=baseline, unit="percent", **summarize(gain, confidence)))


def experiments(requests: dict, seeds: list[int], *, cache: dict | None = None,
                progress: Progress | None = None, keep_partial: bool = False) -> dict:
    if not requests:
        raise ValueError("no simulation experiments requested")
    if not seeds or len(set(seeds)) != len(seeds):
        raise ValueError("experiments require nonempty, unique seeds")
    reports, trials, jobs = plan(requests, seeds)
    completed = {} if cache is None else cache
    isolated = {key: job for key, job in jobs.items() if key not in completed}
    pending_smt = sum(len(t.point["config"]["architectures"]["enabled"])
                      for t in trials if "enabled" in t.modes)
    requested = next(iter(reports.values()))["points"][0]["config"]["simulation"]["parallel"]["workers"]
    workers = worker_count(requested, max(len(isolated), pending_smt))
    progress = progress or Progress()
    progress.plan(isolated, pending_smt, workers)
    failures = {} if keep_partial else None
    with process_pool(workers) if workers > 1 else nullcontext() as pool:
        completed.update(run_jobs(isolated, execute, pool, workers, progress, failures))
        if pending_smt and progress.verbosity != "quiet":
            print("Calibration and isolated baseline phase finished.", flush=True)
        joint = {}
        for trial in trials:
            if "enabled" not in trial.modes or any(key not in completed for key in trial.calibration):
                continue
            reference, cycles = trial.reference(completed)
            trial.point.update(reference_thread=reference, reference_selection_cycles=cycles,
                               reference_benchmark=trial.names[reference], repeated_benchmark=trial.names[1 - reference])
            for arch in trial.point["config"]["architectures"]["enabled"]:
                if any(trial.isolated[arch, tid] not in completed for tid in range(2)):
                    continue
                key = trial.benchmark, trial.point["point"], trial.seed, arch
                joint[key] = WorkItem(trial.benchmark, trial.point["point"], trial.seed, arch,
                                      trial.point["config"], trial.programs, names=trial.names, reference=reference)
        progress.counts.update(joint=len(joint), scheduled=len(isolated) + len(joint))
        smt_runs = run_jobs(joint, execute, pool, workers, progress, failures)
    for trial in trials:
        point, seed = trial.point, trial.seed
        cfg = point["config"]
        paired = "enabled" in trial.modes
        metadata = {"point": point["point"], "seed": seed, "parameters": point["parameters"]}
        if paired:
            metadata["workloads"] = list(trial.names)
        for arch in cfg["architectures"]["enabled"]:
            keys = [trial.isolated[arch, tid] for tid in range(2 if paired else 1)]
            for mode in trial.modes:
                storage = estimate(cfg, arch, 2 if mode == "enabled" else 1)
                rows = []
                joint_key = trial.benchmark, point["point"], seed, arch
                def missing(key):
                    reports[trial.benchmark].setdefault("failures", []).append(dict(
                        benchmark=trial.benchmark, architecture=arch, seed=seed, smt_mode=mode,
                        phase=key[0] if key != joint_key else "joint", error=failures[key]))
                if mode == "enabled":
                    if joint_key not in smt_runs:
                        missing(next(key for key in (*trial.calibration, *keys, joint_key) if key in failures))
                        continue
                    run = smt_runs[joint_key]
                    run["reference_selection_cycles"] = point["reference_selection_cycles"]
                    paired_performance(run, [completed[key] for key in keys])
                    rows.append(run)
                else:
                    for tid, key in enumerate(keys[:2 if trial.mixed else 1]):
                        if key not in completed:
                            missing(key)
                            continue
                        run = dict(completed[key])
                        if paired:
                            run.update(workload=trial.names[tid], total_cycles=run["cycles"],
                                       measured_cycles=run["cycles"], total_committed=run["committed"],
                                       measured_committed=run["committed"], completed_iterations=1,
                                       measured_completed_iterations=1, iteration=0, partial_iteration_committed=0)
                        if trial.mixed:
                            run["isolated_thread"] = tid
                        rows.append(run)
                reports[trial.benchmark]["runs"].extend({**metadata, "smt_mode": mode, "storage": storage, **r}
                                                       for r in rows)
    for report in reports.values():
        summarize_runs(report)
    return reports


def experiment(config: dict, seeds: list[int], grid: dict[str, list] | None = None, *,
               cache: dict | None = None) -> dict:
    config = configure(config)
    _, names, _, mixed = workload_pair(config)
    label = " + ".join(names) if mixed or config["smt"]["mode"] != "disabled" else names[0]
    return experiments({label: (config, grid or {})}, seeds, cache=cache)[label]


def flatten(row: dict, prefix: str = "") -> dict:
    result = {}
    for key, value in row.items():
        if key == "events":
            continue
        name = prefix + str(key)
        if isinstance(value, dict):
            result.update(flatten(value, name + "."))
        elif key == "threads":
            for thread in value:
                result.update(flatten(thread, f"{name}.{thread['thread_id']}."))
        else:
            result[name] = json.dumps(value) if isinstance(value, list) else value
    return result


def write_csv(path: Path, rows: list[dict]) -> None:
    rows = [flatten(row) for row in rows]
    columns = list(dict.fromkeys(key for row in rows for key in row))
    with atomic_output(path) as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def write_json(path: Path, report: dict) -> None:
    with atomic_output(path) as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write("\n")


@contextmanager
def atomic_output(path: Path):
    with NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, newline="", delete=False) as stream:
        temp = Path(stream.name)
        try:
            yield stream
            stream.close()
            os.replace(temp, path)
        finally:
            temp.unlink(missing_ok=True)


def write_tables(report: dict, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "report.json", report)
    for key in ("runs", "ipc_summary", "paired_ipc_improvement"):
        write_csv(output / (key + ".csv"), report[key])
