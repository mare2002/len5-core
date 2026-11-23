"""Suite-level figures and overview drawn from the saved ordered-pair statistics."""
from pathlib import Path
from statistics import fmean, geometric_mean

from .analysis import IDEAL, IDEAL_OOO, PAIRS, UNIFIED_PAIRS, atomic_output
from .config import BLOCK_ARCHITECTURES, IDEAL_ARCHITECTURES, UNIFIED_ARCHITECTURES, UNIFIED_SUFFIX
from .matrix import PERCENT_METRICS, RATIO_METRICS, color_limits, heatmap_label
from .plots import COLOR, LABEL, SHORT


COMPARISONS = tuple((arch, RATIO_METRICS[baseline], f"{SHORT[arch]} / {SHORT[baseline]}")
                    for arch, baseline in PAIRS)
STORAGE_FIELDS = {
    "ROB": ("rob_bits",),
    "Register files": ("register_file_bits",),
    "Reservation stations": ("reservation_station_bits", "rs_thread_tag_bits"),
    "Load / store buffers": ("load_buffer_bits", "load_thread_tag_bits", "store_buffer_bits"),
    "Block maps / checkpoints": ("mapping_bits", "ownership_bits", "block_thread_tag_bits", "checkpoint_bits"),
    "CDB / control": ("cdb_result_buffer_bits", "cdb_thread_tag_bits", "additional_control_bits"),
    "Wrapper result buffers": ("unified_completion_buffer_bits",),
}


def pair_values(matrix: dict, arch: str, view: str, metric: str) -> dict[tuple, float]:
    """Each observed ordered pair contributes one mean, irrespective of its seed count."""
    values = {}
    for pair in matrix["pairs"]:
        stats = pair["architectures"].get(arch, {}).get(view, {})
        if metric in stats:
            values[tuple(pair["names"])] = stats[metric]["mean"]
    return values


def _comparisons(matrix, view, *, architectures=LABEL):
    return [(label, values) for arch, metric, label in COMPARISONS
            if arch in architectures
            and (values := pair_values(matrix, arch, view, metric))]


def _storage(report):
    result = {}
    for run in report["runs"]:
        storage = run.get("storage", {})
        if storage.get("total_bits"):
            result[run["architecture"], run.get("smt_mode", "disabled")] = storage
    return result


def _primary_view(report):
    return "smt" if report.get("benchmark_pairs") or any(
        r.get("smt_mode") == "enabled" for r in report["runs"]) else "isolated"


