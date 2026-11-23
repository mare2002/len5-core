from collections import Counter
import unittest

from system_level.config import ARCHITECTURES, BLOCK_ARCHITECTURES, unit
from system_level.instruction import Instruction as I
from system_level.workload import Timing

from test_pipeline import cycles, events, make, x

BLOCKS = ARCHITECTURES[2]


def timing(latency=1, mispredict=False, recovery=0, memory=4):
    return Timing(latency, "l1", memory, mispredict, recovery)


def block_sim(program, timings=None, **changes):
    execution = changes.pop("execution", {})
    return make(program, BLOCKS, timings, execution={"units": {"branch": unit(8, 1, 1, 16, 8),
                                                                **execution.get("units", {})}},
                **changes)


class BlockTests(unittest.TestCase):
    def test_stores_authorize_only_after_the_oldest_group_completes(self):
        program = [I("div"), I("branch"), I("load", address=16, size=8),
                   I("store", address=8, size=8), I("mul")]
        times = [timing(15), timing(), timing(memory=5), timing(), timing(25)]
        for architecture in BLOCK_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                result = make(program, architecture, times, basic_block={
                    "merging": {"require_older_complete": True}}).run()
                dispatch = events(result, "block_dispatch")
                self.assertNotEqual(dispatch[1]["block"], dispatch[2]["block"])
                self.assertEqual([e["block"] for e in dispatch[2:]], [dispatch[2]["block"]] * 3)
                authorization, = cycles(result, "store_authorize", 3)
                self.assertEqual(authorization, cycles(result, "local_retire", 4)[0])
                self.assertGreater(authorization, cycles(result, "broadcast", 2)[0])
                self.assertGreater(authorization, cycles(result, "local_retire", 0)[0])
                self.assertGreater(cycles(result, "store_complete", 3)[0], authorization)

    def test_store_group_seals_before_blocked_younger_load_or_store(self):
        for architecture in BLOCK_ARCHITECTURES:
            for younger in (I("load", address=8, size=8), I("load"), I("store", address=16, size=8)):
                with self.subTest(architecture=architecture, younger=younger):
                    program = [I("store", address=8, size=8), younger]
                    result = make(program, architecture, basic_block={"max_stores_per_new_block": 2},
                                  memory={"store_buffer_capacity": 1}).run()
                    first, second = events(result, "block_dispatch")
                    self.assertNotEqual(first["block"], second["block"])
                    complete, = cycles(result, "store_complete", 0)
                    self.assertGreaterEqual(cycles(result, "issue", 1)[0], complete)

    def test_ready_store_waits_for_an_incomplete_older_group(self):
        program = [I("div"), I("store", address=8)]
        for architecture in BLOCK_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                result = make(program, architecture, [timing(15), timing()],
                              basic_block={"max_instructions": 1, "merging": {"require_older_complete": True}}).run()
                self.assertLess(cycles(result, "local_retire", 1)[0], cycles(result, "local_retire", 0)[0])
                self.assertEqual(cycles(result, "store_authorize", 1), cycles(result, "local_retire", 0))

    def test_faulting_group_never_authorizes_its_prepared_store(self):
        program = [I("store", address=8, size=8), I("load", address=16, size=8, pc=0x100)]
        for architecture in BLOCK_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                sim = make(program, architecture)
                sim.step()
                list(sim.rob.entries.values())[1].faulted = True
                with self.assertRaisesRegex(RuntimeError, "precise exception at PC 0x100"):
                    sim.run()
                result = sim.report()
                self.assertTrue(events(result, "store_prepare", 0))
                self.assertFalse(events(result, "store_authorize"))

    def test_backend_flush_does_not_wait_for_older_divide(self):
        p = [I("div", destination=x(1)), I("branch"), I("alu")]
        r = block_sim(p, [timing(12), timing(1, True, 3), timing()]).run()
        self.assertEqual(cycles(r, "mispredict"), [4])
        self.assertEqual(cycles(r, "squash", 2), [4])
        self.assertEqual(cycles(r, "flush"), [5])
        self.assertEqual(cycles(r, "dispatch", 2), [1, 7])
        self.assertEqual(cycles(r, "local_retire", 0), [16])

    def test_reused_register_versions_and_out_of_order_rob_slot(self):
        p = [I("div", destination=x(1)), I("alu", (x(1),), x(2)), I("alu", destination=x(1)),
             I("alu", (x(1),), x(3)), I("alu"), I("alu")]
        s = block_sim(p, [timing(12)] + [timing()] * 5, simulation={"rob_size": 3})
        for _ in range(6):
            s.step()
        first, old_user, new_user = s.rob.entries[1], s.rob.entries[2], s.rob.entries[4]
        self.assertEqual(old_user.waiting, {1: x(1)})
        self.assertEqual(new_user.operands, {x(1): 3})
        self.assertEqual(s.blocks.prf.values[first.physical], 3)
        r = s.run()
        self.assertEqual(r["counts"]["physical_allocations"], 3)
        self.assertEqual(r["counts"]["physical_destination_reuses"], 1)
        self.assertEqual(events(r, "block_dispatch", 0)[0]["physical"],
                         events(r, "block_dispatch", 2)[0]["physical"])
        self.assertEqual(events(r, "dispatch", 2)[0]["slot"], events(r, "dispatch", 3)[0]["slot"])
        self.assertNotEqual(events(r, "dispatch", 2)[0]["uid"], events(r, "dispatch", 3)[0]["uid"])
        self.assertLess(cycles(r, "local_retire", 2)[0], cycles(r, "local_retire", 0)[0])
        self.assertEqual(s.blocks.prf.values[s.blocks.prf.architectural[x(1)]], 3)

    def test_widths_merge_into_older_incomplete_and_chain(self):
        p = [I("div", destination=x(1))] + [I("branch")] * 6
        t = [timing(20)] + [timing()] * 6
        for width in (1, 2, 4):
            with self.subTest(width=width):
                r = block_sim(p, t, basic_block={"merging": {"width": width}}).run()
                merges = events(r, "merge")
                by_cycle = Counter(e["cycle"] for e in merges)
                self.assertEqual(max(by_cycle.values()), width)
                self.assertEqual(len(merges), 5)
                self.assertEqual(len({e["younger"] for e in merges}), len(merges))
                self.assertTrue(all(not e["older_complete"] for e in merges))
                self.assertEqual(r["samples"]["merge_candidates"]["peak"], 5)

    def test_merging_pins_superseded_register_until_pending_write_retires(self):
        p = [I("div", destination=x(1)), I("branch"), I("alu", destination=x(1))]
        s = block_sim(p, [timing(15), timing(), timing()])
        for _ in range(6):
            s.step()
        older = s.rob.entries[1]
        self.assertEqual(len(s.blocks.groups), 1)
        self.assertNotEqual(older.physical, s.blocks.groups[0].spans[0].mapping[x(1)])
        self.assertEqual(s.blocks.prf.refs[older.physical], 1)
        mapped = s.blocks.groups[0].spans[0].mapping[x(1)]
        self.assertEqual(s.blocks.groups[0].ownership["x"], 1 << mapped[1])
        r = s.run()
        self.assertEqual(r["samples"]["registers_freed_per_merge"]["total"], 0)
        self.assertIn(older.physical[1], s.blocks.prf.free["x"])

    def test_store_conflict_and_ordered_authorization(self):
        p = [I("div"), I("store", address=8, size=8), I("store", address=12, size=4)]
        r = block_sim(p, [timing(12), timing(memory=30), timing()]).run()
        self.assertGreater(r["counts"]["merge_store_conflict_pair_cycles"], 0)
        self.assertEqual(events(r, "merge"), [])
        self.assertEqual([e["index"] for e in events(r, "store_authorize")], [1, 2])
        self.assertGreater(cycles(r, "store_drain", 2)[0], cycles(r, "store_drain", 1)[0])
        self.assertGreaterEqual(cycles(r, "store_complete", 2)[0], cycles(r, "store_complete", 1)[0])

    def test_flush_widths_and_overlap(self):
        p = [I("branch")] * 6
        t = [timing(10, True, 6)] + [timing(40)] * 5
        for width, count in ((1, 5), (2, 3), (4, 2)):
            with self.subTest(width=width):
                r = block_sim(p, t, basic_block={"flushing": {"width": width}}).run()
                detection = cycles(r, "mispredict")[0]
                self.assertEqual(len(events(r, "flush")), 5)
                self.assertEqual(cycles(r, "flush")[-1] - detection, count)
                self.assertEqual(r["samples"]["block_reclamation_cycles"]["mean"], count)
                self.assertEqual(cycles(r, "dispatch", 1)[1] - detection, 6)
                self.assertEqual(r["counts"]["squashed_instructions"], 5)
                self.assertEqual([e["block"] for e in events(r, "flush")], [5, 4, 3, 2, 1])
                self.assertTrue(all(len(cycles(r, "broadcast", i)) == 1 for i in range(1, 6)))

    def test_reclamation_stalls_small_prf_until_oldest_invalid_group_is_freed(self):
        p = [I("branch"), I("alu", destination=x(1)), I("branch"), *[I("branch")] * 4]
        t = [timing(8, True, 1), timing()] + [timing(40)] * 5
        s = block_sim(p, t, basic_block={"flushing": {"width": 1},
                                         "registers": {"integer_physical": 32}})
        r = s.run()
        miss = cycles(r, "mispredict")[0]
        self.assertEqual(cycles(r, "dispatch", 1)[1], miss + 5)
        self.assertEqual(r["counts"]["dispatch_stall_reclamation"], 4)
        self.assertEqual(r["samples"]["registers_freed_per_flushed_block"]["total"], 1)
        for bank in ("x", "f"):
            self.assertEqual(len(s.blocks.prf.free[bank]), len(set(s.blocks.prf.free[bank])))

    def test_nonoldest_recovery_restores_merged_suffix_and_preserves_old_work(self):
        p = [I("div", destination=x(1)), I("jump"), I("branch"), I("alu", destination=x(1)),
             I("alu", (x(1),), x(2))]
        t = [timing(16), timing(), timing(8, True, 2), timing(), timing()]
        s = block_sim(p, t)
        r = s.run()
        self.assertEqual(r["counts"]["merged_groups_restored"], 1)
        self.assertEqual(r["samples"]["blocks_preserved"]["total"], 2)
        self.assertEqual(r["samples"]["registers_freed_per_flushed_block"]["total"], 2)
        self.assertEqual(len(events(r, "dispatch", 0)), 1)
        self.assertEqual(len(events(r, "dispatch", 3)), 2)
        self.assertEqual(r["committed"], 5)
        self.assertEqual(s.blocks.prf.values[s.blocks.prf.architectural[x(1)]],
                         events(r, "dispatch", 3)[-1]["uid"])

    def test_invalidates_same_cycle_broadcast_candidates_and_rs_waiters(self):
        p = [I("branch"), I("alu", destination=x(1)), I("mul", (x(1),), x(2))]
        t = [timing(1, True, 2), timing(), timing()]
        r = block_sim(p, t).run()
        self.assertEqual(cycles(r, "mispredict"), [4])
        self.assertEqual(cycles(r, "squash", 1), [4])
        self.assertEqual(cycles(r, "broadcast", 1), [9])
        self.assertEqual(cycles(r, "wakeup", 2), [9])
        self.assertEqual(cycles(r, "issue", 2), [10])

    def test_retired_speculative_store_waits_for_confirmation_and_is_flushed(self):
        p = [I("branch"), I("store", address=64, size=8), I("alu", destination=x(1))]
        t = [timing(8, True, 3), timing(), timing()]
        s = block_sim(p, t)
        r = s.run()
        miss = cycles(r, "mispredict")[0]
        first, second = [event["uid"] for event in events(r, "dispatch", 1)]
        self.assertLess(cycles(r, "local_retire", 1)[0], miss)
        self.assertNotIn(first, [event["uid"] for event in events(r, "store_authorize")])
        self.assertEqual([event["uid"] for event in events(r, "store_complete")], [second])
        self.assertEqual(r["counts"]["merged_groups_restored"], 1)

    def test_independent_merge_and_flush_in_same_cycle(self):
        p = [I("div"), I("jump"), I("mul"), I("jump"), I("branch"), I("branch")]
        t = [timing(25), timing(), timing(6), timing(), timing(6, True, 5), timing(30)]
        for allow in (True, False):
            with self.subTest(allow=allow):
                r = block_sim(p, t, basic_block={"flushing": {"allow_unaffected_merges": allow}}).run()
                common = set(cycles(r, "merge")) & set(cycles(r, "flush"))
                self.assertEqual(bool(common), allow)
                for e in events(r, "merge"):
                    if e["cycle"] in common:
                        self.assertEqual((e["older"], e["younger"]), (0, 1))

    def test_block_slot_stall_and_store_limit(self):
        p = [I("branch")] * 5
        t = [timing(9, True, 1)] + [timing(30)] * 4
        r = block_sim(p, t, basic_block={"max_active_blocks": 5, "flushing": {"width": 1}}).run()
        self.assertGreater(r["counts"]["dispatch_stall_reclamation"], 0)
        p = [I("store", address=i * 16, size=8) for i in range(3)]
        r = block_sim(p, basic_block={"max_stores_per_new_block": 2}).run()
        blocks = [e["block"] for e in events(r, "block_dispatch")]
        self.assertEqual(blocks, [0, 0, 1])
