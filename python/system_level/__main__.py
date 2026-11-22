"""Simulate, compare LEN5 benchmarks, sweep parameters, or regenerate plots."""

import argparse
from copy import deepcopy
import os
from pathlib import Path

import yaml

from .analysis import PRESETS, experiments
from .benchmarks import SpikeTools, list_benchmarks, select_benchmark_pairs, select_benchmarks
from .config import integer, load_config
from .parallel import Progress
from .plots import plot
from .results import (benchmark_summary, clean, inside, metric_rows, read_report, reports, reserve,
                      save_benchmarks, save_experiment, simulation_dir)

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parent.parent


def sweeps(items: list[str]) -> dict[str, list]:
    result = {}
    for spec in items:
        name, sep, values = spec.partition("=")
        if not sep or not name or name in result:
            raise ValueError(f"expected a unique PATH=[VALUES] sweep, got {spec!r}")
        result[name] = yaml.safe_load(values)
    return result


def get_seeds(args: argparse.Namespace, config: dict) -> list[int]:
    seeds = args.seeds
    if args.make_seeds is not None:
        pieces = args.make_seeds.replace(",", " ").split()
        if not pieces:
            raise ValueError("SEEDS must be a positive count or a list of seed values")
        seeds = [int(piece) for piece in pieces]
        if len(seeds) == 1:
            integer(seeds[0], "SEEDS")
            first = config["simulation"]["seed"]
            seeds = list(range(first, first + seeds[0]))
    if seeds is None:
        seeds = ([config["simulation"]["seed"]] if args.command == "simulate" else config["analysis"]["seeds"])
    for seed in seeds:
        integer(seed, "seed", 0)
    if len(set(seeds)) != len(seeds):
        raise ValueError("seeds must be unique")
    return seeds


def render(root: Path, report: dict, directory: Path, preset: str | None = None,
           raw_directory: Path | None = None) -> None:
    os.environ["MPLCONFIGDIR"] = str(inside(root, root / ".matplotlib"))
    directory = inside(root, directory)
    plot(report, directory / "plots", preset, raw_directory=raw_directory)