def write_suite_summary(report: dict, matrix: dict, output: Path, *, dashboard: bool, raw_prefix: str = "",
                       figure_dir: Path | None = None) -> None:
    view = _primary_view(report)
    runs = report["runs"]
    names = matrix["names"]
    pair_count = len({tuple(p["names"]) for p in matrix["pairs"]}) if view == "smt" else 0
    modes = (["disabled", "enabled"] if report.get("smt_mode") == "both" else
             [report["smt_mode"]] if "smt_mode" in report else sorted({r.get("smt_mode", "disabled") for r in runs}))
    archs = report.get("architectures") or [a for a in LABEL if any(r["architecture"] == a for r in runs)]
    seeds = report.get("seeds") or sorted({r["seed"] for r in runs})
    policies = sorted({r.get("measurement_policy", "unspecified") for r in runs if r.get("smt_mode") == "enabled"})
    lines = [f"# {report['suite']} benchmark results", "",
             f"{', '.join(LABEL[a] for a in archs)}. SMT {', '.join(modes)}.",
             "", f"- Benchmarks: {len(names)}",
             f"- Ordered workload pairs: {pair_count}",
             f"- Random seeds: {len(seeds)}",
             f"- Measurement: {', '.join(policies) or report.get('measurement_policy', 'one isolated iteration')}"]
    counts = report.get("execution")
    if counts:
        lines.append(f"- Experiments: {counts['completed']} completed, {counts['failed']} failed "
                     f"of {counts['scheduled']} scheduled (including calibration and isolated runs).")
    else:
        lines.append(f"- Saved result rows: {len(runs)}. This report does not record a scheduler failure count.")
    if "reference_completion" in policies:
        lines.append("\nThe reference thread completes one iteration. IPC includes both threads’ committed work through that cycle.")
    lines.extend(["", "## Architectural performance", "",
                  "Ratios above 1 indicate higher IPC in the numerator. Each observed ordered pair has equal weight."])
    for mode, title in (("smt", "SMT"), ("isolated", "Isolated")):
        comps = _comparisons(matrix, mode)
        if comps:
            lines.extend(["", f"### {title}", "", "| IPC ratio | Pairs | Geometric mean |",
                          "|---|---:|---:|"])
            for name, values in comps:
                lines.append(f"| {name} | {len(values)} | {geometric_mean(values.values()):.4f}× |")
    speeds = [(a, pair_values(matrix, a, "smt", "weighted_speedup")) for a in archs]
    if any(values for _, values in speeds):
        lines.extend(["", "### SMT weighted speedup", "",
                      "| Architecture | Pairs | Mean weighted speedup |", "|---|---:|---:|"])
        lines.extend(f"| {LABEL[a]} | {len(v)} | {fmean(v.values()):.3f} |" for a, v in speeds if v)
    ordered = sorted((value, pair, comparison) for comparison, values in _comparisons(matrix, view)
                     for pair, value in values.items())
    if ordered:
        lines.extend(["", f"### Largest changes ({view.upper()})", ""])
        for label, rows in (("Improvements", [p for p in reversed(ordered) if p[0] > 1][:10]),
                            ("Regressions", [p for p in ordered if p[0] < 1][:10])):
            lines.extend([f"**{label}**", ""])
            if rows:
                lines.extend(["| Thread 0 | Thread 1 | Comparison | IPC change |", "|---|---|---|---:|"])
                lines.extend(f"| {a} | {b} | {comparison} | {100*(value-1):+.2f}% |"
                             for value, (a, b), comparison in rows)
            else:
                lines.append("No observed pairs in this group.")
            lines.append("")
    storage = _storage(report)
    if storage:
        lines.extend(["", "## Modeled hardware storage", "",
                      "| Architecture | SMT | Bits |", "|---|---|---:|"])
        lines.extend(f"| {LABEL[a]} | {m} | {storage[a, m]['total_bits']:,} |"
                     for a in archs for m in modes if (a, m) in storage)
    if any(r["architecture"] in IDEAL_ARCHITECTURES and r.get("storage", {}).get("total_bits") is None for r in runs):
        lines.append("\nIdeal baselines with unbounded structures have no finite hardware storage estimate.")
    lines.extend(["", "## Results", ""])
    if dashboard:
        lines.append("- [Interactive workload matrix](dashboard.html)")
        for path in sorted((figure_dir or output / "plots").rglob("*.png")):
            lines.append(f"- [{path.stem.replace('_', ' ').capitalize()}]({path.relative_to(output).as_posix()})")
    prefix = raw_prefix.rstrip("/") + "/" if raw_prefix else ""
    lines.extend([f"- [Per-seed results]({prefix}per_seed_results.csv)", f"- [Aggregate metrics]({prefix}summary.csv)",
                  f"- [Complete suite data]({prefix}summary.json)", f"- [Individual runs]({prefix}individual_benchmarks/)", ""])
    with atomic_output(output / "summary.md") as stream:
        stream.write("\n".join(lines))


