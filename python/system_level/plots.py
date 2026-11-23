"""Headless metric comparisons drawn from saved results."""

from collections import defaultdict
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import re

from .analysis import BLOCKS, IDEAL, IDEAL_OOO, LEN5, NORMAL, PAIRS
from .config import BLOCK_ARCHITECTURES, UNIFIED_SUFFIX
from .results import metric_rows

LABEL = {NORMAL: "Normal OoO", LEN5: "LEN5 OoO commit", BLOCKS: "Basic-block OoO commit",
         IDEAL: "Ideal Commit", IDEAL_OOO: "Ideal Block Commit"}
COLOR = {NORMAL: "#51687c", LEN5: "#148274", BLOCKS: "#b44e2b", IDEAL: "#714aa5", IDEAL_OOO: "#2265ad"}
SHORT = {NORMAL: "Normal", LEN5: "LEN5", BLOCKS: "Basic-block", IDEAL: "Ideal", IDEAL_OOO: "Ideal Block"}
LABEL.update({key + UNIFIED_SUFFIX: value + " (unified RS)" for key, value in LABEL.items()})
SHORT.update({key + UNIFIED_SUFFIX: value + " Unified" for key, value in SHORT.items()})
COLOR.update(dict(zip((key + UNIFIED_SUFFIX for key in COLOR),
                      ("#304c67", "#005448", "#783a14", "#482477", "#103f79"))))
METRIC_LABELS = {"ipc": "Instructions per cycle", "cycles": "Cycles", "committed": "Committed instructions",
                 "rob_occupancy": "Mean occupied ROB entries", "cdb_utilization": "CDB utilization (fraction)",
                 "smt_throughput_improvement": "SMT throughput improvement (%)",
                 "weighted_speedup": "Weighted speedup (×)"}
PLOT_CATEGORIES = {
    "rob": ("rob_", "retire_", "retirement_", "out_of_order_commits", "speculative_window",
            "dispatch_stall:rob_"),
    "reservation_stations": ("rs_", "dependency_", "dispatch_stall:rs_", "issue_blocked:rs_", "unified_"),
    "execution_units": ("execution_lane_", "lane_utilization:", "issue_utilization:", "issues:",
                        "issue_blocked:execution_unit:", "wrapper_", "issue_blocked:wrapper_",
                        "issue_blocked:completion_buffer:"),
    "cdb": ("cdb_", "broadcasts"),
    "memory": ("load_", "store_", "stores_", "cache_", "memory_", "mshr_", "outstanding_loads",
               "dispatch_stall:load_", "dispatch_stall:store_", "issue_blocked:store_",
               "issue_blocked:outstanding_", "issue_blocked:mshr_"),
    "basic_blocks": ("block_occupancy", "block_groups_", "blocks_created", "merge_", "merges",
                     "physical_", "integer_prf_", "fp_prf_", "register_pressure_", "registers_freed_per_merge",
                     "dispatch_stall:block_capacity", "dispatch_stall:integer_prf", "dispatch_stall:fp_prf"),
    "recovery": ("mispredictions", "frontend_recovery_", "recovery_", "flush", "squashed_",
                 "block_reclamation_", "blocks_preserved", "younger_blocks_", "merged_groups_restored",
                 "registers_freed_per_flushed_block", "dispatch_stall:frontend_redirect",
                 "dispatch_stall_reclamation", "dispatch_stall_with_reclaim"),
    "storage": ("storage:", "ipc_vs_storage"),
    "speedup": ("ipc_speedup", "geomean_speedup", "smt_throughput_improvement", "weighted_speedup", "slowdown"),
}


def axis_name(path: str) -> str:
    return path.replace("basic_block.registers.integer_physical+basic_block.registers.fp_physical",
                        "physical registers per bank").replace("_", " ").replace(".", " / ")