def run_experiment(args: argparse.Namespace, scripts: SpikeTools, root: Path, config: dict,
                   seeds: list[int]) -> None:
    smt = config["smt"]
    progress = Progress(args.verbosity)
    preset = "none" if args.no_plots else args.plot_preset or config["plotting"]["preset"]
    enabled = smt["mode"] != "disabled"
    named = {thread: name for thread, name in smt["workloads"].items() if isinstance(name, str)} if enabled else {}

    def load_benchmark(name: str, trace_dir: Path) -> tuple[dict, dict | None]:
        if args.verbosity == "verbose":
            print(f"Loading {args.suite}/{name}", flush=True)
        workload, window = scripts.workload(config, trace_dir / name, suite=args.suite, benchmark=name)
        if window and args.verbosity == "verbose":
            print(f"  CSR-free window: {window['instructions']} of {window['requested_instructions']} "
                  f"instructions; found {len(window['excluded_csrs'])} CSR records", flush=True)
        return workload, window

    if args.command == "benchmarks":
        if enabled:
            configured = smt["benchmark_pairs"]
            if (not configured and named and not args.benchmarks
                    and args.benchmark_pairs is None and args.pair_mode is None):
                if len(named) != 2:
                    raise ValueError("set both named SMT workloads or select BENCHMARK_PAIRS")
                configured = [[named["thread_0"], named["thread_1"]]]
            selections = select_benchmark_pairs(ROOT, args.suite, args.benchmarks, configured,
                                                args.benchmark_pairs, pair_mode=args.pair_mode or "same")
        else:
            selections = [(name,) for name in select_benchmarks(ROOT, args.suite, args.benchmarks)]
        destination = reserve(root, "benchmarks", args.name or args.suite, args.output)
        traces = reserve(root, "trace_artifacts", f"benchmarks-{destination.name}")
        names = dict.fromkeys(name for selection in selections for name in selection)
        if args.verbosity != "quiet":
            print(f"LEN5 · {args.suite} · {len(names)} benchmarks · {len(selections) if enabled else 0} ordered pairs"
                  f" · {len(config['architectures']['enabled'])} architectures · SMT {smt['mode']} · {len(seeds)} seed(s)"
                  f" · {'reference_completion' if enabled else 'single iteration'}", flush=True)
        loaded = {name: load_benchmark(name, traces) for name in names}
        requests, locations = {}, {}
        for selection in selections:
            first = selection[0]
            label = " + ".join(selection)
            slug = first
            workload, window = loaded[first]
            if enabled:
                workload = deepcopy(workload)
                workload["smt"]["workloads"] = {f"thread_{tid}": dict(loaded[name][0]["workload"], name=name)
                                                for tid, name in enumerate(selection)}
                slug = f"pair-{len(first)}-{first}-{selection[1]}"
            requests[label] = workload, {}
            locations[label] = slug, selection, window
        batch = experiments(requests, seeds, progress=progress, keep_partial=True)
        comparisons = {}
        for label, data in batch.items():
            slug, selection, window = locations[label]
            if enabled:
                data["benchmark_pair"] = list(selection)
                data["trace_region"] = {f"thread_{tid}": loaded[name][1] for tid, name in enumerate(selection)}
            elif window:
                data["trace_region"] = window
            comparisons[label] = metric_rows(data)
            save_experiment(data, destination / "individual_benchmarks" / slug, sweep=False,
                            comparison=comparisons[label])
        data = benchmark_summary(args.suite, batch, comparisons=comparisons)
        data["execution"] = progress.counts
        save_benchmarks(data, destination)
        render(root, data, destination, preset)
        if args.verbosity != "quiet":
            print(destination / "summary.md", flush=True)
            if preset != "none":
                print(destination / "dashboard.html", flush=True)
        if data["failures"]:
            raise RuntimeError(f"{progress.counts['failed']} simulation(s) failed. "
                               f"{data['failures'][0]['error']}. See {destination / 'summary.json'}")
        return

    if named:
        select_benchmarks(ROOT, args.suite, " ".join(named.values()))
        traces = reserve(root, "trace_artifacts", f"threads-{args.name or args.suite}")
        loaded = {name: load_benchmark(name, traces)[0]["workload"] for name in dict.fromkeys(named.values())}
        config = deepcopy(config)
        for thread, name in named.items():
            config["smt"]["workloads"][thread] = dict(loaded[name], name=name)

    if args.command == "suite":
        grids = PRESETS
        parent = (reserve(root, "sweeps", args.name or "suite", args.output)
                  if args.name or args.output else None)
    elif args.command == "sweep":
        grid = dict(PRESETS.get(args.preset, {}))
        grid.update(sweeps(args.sweep))
        if not grid:
            raise ValueError("sweep requires --preset or --sweep")
        grids, parent = {args.name or args.preset or "custom": grid}, None
    else:
        grids, parent = {args.name or args.project or "workload": {}}, None

    kind = "single" if args.command == "simulate" else "sweeps"
    locations = {}
    for name, grid in grids.items():
        destination = (reserve(root, kind, name, parent / name) if parent else
                       reserve(root, kind, name, args.output))
        if args.project:
            traces = reserve(root, "trace_artifacts", f"single-{destination.name}")
            config, _ = scripts.workload(config, traces / args.project, project=args.project)
        locations[name] = destination
    batch = experiments({name: (config, grid) for name, grid in grids.items()}, seeds, progress=progress)
    for name, data in batch.items():
        destination, grid = locations[name], grids[name]
        save_experiment(data, destination, sweep=bool(grid))
        if preset != "none":
            render(root, data, destination, preset)
        if args.verbosity == "quiet":
            continue
        print(f"{destination} ({len(data['runs'])} runs)", flush=True)
        if not grid:
            for row in data["ipc_summary"]:
                suffix = " + SMT" if row["smt_mode"] == "enabled" else ""
                if "isolated_thread" in row:
                    suffix = f" (T{row['isolated_thread']} alone)"
                label = row["architecture"] + suffix
                print(f"  {label:<32} {row['mean']:.4f} IPC, {row['storage_bits']:,} bits")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", default="simulate",
                        choices=("simulate", "benchmarks", "sweep", "suite", "report", "list-benchmarks", "clean"))
    parser.add_argument("--config", type=Path, default=PACKAGE / "config.yaml")
    parser.add_argument("--build-dir", type=Path, default=Path(os.environ.get("BUILD_DIR") or ROOT / "build"))
    parser.add_argument("--name", help="run directory name")
    parser.add_argument("--output", type=Path, help="new run directory under BUILD_DIR/simulation")
    parser.add_argument("--input", type=Path, help="saved statistics or benchmark summary JSON to replot")
    seeds = parser.add_mutually_exclusive_group()
    seeds.add_argument("--seeds", nargs="+", type=int, help="explicit paired seeds")
    seeds.add_argument("--make-seeds", help=argparse.SUPPRESS)
    parser.add_argument("--instructions", type=int, help="override random instruction count or Spike trace limit")
    parser.add_argument("--smt", choices=("disabled", "enabled", "both"), help="override smt.mode")
    parser.add_argument("--jobs", help="number of simulation worker processes, or auto")
    parser.add_argument("--preset", choices=PRESETS)
    parser.add_argument("--sweep", action="append", default=[], metavar="PATH=[VALUES]")
    parser.add_argument("--no-plots", action="store_true")
    parser.add_argument("--plot-preset", choices=("essential", "detailed", "none"))
    parser.add_argument("--verbosity", choices=("quiet", "normal", "verbose"), default="normal")
    parser.add_argument("--project", help="build and run a LEN5 application with Spike")
    parser.add_argument("--suite", default="embench")
    parser.add_argument("--benchmarks", default="", help="space-separated benchmark names")
    parser.add_argument("--pair-mode", choices=("same", "all", "ordered"), help="automatic SMT pairs (default: same)")
    parser.add_argument("--benchmark-pairs", help="space-separated A:B benchmark pairs")
    parser.add_argument("--spike", default="spike")
    parser.add_argument("--spike-timeout", type=int, default=300)
    parser.add_argument("--riscv-prefix", default="riscv64-unknown-elf")
    parser.add_argument("--make", default="make")
    args = parser.parse_args()
    try:
        if args.command == "list-benchmarks":
            print("\n".join(list_benchmarks(ROOT, args.suite)))
            return
        root = simulation_dir(args.build_dir if args.build_dir.is_absolute() else ROOT / args.build_dir)
        if args.command == "clean":
            clean(root)
            print(f"Cleaned {root}")
            return
        if args.command == "report":
            sources = [args.input] if args.input else reports(root)
            if not sources:
                raise ValueError(f"no completed simulations under {root}")
            if args.output and not args.input:
                raise ValueError("report --output requires --input")
            for source in sources:
                directory = args.output or inside(root, source).parent
                render(root, read_report(source), directory, "none" if args.no_plots else args.plot_preset,
                       source.resolve().parent)
                if args.verbosity != "quiet":
                    print(directory, flush=True)
            return

        if args.command != "sweep" and (args.preset or args.sweep):
            raise ValueError("--preset and --sweep require the sweep command")
        if args.project and args.command != "simulate":
            raise ValueError("--project requires the simulate command")
        if args.benchmark_pairs is not None and args.command != "benchmarks":
            raise ValueError("--benchmark-pairs requires the benchmarks command")
        if args.pair_mode is not None and args.command != "benchmarks":
            raise ValueError("--pair-mode requires the benchmarks command")
        config = load_config(args.config)
        if args.plot_preset:
            config["plotting"]["preset"] = args.plot_preset
        if args.smt is not None:
            config["smt"]["mode"] = args.smt
        if args.jobs is not None:
            config["simulation"]["parallel"]["workers"] = args.jobs if args.jobs == "auto" else int(args.jobs)
        if args.instructions is not None:
            integer(args.instructions, "--instructions")
            config["workload"]["instructions"] = args.instructions
        integer(args.spike_timeout, "--spike-timeout")
        tools = SpikeTools(ROOT, args.make, args.spike, args.riscv_prefix, args.spike_timeout)
        run_experiment(args, tools, root, config, get_seeds(args, config))
    except (ValueError, OSError, RuntimeError, yaml.YAMLError) as error:
        parser.error(str(error))
    except ModuleNotFoundError as error:
        if error.name != "matplotlib":
            raise
        parser.error("plotting requires Matplotlib; install requirements.txt or use --no-plots")


if __name__ == "__main__":
    main()
