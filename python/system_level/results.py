"""Result directories, per-metric summaries, and paired benchmark comparisons."""

from collections import defaultdict
from functools import lru_cache
from itertools import count
import json
import os
from pathlib import Path
import shutil
from statistics import geometric_mean

import yaml

from .analysis import IDEAL, LEN5, PAIRS, summarize, write_csv, write_json
from .config import (BLOCK_ARCHITECTURES, BRANCH_FORWARDING_ARCHITECTURES, IDEAL_ARCHITECTURES,
                     UNIFIED_RS, WRAPPER_ARCHITECTURES, commit_architecture)
from .benchmarks import name_component

BLOCK_COUNTERS = ("block_", "blocks_", "flush", "merge", "physical_", "register_pressure",
                  "dispatch_stall_reclamation", "dispatch_stall_with_reclaim", "dispatch_stall:block_capacity",
                  "dispatch_stall:integer_prf", "dispatch_stall:fp_prf")
BLOCK_STORAGE = ("mapping_bits", "ownership_bits", "mapping_bits_per_block", "ownership_bits_per_block",
                 "checkpoint_bits", "block_thread_tag_bits", "shared_block_mapping_ownership_bits")
MEASURES = ("ipc", "cycles", "committed", "cdb_utilization", "issue_utilization", "retirement_utilization",
            "merge_utilization", "flush_utilization", "smt_throughput_improvement", "weighted_speedup",
            "sequential_cycles", "completion_cycle", "dispatch_share", "slowdown", "isolated_cycles", "isolated_ipc")


def simulation_dir(build: Path) -> Path:
    root = build.resolve() / "simulation"
    if root.is_symlink():
        raise ValueError(f"refusing to use symlinked simulation directory {root}")
    return root


def inside(root: Path, path: Path) -> Path:
    resolved = path.resolve()
    if resolved == root or root not in resolved.parents:
        raise ValueError(f"{path} must be inside {root}")
    return resolved


def reserve(root: Path, kind: str, name: str, explicit: Path | None = None) -> Path:
    if explicit is not None:
        directory = inside(root, explicit)
        directory.mkdir(parents=True)
        return directory
    base = inside(root, root / kind / name_component(name))
    for suffix in count(1):
        directory = base if suffix == 1 else base.with_name(f"{base.name}-{suffix}")
        try:
            directory.mkdir(parents=True)
            return directory
        except FileExistsError:
            continue
    raise AssertionError("unreachable")


def clean(root: Path) -> None:
    if root.exists():
        shutil.rmtree(root)


def reports(root: Path) -> list[Path]:
    candidates = []
    for directory, dirs, files in os.walk(root):
        excluded = ("individual_benchmarks", "plots", "trace_artifacts", ".matplotlib", ".test-tmp")
        dirs[:] = [name for name in dirs if name not in excluded]
        for filename in ("statistics.json", "summary.json"):
            if filename in files:
                candidates.append(inside(root, Path(directory) / filename))
    return sorted(candidates)


@lru_cache(maxsize=4096)
def metric_summary(values: tuple[float, ...], confidence: float) -> dict:
    return summarize(list(values), confidence)


def metrics(run: dict) -> dict[str, float]:
    values = {field: run[field] for field in MEASURES if run.get(field) is not None}
    for field, sample in run["samples"].items():
        if not sample["samples"] or (field.startswith("execution_lane_busy:") and run["mode"] == "statistical"):
            continue
        values[field] = sample["mean"]
        if "occupancy" in field or field in ("speculative_window", "flush_backlog", "merge_candidates"):
            values["peak:" + field] = sample["peak"]
    for field, value in run["counts"].items():
        values["count:" + field] = value
    for unit, data in run["execution_units"].items():
        for field in ("issue_utilization", "lane_utilization"):
            if data[field] is not None:
                values[f"{field}:{unit}"] = data[field]
    for wrapper, data in run.get("wrappers", {}).items():
        values[f"wrapper_issue_utilization:{wrapper}"] = data["issue_utilization"]
    for level, total in run["histograms"].get("cache_outcomes", {}).items():
        values["cache_requests:" + level] = total
    for key, value in run.get("storage", {}).items():
        if value is not None and (key not in BLOCK_STORAGE or run["architecture"] in BLOCK_ARCHITECTURES):
            values["storage:" + key] = value
    for thread in run.get("threads", ()):
        for metric, value in metrics(thread).items():
            values[f"thread_{thread['thread_id']}:{metric}"] = value
    return values


