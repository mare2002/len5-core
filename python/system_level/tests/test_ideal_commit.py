from collections import Counter
from unittest import TestCase

from system_level.analysis import LEN5, NORMAL
from system_level.config import IDEAL
from system_level.instruction import Instruction as I
from system_level.smt import SMT
from system_level.workload import Timing
from test_pipeline import cycles, events, make, x


def timing(execution=1, memory=3, *, miss=False):
    return Timing(execution, "l1", memory, miss, 3 if miss else 0)


class IdealCommitTests(TestCase):
    def test_independent_retirement_finishes_before_older_divide(self):
        program = [I("div", destination=x(1)), I("mul", destination=x(2)), I("alu", (x(2),), x(3))]
        sim = make(program, IDEAL, [timing(10), timing(), timing()],
                   simulation={"rob_size": 2, "commit_width": 1})
        result = sim.run()
        first, second, third = events(result, "dispatch")
        self.assertEqual((first["slot"], second["slot"], third["slot"]), (0, 1, 2))
        self.assertLess(third["cycle"], cycles(result, "commit", 1)[0])
        self.assertLess(third["cycle"], cycles(result, "broadcast", 0)[0])
        self.assertEqual([event["index"] for event in events(result, "commit")], [1, 2, 0])
        self.assertEqual(result["counts"]["out_of_order_commits"], 2)
        self.assertIsNone(result["retirement_utilization"])
        self.assertNotIn("commit_stage_occupancy", result["samples"])

    def test_unbounded_rob_holds_completed_work_behind_a_slow_load(self):
        program = [I("load", address=8)] + [I("alu", destination=x(reg)) for reg in range(1, 7)]
        times = [timing(memory=30)] + [timing(0)] * 6
        options = {"dispatch_width": 2, "commit_width": 1, "cdb_width": 1}
        small = make(program, IDEAL, times, simulation=options | {"rob_size": 1}).run()
        large = make(program, IDEAL, times, simulation=options | {"rob_size": 32}).run()
        self.assertEqual(small, large)
        self.assertEqual(small["samples"]["rob_occupancy"]["peak"], len(program))
        self.assertEqual(small["counts"].get("dispatch_stall:rob_full", 0), 0)
        load_broadcast, = cycles(small, "broadcast", 0)
        self.assertLess(max(cycles(small, "broadcast", 6)), load_broadcast)
        self.assertEqual(cycles(small, "commit"), [load_broadcast + 1] * len(program))
        bounded = make(program, NORMAL, times, simulation=options | {"rob_size": 1}).run()
        self.assertGreater(bounded["counts"]["dispatch_stall:rob_full"], 0)
        self.assertEqual(bounded["samples"]["rob_occupancy"]["peak"], 1)

    def test_unlimited_retirement_uses_existing_execution_and_cdb_phases(self):
        program = [I("alu"), I("mul"), I("div"), I("fp")]
        for mode in ("event_driven", "statistical"):
            options = {"mode": mode, "cdb_width": 3, "commit_width": 1}
            timestamps = [timing(0)] * len(program)
            reference = make(program, NORMAL, timestamps, simulation=options).run()
            ideal = make(program, IDEAL, timestamps, simulation=options).run()
            for event in ("dispatch", "issue", "execution_complete", "broadcast"):
                self.assertEqual(cycles(ideal, event), cycles(reference, event))
            self.assertEqual(cycles(ideal, "broadcast"), [3, 3, 3, 4])
            self.assertEqual(cycles(ideal, "commit"), [4, 4, 4, 5])
            self.assertFalse(events(ideal, "commit_accept"))

    def test_older_writer_and_live_producer_block_retirement(self):
        program = [I("div", destination=x(1)), I("alu", destination=x(1)),
                   I("mul", (x(1),), x(2)), I("alu", destination=x(3))]
        sim = make(program, IDEAL, [timing(13), timing(), timing(), timing()])
        result = sim.run()
        self.assertEqual([e["index"] for e in events(result, "commit")], [3, 0, 1, 2])
        self.assertLess(cycles(result, "broadcast", 1)[0], cycles(result, "broadcast", 0)[0])
        self.assertGreater(cycles(result, "issue", 2)[0], cycles(result, "broadcast", 1)[0])
        self.assertEqual(sim.rf[x(1)], events(result, "dispatch", 1)[0]["uid"])

    def test_stores_preserve_memory_order_and_alias_rules(self):
        program = [I("load", address=8, size=8), I("store", address=8, size=8),
                   I("store", address=16, size=8), I("load", address=8, size=8)]
        result = make(program, IDEAL, [timing(memory=10), timing(), timing(), timing()]).run()
        self.assertGreater(cycles(result, "store_authorize", 1)[0], cycles(result, "broadcast", 0)[0])
        self.assertGreater(cycles(result, "store_authorize", 2)[0], cycles(result, "store_complete", 1)[0])
        self.assertGreaterEqual(cycles(result, "issue", 3)[0], cycles(result, "store_complete", 1)[0])
        self.assertEqual([e["index"] for e in events(result, "commit")], [0, 1, 2, 3])

    def test_resolved_load_with_pending_writer_only_blocks_ordered_work(self):
        program = [I("div", destination=x(1)), I("load", destination=x(1), address=8),
                   I("alu", destination=x(2)), I("store", address=16)]
        result = make(program, IDEAL, [timing(20), timing(), timing(), timing()]).run()
        self.assertGreater(cycles(result, "commit", 2)[0], cycles(result, "broadcast", 1)[0])
        self.assertEqual([e["index"] for e in events(result, "commit")], [2, 0, 1, 3])
        self.assertGreaterEqual(cycles(result, "store_authorize", 3)[0], cycles(result, "commit", 1)[0])

    def test_faulting_memory_preserves_precise_prefix(self):
        for instruction in (I("load", destination=x(2), pc=0x100, address=8),
                            I("store", pc=0x100, address=8)):
            with self.subTest(kind=instruction.kind):
                program = [I("div", destination=x(1)), instruction,
                           I("alu", (x(2),), x(3)), I("store", address=16)]
                sim = make(program, IDEAL, [timing(12), timing(), timing(), timing()])
                sim.step()
                fault = list(sim.rob.entries.values())[1]
                fault.faulted = True
                with self.assertRaisesRegex(RuntimeError, "precise exception at PC 0x100"):
                    sim.run()
                self.assertEqual(sim.committed, 1)
                report = sim.report()
                self.assertEqual([event["index"] for event in events(report, "commit")], [0])
                self.assertEqual(events(report, "store_authorize"), [])
                self.assertEqual(events(report, "wakeup", 2), [])
                self.assertEqual([sim.rf[x(i)] for i in (2, 3)], [0, 0])

    def test_branch_barrier_replays_younger_work_without_waiting_for_divide(self):
        program = [I("div", destination=x(1)), I("branch"), I("alu", destination=x(2)),
                   I("store", (x(2),), address=8)]
        result = make(program, IDEAL, [timing(20), timing(5, miss=True), timing(), timing()],
                      simulation={"rob_size": 1}).run()
        miss, = cycles(result, "mispredict")
        flush, = cycles(result, "backend_flush")
        self.assertEqual(flush, miss + 1)
        self.assertLess(flush, cycles(result, "commit", 0)[0])
        for index in (2, 3):
            speculative, replayed = events(result, "dispatch", index)
            self.assertIn(speculative["uid"], [e["uid"] for e in events(result, "squash", index)])
            self.assertEqual([e["uid"] for e in events(result, "commit", index)], [replayed["uid"]])
            self.assertLessEqual(replayed["slot"], speculative["slot"])
        self.assertEqual(result["samples"]["rob_occupancy"]["peak"], len(program))
        self.assertGreater(cycles(result, "store_authorize", 3)[0], flush)

    def test_both_smt_threads_exceed_the_configured_rob_size(self):
        program = [I("load", address=8)] + [I("alu")] * 5
        times = [timing(memory=20)] + [timing(0)] * 5
        config = make(program, IDEAL, times, simulation={"rob_size": 1},
                      smt={"mode": "enabled"}).config
        result = SMT(IDEAL, config, program, (times, times), reference_thread=0).run()
        self.assertEqual(result["samples"]["rob_occupancy"]["peak"], 2 * len(program))
        for thread in result["threads"]:
            self.assertEqual(thread["samples"]["rob_occupancy"]["peak"], len(program))
            self.assertEqual(thread["counts"].get("dispatch_stall:rob_full", 0), 0)

    def test_smt_has_no_shared_commit_cap_but_shares_execution_capacity(self):
        program = [I("alu"), I("mul"), I("div"), I("fp")] * 2
        timestamps = [timing(0)] * len(program)
        for arch in (IDEAL, LEN5):
            cfg = make(program, arch, timestamps, simulation={"dispatch_width": 4, "cdb_width": 2,
                       "commit_width": 1}, smt={"mode": "enabled"}).config
            result = SMT(arch, cfg, program, (timestamps, timestamps), reference_thread=0).run()
            self.assertEqual(result["samples"]["cdb_throughput"]["peak"], 2)
            self.assertEqual(max(Counter(cycles(result, "commit")).values()), 2 if arch == IDEAL else 1)
            self.assertEqual(result["threads"][0]["committed"], len(program))
