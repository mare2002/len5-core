import unittest
from itertools import product
from pathlib import Path

from system_level.analysis import BLOCKS, LEN5, NORMAL
from system_level.config import configure
from system_level.matrix import build_matrix
from system_level.storage import estimate
from system_level.suite_figures import STORAGE_FIELDS, plot_suite_overview, write_suite_summary
from test_integration import temporary_build


class SuiteFiguresTests(unittest.TestCase):
    def test_hundred_pairs_have_one_set_of_overviews(self):
        names = [f"work-{i}" for i in range(10)]
        pairs = {f"{a} + {b}": [a, b] for a, b in product(names, repeat=2)}
        config = configure()
        runs = []
        for arch, ipc in [(NORMAL, 1.), (LEN5, 1.1), (BLOCKS, 1.2)]:
            storage = estimate(config, arch, threads=2)
            self.assertEqual(storage["total_bits"], sum(storage.get(k, 0) for keys in STORAGE_FIELDS.values() for k in keys))
            for label, (first, second) in pairs.items():
                threads = [dict(thread_id=i, ipc=ipc/2, benchmark=bench, isolated_ipc=1., isolated_cycles=100)
                           for i, bench in enumerate((first, second))]
                run = dict(architecture=arch, ipc=ipc, weighted_speedup=ipc, smt_mode="enabled", cycles=100,
                           measurement_policy="reference_completion", reference_thread=0, reference_benchmark=first,
                           benchmark=label, workloads=[first, second], threads=threads, seed=7, counts={}, storage=storage)
                if arch == BLOCKS:
                    run.update(merge_utilization=.25, flush_utilization=.125)
                runs.append(run)

        report = dict(suite="ten", seeds=[7], benchmarks=list(pairs), benchmark_pairs=pairs, runs=runs,
                      execution=dict(scheduled=300, completed=300, failed=0))
        matrix = build_matrix(report)
        with temporary_build() as tmp:
            output = Path(tmp)
            plot_suite_overview(report, matrix, output / "plots")
            self.assertEqual(len(list(output.rglob("*.png"))), 12)
            for metric in ("ipc", "thread_0_ipc", "thread_1_ipc", "isolated_ipc"):
                self.assertTrue((output / "plots" / "performance" / f"{metric}.png").is_file())
            self.assertEqual(len(list(output.rglob("*.pdf"))), 2)
            write_suite_summary(report, matrix, output, dashboard=True, raw_prefix="../raw")
            overview = (output / "summary.md").read_text()
            for item in ("300 completed, 0 failed", "Ordered workload pairs: 100", "1.1000×", "../raw/summary.json",
                         "dashboard.html", "hardware storage", "Largest changes", "weighted speedup"):
                self.assertIn(item, overview)

    def test_isolated_suite_without_smt_only_metrics(self):
        runs = [dict(architecture=NORMAL, smt_mode="disabled", seed=1, ipc=1.2, benchmark="a", cycles=10)]
        report = dict(suite="isolated", benchmarks=["a"], seeds=[1], runs=runs)
        matrix = build_matrix(report)
        with temporary_build() as tmp:
            output = Path(tmp)
            plot_suite_overview(report, matrix, output / "plots", detailed=True)
            self.assertEqual([p.name for p in output.rglob("*.png")], ["isolated_ipc.png"])
            write_suite_summary(report, matrix, output, dashboard=False)
            overview = (output / "summary.md").read_text()
            self.assertIn("one isolated iteration", overview)
            self.assertNotIn("dashboard.html", overview)