def metric_label(metric: str) -> str:
    if metric.startswith("thread_"):
        thread, _, field = metric.partition(":")
        return f"Thread {thread[-1]} · {metric_label(field)}"
    if metric in METRIC_LABELS:
        return METRIC_LABELS[metric]
    return metric.replace(":", " · ").replace("_", " ").capitalize()


def filename(metric: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_]+", "_", metric)


def plot_category(metric: str) -> str:
    name = re.sub(r"^thread_[01]:", "", metric).removeprefix("count:").removeprefix("peak:")
    return next((category for category, prefixes in PLOT_CATEGORIES.items()
                 if name.startswith(prefixes)), "performance")


def errors(rows: list[dict]) -> list[list[float]]:
    return [[max(0., row["mean"] - row["ci_low"]) if row["ci_low"] is not None else 0 for row in rows],
            [max(0., row["ci_high"] - row["mean"]) if row["ci_high"] is not None else 0 for row in rows]]


def label_for(architecture: str, smt_mode: str, both: bool) -> str:
    suffix = " · SMT" if smt_mode == "enabled" else " · 1 thread" if both else ""
    return LABEL[architecture] + suffix


def group_bars(ax, categories: list[str], rows: list[dict], category: str,
               paired: bool = False) -> None:
    by_series = defaultdict(dict)
    for row in rows:
        key = row["architecture"], row.get("baseline"), row.get("smt_mode", "disabled"), row.get("isolated_thread")
        by_series[key][row[category]] = row
    series = [(arch, baseline, mode, isolated)
              for arch, baseline in (PAIRS if paired else [(a, None) for a in LABEL])
              for mode in ("disabled", "enabled") for isolated in (None, 0, 1)
              if (arch, baseline, mode, isolated) in by_series]
    both = len({mode for _, _, mode, _ in series}) > 1
    width = .8 / len(series)
    for offset, (architecture, baseline, mode, isolated) in enumerate(series):
        group = by_series[architecture, baseline, mode, isolated]
        present = [(i, group[name]) for i, name in enumerate(categories) if name in group]
        if not present:
            continue
        positions, data = zip(*present)
        x = [i + width * (offset - (len(series) - 1) / 2) for i in positions]
        label = label_for(architecture, mode, both)
        if baseline:
            label = label.replace(LABEL[architecture], f"{SHORT[architecture]} / {SHORT[baseline]}", 1)
        if isolated is not None:
            label += f" · T{isolated} alone"
        hatch = ("//" if mode == "enabled" else "") + (".." if paired and baseline == LEN5 else "")
        if isolated == 1:
            hatch += "\\\\"
        ax.bar(x, [row["mean"] for row in data], width=width, yerr=errors(data), capsize=2,
               color=COLOR[architecture], hatch=hatch or None, label=label)
    ax.set_xticks(range(len(categories)), categories, rotation=35 if len(categories) > 4 else 0,
                  ha="right" if len(categories) > 4 else "center")
    ax.legend(fontsize=8)


def sweep_lines(ax, report: dict, rows: list[dict], *, label_values: bool = False) -> None:
    axes = list(report["sweep"])
    series = defaultdict(list)
    for row in rows:
        arch = row["architecture"]
        other = []
        for axis in axes[1:]:
            value = row["parameters"][axis]
            if arch not in BLOCK_ARCHITECTURES and all(path.startswith("basic_block.") for path in axis.split("+")):
                if value != report["sweep"][axis][0]:
                    break
            else:
                other.append((axis, json.dumps(value)))
        else:
            series[arch, row.get("smt_mode", "disabled"), row.get("isolated_thread"), tuple(other)].append(row)
    styles = ("-", "--", ":", "-.")
    next_style = defaultdict(int)
    both = len({mode for _, mode, _, _ in series}) > 1
    for (architecture, mode, isolated, other), group in series.items():
        settings = [row["parameters"][axes[0]] for row in group]
        x = settings if all(type(value) in (int, float) for value in settings) else [
            json.dumps(value) for value in settings]
        name = label_for(architecture, mode, both)
        if isolated is not None:
            name += f" · T{isolated} alone"
        if other:
            name += " · " + ", ".join(f"{axis_name(axis)} = {value}" for axis, value in other)
        y = [row["mean"] for row in group]
        ax.errorbar(x, y, yerr=errors(group),
                    marker="s" if mode == "enabled" else "o", capsize=3,
                    label=name, color=COLOR[architecture], linestyle=styles[next_style[architecture] % len(styles)])
        if label_values:
            for position, ipc in zip(x, y):
                ax.annotate(f"{ipc:.2f}", (position, ipc), xytext=(0, 5), textcoords="offset points",
                            ha="center", fontsize=7, color=COLOR[architecture])
        next_style[architecture] += 1
    ax.set_xlabel(axis_name(axes[0]))
    ax.legend(fontsize=8)


