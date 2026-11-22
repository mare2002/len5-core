from argparse import Namespace
import csv
import os
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock

from system_level.__main__ import ROOT, get_seeds
from system_level.analysis import BLOCKS, LEN5, NORMAL, experiment
from system_level.benchmarks import csr_free_window, list_benchmarks, select_benchmarks
from system_level.config import configure
from system_level.plots import COLOR, group_bars, plot_category
from system_level.results import (benchmark_summary, clean, inside, reports, reserve, save_benchmarks,
                                  save_experiment, simulation_dir)
from system_level.spike import read_spike


def temporary_build():
    build = ROOT / Path(os.environ.get("BUILD_DIR") or "build")
    parent = simulation_dir(build) / ".test-tmp"
    parent.mkdir(parents=True, exist_ok=True)
    return TemporaryDirectory(dir=parent)


class IntegrationTests(unittest.TestCase):
    def test_plot_categories(self):
        metrics = {"ipc": "performance", "new_metric": "performance", "peak:rob_occupancy": "rob",
                   "count:dispatch_stall:rs_full:alu": "reservation_stations",
                   "issue_utilization:alu": "execution_units", "count:cdb_contention_cycles": "cdb",
                   "cache_requests:l1": "memory", "registers_freed_per_merge": "basic_blocks",
                   "registers_freed_per_flushed_block": "recovery", "ipc_vs_storage": "storage",
                   "storage:total_bits": "storage", "ipc_speedup": "speedup", "geomean_speedup": "speedup"}
        for metric, category in metrics.items():
            with self.subTest(metric=metric):
                self.assertEqual(plot_category(metric), category)

    def test_paths_reservation_discovery_and_clean(self):
        with temporary_build() as temporary:
            build = Path(temporary)
            root = simulation_dir(build)
            other = build / "firmware.elf"
            other.touch()
            first = reserve(root, "single", "workload")
            second = reserve(root, "single", "workload")
            self.assertEqual((first.name, second.name), ("workload", "workload-2"))
            custom = reserve(root, "single", "unused", root / "custom")
            report = custom / "statistics.json"
            report.touch()
            nested = first / "individual_benchmarks"
            nested.mkdir()
            (nested / "summary.json").touch()
            self.assertEqual(reports(root), [report])
            with self.assertRaises(ValueError):
                reserve(root, "single", "../escape")
            with self.assertRaises(ValueError):
                inside(root, other)
            with self.assertRaises(FileExistsError):
                reserve(root, "single", "unused", first)
            clean(root)
            self.assertFalse(root.exists())
            self.assertTrue(other.exists())
            root.symlink_to(build, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symlink"):
                simulation_dir(build)
            self.assertTrue(other.exists())

    def test_seed_count_defaults_and_explicit_selection(self):
        options = Namespace(command="benchmarks", seeds=None, make_seeds=None)
        config = configure()
        self.assertEqual(get_seeds(options, config), [42, 43, 44])
        options.make_seeds = "30"
        self.assertEqual(get_seeds(options, config), list(range(42, 72)))
        options.make_seeds = "2 5 11"
        self.assertEqual(get_seeds(options, config), [2, 5, 11])
        options.make_seeds = "2 2"
        with self.assertRaisesRegex(ValueError, "unique"):
            get_seeds(options, config)
        self.assertIn("crc32", list_benchmarks(ROOT, "embench"))
        self.assertEqual(select_benchmarks(ROOT, "embench", "matmult-int crc32 matmult-int"),
                         ["matmult-int", "crc32"])
        with self.assertRaisesRegex(ValueError, "unavailable"):
            select_benchmarks(ROOT, "embench", "nonexistent")

    def test_csr_window_selects_contiguous_records_without_hiding_parser_error(self):
        with temporary_build() as temporary:
            trace = Path(temporary) / "spike.log"
            trace.write_text("".join(f"core 0: 3 0x{pc:x} (0x{word:08x})\n"
                                     for pc, word in ((0x100, 0x73), (0x200, 0x13), (0x204, 0x202773),
                                                      (0x208, 0x13), (0x20c, 0x13), (0x210, 0x6f))))
            with self.assertRaisesRegex(ValueError, "unsupported"):
                read_spike(trace, start_pc=0x200, stop_at_self_jump=True)
            region = csr_free_window(trace, 0x200, 0, 8)
            self.assertEqual(region["excluded_csrs"], [{"index": 2, "pc": 0x204, "encoding": 0x202773}])
            self.assertEqual((region["instructions"], region["trace_skip"], region["trace_start_pc"]), (2, 3, 0x208))
            loaded = read_spike(trace, skip=region["trace_skip"], limit=region["instructions"],
                                start_pc=region["trace_start_pc"], stop_at_self_jump=True)
            self.assertEqual([insn.pc for insn in loaded], [0x208, 0x20c])

    def test_benchmark_summary_and_grouped_bars(self):
        config = configure({"workload": {"instructions": 20}})
        first = experiment(config, [3, 5])
        second = experiment(config, [3, 5])
        for r in first["runs"]:
            r["ipc"] = {NORMAL: 1.0, LEN5: 1.25, BLOCKS: 2.0}[r["architecture"]]
        for r in second["runs"]:
            r["ipc"] = {NORMAL: 1.0, LEN5: 2.0, BLOCKS: 4.5}[r["architecture"]]

        summary = benchmark_summary("embench", {"crc32": first, "matmult-int": second})
        self.assertEqual(summary["benchmarks"], ["crc32", "matmult-int"])
        self.assertEqual(len(summary["runs"]), 12)
        self.assertAlmostEqual(next(row["mean"] for row in summary["geomean_speedup"]
                                    if row["architecture"] == BLOCKS and row["baseline"] == NORMAL), 3)
        for row in summary["metrics"]:
            if row["metric"] == "block_occupancy":
                self.assertEqual(row["architecture"], BLOCKS)

        ax = Mock()
        rows = [row for row in summary["metrics"] if row["metric"] == "ipc"]
        group_bars(ax, summary["benchmarks"], rows, "benchmark")
        bars = ax.bar.call_args_list
        self.assertEqual([call.kwargs["color"] for call in bars], list(COLOR.values()))
        self.assertEqual([call.args[1] for call in bars], [[1, 1], [1.25, 2], [2, 4.5]])
        self.assertLess(bars[0].args[0][0], bars[1].args[0][0])
        self.assertLess(bars[1].args[0][0], bars[2].args[0][0])

        with temporary_build() as temporary:
            directory = Path(temporary)
            save_benchmarks(summary, directory)
            save_experiment(first, directory / "individual", sweep=False)
            with (directory / "per_seed_results.csv").open() as stream:
                self.assertEqual(len(list(csv.DictReader(stream))), 12)
            self.assertTrue((directory / "individual/config.yaml").is_file())
            self.assertTrue((directory / "individual/comparison.csv").is_file())
