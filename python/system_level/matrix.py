"""Compact seed-paired views of one saved benchmark suite, indexed by thread order."""

from collections import defaultdict
from math import isfinite

from .analysis import BLOCKS, LEN5, NORMAL
from .results import metric_summary

# Labels include units and describe the denominator for every normalized metric.
LABELS = {
    "ipc": "SMT aggregate IPC (instructions/cycle)",
    "thread_0_ipc": "Thread 0 IPC (instructions/cycle)",
    "thread_1_ipc": "Thread 1 IPC (instructions/cycle)",
    "weighted_speedup": "Weighted speedup (× isolated throughput)",
    "vs_normal": "IPC relative to normal OoO (×)",
    "vs_len5": "IPC relative to LEN5 OoO (×)",
    "rob_occupancy": "ROB occupancy (entries)",
    "cdb_utilization": "CDB bandwidth utilization (fraction)",
    "issue_utilization": "Execution issue utilization (fraction)",
    "cdb_contention": "Cycles with CDB contention (fraction)",
    "retire_blocked": "Cycles with work in ROB and no retirement (fraction)",
    "recovery_wait": "Detection to backend flush (cycles/event)",
    "squash_rate": "Squashed instructions per 1,000 commits",
    "block_occupancy": "Active basic blocks (slots)",
    "merge_utilization": "Block merge bandwidth utilization (fraction)",
    "flush_utilization": "Block flush bandwidth utilization (fraction)",
    "cycles": "Completion time (core cycles)",
    "storage_bits": "Modeled hardware storage (bits)",
}


PERCENT_METRICS = {"cdb_utilization", "issue_utilization", "cdb_contention", "retire_blocked",
                   "merge_utilization", "flush_utilization"}


def heatmap_label(value: float | None, metric: str) -> str:
    """Format cell labels while keeping the underlying values in their recorded units."""
    if value is None:
        return "—"
    if metric in PERCENT_METRICS:
        return f"{value:.1%}"
    if metric in {"cycles", "storage_bits"}:
        return f"{value / 1000:.1f}k" if value >= 1000 else f"{value:.0f}"
    return f"{value:.2f}"


def color_limits(values, centered: bool = False) -> tuple[float, float]:
    """One scale for every architecture, including filtered views of the same metric."""
    values = [v for v in values if v is not None and isfinite(v)]
    if centered:
        radius = max((abs(v - 1) for v in values), default=0) or .01
        return max(0, 1 - radius), 1 + radius
    return 0, max(values, default=0) or 1


def measured(run: dict) -> dict:
    values = {key: run[key] for key in ("ipc", "cycles", "weighted_speedup", "issue_utilization",
                                          "cdb_utilization", "merge_utilization", "flush_utilization")
              if run.get(key) is not None}
    for key, source in (("rob_occupancy", "rob_occupancy"), ("block_occupancy", "block_occupancy"),
                        ("recovery_wait", "recovery_detection_to_flush")):
        sample = run.get("samples", {}).get(source, {})
        if sample.get("samples") and sample.get("mean") is not None:
            values[key] = sample["mean"]
    if run.get("cycles") and "counts" in run:
        for key, source in (("cdb_contention", "cdb_contention_cycles"),
                            ("retire_blocked", "retire_blocked_cycles")):
            values[key] = run["counts"].get(source, 0) / run["cycles"]
        if run.get("committed"):
            values["squash_rate"] = 1000 * run["counts"].get("squashed_instructions", 0) / run["committed"]
    if "total_bits" in run.get("storage", {}):
        values["storage_bits"] = run["storage"]["total_bits"]
    return values


def _point_signature(run: dict) -> tuple:
    return (run.get("point", 0), tuple(sorted((k, repr(v)) for k, v in run.get("parameters", {}).items())),
            run.get("mode"), tuple(run.get("workloads", ())))


def _comparison_key(run: dict) -> tuple | None:
    if run.get("smt_mode") != "enabled":
        return _point_signature(run)
    if run.get("measurement_policy") != "reference_completion" or run.get("reference_thread") not in (0, 1):
        return None
    threads = sorted(run.get("threads", ()), key=lambda t: t["thread_id"])
    workload_signature = tuple((t.get("benchmark"), t.get("instructions_per_iteration")) for t in threads)
    return (*_point_signature(run), run["reference_thread"], run.get("reference_benchmark"), workload_signature)


def _trial_views(joint: dict | None, alone: dict, paired: bool) -> dict:
    """A sequential baseline runs one full iteration of each program on its own."""
    views = {}
    if not paired:
        if alone:
            views["isolated"] = measured(next(iter(alone.values())))
        return views

    isolated = {}
    isolated_cycles = {}
    for tid, run in alone.items():
        isolated[f"thread_{tid}_ipc"] = run["ipc"]
        isolated_cycles[tid] = run["cycles"]
        if "total_bits" in run.get("storage", {}):
            isolated["storage_bits"] = run["storage"]["total_bits"]
    if joint:
        smt = views["smt"] = measured(joint)
        relative = {}
        for thread in joint.get("threads", ()):
            tid = thread["thread_id"]
            key = f"thread_{tid}_ipc"
            smt[key] = thread["ipc"]
            if thread.get("isolated_ipc") is not None and thread.get("isolated_cycles"):
                isolated[key] = thread["isolated_ipc"]
                isolated_cycles[tid] = thread["isolated_cycles"]
            if isolated.get(key):
                relative[key] = smt[key] / isolated[key]
        if "weighted_speedup" in smt:
            relative["weighted_speedup"] = smt["weighted_speedup"]
        if relative:
            views["relative"] = relative
    if isolated_cycles.keys() == {0, 1}:
        cycles = sum(isolated_cycles.values())
        isolated["cycles"] = cycles
        isolated["ipc"] = sum(isolated[f"thread_{tid}_ipc"] * n for tid, n in isolated_cycles.items()) / cycles
    if isolated:
        views["isolated"] = isolated
    return views


