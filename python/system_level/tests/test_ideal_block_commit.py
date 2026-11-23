from collections import Counter
from unittest import TestCase

from system_level.config import IDEAL_OOO
from system_level.instruction import Instruction as I
from test_ideal_commit import timing
from test_pipeline import cycles, events, make, x
from test_smt import core


class IdealBlockCommitTests(TestCase):
    def test_small_configured_limits_do_not_cap_occupancy_or_retirement(self):
        program = [I("branch")] + [I("alu", destination=x(i)) for i in range(1, 7)]
        times = [timing(12)] + [timing(0)] * 6
        sim_options = {"commit_width": 1, "dispatch_width": 8}
        small = make(program, IDEAL_OOO, times, simulation=sim_options | {"rob_size": 1},
                     basic_block={"max_active_blocks": 1, "max_instructions": 1, "merging": {"width": 1}}).run()
        large = make(program, IDEAL_OOO, times, simulation=sim_options | {"rob_size": 32},
                     basic_block={"max_active_blocks": 16, "max_instructions": 1, "merging": {"width": 8}}).run()
        self.assertEqual(small, large)
        self.assertEqual(small["samples"]["rob_occupancy"]["peak"], len(program))
        self.assertEqual(small["samples"]["block_occupancy"]["peak"], len(program))
        self.assertEqual(small["counts"].get("dispatch_stall:rob_full", 0), 0)
        self.assertEqual(small["counts"].get("dispatch_stall:block_capacity", 0), 0)
        self.assertEqual(small["counts"]["merges_delayed_by_bandwidth"], 0)
        self.assertGreater(max(Counter(cycles(small, "local_retire")).values()), 1)
        self.assertGreater(small["samples"]["merge_operations_per_cycle"]["peak"], 1)
        self.assertIsNone(small["merge_utilization"])
        self.assertIsNone(small["retirement_utilization"])
        self.assertEqual(small["committed"], len(program))

    def test_all_ready_groups_publish_with_ordered_store_service(self):
        program = [I("store", address=8, size=8)] * 2
        r = make(program, IDEAL_OOO, [timing(0), timing(0)],
                 simulation={"commit_width": 1},
                 basic_block={"max_active_blocks": 1, "max_stores_per_new_block": 1},
                 memory={"store_drain_width": 1}).run()
        first, second = cycles(r, "block_publish")
        self.assertEqual(first, second)
        self.assertEqual(cycles(r, "store_drain"), [first, first + 1])
        self.assertEqual(r["committed"], 2)

    def test_both_register_banks_grow_and_reclaim_speculative_versions(self):
        program = [I("branch"), I("alu", destination=x(1)), I("fp", destination=("f", 1)),
                   I("alu", destination=x(2)), I("fp", destination=("f", 2))]
        times = [timing(10, miss=True)] + [timing()] * 4
        blocks = {"max_active_blocks": 1, "max_instructions": 1, "flushing": {"width": 1}}
        small = make(program, IDEAL_OOO, times, basic_block=blocks | {
            "registers": {"integer_physical": 32, "fp_physical": 33}})
        report = small.run()
        self.assertEqual(report, make(program, IDEAL_OOO, times, basic_block=blocks).run())
        for bank, metric, peak in (("x", "integer", 33), ("f", "fp", 34)):
            self.assertEqual(report["samples"][metric + "_prf_occupancy"]["peak"], peak)
            self.assertEqual(report["counts"].get("dispatch_stall:" + metric + "_prf", 0), 0)
            self.assertEqual(small.blocks.prf.occupancy(bank), peak - 2)
        for index, insn in enumerate(program[1:], 1):
            replay = events(report, "dispatch", index)[-1]
            self.assertEqual(small.blocks.read(insn.destination), replay["uid"])

    def test_recovery_squashes_grown_state_at_configured_flush_width(self):
        program = [I("branch")] + [I("load", destination=x(i), address=8*i) for i in range(1, 5)]
        times = [timing(5, miss=True)] + [timing(memory=20)] * 4
        sim = make(program, IDEAL_OOO, times, simulation={"rob_size": 1},
                   basic_block={"max_active_blocks": 1, "max_instructions": 1, "flushing": {"width": 1}})
        result = sim.run()
        miss, = cycles(result, "mispredict")
        self.assertEqual(cycles(result, "flush"), list(range(miss + 1, miss + 5)))
        self.assertEqual(result["samples"]["block_occupancy"]["peak"], len(program))
        self.assertEqual(result["committed"], len(program))
        for index in range(1, len(program)):
            wrong, right = events(result, "dispatch", index)
            self.assertEqual([e["uid"] for e in events(result, "squash", index)], [wrong["uid"]])
            self.assertEqual([e["uid"] for e in events(result, "local_retire", index)], [right["uid"]])
            self.assertEqual(sim.blocks.read(x(index)), right["uid"])

    def test_fault_blocks_publication_and_younger_stores(self):
        program = [I("load", destination=x(1), address=8, pc=0x100),
                   I("store", address=16, size=8), I("alu", (x(1),), x(2))]
        times = [timing(memory=10), timing(0), timing(0)]
        sim = make(program, IDEAL_OOO, times, simulation={"rob_size": 1},
                   basic_block={"max_active_blocks": 1, "max_instructions": 1})
        sim.step()
        sim.rob.head.faulted = True
        with self.assertRaisesRegex(RuntimeError, "precise exception at PC 0x100"):
            sim.run()
        report = sim.report()
        for name in ("store_authorize", "store_drain", "block_publish", "wakeup"):
            self.assertEqual(events(report, name), [])
        self.assertEqual(events(report, "local_retire", 0), [])
        self.assertEqual(sim.blocks.prf.values[sim.blocks.prf.architectural[x(1)]], 0)
        self.assertEqual(report["committed"], 0)

    def test_smt_pool_grows_and_has_no_shared_commit_or_merge_cap(self):
        program = [I("branch")] + [I("alu", destination=x(i)) for i in range(1, 7)]
        times = [timing(14)] + [timing(0)] * 6
        sim = core(program, IDEAL_OOO, (times, times),
                   simulation={"rob_size": 1, "commit_width": 1},
                   basic_block={"max_active_blocks": 1, "max_instructions": 1, "merging": {"width": 1},
                                "registers": {"integer_physical": 32}})
        result = sim.run()
        self.assertGreater(result["samples"]["block_occupancy"]["peak"], 2)
        self.assertGreater(result["samples"]["rob_occupancy"]["peak"], 2)
        self.assertGreater(result["samples"]["merge_operations_per_cycle"]["peak"], 1)
        self.assertGreater(max(Counter(cycles(result, "local_retire")).values()), 1)
        self.assertEqual(result["committed"], 2 * len(program))
        for thread in result["threads"]:
            self.assertEqual(thread["counts"].get("dispatch_stall:rob_full", 0), 0)
            self.assertEqual(thread["counts"].get("dispatch_stall:block_capacity", 0), 0)
            self.assertEqual(thread["counts"].get("dispatch_stall:integer_prf", 0), 0)
            self.assertGreater(thread["samples"]["integer_prf_occupancy"]["peak"], 32)
        self.assertTrue(all(group is None for group in sim.pool))