def applicable_count(metric: str, run: dict) -> bool:
    field = metric.removeprefix("count:")
    if (field.startswith("smt_") or field == "physical_registers_reclaimed") and run.get(
            "smt_mode", "disabled") != "enabled":
        return False
    if field in ("cdb_contention_cycles", "cdb_deferred_requests") and "thread_id" in run:
        return False
    arch = run["architecture"]
    if field.startswith(("branch_direct_", "branch_cdb_")):
        return arch in BRANCH_FORWARDING_ARCHITECTURES
    if (field.startswith(("unified_", "wrapper_", "issue_blocked:wrapper_", "issue_blocked:completion_buffer:"))
            or field.endswith(":" + UNIFIED_RS)):
        return arch in WRAPPER_ARCHITECTURES
    if field.startswith(BLOCK_COUNTERS):
        return arch in BLOCK_ARCHITECTURES
    if field == "out_of_order_commits":
        return commit_architecture(arch) in (LEN5, IDEAL)
    if field in ("retirement_width_saturated_cycles", "recovery_wait_for_rob_head_cycles"):
        return arch not in IDEAL_ARCHITECTURES
    if field == "statistical_cycles_skipped":
        return run["mode"] == "statistical"
    return True


def metric_rows(report: dict) -> list[dict]:
    by_point = defaultdict(list)
    for run in report["runs"]:
        by_point[run["point"]].append((run, metrics(run)))
    rows = []
    for point in report["points"]:
        confidence = point["config"]["analysis"]["confidence"]
        runs = by_point[point["point"]]
        fields = sorted({key for _, values in runs for key in values})
        groups = defaultdict(list)
        for run, values in runs:
            groups[run["architecture"], run.get("smt_mode", "disabled"), run.get("isolated_thread")].append((run, values))
        for (arch, mode, isolated), trials in groups.items():
            variant = {"isolated_thread": isolated} if isolated is not None else {}
            for metric in fields:
                values = []
                for run, trial in trials:
                    if metric in trial:
                        values.append(trial[metric])
                    elif metric.startswith("cache_requests:") or (
                            metric.startswith("count:") and applicable_count(metric, run)):
                        values.append(0)
                    elif metric.startswith("thread_") and mode == "enabled":
                        thread, _, suffix = metric.partition(":")
                        local = run["threads"][int(thread[-1])]
                        if suffix.startswith("cache_requests:") or (
                                suffix.startswith("count:") and applicable_count(suffix, local)):
                            values.append(0)
                if values:
                    rows.append({"point": point["point"], "architecture": arch, "metric": metric,
                                 "smt_mode": mode, **variant, "parameters": point["parameters"],
                                 **metric_summary(tuple(values), confidence)})
    return rows


def save_experiment(report: dict, output: Path, sweep: bool, *, comparison: list[dict] | None = None) -> None:
    output.mkdir(parents=True, exist_ok=True)
    config = report["points"][0]["config"]
    (output / "config.yaml").write_text(yaml.safe_dump(config, sort_keys=False))
    for run in report["runs"]:
        seed = f"seed-{run['seed']}"
        if "isolated_thread" in run:
            seed += f"-thread-{run['isolated_thread']}"
        path = (output / "individual_runs" / f"point-{run['point']}" /
                run["architecture"] / run["smt_mode"] / (seed + ".json"))
        path.parent.mkdir(parents=True, exist_ok=True)
        write_json(path, run)
    write_csv(output / ("results.csv" if sweep else "comparison.csv"),
              report["runs"] if sweep else comparison if comparison is not None else metric_rows(report))
    if not sweep:
        write_csv(output / "per_seed_results.csv", report["runs"])
    write_csv(output / "ipc_summary.csv", report["ipc_summary"])
    write_csv(output / "paired_ipc_improvement.csv", report["paired_ipc_improvement"])
    write_json(output / "statistics.json", report)


