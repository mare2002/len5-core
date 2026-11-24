import unittest

from system_level.config import (ARCHITECTURES, BLOCK_ARCHITECTURES, IDEAL, SEPARATE_ARCHITECTURES,
                                 configure, fixed, unit)
from system_level.instruction import Instruction as I
from system_level.simulator import Simulator
from system_level.workload import Timing, sample_timing


def x(i):
    return "x", i


def make(program, architecture=ARCHITECTURES[0], timings=None, **changes):
    defaults = {"dispatch_width": 8, "rob_size": 32,
                "max_cycles": 2000, "record_events": True}
    config = configure({**changes, "simulation": defaults | changes.get("simulation", {})})
    if timings is None:
        timings = [Timing(1, "l1", 3, False, 0) for _ in program]
    return Simulator(architecture, config, program, timings)


def events(report, name, index=None):
    return [e for e in report["events"]
            if e["event"] == name and (index is None or e.get("index") == index)]


def cycles(report, name, index=None):
    return [e["cycle"] for e in events(report, name, index)]


class PipelineTests(unittest.TestCase):
    def test_full_rob_reuses_slot_on_cycle_after_handoff(self):
        p = [I("alu", destination=x(1)), I("alu", (x(1),))]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                r = make(p, architecture, simulation={"rob_size": 1}).run()
                self.assertEqual(cycles(r, "commit_accept"), [5, 10])
                self.assertEqual(cycles(r, "commit"), [6, 11])
                self.assertEqual(cycles(r, "dispatch"), [1, 6])
                self.assertEqual([e["slot"] for e in events(r, "dispatch")], [0, 0])
                self.assertEqual(r["counts"]["rob_reuse_delayed_cycles"], 1)
                self.assertEqual(r["samples"]["rob_occupancy"]["peak"], 1)

    def test_len5_clear_walk_uses_only_a_matching_nonfaulting_broadcast(self):
        p = [I("branch"), I("mul"), I("alu")]
        for fault, miss in ((False, False), (True, False), (False, True)):
            with self.subTest(fault=fault, miss=miss):
                t = [Timing(5, "", 0, miss, 0)] + [Timing(1, "", 0, False, 0)] * 2
                s = make(p, ARCHITECTURES[1], t)
                s.step()
                branch = s.rob.head
                branch.faulted = fault
                for _ in range(3):
                    s.step()
                self.assertEqual(s.rob.clear_index, 0)
                self.assertEqual(s.rob.entries[2].completed, 4)
                self.assertFalse(s.rob.entries[2].mem_clear)
                for _ in range(4):
                    s.step()
                self.assertEqual(branch.completed, 8)
                self.assertEqual(s.rob.clear_index, 0 if fault or miss else 1)
                self.assertEqual(s.stats.counts["rob_clear_cdb_bypasses"], int(not (fault or miss)))
                self.assertFalse(s.rob.entries[2].mem_clear)
                self.assertIs(s.rob.head, branch)

    def test_len5_clear_walk_waits_at_full_tail_until_that_slot_is_released(self):
        p = [I("branch"), I("alu"), I("alu")]
        s = make(p, ARCHITECTURES[1], simulation={"rob_size": 2})
        for _ in range(4):
            s.step()
        self.assertEqual(s.rob.head.completed, 4)
        self.assertEqual(s.rob.clear_index, 0)
        self.assertEqual(s.cursor, 2)
        s.step()
        self.assertEqual(s.rob.clear_index, 1)
        self.assertEqual(s.cursor, 2)
        s.step()
        self.assertEqual(s.cursor, 3)

    def test_store_authorization_observes_commit_ready_and_fault(self):
        p = [I("branch"), I("store", address=8, size=8)]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                t = [Timing(1, "", 0, True, 0), Timing(1, "", 3, False, 0)]
                s = make(p, architecture, t)
                for _ in range(5):
                    s.step()
                self.assertEqual(s.commit_stage[0].index, 0)
                wrong_store = s.rob.head
                self.assertEqual(wrong_store.prepared, 3)
                self.assertFalse(wrong_store.authorized)
                s.step()
                self.assertFalse(wrong_store.valid)
                self.assertFalse(wrong_store.launched)
                r = s.run()
                self.assertEqual(cycles(r, "backend_flush"), [6])
                self.assertEqual(cycles(r, "store_prepare", 1), [3, 9])
                self.assertEqual(cycles(r, "store_authorize", 1), [10])
                self.assertEqual(cycles(r, "store_drain", 1), [10])
                self.assertEqual(cycles(r, "store_complete", 1), [13])

                s = make(p[1:], architecture)
                s.step()
                faulted_store = s.rob.head
                faulted_store.faulted = True
                for _ in range(7):
                    s.step()
                self.assertTrue(faulted_store.prepared)
                self.assertFalse(faulted_store.authorized)
                self.assertFalse(faulted_store.launched)
                self.assertEqual(s.stats.counts["stores_serviced"], 0)

    def test_commit_handoff_sustains_configured_width(self):
        p = [I("alu")] * 16
        for architecture in ARCHITECTURES[:2]:
            for width in (1, 2, 4, 8):
                with self.subTest(architecture=architecture, width=width):
                    r = make(p, architecture, simulation={"commit_width": width},
                             execution={"units": {"alu": unit(8, 1, 1, 16, 8)}}).run()
                    self.assertEqual(cycles(r, "commit_accept"), [5 + i // width for i in range(16)])
                    self.assertEqual(cycles(r, "commit"), [6 + i // width for i in range(16)])
                    self.assertEqual([e["index"] for e in events(r, "commit")], list(range(16)))
                    self.assertEqual(r["samples"]["commit_stage_occupancy"]["peak"], width)

    def test_prepared_store_waits_for_oldest_slot_at_all_commit_widths(self):
        p = [I("div"), I("store", address=8, size=8), I("alu")]
        timings = [Timing(8, "", 0, False, 0), Timing(1, "l1", 3, False, 0),
                   Timing(1, "", 0, False, 0)]
        for architecture in ARCHITECTURES[:2]:
            for width in (1, 2, 4, 8):
                with self.subTest(architecture=architecture, width=width):
                    r = make(p, architecture, timings, simulation={"commit_width": width}).run()
                    self.assertEqual(cycles(r, "store_prepare", 1), [3])
                    self.assertEqual(cycles(r, "commit_accept", 0), [12])
                    self.assertEqual(cycles(r, "store_authorize", 1), [13])
                    self.assertEqual(cycles(r, "store_complete", 1), [16])
                    self.assertEqual(cycles(r, "commit", 1), [18])
                    younger_commit = 18 if architecture == ARCHITECTURES[0] else 13
                    self.assertEqual(cycles(r, "commit", 2), [younger_commit + int(width == 1)])

    def test_dispatch_can_read_a_result_in_the_commit_register(self):
        p = [I("mul", destination=x(1)), I("alu", (x(1),)), I("alu", (x(1),))]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                r = make(p, architecture, simulation={"dispatch_width": 1},
                         execution={"units": {"alu": unit(1, 1, 1, 1, 1)}}).run()
                self.assertEqual(cycles(r, "commit_accept", 0), [5])
                self.assertEqual(cycles(r, "dispatch", 2), [5])
                self.assertEqual(cycles(r, "commit", 0), [6])
                self.assertEqual(cycles(r, "issue", 2), [6])

    def test_backend_flush_waits_for_older_work(self):
        p = [I("div", destination=x(1)), I("alu", destination=x(2)), I("branch"),
             I("mul"), I("alu")]
        t = [Timing(12, "", 0, False, 0), Timing(1, "", 0, False, 0), Timing(1, "", 0, True, 5),
             Timing(30, "", 0, False, 0), Timing(1, "", 0, False, 0)]
        for architecture in ARCHITECTURES[:2]:
            for mode in ("event_driven", "statistical"):
                with self.subTest(architecture=architecture, mode=mode):
                    s = make(p, architecture, t, simulation={"mode": mode})
                    for _ in range(4):
                        s.step()
                    branch = s.pending_recovery
                    self.assertEqual(branch.index, 2)
                    self.assertTrue(branch.done)
                    self.assertEqual(len(s.rob.entries), 5)
                    self.assertTrue(all(entry.valid for entry in s.rob.entries.values()))
                    self.assertEqual(s.redirect_until, 9)
                    r = s.run()
                    self.assertEqual(cycles(r, "mispredict"), [4])
                    self.assertEqual(cycles(r, "commit_accept", 2), [16])
                    self.assertEqual(cycles(r, "backend_flush"), [17])
                    self.assertEqual(cycles(r, "squash"), [17, 17])
                    self.assertEqual(cycles(r, "commit", 0), [17])
                    self.assertEqual(cycles(r, "commit", 1), [6 if s.rob.len5 else 17])
                    self.assertEqual(cycles(r, "commit", 2), [17])
                    self.assertEqual(cycles(r, "dispatch", 3), [1, 18])
                    self.assertEqual(r["counts"]["recovery_pending_cycles"], 13)
                    self.assertEqual(r["counts"]["recovery_wait_for_rob_head_cycles"], 12)
                    self.assertEqual(r["samples"]["recovery_detection_to_flush"]["mean"], 13)
                    self.assertEqual(r["samples"]["recovery_pending_rob_occupancy"]["peak"], 5)
                    self.assertEqual(r["samples"]["recovery_dispatch_extra_delay"]["mean"], 9)
                    self.assertEqual(r["counts"]["squashed_instructions"], 2)
                    self.assertEqual(s.rf[x(2)], events(r, "dispatch", 1)[0]["uid"])

    def test_len5_unresolved_head_blocks_younger_register_write(self):
        program = [I("alu", destination=x(15)), I("branch"), I("alu", (x(15),), x(15))]
        timings = [Timing(1, "", 0, False, 0), Timing(9, "", 0, True, 0), Timing(1, "", 0, False, 0)]
        sim = make(program, ARCHITECTURES[1], timings)
        for _ in range(7):
            sim.step()
        branch, younger = sim.rob.entries.values()
        self.assertFalse(branch.done)
        self.assertTrue(younger.done)
        # A stale clear bit must never let a speculative write reach the register file.
        younger.mem_clear = True
        self.assertIsNone(sim.rob.retirement_candidate())

        report = sim.run()
        replayed = events(report, "dispatch", 2)[-1]["uid"]
        self.assertNotEqual(younger.uid, replayed)
        self.assertEqual([e["uid"] for e in events(report, "squash", 2)], [younger.uid])
        self.assertEqual([e["uid"] for e in events(report, "commit", 2)], [replayed])
        self.assertEqual(sim.rf[x(15)], replayed)

    def test_head_misprediction_flushes_at_first_commit_opportunity(self):
        p = [I("jump", destination=x(1)), I("alu", (x(1),))]
        for architecture in ARCHITECTURES[:2]:
            for latency in (0, 10):
                with self.subTest(architecture=architecture, latency=latency):
                    t = [Timing(1, "", 0, True, latency), Timing(1, "", 0, False, 0)]
                    r = make(p, architecture, t).run()
                    self.assertEqual(cycles(r, "mispredict"), [4])
                    self.assertEqual(cycles(r, "commit_accept", 0), [5])
                    self.assertEqual(cycles(r, "backend_flush"), [6])
                    self.assertEqual(cycles(r, "commit", 0), [6])
                    self.assertEqual(cycles(r, "dispatch", 1), [1, max(7, 4 + latency)])
                    self.assertEqual(r["counts"].get("recovery_wait_for_rob_head_cycles", 0), 0)
                    self.assertEqual(r["samples"]["recovery_dispatch_extra_delay"]["mean"], 3 if latency == 0 else 0)

    def test_older_misprediction_overrides_younger_recovery(self):
        p = [I("div"), I("branch"), I("branch"), I("alu")]
        t = [Timing(14, "", 0, False, 0), Timing(7, "", 0, True, 3),
             Timing(1, "", 0, True, 30), Timing(1, "", 0, False, 0)]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                r = make(p, architecture, t).run()
                younger, older, replay = events(r, "mispredict")
                self.assertEqual([(e["index"], e["cycle"]) for e in (younger, older, replay)],
                                 [(2, 5), (1, 10), (2, 23)])
                self.assertEqual([e["uid"] for e in events(r, "backend_flush")], [older["uid"], replay["uid"]])
                self.assertEqual(cycles(r, "backend_flush"), [19, 25])
                self.assertEqual(cycles(r, "dispatch", 2), [1, 20])
                self.assertEqual(cycles(r, "dispatch", 3), [1, 20, 53])
                self.assertEqual(cycles(r, "squash", 2), [19])

    def test_younger_misprediction_does_not_restart_frontend_recovery(self):
        p = [I("div"), I("branch"), I("branch"), I("alu")]
        t = [Timing(14, "", 0, False, 0), Timing(1, "", 0, True, 3),
             Timing(4, "", 0, True, 30), Timing(1, "", 0, False, 0)]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                r = make(p, architecture, t).run()
                older, younger, _ = events(r, "mispredict")
                self.assertEqual((older["cycle"], younger["cycle"]), (4, 8))
                self.assertEqual((younger["redirected"], younger["frontend_ready"]), (0, 7))
                self.assertEqual(cycles(r, "dispatch", 2), [1, 20])
                self.assertEqual(events(r, "backend_flush")[0]["uid"], older["uid"])

    def test_deferred_flush_cancels_stale_cdb_execution_and_memory_events(self):
        p = [I("div"), I("branch"), I("mul", destination=x(1)), I("alu", (x(1),), x(2)),
             I("store", address=8, size=8), I("load", address=32, size=8),
             I("fp", destination=("f", 1))]
        t = [Timing(10, "", 0, False, 0), Timing(1, "", 0, True, 3), Timing(12, "", 0, False, 0),
             Timing(1, "", 0, False, 0), Timing(1, "", 2, False, 0), Timing(1, "dram", 40, False, 0),
             Timing(17, "", 0, False, 0)]
        for architecture in ARCHITECTURES[:2]:
            with self.subTest(architecture=architecture):
                s = make(p, architecture, t, simulation={"rob_size": len(p)})
                for _ in range(14):
                    s.step()
                wrong_mul, waiting_add, wrong_store, wrong_load, wrong_fp = s.rob.entries.values()
                self.assertIn(wrong_mul.uid, s.cdb)
                self.assertIn(wrong_mul.uid, waiting_add.waiting)
                self.assertFalse(wrong_store.authorized)
                self.assertIn(wrong_load.uid, s.memory.outstanding)
                r = s.run()
                self.assertEqual(cycles(r, "backend_flush"), [15])
                squashed = {e["uid"] for e in events(r, "squash")}
                self.assertEqual(squashed, {e.uid for e in (wrong_mul, waiting_add, wrong_store, wrong_load, wrong_fp)})
                for event in ("commit", "store_authorize", "store_drain", "load_response", "wakeup"):
                    self.assertTrue(squashed.isdisjoint(e["uid"] for e in events(r, event)), event)
                self.assertNotIn(wrong_mul.uid, {e["uid"] for e in events(r, "broadcast")})
                self.assertNotIn(wrong_fp.uid, {e["uid"] for e in events(r, "execution_complete")})
                original, reused = events(r, "dispatch", 2)
                self.assertEqual(original["slot"], events(r, "dispatch", 4)[-1]["slot"])
                self.assertEqual(reused["slot"], 0)
                self.assertNotEqual(original["uid"], reused["uid"])
                self.assertEqual(s.rf[x(1)], reused["uid"])
                self.assertEqual(r["counts"]["stores_serviced"], 1)

    def test_execution_latency_phases(self):
        program = [I("alu", destination=x(1))]
        for mode in ("event_driven", "statistical"):
            for latency in (0, 1, 2):
                with self.subTest(mode=mode, latency=latency):
                    config = configure({"simulation": {"mode": mode, "record_events": True},
                                        "execution": {"units": {"alu": {"latency": fixed(latency)}}}})
                    timings = sample_timing(program, config, 42)
                    r = Simulator(ARCHITECTURES[0], config, program, timings).run()
                    self.assertEqual(cycles(r, "issue"), [2])
                    self.assertEqual(cycles(r, "execution_complete"), [2 + latency])
                    self.assertEqual(cycles(r, "broadcast"), [3 + latency])
                    self.assertEqual(cycles(r, "commit_accept"), [4 + latency])
                    self.assertEqual(cycles(r, "commit"), [5 + latency])

    def test_zero_latency_cdb_contention_and_wakeup(self):
        p = [I("alu", destination=x(1)), I("alu", destination=x(2)), I("mul", (x(1), x(2)))]
        t = [Timing(0, "", 0, False, 0)] * len(p)
        for architecture in SEPARATE_ARCHITECTURES:
            for mode in ("event_driven", "statistical"):
                with self.subTest(architecture=architecture, mode=mode):
                    r = make(p, architecture, t, simulation={"mode": mode, "cdb_width": 1}).run()
                    self.assertEqual(cycles(r, "issue"), [2, 2, 5])
                    self.assertEqual(cycles(r, "execution_complete"), [2, 2, 5])
                    self.assertEqual(cycles(r, "broadcast"), [3, 4, 6])
                    self.assertEqual(cycles(r, "wakeup", 2), [4])
                    self.assertEqual(r["counts"]["cdb_contention_cycles"], 1)
                    expected_cycles = 7 if architecture in (*BLOCK_ARCHITECTURES, IDEAL) else 8
                    self.assertEqual((r["committed"], r["cycles"]), (3, expected_cycles))

    def test_local_forwarding_wakes_multiple_consumers_during_cdb_contention(self):
        p = [I("alu", destination=x(1)), I("alu", destination=x(2)),
             I("alu", (x(2),)), I("alu", (x(1), x(2))), I("mul", (x(2),))]
        t = [Timing(0, "", 0, False, 0)] * len(p)
        for architecture in SEPARATE_ARCHITECTURES:
            for mode in ("event_driven", "statistical"):
                with self.subTest(architecture=architecture, mode=mode):
                    r = make(p, architecture, t, simulation={"mode": mode, "cdb_width": 1}).run()
                    self.assertEqual(cycles(r, "issue"), [2, 2, 3, 3, 5])
                    self.assertEqual(cycles(r, "broadcast", 1), [4])
                    local = [e for e in events(r, "wakeup") if e.get("source") == "local"]
                    self.assertEqual([(e["index"], e["producer"], e["cycle"]) for e in local],
                                     [(2, 2, 2), (3, 2, 2)])
                    self.assertEqual(cycles(r, "wakeup", 4), [4])
                    self.assertEqual(len(events(r, "wakeup")), 3)
                    self.assertEqual(r["committed"], len(p))

    def test_multicycle_arithmetic_completion_forwards_in_its_own_station(self):
        for kind in ("alu", "mul", "div", "fp"):
            with self.subTest(kind=kind):
                reg = ("f", 1) if kind == "fp" else x(1)
                p = [I(kind, destination=reg), I(kind, (reg,)), I("store", (reg,), address=8, size=8)]
                t = [Timing(2, "l1", 3, False, 0)] * len(p)
                r = make(p, timings=t, execution={"units": {kind: unit(1, 2, 1, 4, 1)}}).run()
                self.assertEqual(cycles(r, "execution_complete", 0), [4])
                self.assertEqual(cycles(r, "broadcast", 0), [5])
                self.assertEqual(cycles(r, "wakeup", 1), [4])
                self.assertEqual(cycles(r, "issue", 1), [5])
                self.assertEqual(cycles(r, "issue", 2), [6])

    def test_consumer_waits_for_cdb_operand_after_local_forward(self):
        p = [I("alu", destination=x(1)), I("mul", destination=x(2)),
             I("alu", (x(1), x(2)), x(3))]
        t = [Timing(n, "", 0, False, 0) for n in (1, 3, 0)]
        s = make(p, timings=t)
        for _ in range(3):
            s.step()
        consumer = s.rob.entries[3]
        self.assertEqual(consumer.operands, {x(1): 1})
        self.assertEqual(consumer.waiting, {2: x(2)})
        r = s.run()
        self.assertEqual(cycles(r, "wakeup", 2), [6])
        self.assertEqual(cycles(r, "issue", 2), [7])

    def test_dispatch_latches_only_current_cycle_local_completion(self):
        t = Timing(0, "", 0, False, 0)
        for kind, issue in (("alu", 3), ("mul", 4)):
            with self.subTest(kind=kind):
                p = [I("alu", destination=x(1)), I(kind, (x(1),))]
                r = make(p, timings=[t] * len(p), simulation={"dispatch_width": 1},
                         execution={"shared_rs": {"size": 4, "issue_width": 2}}).run()
                self.assertEqual(cycles(r, "dispatch", 1), [2])
                self.assertEqual(cycles(r, "issue", 1), [issue])

        p = [I("alu", destination=x(1)), I("alu", destination=x(2)),
             I("mul"), I("div"), I("alu", (x(2),))]
        r = make(p, timings=[t] * len(p), simulation={"dispatch_width": 2, "cdb_width": 1}).run()
        self.assertEqual(cycles(r, "dispatch", 4), [3])
        self.assertEqual(cycles(r, "wakeup", 4), [4])
        self.assertEqual(cycles(r, "issue", 4), [5])

    def test_faulted_arithmetic_result_does_not_forward_locally(self):
        p = [I("alu", destination=x(1), pc=0x100), I("alu", (x(1),))]
        s = make(p, architecture=IDEAL)
        s.step()
        s.rob.head.faulted = True
        with self.assertRaisesRegex(RuntimeError, "precise exception at PC 0x100"):
            s.run()
        self.assertEqual(events(s.report(), "wakeup", 1), [])

    def test_zero_latency_lsu_keeps_memory_response_limit(self):
        p = [I("load", address=address, size=8) for address in (8, 16)]
        t = [Timing(0, "l1", 1, False, 0)] * len(p)
        r = make(p, timings=t, memory={"response_width": 1}).run()
        self.assertEqual(cycles(r, "execution_complete"), [2, 2])
        self.assertEqual(cycles(r, "load_response"), [3, 4])
        self.assertEqual(cycles(r, "broadcast"), [4, 5])

    def test_hand_calculated_cdb_and_multi_dependency_timing(self):
        program = [I("alu", destination=x(1)), I("alu", destination=x(2)),
                   I("mul", (x(1), x(2)), x(3)), I("div", (x(1),), x(4))]
        sim = make(program, simulation={"cdb_width": 1})
        for _ in range(4):
            sim.step()
        consumer = sim.rob.entries[3]
        self.assertEqual(consumer.operands, {x(1): 1})
        self.assertEqual(consumer.waiting, {2: x(2)})
        r = sim.run()
        self.assertEqual(cycles(r, "dispatch", 0), [1])
        self.assertEqual(cycles(r, "issue", 0), [2])
        self.assertEqual(cycles(r, "execution_complete", 0), [3])
        self.assertEqual(cycles(r, "broadcast", 0), [4])
        self.assertEqual(cycles(r, "broadcast", 1), [5])
        self.assertEqual(cycles(r, "wakeup", 2), [5])
        self.assertEqual(cycles(r, "issue", 2), [6])
        self.assertEqual(cycles(r, "issue", 3), [5])
        self.assertEqual(cycles(r, "commit", 0), [6])
        self.assertEqual(r["counts"]["cdb_contention_cycles"], 1)

    def test_oldest_ready_and_station_capacity(self):
        program = [I("div", destination=x(1)), I("alu", (x(1),)), I("alu"), I("alu"), I("alu")]
        timing = [Timing(6, "", 0, False, 0)] + [Timing(1, "", 0, False, 0)] * 4
        r = make(program, timings=timing, execution={"units": {"alu": unit(1, 1, 1, 2, 1)}}).run()
        self.assertEqual([e["index"] for e in events(r, "issue")], [0, 2, 3, 4, 1])
        self.assertEqual(cycles(r, "issue", 2), [2])
        self.assertGreater(r["counts"]["dispatch_stall:rs_full:alu"], 0)
        self.assertEqual(r["samples"]["rs_occupancy:alu"]["peak"], 2)

    def test_initiation_interval_and_shared_rs_width(self):
        p = [I("mul")] * 4
        execution = {"units": {"mul": unit(2, 1, 4, 1, 2)}, "shared_rs": {"size": 4, "issue_width": 1}}
        r = make(p, execution=execution).run()
        approx = make(p, execution=execution, simulation={"mode": "statistical"}).run()
        self.assertEqual(cycles(r, "issue"), [2, 3, 6, 7])
        self.assertEqual(cycles(approx, "issue"), [2, 3, 4, 5])
        self.assertAlmostEqual(r["issue_utilization"], len(p) / r["cycles"])

    def test_dispatch_cdb_and_commit_widths(self):
        r = make([I("alu")] * 4, simulation={"dispatch_width": 2, "commit_width": 1}).run()
        self.assertEqual(cycles(r, "dispatch"), [1, 1, 2, 2])
        self.assertEqual(cycles(r, "issue"), [2, 2, 3, 3])
        self.assertEqual(cycles(r, "broadcast"), [4, 4, 5, 5])
        self.assertEqual(cycles(r, "commit_accept"), [5, 6, 7, 8])
        self.assertEqual(cycles(r, "commit"), [6, 7, 8, 9])
        self.assertEqual(r["cycles"], 9)

    def test_independent_stations_issue_together_after_single_width_dispatch(self):
        p = [I("div", destination=x(1)), I("alu", (x(1),)), I("mul", (x(1),)), I("fp", (x(1),)),
             I("load", (x(1),), address=8), I("branch", (x(1),))]
        t = [Timing(6, "", 0, False, 0)] + [Timing(1, "l1", 3, False, 0)] * 5
        for architecture in SEPARATE_ARCHITECTURES:
            for mode in ("event_driven", "statistical"):
                with self.subTest(architecture=architecture, mode=mode):
                    r = make(p, architecture, t, simulation={"dispatch_width": 1, "mode": mode}).run()
                    self.assertEqual(cycles(r, "dispatch"), [1, 2, 3, 4, 5, 6])
                    self.assertEqual(cycles(r, "issue"), [2, 10, 10, 10, 10, 10])
                    self.assertEqual(r["samples"]["issue_throughput"]["peak"], 5)
                    self.assertEqual(r["samples"]["cdb_throughput"]["peak"], 1)
                    retirements = cycles(r, "local_retire" if architecture in BLOCK_ARCHITECTURES else "commit")
                    self.assertEqual(len(set(retirements)), len(p) - int(architecture == IDEAL))
                    self.assertAlmostEqual(r["issue_utilization"], len(p) / (8 * r["cycles"]))

    def test_len5_lookahead_and_in_order_store(self):
        p = [I("div", destination=x(1)), I("alu", destination=x(2)),
             I("store", address=128, size=8), I("alu", destination=x(3))]
        timing = [Timing(10, "", 0, False, 0)] + [Timing(1, "", 3, False, 0)] * 3
        normal = make(p, timings=timing).run()
        len5 = make(p, ARCHITECTURES[1], timing).run()
        self.assertEqual([e["index"] for e in events(normal, "commit")], [0, 1, 2, 3])
        self.assertEqual(cycles(len5, "commit", 1), [6])
        self.assertEqual(cycles(len5, "store_prepare", 2), [3])
        self.assertEqual(cycles(len5, "store_authorize", 2), [15])
        self.assertEqual(cycles(len5, "store_complete", 2), [18])
        self.assertEqual(cycles(len5, "commit", 2), [20])
        self.assertEqual(len5["counts"]["out_of_order_commits"], 2)

    def test_len5_raw_waw_and_sequential_slot_reuse(self):
        # Same raw rd even across FP/int banks blocks the only lookahead entry.
        p = [I("div", destination=x(5)), I("fp", destination=("f", 5))] + [I("alu")] * 4
        timing = [Timing(10, "", 0, False, 0)] + [Timing(1, "", 0, False, 0)] * 5
        r = make(p, ARCHITECTURES[1], timing, simulation={"rob_size": 4, "dispatch_width": 2}).run()
        self.assertEqual(cycles(r, "commit", 1), [15])
        self.assertEqual(cycles(r, "dispatch", 4), [15])
        p[1] = I("fp", destination=("f", 6))
        r = make(p, ARCHITECTURES[1], timing, simulation={"rob_size": 4, "dispatch_width": 2}).run()
        self.assertEqual(cycles(r, "commit", 1), [6])
        self.assertEqual(cycles(r, "dispatch", 4), [15])

    def test_len5_unresolved_branch_blocks_memory_clear_walk(self):
        p = [I("div", destination=x(1)), I("branch", (x(1),)), I("alu", destination=x(2))]
        timing = [Timing(10, "", 0, False, 0)] + [Timing(1, "", 0, False, 0)] * 2
        r = make(p, ARCHITECTURES[1], timing).run()
        self.assertEqual(cycles(r, "broadcast", 2), [4])
        self.assertGreater(cycles(r, "commit", 2)[0], cycles(r, "broadcast", 1)[0])

    def test_load_conflict_and_independent_memory(self):
        p = [I("store", address=4, size=4), I("load", destination=x(1), address=6, size=2),
             I("load", destination=x(2), address=16, size=8), I("alu", (x(1), x(2)))]
        r = make(p).run()
        self.assertEqual(cycles(r, "issue", 2), [2])
        self.assertLess(cycles(r, "broadcast", 2)[0], cycles(r, "broadcast", 1)[0])
        self.assertEqual(cycles(r, "issue", 1), cycles(r, "store_complete", 0))
        self.assertEqual(r["counts"]["store_load_conflicts"], 1)
        self.assertEqual(r["histograms"]["cache_outcomes"]["l1"], 2)
        self.assertEqual(cycles(r, "issue", 3)[0], cycles(r, "broadcast", 1)[0] + 1)

    def test_outstanding_miss_and_response_limits(self):
        p = [I("load", address=i * 8, size=8) for i in range(4)]
        t = [Timing(1, level, 5, False, 0) for level in ("dram", "dram", "l1", "l1")]
        r = make(p, timings=t, memory={"max_outstanding_loads": 3, "mshr_capacity": 1,
                                       "response_width": 1, "load_buffer_capacity": 3}).run()
        self.assertEqual(cycles(r, "issue", 0), [2])
        self.assertEqual(cycles(r, "issue", 1), [8])
        self.assertEqual(cycles(r, "load_response", 2), [9])
        self.assertEqual(r["counts"]["memory_response_contention_cycles"], 1)
        self.assertEqual(r["samples"]["mshr_occupancy"]["peak"], 1)
        self.assertGreater(r["counts"]["dispatch_stall:load_buffer_full"], 0)

    def test_statistical_idle_skip_does_not_skip_store_retirement(self):
        p = [I("store", address=8), I("div", destination=x(1))]
        timing = [Timing(1, "", 20, False, 0), Timing(40, "", 0, False, 0)]
        exact = make(p, timings=timing).run()
        statistical = make(p, timings=timing, simulation={"mode": "statistical"}).run()
        self.assertEqual(exact["events"], statistical["events"])
        self.assertGreater(statistical["counts"]["statistical_cycles_skipped"], 0)