ESSENTIAL = {"ipc", "cycles", "rob_occupancy", "cdb_utilization", "weighted_speedup",
             "merge_utilization", "flush_utilization"}
DIAGNOSTICS = {"speculative_window", "retirement_utilization", "issue_utilization", "block_occupancy",
               "load_buffer_occupancy", "store_buffer_occupancy", "cdb_wait", "thread_0:ipc", "thread_1:ipc"}


def plot_workload(report: dict, output: Path, detailed: bool) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.container import BarContainer

    def save(fig, ax, metric: str, ylabel: str) -> None:
        ax.set_ylabel(ylabel)
        ax.grid(axis="y", alpha=.2)
        ax.set_axisbelow(True)
        fig.tight_layout()
        path = output / plot_category(metric) / (filename(metric) + ".png")
        path.parent.mkdir(parents=True, exist_ok=True)
        fig.savefig(path, dpi=150)
        plt.close(fig)

    by_metric = defaultdict(list)
    selected = ESSENTIAL | DIAGNOSTICS if detailed else ESSENTIAL
    for row in metric_rows(report):
        if row["metric"] in selected:
            by_metric[row["metric"]].append(row)
    for metric, rows in by_metric.items():
        fig, ax = plt.subplots(figsize=(8, 4.7))
        if report["sweep"]:
            sweep_lines(ax, report, rows, label_values=metric == "ipc")
        elif any(row.get("smt_mode") == "enabled" or "isolated_thread" in row for row in rows):
            group_bars(ax, [""], [dict(row, run="") for row in rows], "run")
        else:
            rows = sorted(rows, key=lambda row: list(LABEL).index(row["architecture"]))
            archs = [row["architecture"] for row in rows]
            ax.bar([LABEL[a] for a in archs], [row["mean"] for row in rows],
                   color=[COLOR[a] for a in archs], yerr=errors(rows), capsize=4)
        if metric == "ipc" and not report["sweep"]:
            for bars in ax.containers:
                if isinstance(bars, BarContainer):
                    ax.bar_label(bars, fmt="%.2f", padding=3, fontsize=8)
            ax.margins(y=.15)
        save(fig, ax, metric, metric_label(metric))
    runs = report["runs"]
    modes = {run.get("smt_mode", "disabled") for run in runs}
    ipc = [row for row in report["ipc_summary"] if row["storage_bits"] is not None]
    if not ipc:
        return

    fig, ax = plt.subplots(figsize=(8, 4.7))
    for architecture in LABEL:
        for mode in ("disabled", "enabled"):
            rows = [row for row in ipc if row["architecture"] == architecture
                    and row.get("smt_mode", "disabled") == mode]
            if rows:
                ax.errorbar([row["storage_bits"] / 1024 for row in rows], [row["mean"] for row in rows],
                            yerr=errors(rows), fmt="s" if mode == "enabled" else "o", alpha=.8,
                            label=label_for(architecture, mode, len(modes) > 1),
                            color=COLOR[architecture], capsize=3)
    ax.set_xlabel("Modeled storage (Kibit)")
    ax.legend()
    save(fig, ax, "ipc_vs_storage", "Instructions per cycle")

    if "enabled" in modes:
        storage = {}
        for run in runs:
            if run["storage"]["total_bits"] is not None:
                storage.setdefault((run["architecture"], run.get("smt_mode", "disabled")), run["storage"])
        variants = [(arch, mode) for arch in LABEL for mode in ("disabled", "enabled") if (arch, mode) in storage]
        components = dict.fromkeys(key for variant in variants for key, value in storage[variant].items()
                                   if value and key.endswith("_bits") and key not in
                                   ("total_bits", "shared_block_mapping_ownership_bits"))
        fig, ax = plt.subplots(figsize=(10, 5.4))
        bottom = [0] * len(variants)
        for component in components:
            values = [storage[variant].get(component, 0) for variant in variants]
            bars = ax.bar(range(len(variants)), values, bottom=bottom, label=metric_label(component))
            for bar, (_, mode) in zip(bars, variants):
                if mode == "enabled":
                    bar.set_hatch("//")
            bottom = [old + value for old, value in zip(bottom, values)]
        ax.set_xticks(range(len(variants)), [label_for(a, m, len(modes) > 1) for a, m in variants],
                      rotation=25, ha="right")
        if report.get("sweep"):
            ax.set_title("Storage at the first sweep point for each architecture and mode")
        ax.legend(fontsize=7, ncol=3)
        assert all(height == storage[variant]["total_bits"] for variant, height in zip(variants, bottom))
        save(fig, ax, "storage:breakdown", "Modeled storage (bits)")

