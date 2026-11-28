"""Frontend, branch-prediction, RAS, training-queue and occupancy figures.

Figures are drawn only when the corresponding statistics exist, so backend-only reports produce none.
Single-workload reports compare architectures (including ``arch@variant`` frontend variants) at the
first sweep point; suite reports use benchmark x architecture heatmaps with annotated values.
"""

from collections import Counter, defaultdict
from pathlib import Path
from statistics import fmean

STAGES = ("l0", "l1", "final")
REDIRECTS = ("l0", "l1", "final", "ras_repair", "backend")
RAS_EVENTS = ("ras_wraparounds", "ras_overflows", "ras_underflows", "ras_overflow_losses",
              "ras_overwritten_addresses", "ras_entries_invalidated", "ras_saved_top_restored", "ras_recoveries")
BTQ_EVENTS = ("btq_allocated", "btq_dropped", "btq_trained", "btq_flushed", "btq_confirmed_flushed")
LATENCIES = ("btq_prediction_to_training", "btq_issue_to_confirmation", "btq_confirmation_to_training",
             "btq_residence")
RECOVERY = ("branch_resolution_to_recovery", "recovery_to_first_correct_fetch", "recovery_to_first_correct_issue")
IDEAL_WORDS = ("ideal", "perfect", "unlimited")
LATENCY_HISTOGRAMS = ("fe_redirect_latency:final", "fe_redirect_latency:l1", "fe_redirect_latency:backend",
                      "recovery_to_first_correct_fetch", "recovery_to_first_correct_issue")


def _pyplot():
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    return plt


