from collections import Counter
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from system_level.analysis import experiment, program_for
from system_level.benchmarks import select_benchmark_pairs
from system_level.config import ARCHITECTURES, configure, fixed, unit
from system_level.instruction import Instruction
from system_level.plots import group_bars
from system_level.results import benchmark_summary
from system_level.smt import SMT
from system_level.workload import Timing, load_program, sample_timing

from test_integration import ROOT
from test_smt import events


class ReplayTests(unittest.TestCase):
    def test_reference_drains_stores_and_stops_other_thread_mid_iteration(self):
        long = [Instruction("div", destination=("x", 1)), Instruction("store", (("x", 1),), address=8, size=8)]
        short = [Instruction("alu", (("x", 2),), ("x", 2))]
        timing = ([Timing(18, "l1", 0, False, 0), Timing(1, "l1", 11, False, 0)],
                  [Timing(0, "l1", 0, False, 0)])
        config = configure({"smt": {"mode": "enabled", "measurement": {
            "policy": "reference_completion", "reference_thread": 0}},
            "execution": {"units": {"alu": unit(1, 0, 1, 4, 1)}},
            "simulation": {"record_events": True, "dispatch_width": 2, "commit_width": 2}})
        for arch in ARCHITECTURES:
            with self.subTest(arch=arch):
                smt = SMT(arch, config, long, timing, other_program=short, names=("long", "short"))
                report = smt.run()
                first, second = report["threads"]
                self.assertEqual(report["workloads"], ["long", "short"])
                self.assertEqual((first["completed_iterations"], first["total_committed"]), (1, 2))
                self.assertGreater(second["completed_iterations"], 1)
                self.assertEqual(report["cycles"], first["completion_cycle"])
                store = events(report, "store_complete", 0)[0]["cycle"]
                self.assertLessEqual(store, report["cycles"])
                self.assertEqual(len(events(report, "dispatch", 0)), 2)
                launches = events(report, "dispatch", 1)
                self.assertEqual(len({event["uid"] for event in launches}), len(launches))
                self.assertEqual([event["iteration"] for event in launches], list(range(len(launches))))
                self.assertFalse(events(report, "wakeup", 1))
                self.assertFalse(smt.memory.responses or smt.core.rs or smt.core.cdb or smt.core.executing)
                self.assertTrue(all(not thread.rob.entries for thread in smt.threads))
                for thread in report["threads"]:
                    self.assertEqual(thread["total_committed"], thread["completed_iterations"] *
                                     thread["instructions_per_iteration"] + thread["partial_iteration_committed"])
                self.assertEqual(report["ipc"], report["committed"] / report["measured_cycles"])

    def test_identical_pair_stops_at_reference_with_partial_iteration(self):
        p = [Instruction("alu", destination=("x", i)) for i in (1, 2, 3)]
        times = ([Timing(18, "l1", 0, False, 0)] * 3, [Timing(0, "l1", 0, False, 0)] * 3)
        cfg = configure({"smt": {"mode": "enabled", "measurement": {"reference_thread": 0}},
                         "simulation": {"record_events": True, "dispatch_width": 4, "commit_width": 2},
                         "execution": {"units": {"alu": unit(2, 0, 1, 10, 2)}}})
        sim = SMT(ARCHITECTURES[0], cfg, p, times, names=("same", "same"))
        r = sim.run()
        first, other = r["threads"]
        self.assertEqual(r["cycles"], first["completion_cycle"])
        self.assertEqual(r["cycles"], r["measured_cycles"])
        self.assertEqual(first["completed_iterations"], 1)
        self.assertGreater(other["completed_iterations"], 1)
        self.assertGreater(other["partial_iteration_committed"], 0)
        self.assertEqual(r["committed"], len(events(r, "commit")))
        self.assertEqual(other["committed"], len(events(r, "commit", 1)))
        self.assertAlmostEqual(r["ipc"], sum(thread["ipc"] for thread in r["threads"]))
        self.assertEqual(r["reference_benchmark"], r["repeated_benchmark"])
        with self.assertRaisesRegex(RuntimeError, "already ended"):
            sim.step()

    def test_fixed_cycles_rejected(self):
        with self.assertRaisesRegex(ValueError, "reference_completion"):
            configure({"smt": {"mode": "enabled", "measurement": {"policy": "fixed_cycles"}}})

    def test_mixed_spike_and_synthetic_baselines_replay_and_cache(self):
        trace = Path(__file__).parent / "fixtures" / "hello-world.spike.log"
        config = configure({"smt": {"mode": "both", "measurement": {
            "reference_thread": 0},
            "workloads": {"thread_0": {"name": "hello", "type": "spike", "trace": str(trace)},
                          "thread_1": {"name": "random-short", "instructions": 3,
                                       "mix": dict.fromkeys(("mul", "div", "branch", "jump", "load", "store", "fp"), 0)
                                       | {"alu": 1}}}},
            "simulation": {"parallel": {"workers": 1}}})
        cache = {}
        program_for.cache_clear()
        with patch("system_level.analysis.load_program", wraps=load_program) as loader:
            report = experiment(config, [42, 43], cache=cache)
            self.assertEqual(report, experiment(config, [42, 43], cache=cache))
            self.assertEqual(loader.call_count, 3)
        for arch in ARCHITECTURES:
            first, second, smt = [r for r in report["runs"] if r["architecture"] == arch and r["seed"] == 42]
            self.assertEqual([r["isolated_thread"] for r in (first, second)], [0, 1])
            self.assertEqual([r["workload"] for r in (first, second)], ["hello", "random-short"])
            self.assertTrue(all(row["measured_cycles"] == row["cycles"] for row in (first, second, smt)))
            for tid, isolated in enumerate((first, second)):
                self.assertEqual(smt["threads"][tid]["isolated_ipc"], isolated["ipc"])
                self.assertEqual(isolated["total_committed"], isolated["measured_committed"])
            self.assertEqual(smt["threads"][0]["completed_iterations"], 1)
            self.assertGreaterEqual(smt["threads"][1]["completed_iterations"], 1)
            self.assertAlmostEqual(smt["weighted_speedup"], sum(t["ipc"] / t["isolated_ipc"] for t in smt["threads"]))
        benchmark = benchmark_summary("test", {"hello + random-short": report})
        bars = Mock()
        group_bars(bars, benchmark["benchmarks"], [r for r in benchmark["metrics"] if r["metric"] == "ipc"], "benchmark")
        self.assertEqual(bars.bar.call_count, 9)

    def test_reference_auto_chooses_cycles_instead_of_instruction_count(self):
        def only(kind):
            return dict.fromkeys(("alu", "mul", "div", "load", "store", "branch", "jump", "fp"), 0) | {kind: 1}

        config = configure({"smt": {"mode": "both", "measurement": {"policy": "reference_completion"},
            "workloads": {"thread_0": {"name": "short-divide", "instructions": 4, "mix": only("div")},
                          "thread_1": {"name": "long-alu", "instructions": 10, "mix": only("alu")}}},
            "execution": {"units": {"div": {"latency": fixed(0), "initiation_interval": 1}}}})
        data = experiment(config, [42, 43], {"simulation.dispatch_width": [1, 4]})
        self.assertEqual([p["reference_thread"] for p in data["points"]], [0, 0])
        self.assertEqual({r["reference_thread"] for r in data["runs"] if r["smt_mode"] == "enabled"}, {0})
        first, second = data["points"][0]["reference_selection_cycles"]
        self.assertGreater(first, second)
        self.assertEqual(data["points"][1]["reference_selection_cycles"], [first, second])

    def test_timing_keys_and_benchmark_pair_selection(self):
        p = [Instruction("div")] * 20
        cfg = configure()
        keyed = [sample_timing(p, cfg, 42, tid, benchmark=name, iteration=iteration)
                 for tid in (0, 1) for name in ("a", "b") for iteration in (0, 1)]
        self.assertEqual(len({tuple(t) for t in keyed}), 8)
        self.assertEqual(keyed[5], sample_timing(p, cfg, 42, 1, benchmark="a", iteration=1))
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", "crc32 cubic", []),
                         [("crc32", "crc32"), ("cubic", "cubic")])
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", "", [["crc32", "crc32"]], "aha-mont64:cubic cubic:cubic"),
                         [("aha-mont64", "cubic"), ("cubic", "cubic")])
        with self.assertRaisesRegex(ValueError, "A:B"):
            select_benchmark_pairs(ROOT, "embench", "", [], "crc32")
        with self.assertRaisesRegex(ValueError, "unavailable"):
            select_benchmark_pairs(ROOT, "embench", "", [["crc32", "missing"]])

    def test_automatic_pair_modes_and_explicit_override(self):
        ordered = select_benchmark_pairs(ROOT, "embench", "crc32 cubic", [], pair_mode="ordered")
        self.assertEqual(ordered, [("crc32", "crc32"), ("crc32", "cubic"),
                                   ("cubic", "crc32"), ("cubic", "cubic")])
        selection = "crc32 cubic edn crc32"
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", selection, [], pair_mode="same"),
                         [("crc32", "crc32"), ("cubic", "cubic"), ("edn", "edn")])
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", selection, [], pair_mode="all"),
                         [("crc32", "crc32"), ("crc32", "cubic"), ("crc32", "edn"),
                          ("cubic", "cubic"), ("cubic", "edn"), ("edn", "edn")])
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", selection, [["edn", "edn"]],
                                                pair_mode="all"), [("edn", "edn")])
        self.assertEqual(select_benchmark_pairs(ROOT, "embench", selection, [["edn", "edn"]],
                                                "cubic:crc32", pair_mode="all"), [("cubic", "crc32")])

    def test_block_replay_preserves_shared_width_and_thread_local_pool(self):
        p = [Instruction("div"), *[Instruction("branch")] * 4]
        fast = [Instruction("branch"), Instruction("alu", destination=("x", 1))]
        cfg = configure({"smt": {"mode": "enabled", "measurement": {"reference_thread": 0}},
                         "branch": {"misprediction_probability": 0},
                         "basic_block": {"max_active_blocks": 6}, "simulation": {"record_events": True}})
        late = [Timing(30, "l1", 0, False, 0)] + [Timing(1, "l1", 0, False, 0)] * 4
        sim = SMT(ARCHITECTURES[2], cfg, p, (late, late[1:3]), other_program=fast, names=("slow", "fast"))
        r = sim.run()
        dispatches = {(e["thread_id"], e["block"]) for e in events(r, "block_dispatch")}
        merges = events(r, "merge")
        self.assertTrue(merges)
        self.assertTrue(all((e["thread_id"], e["older"]) in dispatches and
                            (e["thread_id"], e["younger"]) in dispatches for e in merges))
        self.assertLessEqual(max(Counter(e["cycle"] for e in merges).values()), 1)
        self.assertLessEqual(r["samples"]["block_occupancy"]["peak"], 6)