def plot(report: dict, output: Path, preset: str | None = None, *, raw_directory: Path | None = None) -> None:
    """Publish only complete renderings. Keep raw tables and logs during regeneration."""
    directory = output.parent
    directory.mkdir(parents=True, exist_ok=True)
    config = report if "suite" in report else report["points"][0]["config"]
    preset = preset or config.get("plotting", {}).get("preset", "essential")
    if preset not in ("essential", "detailed", "none"):
        raise ValueError(f"unknown plotting preset {preset!r}")
    if output.is_symlink():
        raise ValueError(f"refusing symlinked plots directory {output}")

    with TemporaryDirectory(dir=directory, prefix=".render-") as staging:
        stage = Path(staging)
        figure_dir = stage / output.name
        if "suite" in report:
            from .dashboard import write_dashboard
            from .matrix import build_matrix
            from .suite_figures import plot_suite_overview, write_suite_summary

            matrix = build_matrix(report)
            raw_prefix = os.path.relpath(raw_directory, directory) + "/" if raw_directory and raw_directory != directory else ""
            if preset != "none":
                write_dashboard(stage, matrix, raw_prefix=raw_prefix)
                plot_suite_overview(report, matrix, figure_dir, detailed=preset == "detailed")
            write_suite_summary(report, matrix, stage, dashboard=preset != "none", raw_prefix=raw_prefix,
                               figure_dir=figure_dir)
        elif preset != "none":
            plot_workload(report, figure_dir, preset == "detailed")

        files = {p.relative_to(stage) for p in stage.rglob("*") if p.is_file()}
        for name in files:
            destination = directory / name
            if destination.resolve() != directory.resolve() / name:
                raise ValueError(f"refusing symlinked report path {destination}")
        for name in files:
            destination = directory / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            (stage / name).replace(destination)
        for path in output.rglob("*"):
            if (path.suffix.lower() in (".png", ".svg", ".pdf") and path.is_file()
                    and path.relative_to(directory) not in files):
                path.unlink()
        for path in sorted(output.rglob("*"), reverse=True):
            if path.is_dir() and not path.is_symlink() and not any(path.iterdir()):
                path.rmdir()
        if preset == "none" and "suite" in report:
            (directory / "dashboard.html").unlink(missing_ok=True)
