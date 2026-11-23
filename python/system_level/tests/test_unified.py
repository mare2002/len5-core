from collections import Counter
import unittest

from system_level.config import UNIFIED_ARCHITECTURES, UNIFIED_RS, configure, unit
from system_level.instruction import Instruction as I
from system_level.storage import estimate
from system_level.workload import Timing

from test_pipeline import cycles, events, make, x
from test_smt import core, events as smt_events

NORMAL, _, BLOCKS, _, _ = UNIFIED_ARCHITECTURES


def timings(*latencies):
    return [Timing(value, "", 0, False, 0) for value in latencies]


def one_wrapper(latency=0, interval=1):
    return {"units": {name: unit(1, latency, interval, 4, 1) for name in ("alu", "mul", "div")}}


class UnifiedRSTests(unittest.TestCase):
    def test_capacity_and_oldest_compatible_grants(self):
        p = [I(kind) for kind in ("alu", "alu", "div", "mul", "alu")]
        execution = {"units": {"alu": unit(3, 0, 1, 2, 3), "mul": unit(2, 0, 1, 1, 2),
                               "div": unit(1, 0, 1, 2, 1)}}
        simulator = make(p, NORMAL, timings(0, 0, 0, 0, 0), execution=execution)
        self.assertEqual(simulator.unified.wrappers, (("alu", "mul", "div"), ("alu", "mul"), ("alu",)))
        self.assertEqual(simulator.rs_limits[UNIFIED_RS], (5, 3))
        r = simulator.run()
        self.assertEqual([(e["cycle"], e["index"], e["wrapper"]) for e in events(r, "issue")],
                         [(2, 0, 2), (2, 1, 1), (2, 2, 0), (3, 3, 1), (3, 4, 2)])
        self.assertEqual(r["samples"]["rs_occupancy:" + UNIFIED_RS]["peak"], 5)
        self.assertEqual([record["issues"] for record in r["wrappers"].values()], [1, 2, 2])
        self.assertEqual(Counter(cycles(r, "local_forward")), {2: 3, 3: 2})

        r = make(p + [I("alu")], NORMAL, timings(0, 0, 0, 0, 0, 0),
                 execution=execution | {"unified_issue_width": 1}).run()
        self.assertEqual(cycles(r, "issue"), [2, 3, 4, 5, 6, 7])
        self.assertEqual(r["counts"]["unified_rs_full_cycles"], 1)
        self.assertEqual(r["samples"]["rs_occupancy:" + UNIFIED_RS]["peak"], 5)
        with self.assertRaisesRegex(ValueError, "unified_issue_width"):
            configure({"execution": {"unified_issue_width": 0}})

    def test_one_wrapper_concurrent_units_and_initiation_interval_in_both_modes(self):
        p = [I("div"), I("div"), I("alu"), I("mul")]
        execution = one_wrapper()
        execution["units"]["div"] = unit(1, 5, 4, 4, 1)
        for mode in ("event_driven", "statistical"):
            with self.subTest(mode=mode):
                r = make(p, NORMAL, timings(5, 5, 0, 0), simulation={"mode": mode}, execution=execution).run()
                self.assertEqual([(e["index"], e["cycle"]) for e in events(r, "issue")],
                                 [(0, 2), (2, 3), (3, 4), (1, 6)])
                self.assertEqual(cycles(r, "execution_complete", 0), [7])
                self.assertEqual(cycles(r, "execution_complete", 1), [11])

    def test_oldest_ready_completion_can_overtake_buffered_younger_result(self):
        p = [I("alu", destination=x(1)), I("mul", destination=x(2)),
             I("div", destination=x(3)), I("mul", (x(1),))]
        r = make(p, NORMAL, timings(4, 2, 1, 0), execution=one_wrapper(latency=4),
                 simulation={"cdb_width": 1}).run()
        self.assertEqual([(e["index"], e["cycle"]) for e in events(r, "execution_complete")][:3],
                         [(1, 5), (2, 5), (0, 6)])
        self.assertEqual([(e["index"], e["cycle"], e["delay"]) for e in events(r, "local_forward")],
                         [(1, 5, 0), (0, 6, 0), (2, 7, 2), (3, 8, 1)])
        self.assertEqual(cycles(r, "issue", 3), [7])
        self.assertEqual(cycles(r, "broadcast", 0), [8])
        self.assertEqual(r["samples"]["unified_forwarding_backlog"]["peak"], 1)
        self.assertEqual(r["counts"]["unified_local_forwards_delayed"], 2)

    def test_simultaneous_completions_and_cross_station_dependency(self):
        p = [I("mul", destination=x(1)), I("div", destination=x(2)), I("alu", destination=x(3)),
             I("alu", (x(2),)), I("fp", (x(2),))]
        for architecture in UNIFIED_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                r = make(p, architecture, timings(3, 2, 1, 0, 0), execution=one_wrapper(latency=3),
                         simulation={"cdb_width": 1}).run()
                self.assertEqual(cycles(r, "execution_complete")[:3], [5, 5, 5])
                self.assertEqual([(e["index"], e["cycle"]) for e in events(r, "local_forward")][:3],
                                 [(0, 5), (1, 6), (2, 7)])
                self.assertEqual(cycles(r, "issue", 3), [7])
                self.assertEqual(cycles(r, "issue", 4), [8])
                self.assertEqual([e.get("source") for e in events(r, "wakeup", 3)], ["local"])
                self.assertIsNone(events(r, "wakeup", 4)[0].get("source"))
                self.assertEqual(r["committed"], 5)

    def test_bounded_result_storage_backpressures_issue_without_blocking_local_forward(self):
        p = [I("fp")] * 8 + [I("alu")] * 6
        execution = one_wrapper()
        execution["units"]["fp"] = unit(8, 0, 1, 8, 8)
        r = make(p, NORMAL, timings(*([0] * len(p))), execution=execution,
                 simulation={"dispatch_width": 16, "cdb_width": 1}).run()
        self.assertEqual(cycles(r, "local_forward")[:2], [2, 3])
        self.assertEqual(cycles(r, "issue", 10), [11])
        self.assertEqual(r["samples"]["unified_completion_occupancy"]["peak"], 2)
        self.assertGreater(r["counts"]["issue_blocked:completion_buffer:alu"], 0)
        self.assertEqual(r["counts"]["unified_completion_buffer_stall_cycles"], 7)
        self.assertEqual(len(events(r, "local_forward")), 6)
        self.assertEqual(len(events(r, "broadcast")), len(p))

    def test_dispatch_uses_only_the_current_wrapper_grant(self):
        p = [I("alu", destination=x(1)), I("mul", (x(1),))]
        r = make(p, NORMAL, timings(0, 0), execution=one_wrapper(),
                 simulation={"dispatch_width": 1}).run()
        self.assertEqual(cycles(r, "dispatch", 1), [2])
        self.assertEqual(cycles(r, "wakeup", 1), [2])
        self.assertEqual(cycles(r, "issue", 1), [3])

    def test_squash_drops_result_waiting_for_local_port(self):
        p = [I("branch"), I("mul", destination=x(1)), I("div", destination=x(2)), I("alu", (x(2),))]
        t = [Timing(2, "", 0, True, 3), *timings(2, 1, 0)]
        r = make(p, BLOCKS, t, execution=one_wrapper(latency=2), simulation={"cdb_width": 1}).run()
        wrong, replayed = (e["uid"] for e in events(r, "dispatch", 2))
        self.assertEqual(cycles(r, "squash", 2), [5])
        self.assertEqual([e["uid"] for e in events(r, "local_forward", 2)], [replayed])
        self.assertEqual([e["uid"] for e in events(r, "broadcast", 2)], [replayed])
        self.assertNotIn(wrong, [e["producer"] for e in events(r, "wakeup", 3)])

    def test_shared_smt_ports_and_recovery(self):
        p = [I("branch"), I("alu", destination=x(1)), I("mul", (x(1),), x(2))]
        t = ([Timing(1, "", 0, True, 3), *timings(0, 8)], timings(5, 0, 8))
        for architecture in UNIFIED_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                s = core(p, architecture, t, execution=one_wrapper(latency=8),
                         simulation={"dispatch_width": 8, "cdb_width": 1})
                self.assertIs(s.threads[0].unified, s.threads[1].unified)
                r = s.run()
                self.assertEqual(r["committed"], 6)
                self.assertLessEqual(max(Counter(e["cycle"] for e in smt_events(r, "local_forward")).values()), 1)
                issues = [e["cycle"] for e in smt_events(r, "issue") if "wrapper" in e]
                self.assertEqual(len(issues), len(set(issues)))
                for tid in (0, 1):
                    for wake in smt_events(r, "wakeup", tid, 2):
                        self.assertIn(wake["producer"], [e["uid"] for e in smt_events(r, "dispatch", tid, 1)])
                wrong = smt_events(r, "squash", 0, 2)[0]["uid"]
                self.assertNotIn(wrong, [e["uid"] for e in smt_events(r, "broadcast")])
                self.assertFalse(s.core.unified.results)

    def test_storage_preserves_commit_state_and_counts_completion_buffer(self):
        config = configure()
        for architecture in UNIFIED_ARCHITECTURES[:3]:
            separate = estimate(config, architecture.removesuffix("_unified_rs"), 2)
            combined = estimate(config, architecture, 2)
            for field in ("rob_bits", "register_file_bits", "store_buffer_bits"):
                self.assertEqual(separate[field], combined[field])
            self.assertEqual(combined["rs_thread_tag_bits"], separate["rs_thread_tag_bits"])
            self.assertGreater(combined["unified_completion_buffer_bits"], 0)