def benchmark_summary(suite: str, experiments: dict[str, dict], *, comparisons: dict | None = None) -> dict:
    rows, per_seed, speedups, geomean = [], [], [], []
    paired = defaultdict(list)
    for bench, report in experiments.items():
        comparison = comparisons[bench] if comparisons is not None else metric_rows(report)
        rows.extend({"benchmark": bench, **row} for row in comparison)
        per_seed.extend({"benchmark": bench, **row} for row in report["runs"])
        ipc = {(run["seed"], run["architecture"], run.get("smt_mode", "disabled"),
                run.get("isolated_thread")): run["ipc"]
               for run in report["runs"]}
        config = report["points"][0]["config"]
        seeds, confidence = report["seeds"], config["analysis"]["confidence"]
        archs = config["architectures"]["enabled"]
        for mode, isolated in dict.fromkeys(key[2:] for key in ipc):
            variant = {"isolated_thread": isolated} if isolated is not None else {}
            for architecture, baseline in PAIRS:
                if architecture not in archs or baseline not in archs:
                    continue
                gains = [(seed, ipc[seed, architecture, mode, isolated] / ipc[seed, baseline, mode, isolated])
                         for seed in seeds if ipc.get((seed, baseline, mode, isolated))
                         and (seed, architecture, mode, isolated) in ipc]
                if not gains:
                    continue
                speedups.append({"benchmark": bench, "architecture": architecture, "baseline": baseline,
                                 "smt_mode": mode, **variant, **metric_summary(tuple(v for _, v in gains), confidence)})
                for seed, ratio in gains:
                    paired[architecture, baseline, mode, isolated, seed].append(ratio)
    ratios_by_variant = defaultdict(list)
    for (architecture, baseline, mode, isolated, _), ratios in paired.items():
        ratios_by_variant[architecture, baseline, mode, isolated].append(geometric_mean(ratios) if all(ratios) else 0)
    for (architecture, baseline, mode, isolated), values in ratios_by_variant.items():
        variant = {"isolated_thread": isolated} if isolated is not None else {}
        geomean.append({"architecture": architecture, "baseline": baseline, "smt_mode": mode,
                        **variant, **metric_summary(tuple(values), confidence)})
    smt = config.get("smt", {})
    mode = smt.get("mode", "disabled")
    policy = smt.get("measurement", {}).get("policy", "unspecified")
    return {"suite": suite, "benchmarks": list(experiments), "seeds": seeds, "metrics": rows,
            "confidence": confidence, "plotting": config.get("plotting", {"preset": "essential"}),
            "architectures": archs, "smt_mode": mode,
            "measurement_policy": policy if mode != "disabled" else "one isolated iteration",
            "failures": [row for report in experiments.values() for row in report.get("failures", ())],
            "trace_regions": {name: report["trace_region"] for name, report in experiments.items()
                              if "trace_region" in report},
            "benchmark_pairs": {name: report["benchmark_pair"] for name, report in experiments.items()
                                if "benchmark_pair" in report},
            "runs": per_seed, "ipc_speedup": speedups, "geomean_speedup": geomean}


def save_benchmarks(report: dict, output: Path) -> None:
    write_csv(output / "summary.csv", report["metrics"])
    write_csv(output / "per_seed_results.csv", report["runs"])
    write_csv(output / "ipc_speedup.csv", report["ipc_speedup"])
    write_csv(output / "geomean_speedup.csv", report["geomean_speedup"])
    write_json(output / "summary.json", report)


def read_report(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)