def plot_suite_overview(report: dict, matrix: dict, plot_dir: Path, *, detailed: bool = False) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import Normalize, TwoSlopeNorm
    from matplotlib.ticker import PercentFormatter

    names = matrix["names"]
    view = _primary_view(report)
    view_label = "SMT" if view == "smt" else "Isolated"
    archs = [a for a in LABEL if pair_values(matrix, a, view, "ipc")]

    def save(fig, relative, *, vector=False):
        stem = plot_dir / relative
        stem.parent.mkdir(parents=True, exist_ok=True)
        try:
            fig.savefig(stem.with_suffix(".png"), dpi=180, bbox_inches="tight")
            if vector:
                fig.savefig(stem.with_suffix(".pdf"), bbox_inches="tight")
        finally:
            plt.close(fig)

    def heatmap(series, title, label, relative, *, metric, ratio=False, vector=False, limits=None):
        series = [(label, vals) for label, vals in series if vals]
        if not series:
            return
        if limits is None:
            limits = color_limits([v for _, vals in series for v in vals.values()], centered=ratio)
        if len(series) > 5:
            for start in range(0, len(series), 5):
                heatmap(series[start:start + 5], title, label, f"{relative}_{start // 5 + 1}",
                        metric=metric, ratio=ratio, vector=vector, limits=limits)
            return
        norm = TwoSlopeNorm(1., *limits) if ratio else Normalize(*limits)
        cmap = matplotlib.colormaps["RdBu" if ratio else "viridis"].with_extremes(bad="#dddede")
        side = max(3.6, .44 * len(names))
        fig, axes = plt.subplots(1, len(series), squeeze=False, layout="constrained",
                                 figsize=(side * len(series) + 1.6, side + 1.8), sharey=True)
        for ax, (heading, vals) in zip(axes[0], series):
            grid = [[vals.get((a, b), float("nan")) for b in names] for a in names]
            img = ax.imshow(grid, cmap=cmap, norm=norm, interpolation="nearest")
            for y, a in enumerate(names):
                for x, b in enumerate(names):
                    value = vals.get((a, b))
                    rgb = cmap(norm(grid[y][x]))[:3]
                    linear = [v / 12.92 if v <= .04045 else ((v + .055) / 1.055) ** 2.4 for v in rgb]
                    brightness = sum(v * w for v, w in zip(linear, (.2126, .7152, .0722)))
                    ax.text(x, y, heatmap_label(value, metric), ha="center", va="center",
                            color="black" if brightness > .179 else "white", fontsize=8)
            ax.set_xticks(range(len(names)), names, rotation=90, fontsize=7)
            ax.set_yticks(range(len(names)), names, fontsize=7)
            # Outline the same-workload diagonal without obscuring the cell value.
            for i in range(len(names)):
                ax.add_patch(plt.Rectangle((i-.47, i-.47), .94, .94, fill=False, lw=.5, edgecolor="#444"))
            ax.set_title(heading, fontsize=10)
            ax.set_xlabel("Thread 1 benchmark")
        axes[0][0].set_ylabel("Thread 0 benchmark")
        scale_format = PercentFormatter(1) if metric in PERCENT_METRICS else None
        fig.colorbar(img, ax=list(axes[0]), shrink=.78, label=label, format=scale_format)
        fig.suptitle(title + "\nGray = missing  ·  Outline = identical workloads", fontsize=12)
        save(fig, relative, vector=vector)

    ratios = _comparisons(matrix, view)
    if ratios and view == "smt":
        bounded = [arch for arch in LABEL if arch not in (*IDEAL_ARCHITECTURES, *UNIFIED_ARCHITECTURES)]
        heatmap(_comparisons(matrix, view, architectures=bounded), "Throughput by ordered workload pair", "Paired IPC ratio",
                "speedup/architecture_ratios", metric="vs_normal", ratio=True, vector=True)
        for arch in (IDEAL, IDEAL_OOO):
            heatmap(_comparisons(matrix, view, architectures=(arch,)), f"{LABEL[arch]} throughput by workload pair",
                    "Paired IPC ratio", f"speedup/{arch}_ratios", metric="vs_normal", ratio=True, vector=True)
    heatmap([(f"{SHORT[a]} / {SHORT[b]}", pair_values(matrix, a, view, RATIO_METRICS[b]))
             for a, b in UNIFIED_PAIRS], f"{view_label} unified versus separate integer RS",
            "Paired IPC ratio", "speedup/unified_vs_separate", metric="vs_normal", ratio=True)
    heatmap([(title, pair_values(matrix, arch, view, metric)) for arch, metric, title in COMPARISONS
             if metric.endswith(UNIFIED_SUFFIX)], f"{view_label} commit policies with unified integer RS",
            "Paired IPC ratio", "speedup/unified_commit_ratios", metric="vs_normal", ratio=True)
    if view == "smt":
        heatmap([(SHORT[a], pair_values(matrix, a, view, "weighted_speedup")) for a in archs],
                "SMT weighted speedup", "Sum of thread IPC / isolated IPC", "performance/weighted_speedup",
                metric="weighted_speedup", vector=True)
        for metric, title in (("ipc", "SMT aggregate IPC"), ("thread_0_ipc", "SMT thread 0 IPC"),
                              ("thread_1_ipc", "SMT thread 1 IPC")):
            heatmap([(SHORT[a], pair_values(matrix, a, view, metric)) for a in archs],
                    title, "Instructions per cycle", f"performance/{metric}", metric=metric)
    isolated_title = "Serial pair IPC from isolated runs" if matrix["paired"] else "Single-thread IPC"
    heatmap([(SHORT[a], pair_values(matrix, a, "isolated", "ipc")) for a in LABEL],
            isolated_title, "Instructions per cycle", "performance/isolated_ipc", metric="ipc")
    if not archs:
        return

    if ratios:
        fig, ax = plt.subplots(figsize=(7, 4), layout="constrained")
        for name, values in ratios:
            x = sorted(values.values())
            ax.step([x[0], *x], [0, *[i/len(x) for i in range(1, len(x)+1)]], where="post", label=name)
        ax.axvline(1, color=".35", ls="--", lw=1)
        ax.yaxis.set_major_formatter(PercentFormatter(1))
        ax.set(xlabel="Paired IPC ratio  (below 1 = regression)", ylabel="Cumulative share of pairs",
               title=f"{view_label} architectural improvements")
        if len(ratios) > 10:
            ax.legend(fontsize=7, ncols=3, loc="upper center", bbox_to_anchor=(.5, -.22))
        else:
            ax.legend()
        save(fig, "speedup/improvement_distribution")

        fig, ax = plt.subplots(figsize=(7, max(4.6 if IDEAL_OOO in archs else 3.5,
                                               len(ratios) * .24 + 1)), layout="constrained")
        for offset, mode, marker in [(-.10, "isolated", "o"), (.10, "smt", "s")]:
            comps = dict(_comparisons(matrix, mode))
            indices = [i for i, (_, _, label) in enumerate(COMPARISONS) if label in comps]
            if indices:
                ax.scatter([geometric_mean(comps[COMPARISONS[i][2]].values()) for i in indices],
                           [i+offset for i in indices], label=mode.upper(), marker=marker)
        ax.axvline(1, color=".35", ls="--", lw=1)
        shown = sorted({i for mode in ("isolated", "smt") for i, (_, _, label) in enumerate(COMPARISONS)
                        if label in dict(_comparisons(matrix, mode))})
        ax.set_yticks(shown, [COMPARISONS[i][2] for i in shown])
        ax.set(xlabel="Geometric mean paired IPC ratio", title="Architectural performance across workload pairs")
        ax.legend()
        save(fig, "speedup/geomean_improvement")

    def pressure(metrics, architectures, title, path):
        points = [(i, j, fmean(v.values())) for i, (key, _) in enumerate(metrics)
                  for j, a in enumerate(architectures) if (v := pair_values(matrix, a, view, key))]
        if points:
            fig, ax = plt.subplots(figsize=(7, 3.6), layout="constrained")
            width = .8/len(architectures)
            for j, a in enumerate(architectures):
                xy = [(i+width*(j-(len(architectures)-1)/2), v) for i, k, v in points if k == j]
                if xy:
                    ax.bar([x for x, _ in xy], [y for _, y in xy], width, color=COLOR[a], label=SHORT[a])
            ax.set_xticks(range(len(metrics)), [label for _, label in metrics])
            ax.yaxis.set_major_formatter(PercentFormatter(1))
            ax.set(ylabel="Mean across observed pairs", title=title)
            ax.set_ylim(0, max(.05, ax.get_ylim()[1]))
            ax.legend()
            save(fig, path)

    pressure([("retire_blocked", "Pending ROB work,\nno retirement"), ("cdb_contention", "CDB requests\nexceed bandwidth")],
             archs, f"{view_label} backend stalls as a share of core cycles", "rob/backend_bottlenecks")
    if block_archs := [arch for arch in archs if arch in BLOCK_ARCHITECTURES]:
        pressure([("merge_utilization", "Merge engine"), ("flush_utilization", "Flush engine")], block_archs,
                 "Basic-block bandwidth used", "basic_blocks/engine_utilization")

    storage = _storage(report)
    variants = [(a, mode) for a in archs for mode in ("disabled", "enabled") if (a, mode) in storage]
    if variants:
        fig, ax = plt.subplots(figsize=(8, max(4.4, len(variants) * .27 + 1.4)), layout="constrained")
        left = [0.] * len(variants)
        for label, keys in STORAGE_FIELDS.items():
            if label == "Wrapper result buffers" and not any(keys[0] in storage[v] for v in variants):
                continue
            bits = [sum(storage[v].get(key, 0) for key in keys) / 1024 for v in variants]
            ax.barh(range(len(variants)), bits, left=left, label=label)
            left = [x+y for x,y in zip(left,bits)]
        ax.set_yticks(range(len(variants)), [SHORT[a]+(" · SMT" if m == "enabled" else " · isolated") for a,m in variants])
        ax.set(xlabel="Modeled storage (Kibit)", title="Hardware storage breakdown")
        ax.legend(ncols=2, fontsize=8, loc="upper left", bbox_to_anchor=(0, -.18))
        save(fig, "storage/breakdown")

        fig, ax = plt.subplots(figsize=(7.2, 4.2), layout="constrained")
        for m, data_view in (("disabled", "isolated"), ("enabled", "smt")):
            series = {a: pair_values(matrix, a, data_view, "ipc") for a in archs if (a, m) in storage}
            common = set.intersection(*(set(s) for s in series.values())) if series else set()
            if common:
                for a, values in series.items():
                    ax.scatter(storage[a, m]["total_bits"]/1024, geometric_mean(values[p] for p in sorted(common)),
                               color=COLOR[a], marker="s" if m == "enabled" else "o",
                               label=f"{SHORT[a]} · {data_view}")
        if ax.collections:
            ax.set(xlabel="Modeled storage (Kibit)", ylabel="Geometric mean IPC",
                   title="Throughput and storage across common workload pairs")
            ax.legend(fontsize=8, ncols=2)
            save(fig, "storage/performance_vs_storage")
        else:
            plt.close(fig)
    if detailed and view == "smt":
        for metric, title, unit, path in (("rob_occupancy", "ROB pressure", "Mean occupied entries", "rob/occupancy"),
                                         ("cdb_utilization", "CDB utilization", "Broadcast capacity used", "cdb/utilization"),
                                         ("issue_utilization", "Execution issue utilization", "Issue capacity used", "execution_units/issue")):
            heatmap([(SHORT[a], pair_values(matrix, a, view, metric)) for a in archs],
                    title, unit, path, metric=metric, vector=True)