def build_matrix(report: dict) -> dict:
    pairs = {label: tuple(pair) for label, pair in report.get("benchmark_pairs", {}).items()}
    for run in report.get("runs", ()):
        if len(run.get("workloads", ())) == 2:
            pairs.setdefault(run["benchmark"], tuple(run["workloads"]))
    rows = defaultdict(dict)
    for run in report.get("runs", ()):
        label = run["benchmark"]
        by_seed = rows[label].setdefault(run["seed"], {})
        arch = by_seed.setdefault(run["architecture"], {})
        slot = "joint" if run.get("smt_mode") == "enabled" else run.get("isolated_thread", 0)
        if slot in arch:
            raise ValueError(f"duplicate benchmark row for {label}, {run['architecture']}, seed {run['seed']}, {slot}")
        arch[slot] = run

    confidence = report.get("confidence") or next(
        (row["confidence"] for row in report.get("metrics", ()) if row.get("confidence")), .95)
    cells = []
    sorting_ipcs = defaultdict(list)
    arch_names = set(report.get("architectures", ()))
    scales = defaultdict(list)
    names = set()
    labels = dict.fromkeys([*report.get("benchmarks", ()), *pairs, *rows])
    for label in labels:
        workloads = pairs.get(label, (label, label))
        names.update(workloads)
        by_arch = defaultdict(lambda: defaultdict(lambda: defaultdict(list)))
        reference_ids = set()
        policies = set()
        for trials in rows[label].values():
            by_seed = {}
            keys = {}
            for arch, slots in trials.items():
                joint = slots.get("joint")
                alone = {tid: run for tid, run in slots.items() if tid != "joint"}
                views = _trial_views(joint, alone, label in pairs or joint is not None)
                by_seed[arch] = views
                keys[arch] = {}
                if joint:
                    keys[arch]["smt"] = _comparison_key(joint)
                    if joint.get("reference_thread") in (0, 1):
                        reference_ids.add(joint["reference_thread"])
                    policies.add(joint.get("measurement_policy", "unspecified"))
                if "isolated" in views:
                    source = joint if joint else next(iter(alone.values()))
                    keys[arch]["isolated"] = _point_signature(source)
                if arch == NORMAL and "isolated" in views:
                    for tid, name in enumerate(workloads):
                        ipc = views["isolated"].get(f"thread_{tid}_ipc")
                        if ipc is None and label not in pairs and tid == 0:
                            ipc = views["isolated"].get("ipc")
                        if ipc is not None:
                            # A program reused in several pairs should have one vote per sample.
                            sorting_ipcs[name].append((source["seed"], tid, ipc))
            for arch, views in by_seed.items():
                for view, values in views.items():
                    for baseline, metric in ((NORMAL, "vs_normal"), (LEN5, "vs_len5")):
                        if arch == baseline or (baseline == LEN5 and arch != BLOCKS):
                            continue
                        denominator = by_seed.get(baseline, {}).get(view, {}).get("ipc")
                        key = keys[arch].get(view)
                        if denominator and key is not None and key == keys[baseline].get(view) and "ipc" in values:
                            values[metric] = values["ipc"] / denominator
                    for metric, value in values.items():
                        if isfinite(value):
                            by_arch[arch][view][metric].append(value)

        architectures = {}
        for arch, views in by_arch.items():
            arch_names.add(arch)
            variants = architectures[arch] = {}
            for view, metrics in views.items():
                stats = variants[view] = {}
                for metric, values in metrics.items():
                    summary = metric_summary(tuple(values), confidence)
                    mean = summary["mean"]
                    stats[metric] = {"mean": mean, "n": summary["trials"],
                                     "low": summary["ci_low"], "high": summary["ci_high"],
                                     "label": heatmap_label(mean, metric)}
                    scales[view, metric].append(mean)
        reference = next(iter(reference_ids)) if len(reference_ids) == 1 else None
        cells.append({"names": list(workloads), "architectures": architectures,
                      "reference_thread": reference, "reference_benchmark": workloads[reference] if reference is not None else None,
                      "policies": sorted(policies), "label": label})
    limits = {f"{view}/{metric}": color_limits(values, view == "relative" or metric.startswith("vs_"))
              for (view, metric), values in scales.items()}
    limit_labels = {key: [heatmap_label(value, key.split("/")[1]) for value in bounds]
                    for key, bounds in limits.items()}
    rank = {}
    for name, samples in sorting_ipcs.items():
        unique = set(samples)
        rank[name] = sum(ipc for _, _, ipc in unique) / len(unique)
    failures = [{k: f.get(k) for k in ("benchmark", "architecture", "smt_mode", "seed", "phase")}
                for f in report.get("failures", ())]
    return {"suite": report.get("suite", "Benchmark suite"), "names": sorted(names), "pairs": cells,
            "paired": bool(pairs),
            "architectures": [a for a in (NORMAL, LEN5, BLOCKS) if a in arch_names],
            "sort_ipc": rank, "limits": limits, "limit_labels": limit_labels, "labels": LABELS, "confidence": confidence,
            "seeds": report.get("seeds", []), "failures": failures}
