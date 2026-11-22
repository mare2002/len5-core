from copy import deepcopy
import csv
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from system_level.analysis import experiments
from system_level.config import ARCHITECTURES, configure
from system_level.parallel import available_cpus, worker_count
from system_level.plots import plot
from system_level.results import benchmark_summary, save_benchmarks, save_experiment
from system_level.simulator import Simulator
from system_level.workload import make_workload, sample_timing

from test_integration import temporary_build


class ParallelTests(unittest.TestCase):
    def requests(self, workers):
        cfg = configure({"smt": {"mode": "both", "workloads": {
            "thread_0": {"name": "long", "instructions": 35}, "thread_1": {"name": "short", "instructions": 12}}},
            "simulation": {"record_events": True, "parallel": {"workers": workers}}})
        same = deepcopy(cfg)
        same["smt"]["workloads"]["thread_0"] = same["smt"]["workloads"]["thread_1"].copy()
        return {"long + short": (cfg, {"simulation.rob_size": [16, 32]}), "short + short": (same, {})}

    def without_worker_setting(self, batch):
        result = deepcopy(batch)
        for report in result.values():
            for point in report["points"]:
                del point["config"]["simulation"]["parallel"]
        return result

    def test_paired_experiments_exact_at_one_two_four_workers(self):
        seeds = [42, 43]
        with patch("system_level.analysis.process_pool") as pool:
            serial = experiments(self.requests(1), seeds)
            pool.assert_not_called()
        for count in (2, 4):
            with self.subTest(workers=count):
                parallel = experiments(self.requests(count), seeds)
                self.assertEqual(self.without_worker_setting(serial), self.without_worker_setting(parallel))
        self.assertEqual(len(serial["long + short"]["runs"]), 36)
        self.assertEqual(len(serial["short + short"]["runs"]), 12)
        for report in serial.values():
            for run in report["runs"]:
                if run["smt_mode"] == "enabled":
                    self.assertEqual(run["threads"][run["reference_thread"]]["completed_iterations"], 1)
                    self.assertEqual(run["cycles"], run["threads"][run["reference_thread"]]["completion_cycle"])
                    self.assertEqual(run["ipc"], run["committed"] / run["cycles"])
        tie = serial["short + short"]["points"][0]
        self.assertEqual(tie["reference_thread"], 0)
        self.assertEqual(*tie["reference_selection_cycles"])

    def test_unique_result_files_and_plot_after_parallel_sweep(self):
        data = experiments(self.requests(2), [42, 43])
        mixed = data["long + short"]
        with temporary_build() as temp:
            directory = Path(temp)
            save_experiment(mixed, directory / "sweep", sweep=True)
            files = list((directory / "sweep" / "individual_runs").rglob("*.json"))
            self.assertEqual(len(files), len(mixed["runs"]))
            rows = [json.loads(file.read_text()) for file in files]
            identity = lambda row: (row["architecture"], row["smt_mode"], row["seed"], row["point"],
                                    row.get("isolated_thread"))
            self.assertEqual({identity(row) for row in rows}, {identity(row) for row in mixed["runs"]})
            with (directory / "sweep" / "results.csv").open() as file:
                self.assertEqual(len(list(csv.DictReader(file))), len(rows))
            small = {name: dict(report, runs=[r for r in report["runs"] if r["point"] == 0],
                                points=report["points"][:1]) for name, report in data.items()}
            suite = benchmark_summary("test", small)
            save_benchmarks(suite, directory)
            self.assertEqual(len(json.loads((directory / "summary.json").read_text())["runs"]), 30)
            suite["metrics"] = [row for row in suite["metrics"] if row["metric"] in ("ipc", "storage:total_bits")]
            plot(suite, directory / "plots")
            self.assertTrue((directory / "plots" / "speedup" / "architecture_ratios.png").is_file())
            self.assertTrue((directory / "dashboard.html").is_file())

    def test_worker_failure_and_safety_limit(self):
        cfg = configure({"architectures": {"enabled": [ARCHITECTURES[0]]},
                         "simulation": {"max_cycles": 1, "parallel": {"workers": 2}}})
        with self.assertRaisesRegex(RuntimeError, r"'failed \[random\]', normal_ooo, SMT disabled, seed (42|43).*max_cycles"):
            experiments({"failed": (cfg, {})}, [42, 43])

    def test_explicit_reference_and_legacy_single_thread_results(self):
        cfg = self.requests(2)["long + short"][0]
        cfg["smt"]["measurement"]["reference_thread"] = 1
        row = next(r for r in experiments({"ordered": (cfg, {})}, [42])["ordered"]["runs"]
                   if r["smt_mode"] == "enabled")
        self.assertEqual((row["reference_thread"], row["reference_benchmark"], row["repeated_benchmark"]),
                         (1, "short", "long"))
        self.assertIsNone(row["reference_selection_cycles"])
        cfg["smt"]["mode"] = "disabled"
        cfg["workload"]["instructions"] = 20
        program = make_workload(cfg, 42)
        timing = sample_timing(program, cfg, 42)
        for row in experiments({"ordinary": (cfg, {})}, [42])["ordinary"]["runs"]:
            original = Simulator(row["architecture"], cfg, program, timing).run()
            self.assertEqual({key: row[key] for key in original}, original)

    def test_workers_respect_task_and_cpu_limits(self):
        with patch("system_level.parallel.available_cpus", return_value=12):
            self.assertEqual(worker_count("auto", 100), 4)
            self.assertEqual(worker_count(8, 2), 2)
            self.assertEqual(worker_count(8, 1), 1)
        self.assertLessEqual(worker_count(8, 100), available_cpus())
        for value in (0, -1, True, "eight"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "parallel.workers"):
                configure({"simulation": {"parallel": {"workers": value}}})