def _save(fig, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.tight_layout()
    fig.savefig(path, dpi=140)
    _pyplot().close(fig)


def heatmap(path: Path, title: str, rows: list[str], columns: list[str], values: dict, fmt: str = "{:.2f}",
            cmap: str = "viridis") -> None:
    """Annotated heatmap; missing cells stay blank."""
    if not rows or not columns or not values:
        return
    plt = _pyplot()
    import numpy as np
    data = np.array([[values.get((r, c), np.nan) for c in columns] for r in rows], dtype=float)
    fig, ax = plt.subplots(figsize=(max(5, 1.2 * len(columns) + 2.5), max(3, .42 * len(rows) + 1.6)))
    image = ax.imshow(data, aspect="auto", cmap=cmap)
    ax.set_xticks(range(len(columns)), columns, rotation=35, ha="right", fontsize=8)
    ax.set_yticks(range(len(rows)), rows, fontsize=8)
    finite = data[np.isfinite(data)]
    middle = (finite.min() + finite.max()) / 2 if finite.size else 0
    for i in range(len(rows)):
        for j in range(len(columns)):
            if np.isfinite(data[i, j]):
                ax.text(j, i, fmt.format(data[i, j]), ha="center", va="center", fontsize=7,
                        color="white" if data[i, j] < middle else "black")
    fig.colorbar(image, ax=ax, fraction=.04)
    ax.set_title(title, fontsize=10)
    _save(fig, path)


def bars(path: Path, title: str, categories: list[str], series: dict[str, list], ylabel: str,
         stacked: bool = False) -> None:
    series = {name: values for name, values in series.items() if any(v for v in values if v is not None)}
    if not categories or not series:
        return
    plt = _pyplot()
    fig, ax = plt.subplots(figsize=(max(6, 1.1 * len(categories) + 3), 4.4))
    width = .8 if stacked else .8 / len(series)
    bottom = [0.0] * len(categories)
    for offset, (name, values) in enumerate(series.items()):
        values = [v or 0 for v in values]
        x = [i + (0 if stacked else width * (offset - (len(series) - 1) / 2)) for i in range(len(categories))]
        ax.bar(x, values, width, bottom=bottom if stacked else None, label=name)
        if stacked:
            bottom = [b + v for b, v in zip(bottom, values)]
    ax.set_xticks(range(len(categories)), categories, rotation=25 if len(categories) > 3 else 0,
                  ha="right" if len(categories) > 3 else "center", fontsize=8)
    ax.set_ylabel(ylabel)
    ax.set_title(title, fontsize=10)
    ax.grid(axis="y", alpha=.2)
    ax.legend(fontsize=7, ncol=2)
    _save(fig, path)


def _first_point_rows(rows: list[dict]) -> list[dict]:
    first = min((row["point"] for row in rows), default=0)
    return [row for row in rows if row["point"] == first and row.get("smt_mode", "disabled") == "disabled"
            and row.get("isolated_thread") is None]


def plot_frontend_workload(report: dict, output: Path, labels: dict) -> None:
    from .results import metric_rows
    rows = _first_point_rows(metric_rows(report))
    if not any(row["metric"].startswith("frontend:") for row in rows):
        return
    value = {(row["architecture"], row["metric"]): row["mean"] for row in rows}
    archs = [a for a in dict.fromkeys(row["architecture"] for row in rows)
             if (a, "frontend:fetch_ipc") in value]
    names = [labels.get(a, a) for a in archs]

    def get(metric: str) -> list:
        return [value.get((a, metric)) for a in archs]

    bars(output / "frontend" / "throughput.png", "Fetch, issue and commit throughput", names,
         {"committed IPC": get("ipc"), "fetch IPC": get("frontend:fetch_ipc"),
          "correct-path fetch IPC": get("frontend:correct_path_fetch_ipc"), "issue IPC": get("frontend:issue_ipc")},
         "Instructions per cycle")
    bars(output / "frontend" / "starvation.png", "Dispatch cycles lost to the frontend or backend", names,
         {"frontend starvation": get("frontend:frontend_starvation"),
          "backend starvation": get("frontend:backend_starvation")}, "Fraction of cycles")
    bars(output / "frontend" / "wrong_path.png", "Wrong-path work", names,
         {"fetched": get("count:fe_wrong_path_fetched"), "dispatched": get("count:wrong_path_dispatched"),
          "icache requests": get("count:icache_wrong_path_requests")}, "Instructions or requests")
    bars(output / "branch_prediction" / "accuracy_by_stage.png", "Correct-path prediction accuracy by stage", names,
         {stage: get(f"frontend:{stage}_accuracy") for stage in STAGES}, "Accuracy")
    bars(output / "branch_prediction" / "mpki.png", "Backend misprediction MPKI", names,
         {kind: get(f"frontend:{kind}_mpki") for kind in ("conditional", "target", "return")}, "MPKI", stacked=True)
    bars(output / "branch_prediction" / "redirects.png", "Frontend redirects by source", names,
         {source: get("count:fe_redirects:" + source) for source in REDIRECTS}, "Redirects", stacked=True)
    bars(output / "branch_prediction" / "overrides.png", "Useful and harmful prediction overrides", names,
         {f"{kind} {stage}": get(f"count:bp_override_{kind}:{stage}") for stage in ("l1", "final")
          for kind in ("useful", "harmful")}, "Correct-path instructions")
    bars(output / "ras" / "events.png", "RAS events", names,
         {name.removeprefix("ras_").replace("_", " "): get("count:" + name) for name in RAS_EVENTS}, "Events")
    bars(output / "ras" / "accuracy.png", "Return prediction", names,
         {"RAS coverage": get("frontend:ras_coverage"), "RAS accuracy": get("frontend:ras_accuracy"),
          "return accuracy": get("frontend:return_accuracy"),
          "L1 fallback accuracy": get("frontend:ras_l1_fallback_accuracy"),
          "L0 fallback accuracy": get("frontend:ras_l0_fallback_accuracy")}, "Fraction")
    bars(output / "training" / "btq.png", "Branch training queue", names,
         {name.removeprefix("btq_").replace("_", " "): get("count:" + name) for name in BTQ_EVENTS}, "Entries")
    bars(output / "training" / "latency.png", "Training latencies (mean cycles)", names,
         {name.removeprefix("btq_").replace("_", " "): get(name) for name in LATENCIES}, "Cycles")
    bars(output / "training" / "conflicts.png", "Training stalls", names,
         {"head-of-line blocking cycles": get("count:btq_head_of_line_blocking_cycles"),
          "SRAM write conflicts": get("count:btq_sram_conflicts")}, "Cycles")
    bars(output / "recovery" / "frontend_recovery.png", "Recovery latencies (mean cycles)", names,
         {name.replace("_", " "): get(name) for name in RECOVERY}, "Cycles")
    bars(output / "memory" / "icache.png", "Instruction cache", names,
         {"hit rate": get("frontend:icache_hit_rate")}, "Fraction")
    histograms(report, output, labels)
    occupancy_figures(rows, output, labels)
    storage = [(value.get((a, "frontend:predictor_storage_bits")), value.get((a, "ipc")), labels.get(a, a))
               for a in archs]
    storage = [item for item in storage if item[0] is not None and item[1] is not None]
    if len(storage) > 1:
        plt = _pyplot()
        fig, ax = plt.subplots(figsize=(7, 4.4))
        for bits, ipc, name in storage:
            ax.scatter(bits / 8192, ipc)
            ax.annotate(name, (bits / 8192, ipc), fontsize=7, xytext=(3, 3), textcoords="offset points")
        ax.set_xlabel("Modeled predictor storage (KiB)")
        ax.set_ylabel("Instructions per cycle")
        ax.grid(alpha=.2)
        _save(fig, output / "branch_prediction" / "ipc_vs_predictor_storage.png")
    ideal = [a for a in archs if any(word in a for word in IDEAL_WORDS)]
    if ideal:
        bars(output / "ideal_comparison" / "ipc.png", "Realistic versus idealized structures", names,
             {"IPC": get("ipc"), "MPKI": get("frontend:mpki")}, "Value")


def histograms(report: dict, output: Path, labels: dict) -> None:
    """Distributions from the raw runs (TAGE providers, return sources, occupancy histograms)."""
    runs = [run for run in report["runs"] if run["point"] == report["points"][0]["point"]
            and run.get("smt_mode", "disabled") == "disabled" and "frontend" in run]
    if not runs:
        return
    merged: dict[str, dict[str, Counter]] = defaultdict(lambda: defaultdict(Counter))
    allocations: dict[str, Counter] = defaultdict(Counter)
    for run in runs:
        arch = labels.get(run["architecture"], run["architecture"])
        for name in ("tage_provider", "return_target_source", "tage_useful", *LATENCY_HISTOGRAMS):
            merged[name][arch].update(run["histograms"].get(name, {}))
        for key, count in run["counts"].items():
            if key.startswith("tage_allocations:"):
                allocations[arch][key.partition(":")[2]] += count
    for name, title in (("tage_provider", "TAGE provider distribution"),
                        ("return_target_source", "Return target source"), ("tage_useful", "TAGE usefulness counters")):
        data = merged.get(name)
        if not data:
            continue
        keys = sorted({k for counter in data.values() for k in counter}, key=str)
        archs = list(data)
        bars(output / ("ras" if name == "return_target_source" else "branch_prediction") / f"{name}.png", title,
             archs, {str(k): [data[a][k] for a in archs] for k in keys}, "Count", stacked=True)
    latencies = {name: merged[name] for name in LATENCY_HISTOGRAMS if merged.get(name)}
    if latencies:
        plt = _pyplot()
        fig, axes = plt.subplots(1, len(latencies), figsize=(5 * len(latencies), 3.6), squeeze=False)
        for ax, (name, data) in zip(axes.flat, latencies.items()):
            for arch, counter in data.items():
                points = sorted((int(k), v) for k, v in counter.items())
                ax.step([k for k, _ in points], [v for _, v in points], where="mid", label=arch)
            ax.set_title(name.replace("_", " "), fontsize=9)
            ax.set_xlabel("Cycles")
            ax.legend(fontsize=6)
        _save(fig, output / "recovery" / "latency_distributions.png")
    if allocations:
        archs = list(allocations)
        tables = sorted({t for counter in allocations.values() for t in counter})
        bars(output / "branch_prediction" / "tage_allocations.png", "TAGE allocations per table", archs,
             {t: [allocations[a][t] for a in archs] for t in tables}, "Allocations")
    run = runs[0]
    occupancy = {name: record for name, record in run.get("occupancy", {}).items() if record["histogram"]}
    if occupancy:
        plt = _pyplot()
        names = list(occupancy)
        columns = 4
        fig, axes = plt.subplots((len(names) + columns - 1) // columns, columns,
                                 figsize=(14, 2.3 * ((len(names) + columns - 1) // columns)), squeeze=False)
        for ax, name in zip(axes.flat, names):
            histogram = {int(k): v for k, v in occupancy[name]["histogram"].items()}
            ax.bar(list(histogram), list(histogram.values()), width=1)
            ax.set_title(name, fontsize=8)
            ax.tick_params(labelsize=6)
        for ax in list(axes.flat)[len(names):]:
            ax.axis("off")
        fig.suptitle(f"Occupancy histograms (cycles) · {labels.get(run['architecture'], run['architecture'])} · seed {run['seed']}",
                     fontsize=10)
        _save(fig, output / "queue_occupancy" / "histograms.png")


def occupancy_figures(rows: list[dict], output: Path, labels: dict, *, group: str = "architecture") -> None:
    data: dict[str, dict] = defaultdict(dict)
    for row in rows:
        metric = row["metric"]
        if not metric.startswith("occupancy:"):
            continue
        structure, _, field = metric.removeprefix("occupancy:").rpartition(":")
        data[field].setdefault((structure, labels.get(row[group], row[group])), []).append(row["mean"])
    if not data:
        return
    structures = sorted({s for s, _ in data["mean"]})
    columns = list(dict.fromkeys(c for _, c in data["mean"]))
    for field, name, title, fmt in (
            ("mean", "mean.png", "Average occupancy (entries, time weighted)", "{:.1f}"),
            ("mean_percent", "utilization.png", "Average occupancy (% of capacity)", "{:.0f}"),
            ("peak", "peak.png", "Maximum occupancy (entries)", "{:.0f}"),
            ("empty_percent", "empty_percent.png", "Empty cycles (%)", "{:.0f}"),
            ("full_percent", "full_percent.png", "Full cycles (%)", "{:.0f}"),
            ("allocation_failures", "allocation_failures.png", "Allocation failures", "{:.0f}")):
        values = {key: fmean(v) for key, v in data.get(field, {}).items()}
        rows_present = [s for s in structures if any((s, c) in values for c in columns)]
        heatmap(output / "queue_occupancy" / name, title, rows_present, columns, values, fmt)


def plot_frontend_suite(report: dict, output: Path, labels: dict) -> None:
    rows = [row for row in report.get("metrics", ()) if row.get("smt_mode", "disabled") == "disabled"
            and row.get("isolated_thread") is None and row.get("point", 0) == 0]
    if not any(row["metric"].startswith("frontend:") for row in rows):
        return
    benchmarks = list(dict.fromkeys(row["benchmark"] for row in rows))
    archs = list(dict.fromkeys(row["architecture"] for row in rows))
    columns = [labels.get(a, a) for a in archs]
    value = {(row["benchmark"], labels.get(row["architecture"], row["architecture"]), row["metric"]): row["mean"]
             for row in rows}

    def grid(metric: str) -> dict:
        return {(b, c): value[b, c, metric] for b in benchmarks for c in columns if (b, c, metric) in value}

    for directory, metric, title, fmt in (
            ("frontend", "ipc", "Committed IPC by benchmark and architecture", "{:.2f}"),
            ("frontend", "frontend:fetch_ipc", "Fetch IPC", "{:.2f}"),
            ("frontend", "frontend:frontend_starvation", "Frontend starvation (fraction of cycles)", "{:.2f}"),
            ("branch_prediction", "frontend:mpki", "Backend misprediction MPKI", "{:.1f}"),
            ("branch_prediction", "frontend:conditional_mpki", "Conditional-branch MPKI", "{:.1f}"),
            ("branch_prediction", "frontend:final_accuracy", "Final prediction accuracy", "{:.3f}"),
            ("ras", "frontend:return_accuracy", "Return target accuracy", "{:.3f}"),
            ("ras", "frontend:ras_coverage", "RAS prediction coverage", "{:.2f}"),
            ("ras", "frontend:return_mpki", "Return-target MPKI", "{:.2f}"),
            ("training", "frontend:btq_drop_rate", "Dropped training opportunities (fraction)", "{:.2f}"),
            ("memory", "frontend:icache_hit_rate", "Instruction cache hit rate", "{:.3f}"),
            ("recovery", "recovery_to_first_correct_issue", "Recovery to first correct issue (cycles)", "{:.1f}")):
        heatmap(output / directory / (metric.replace("frontend:", "").replace(":", "_") + "_heatmap.png"),
                title, benchmarks, columns, grid(metric), fmt)
    for stage in STAGES:
        heatmap(output / "branch_prediction" / f"{stage}_accuracy_heatmap.png",
                f"{stage.upper()} stage accuracy", benchmarks, columns, grid(f"frontend:{stage}_accuracy"), "{:.3f}")
    occupancy_figures(rows, output, labels)
    ideal = [c for a, c in zip(archs, columns) if any(word in a for word in IDEAL_WORDS)]
    if ideal:
        reference = {}
        for b in benchmarks:
            for a, c in zip(archs, columns):
                base = next((labels.get(o, o) for o in archs if o.partition("@")[0] == a.partition("@")[0]), c)
                if (b, base, "ipc") in value and (b, c, "ipc") in value and value[b, base, "ipc"]:
                    reference[b, c] = value[b, c, "ipc"] / value[b, base, "ipc"]
        heatmap(output / "ideal_comparison" / "ipc_ratio_heatmap.png",
                "IPC relative to the first variant of the same backend", benchmarks, columns, reference, "{:.2f}",
                cmap="RdBu")
