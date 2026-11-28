"""Directed tests for the frontend, branch predictors, RAS, branch training queue and occupancy statistics."""

from collections import Counter
from dataclasses import replace
from itertools import chain, repeat
import unittest

from system_level.btq import BTQ
from system_level.config import ARCHITECTURES, SEPARATE_ARCHITECTURES, configure, variant_config
from system_level.frontend import Frontend, Shared
from system_level.image import static
from system_level.metrics import Metrics, Occupancy
from system_level.predictors import TAGE, Bypass, Counters, Ports, train_counter
from system_level.ras import RAS, ras_action
from system_level.simulator import Simulator
from system_level.smt import SMT
from system_level.spike import decode
from system_level.workload import Timing

NOP = 0x00000013
RET = 0x00008067


def addi(rd: int, rs: int) -> int:
    return (1 << 20) | (rs << 15) | (rd << 7) | 0x13


def jal(rd: int, offset: int) -> int:
    imm = offset & 0x1fffff
    return (((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3ff) << 21 | ((imm >> 11) & 1) << 20
            | ((imm >> 12) & 0xff) << 12 | rd << 7 | 0x6f)


def bne(rs1: int, rs2: int, offset: int) -> int:
    imm = offset & 0x1fff
    return (((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3f) << 25 | rs2 << 20 | rs1 << 15 | 1 << 12
            | ((imm >> 1) & 0xf) << 8 | ((imm >> 11) & 1) << 7 | 0x63)


def jalr(rd: int, rs1: int) -> int:
    return rs1 << 15 | rd << 7 | 0x67


def execute(code: dict[int, int], start: int, outcomes, length: int, indirect: dict[int, int] | None = None):
    """Dynamic trace of ``code`` with branch outcomes from ``outcomes`` and a real return stack."""
    stack, program, pc = [], [], start
    outcomes = iter(outcomes)
    for _ in range(length):
        word = code.get(pc, NOP)
        insn = decode(pc, word, "")
        item = static(insn)
        if item.cfi == "branch":
            next_pc = item.target if next(outcomes) else pc + 4
        elif item.cfi == "jal":
            next_pc = item.target
        elif item.cfi == "jalr":
            next_pc = stack.pop() if item.action in ("pop", "pop_push") else indirect[pc]
            if item.action == "pop_push":
                stack.append(pc + 4)
        else:
            next_pc = pc + 4
        if item.action == "push" or (item.cfi == "jal" and item.action == "push"):
            stack.append(pc + 4)
        program.append(replace(insn, next_pc=next_pc, taken=next_pc != pc + 4 if item.cfi else None))
        pc = next_pc
    return program


def loop_with_call(iterations: int = 60):
    """for (i...) { f(); }  with f at a distant address returning through the RAS."""
    code = {0x1000: addi(5, 5), 0x1004: jal(1, 0x100), 0x1008: bne(5, 6, -8), 0x1104: addi(7, 7), 0x1108: RET}
    outcomes = chain(repeat(True, iterations - 1), [False])
    return execute(code, 0x1000, outcomes, 5 * iterations)


def config(**frontend):
    record = frontend.pop("record_events", False)
    simulation = {"record_events": record, "max_cycles": 200000, **frontend.pop("simulation", {})}
    sections = {key: frontend.pop(key) for key in ("execution", "memory", "basic_block") if key in frontend}
    return configure({"frontend": {"enabled": True, **frontend}, "simulation": simulation, **sections})


def run(program, architecture="basic_block_ooo_commit", **frontend):
    cfg = config(**frontend)
    timings = [Timing(1, "l1" if i.kind == "load" else "", 2 if i.kind == "load" else 0, False, 0) for i in program]
    return Simulator(architecture, cfg, program, timings, seed=1).run()


def simulator(program, architecture="basic_block_ooo_commit", **frontend):
    cfg = config(**frontend)
    timings = [Timing(1, "", 0, False, 0) for _ in program]
    return Simulator(architecture, cfg, program, timings, seed=1)


class FrontendPipelineTests(unittest.TestCase):
    def test_fetch_to_issue_latency_follows_rtl_spill_cells(self):
        # PC/request in cycle 1, 1-cycle memory, answer spill cell -> predecode in 3, output spill cell,
        # issue-queue push in 4 and backend dispatch in 5 (RTL fetch_stage + issue_queue registers).
        program = execute({}, 0x1000, (), 8)
        report = run(program, "normal_ooo", icache={"perfect": True}, record_events=True)
        first = min(e["cycle"] for e in report["events"] if e["event"] == "dispatch")
        self.assertEqual(first, 5)

    def test_all_architectures_and_wrong_path_modes_complete(self):
        program = loop_with_call(30)
        for mode in ("bubble", "frontend", "full"):
            for architecture in SEPARATE_ARCHITECTURES:
                with self.subTest(mode=mode, architecture=architecture):
                    report = run(program, architecture, wrong_path=mode)
                    self.assertEqual(report["committed"], len(program))
                    wrong = report["counts"].get("wrong_path_dispatched", 0)
                    self.assertEqual(wrong > 0, mode == "full" and report["counts"]["mispredictions"] > 0)

    def test_ideal_predictor_never_mispredicts(self):
        report = run(loop_with_call(40), predictor="ideal")
        self.assertEqual(report["counts"].get("mispredictions", 0), 0)
        self.assertEqual(report["frontend"]["final_accuracy"], 1.0)

    def test_predictors_learn_the_loop(self):
        program = loop_with_call(200)
        for predictor in ("l0_only", "l1_bim", "gshare", "tage", "len5"):
            with self.subTest(predictor=predictor):
                report = run(program, predictor=predictor)
                # Gshare also mispredicts once per new history pattern while its 16-bit history warms up.
                self.assertLess(report["counts"]["mispredictions"], 25, predictor)
                self.assertGreater(report["counts"]["btq_trained"], 300)

    def test_l0_prediction_and_l1_correction(self):
        # A one-entry L0 thrashes between the call and the loop branch; the L1 BTB holds both and corrects it.
        program = loop_with_call(100)
        report = run(program, predictor="l1_bim", l0_btb={"entries": 1, "ways": 1}, l1_btb={"latency": 1})
        counts = report["counts"]
        self.assertGreater(counts.get("fe_redirects:l1", 0), 50)
        self.assertGreater(report["frontend"]["l1_accuracy"], report["frontend"]["l0_accuracy"])
        self.assertGreater(counts.get("bp_override_useful:l1", 0), 0)

    def test_variable_latency_final_correction(self):
        program = loop_with_call(80)
        fast = run(program, predictor="tage", tage={"latency": 1})
        slow = run(program, predictor="tage", tage={"latency": 4})
        self.assertGreater(slow["cycles"], fast["cycles"])
        self.assertGreater(slow["samples"]["fe_redirect_latency:final"]["mean"] if
                           "fe_redirect_latency:final" in slow["samples"] else 1, 0)

    def test_icache_hit_and_miss_latency(self):
        program = execute({}, 0x1000, (), 64)
        hit = run(program, icache={"perfect": True})
        miss = run(program, icache={"l1": {"miss_probability": 1, "latency": 1},
                                    "l2": {"miss_probability": 0, "latency": 9}})
        self.assertEqual(hit["counts"]["icache_misses"] if "icache_misses" in hit["counts"] else 0, 0)
        self.assertEqual(miss["counts"]["icache_hits"] if "icache_hits" in miss["counts"] else 0, 0)
        self.assertGreater(miss["cycles"], hit["cycles"] + 8)

    def test_fifo_credit_freed_next_cycle_and_full_condition(self):
        program = execute({}, 0x1000, (), 400)
        # Depth one: the slot freed by a dequeue is reusable only in the following cycle.
        one = run(program, "normal_ooo", icache={"perfect": True}, memory_fifo={"depth": 1}, fetch_width=2)
        two = run(program, "normal_ooo", icache={"perfect": True}, memory_fifo={"depth": 2}, fetch_width=2)
        self.assertGreater(one["counts"]["fe_stall:fetch_fifo_full"], 0)
        self.assertEqual(one["occupancy"]["fetch_fifo"]["peak"], 1)
        self.assertGreater(one["occupancy"]["fetch_fifo"]["full_cycles"], 0)
        self.assertGreater(one["occupancy"]["fetch_fifo"]["empty_cycles"], 0)
        self.assertGreater(two["frontend"]["fetch_ipc"], one["frontend"]["fetch_ipc"])

    def test_simultaneous_enqueue_and_dequeue_sustain_one_bundle_per_cycle(self):
        sim = simulator(execute({}, 0x1000, (), 400), "normal_ooo", icache={"perfect": True},
                        memory_fifo={"depth": 2}, simulation={"dispatch_width": 8, "rob_size": 128},
                        issue_queue={"capacity": 64})
        frontend = sim.frontend
        for _ in range(12):
            sim.step()
        # With depth two, every cycle both allocates a new request and dequeues an older response.
        self.assertEqual(sim.stats.counts["fe_bundles_fetched"], 12)

    def test_obsolete_responses_after_flush_are_discarded(self):
        program = loop_with_call(20)
        for drain in (True, False):
            with self.subTest(drain=drain):
                report = run(program, predictor="l0_only", wrong_path="frontend",
                             icache={"l1": {"miss_probability": .5, "latency": 1}},
                             memory_fifo={"depth": 4, "drain_on_flush": drain})
                self.assertEqual(report["committed"], len(program))
                self.assertEqual(report["counts"].get("fetch_fifo_discarded_responses", 0) > 0, drain)
                self.assertGreater(report["counts"]["fe_bundles_killed"], 0)

    def test_issue_queue_backpressure(self):
        report = run(execute({}, 0x1000, (), 300), "normal_ooo", icache={"perfect": True},
                     issue_queue={"capacity": 8}, simulation={"dispatch_width": 1})
        self.assertGreater(report["counts"]["fe_stall:issue_queue_full"], 0)
        self.assertLessEqual(report["occupancy"]["issue_queue"]["peak"], 8)

    def test_backend_continues_during_frontend_misses(self):
        # The issue queue decouples the stages: the backend keeps issuing buffered work while fetch stalls.
        report = run(execute({}, 0x1000, (), 600), "normal_ooo", issue_queue={"capacity": 64},
                     icache={"l1": {"miss_probability": .2, "latency": 1},
                             "l2": {"miss_probability": 0, "latency": 12}},
                     simulation={"dispatch_width": 1})
        self.assertGreater(report["occupancy"]["issue_queue"]["mean"], 4)

    def test_speculative_history_recovery(self):
        sim = simulator(loop_with_call(40), "basic_block_ooo_commit", predictor="gshare")
        frontend = sim.frontend
        captured = []
        original = frontend.apply_recovery

        def spy(cycle):
            if frontend.recovery is not None and frontend.recovery[1] <= cycle:
                branch = frontend.recovery[0]
                captured.append((branch.fetch.history, sim.program[branch.index]))
                original(cycle)
                captured[-1] += (frontend.history,)
            else:
                original(cycle)
        frontend.apply_recovery = spy
        sim.run()
        self.assertTrue(captured)
        for history, insn, after in captured:
            taken = insn.next_pc != insn.pc + 4
            if insn.kind == "branch":
                self.assertEqual(after, ((history << 1) | taken) & frontend.history_mask)

    def test_history_only_relookup_for_stale_history(self):
        program = loop_with_call(60)
        relookup = run(program, predictor="tage", tage={"latency": 3, "start": "pc"})
        stale = run(program, predictor="tage", tage={"latency": 3, "start": "pc"},
                    history={"stale_policy": "use_stale", "update": "per_branch"})
        self.assertGreater(relookup["counts"].get("fe_history_repairs", 0), 0)
        self.assertGreater(stale["counts"].get("fe_stale_history_predictions", 0), 0)


class PredictorTests(unittest.TestCase):
    def tage(self, bypass=4):
        spec = configure()["frontend"]["tage"] | {"bypass_entries": bypass}
        from random import Random
        return TAGE(spec, 4, Random(0))

    def test_tage_allocation_and_usefulness(self):
        tage, stats, histograms = self.tage(), Counter(), {"tage_provider": Counter()}
        taken, meta = tage.predict(0x2000, 0b1011, False)
        self.assertIsNone(meta["provider"])
        tage.train(meta, True, stats, histograms)  # Misprediction allocates in a tagged table.
        self.assertEqual(stats["tage_allocations"], 1)
        taken, meta = tage.predict(0x2000, 0b1011, False)
        self.assertIsNotNone(meta["provider"])
        for _ in range(3):
            taken, meta = tage.predict(0x2000, 0b1011, False)
            tage.train(meta, True, stats, histograms)
        taken, meta = tage.predict(0x2000, 0b1011, False)
        self.assertTrue(taken)
        # The first allocated entry was correct where its alternate (the base predictor) was wrong.
        self.assertTrue(any(entry.useful for table in tage.storage for entry in table.values()))
        self.assertGreaterEqual(stats["tage_allocations"], 1)

    def test_tage_stale_counter_bypass(self):
        for bypass, lost in ((4, 0), (0, 1)):
            with self.subTest(bypass=bypass):
                tage, stats, histograms = self.tage(bypass), Counter(), {"tage_provider": Counter()}
                _, meta = tage.predict(0x3000, 7, False)
                tage.train(meta, True, stats, histograms)
                # Two predictions read the same entry before either trains (no extra read port).
                _, first = tage.predict(0x3000, 7, False)
                _, second = tage.predict(0x3000, 7, False)
                tage.train(first, True, stats, histograms)
                tage.train(second, True, stats, histograms)
                self.assertEqual(stats["tage_lost_updates"], lost)
                self.assertEqual(stats["tage_stale_metadata"], 1)

    def test_tage_useful_reset(self):
        spec = configure()["frontend"]["tage"] | {"useful_reset_period": 4}
        from random import Random
        tage, stats = TAGE(spec, 4, Random(0)), Counter()
        for i in range(8):
            _, meta = tage.predict(0x4000 + 4 * i, i, False)
            tage.train(meta, True, stats, {"tage_provider": Counter()})
        self.assertEqual(stats["tage_useful_resets"], 2)

    def test_counter_bypass_and_lost_update(self):
        table, stats = Counters(16, 2), Counter()
        saved = table.get(3)
        train_counter(table, Bypass(0), 3, saved, True, stats, "x")
        train_counter(table, Bypass(0), 3, saved, True, stats, "x")  # Stale saved value: update lost.
        self.assertEqual(table.get(3), 2)
        self.assertEqual(stats["x_lost_updates"], 1)
        table, bypass = Counters(16, 2), Bypass(2)
        train_counter(table, bypass, 3, saved, True, stats, "y")
        train_counter(table, bypass, 3, saved, True, stats, "y")
        self.assertEqual(table.get(3), 3)

    def test_sram_port_conflicts(self):
        ports = Ports({"read_ports": 1, "write_ports": 1, "single_port": False})
        self.assertTrue(ports.write(5))
        self.assertFalse(ports.write(5))
        self.assertTrue(ports.read(5))
        self.assertTrue(ports.write(6))
        single = Ports({"read_ports": 1, "write_ports": 1, "single_port": True})
        self.assertTrue(single.read(1))
        self.assertFalse(single.write(1))  # A one-port SRAM cannot read and write in one cycle.
        report = run(loop_with_call(60), predictor="tage", btq={"training_width": 4, "coalesce": False},
                     tage={"write_ports": 1})
        self.assertGreater(report["counts"].get("btq_sram_conflicts", 0), 0)


class TrainingQueueTests(unittest.TestCase):
    def test_overflow_drops_without_stalling(self):
        program = loop_with_call(40)
        full = run(program, btq={"capacity": 0})
        self.assertEqual(full["committed"], len(program))
        self.assertEqual(full["counts"].get("btq_trained", 0), 0)
        controls = sum(i.kind in ("branch", "jump") for i in program)
        self.assertGreaterEqual(full["counts"]["btq_dropped"], controls)
        self.assertFalse(any(k.startswith("dispatch_stall:btq") for k in full["counts"]))
        # Recovery-critical state does not depend on the BTQ.
        self.assertGreater(full["counts"]["mispredictions"], 0)

    def test_partial_allocation_takes_oldest_first(self):
        btq = BTQ(1, Metrics(False))
        self.assertTrue(btq.allocate(1, 0, 0, None, 1))
        self.assertFalse(btq.allocate(2, 0, 1, None, 1))
        self.assertEqual([e.uid for e in btq.entries], [1])
        self.assertEqual(btq.stats.occupancy["btq"].failures, 1)

    def test_out_of_order_confirmation_in_order_training(self):
        stats = Metrics(False)
        btq = BTQ(4, stats)
        for uid in (1, 2, 3):
            btq.allocate(uid, 0, uid, None, 0)
        btq.confirm(3, 5)
        btq.commit(2, 6)  # Younger committed first: still cannot bypass the head.
        self.assertFalse(btq.entries[0].safe)
        self.assertEqual(btq.confirmed_waiting, 2)
        btq.flush_younger(2)
        self.assertEqual(stats.counts["btq_confirmed_flushed"], 1)
        self.assertEqual([e.uid for e in btq.entries], [1, 2])

    def test_training_only_after_safe_commit_even_with_dropped_older_entries(self):
        sim = simulator(loop_with_call(30), btq={"capacity": 2, "training_width": "unlimited"})
        trained_before_commit = []
        original = sim.frontend.apply_training

        def check(entry, cycle):
            trained_before_commit.append(entry.index >= sim.committed)
            original(entry, cycle)
        sim.frontend.apply_training = check
        sim.run()
        self.assertTrue(trained_before_commit)
        self.assertFalse(any(trained_before_commit))
        self.assertGreater(sim.stats.counts["btq_dropped"], 0)

    def test_block_confirmation_merging_and_complete_training(self):
        program = loop_with_call(50)
        controls = sum(i.kind in ("branch", "jump") for i in program)
        for architecture in ("basic_block_ooo_commit", "ideal_commit_ooo", "normal_ooo"):
            with self.subTest(architecture=architecture):
                sim = simulator(program, architecture, wrong_path="full",
                                btq={"capacity": "unlimited", "training_width": "unlimited"},
                                basic_block={"merging": {"width": 2}, "max_active_blocks": 4})
                report = sim.run()
                left = len(sim.frontend.btq.entries)
                self.assertEqual(report["counts"]["btq_trained"] + left, controls)
                self.assertTrue(all(e.index is not None for e in sim.frontend.btq.entries))

    def test_wrong_path_entries_never_train(self):
        sim = simulator(loop_with_call(40), wrong_path="full", predictor="l0_only")
        indices = []
        original = sim.frontend.apply_training
        sim.frontend.apply_training = lambda entry, cycle: (indices.append(entry.index), original(entry, cycle))
        report = sim.run()
        self.assertGreater(report["counts"]["wrong_path_dispatched"], 0)
        self.assertNotIn(None, indices)


class RecoveryTests(unittest.TestCase):
    def test_selective_recovery_rejects_flushed_events(self):
        program = loop_with_call(40)
        for architecture in ("basic_block_ooo_commit", "normal_ooo", "len5_ooo_commit", "ideal_commit"):
            with self.subTest(architecture=architecture):
                report = run(program, architecture, wrong_path="full", predictor="l0_only", record_events=True,
                             basic_block={"flushing": {"width": 1}})
                squashed = {e["uid"]: e["cycle"] for e in report["events"] if e["event"] == "squash"}
                self.assertTrue(squashed)
                late = [e for e in report["events"] if e.get("uid") in squashed
                        and e["event"] in ("broadcast", "commit", "local_retire") and e["cycle"] > squashed[e["uid"]]]
                self.assertEqual(late, [])
                self.assertEqual(report["committed"], len(program))

    def test_flush_bandwidth_settings(self):
        program = loop_with_call(40)
        slow = run(program, wrong_path="full", predictor="l0_only", basic_block={"flushing": {"width": 1}})
        fast = run(program, wrong_path="full", predictor="l0_only", basic_block={"flushing": {"width": "unlimited"}})
        self.assertEqual(slow["committed"], fast["committed"])
        self.assertIsNone(fast["flush_utilization"])


class RASTests(unittest.TestCase):
    def test_call_return_classification(self):
        self.assertEqual(ras_action("jal", 1, None), "push")
        self.assertEqual(ras_action("jal", 5, None), "push")
        self.assertEqual(ras_action("jal", 0, None), "none")
        self.assertEqual(ras_action("jalr", 0, 1), "pop")
        self.assertEqual(ras_action("jalr", 0, 5), "pop")
        self.assertEqual(ras_action("jalr", 1, 6), "push")
        self.assertEqual(ras_action("jalr", 1, 1), "push")
        self.assertEqual(ras_action("jalr", 1, 5), "pop_push")
        self.assertEqual(ras_action("jalr", 5, 1), "pop_push")
        self.assertEqual(ras_action("jalr", 0, 6), "none")

    def test_return_address_uses_instruction_length(self):
        compressed = static(decode(0x100, 0x9082, ""))   # c.jalr x1 (rs1=x1): push with pc + 2
        normal = static(decode(0x200, jal(1, 16), ""))
        self.assertEqual((compressed.size, compressed.action), (2, "push"))
        self.assertEqual((normal.size, normal.action), (4, "push"))

    def test_nested_calls_and_combined_pop_push(self):
        ras = RAS(8, Counter())
        for address in (0x10, 0x20, 0x30):
            ras.push(address)
        self.assertEqual(ras.top(), (0x30, ""))
        ras.apply("pop_push", 0x99)  # Coroutine swap: pops 0x30 and pushes the new link.
        self.assertEqual(ras.top(), (0x99, ""))
        ras.pop()
        self.assertEqual(ras.top(), (0x20, ""))

    def test_wraparound_overflow_and_underflow(self):
        stats = Counter()
        ras = RAS(2, stats)
        for address in (1, 2, 3):
            ras.push(address)
        self.assertEqual(stats["ras_overflows"], 1)
        self.assertGreaterEqual(stats["ras_wraparounds"], 1)
        self.assertEqual((ras.logical, ras.physically_valid()), (3, 2))  # Logical depth > valid entries.
        ras.pop()
        ras.pop()
        self.assertEqual(ras.top(), (None, "overflow_loss"))
        ras.pop()
        self.assertEqual(ras.top(), (None, "underflow"))
        ras.pop()
        self.assertEqual(stats["ras_underflows"], 1)

    def test_saved_top_restored_after_overwriting_push(self):
        stats = Counter()
        ras = RAS(4, stats)
        ras.push(0x100)
        ras.push(0x200)
        saved = ras.checkpoint()
        ras.pop()           # Speculative pop of 0x200 ...
        ras.push(0xbad)     # ... and a push that overwrites its slot.
        ras.restore(saved)
        self.assertEqual(ras.top(), (0x200, ""))
        self.assertEqual(stats["ras_saved_top_restored"], 1)
        ras.pop()
        self.assertEqual(ras.top(), (0x100, ""))  # Unaffected older entry preserved.

    def test_corrupted_entries_invalidated_but_unaffected_preserved(self):
        stats = Counter()
        ras = RAS(3, stats)
        for address in (1, 2, 3):
            ras.push(address)
        saved = ras.checkpoint()
        for _ in range(3):
            ras.pop()
        ras.push(0xa)
        ras.push(0xb)       # Overwrites the slots that held 1 and 2.
        invalidated = ras.restore(saved)
        self.assertEqual(invalidated, 2)
        self.assertEqual(ras.top(), (3, ""))
        ras.pop()
        self.assertEqual(ras.top(), (None, "corruption"))
        ras = RAS(4, Counter())
        for address in (1, 2):
            ras.push(address)
        saved = ras.checkpoint()
        ras.push(3)  # Writes an unused slot only.
        self.assertEqual(ras.restore(saved), 0)
        ras.pop()
        self.assertEqual(ras.top(), (1, ""))

    def test_multiple_nested_checkpoints_and_wrapping_pushes(self):
        ras = RAS(4, Counter())
        ras.push(1)
        outer = ras.checkpoint()
        ras.push(2)
        inner = ras.checkpoint()
        for address in range(10, 16):  # Six pushes wrap the four-entry buffer.
            ras.push(address)
        ras.restore(inner)
        self.assertEqual(ras.top(), (2, ""))
        ras.restore(outer)
        self.assertEqual(ras.top(), (1, ""))
        self.assertEqual(ras.logical, 1)

    def test_unlimited_ras_never_overflows(self):
        stats = Counter()
        ras = RAS("unlimited", stats)
        for address in range(100):
            ras.push(address)
        for address in reversed(range(100)):
            self.assertEqual(ras.top(), (address, ""))
            ras.pop()
        self.assertEqual(stats["ras_overflows"], 0)

    def frontend_bundle(self, ras_valid: bool, l1: int | None, l0: int | None, **frontend):
        program = loop_with_call(4)
        sim = simulator(program, **frontend)
        fe = sim.frontend
        if ras_valid:
            fe.ras.push(0x100c)
        from system_level.frontend import Bundle
        bundle = Bundle(1, 0x1108, 0, fe.slots(0x1108), None)
        slot = 0
        bundle.hits["l1"] = [("ret", l1, True) if l1 else None] + [None] * (len(bundle.slots) - 1)
        bundle.hits["l0"] = [("ret", l0, True) if l0 else None] + [None] * (len(bundle.slots) - 1)
        return fe.indirect(bundle, slot, bundle.slots[slot], None, 0x100c), sim

    def test_return_target_priority(self):
        pred, _ = self.frontend_bundle(True, 0x2222, 0x3333)
        self.assertEqual((pred.target, pred.source), (0x100c, "ras"))
        pred, sim = self.frontend_bundle(False, 0x2222, 0x3333)
        self.assertEqual((pred.target, pred.source), (0x2222, "l1"))
        self.assertEqual(sim.stats.counts["ras_fallback_reason:underflow"], 1)
        pred, _ = self.frontend_bundle(False, None, 0x3333)
        self.assertEqual((pred.target, pred.source), (0x3333, "l0"))
        pred, sim = self.frontend_bundle(False, None, None)
        self.assertIsNone(pred)
        self.assertEqual(sim.stats.counts["ras_no_prediction"], 1)
        pred, sim = self.frontend_bundle(True, 0x100c, None)
        self.assertEqual(sim.stats.counts.get("ras_override_correct", 0), 0)  # Agreement is not an override.

    def test_later_l1_response_does_not_override_valid_early_ras(self):
        program = loop_with_call(120)
        report = run(program, predictor="l1_bim", ras={"access_stage": "pcgen"})
        self.assertEqual(report["counts"].get("mispredictions:return", 0), 0)
        self.assertEqual(report["committed"], len(program))

    def test_ras_actions_are_applied_once_per_dynamic_instruction(self):
        program = loop_with_call(80)
        calls = sum(1 for i in program if static(i).action == "push")
        returns = sum(1 for i in program if static(i).action == "pop")
        for stage in ("predecode", "pcgen"):
            for mode in ("frontend", "full"):
                with self.subTest(stage=stage, mode=mode):
                    sim = simulator(program, predictor="tage", wrong_path=mode, ras={"access_stage": stage})
                    sim.run()
                    # The final RAS state reflects exactly the correct-path calls and returns.
                    self.assertEqual(sim.frontend.ras.logical, calls - returns)
                    self.assertEqual(sim.stats.counts.get("mispredictions:return", 0), 0)

    def test_ras_recovery_without_btq_allocation(self):
        program = loop_with_call(60)
        report = run(program, btq={"capacity": 0}, wrong_path="full", predictor="l0_only")
        self.assertEqual(report["committed"], len(program))
        self.assertGreater(report["counts"]["ras_recoveries"], 0)
        self.assertEqual(report["counts"].get("mispredictions:return", 0), 0)

    def test_deep_recursion_falls_back_to_btb_after_overflow(self):
        # f calls itself 12 times through `jal x1` with a 4-entry RAS, then unwinds.
        code = {0x1000: jal(1, 0x100), 0x1004: NOP, 0x1100: bne(5, 6, 8), 0x1104: RET, 0x1108: jal(1, -8),
                0x110c: RET}
        depth = 12
        outcomes = chain(repeat(True, depth), [False])
        program = execute(code, 0x1000, outcomes, 3 + 2 * depth + 2 * depth)
        report = run(program, ras={"depth": 4})
        counts = report["counts"]
        self.assertGreater(counts["ras_overflows"], 0)
        self.assertGreater(counts.get("ras_fallback_reason:overflow_loss", 0), 0)
        unlimited = run(program, ras={"depth": "unlimited"})
        self.assertEqual(unlimited["counts"].get("ras_overflows", 0), 0)
        self.assertLessEqual(unlimited["counts"].get("mispredictions:return", 0),
                             counts.get("mispredictions:return", 0))


class SMTAndConfigurationTests(unittest.TestCase):
    def smt(self, **frontend):
        cfg = configure({"frontend": {"enabled": True, **frontend},
                         "smt": {"mode": "enabled", "measurement": {"reference_thread": 0}}})
        p0, p1 = loop_with_call(30), loop_with_call(20)
        timings = tuple([Timing(1, "", 0, False, 0) for _ in p] for p in (p0, p1))
        return SMT("basic_block_ooo_commit", cfg, p0, timings, other_program=p1, seed=3, reference_thread=0)

    def test_smt_threads_have_independent_ras_history_and_btq(self):
        smt = self.smt(wrong_path="full")
        threads = smt.threads
        self.assertIsNot(threads[0].frontend.ras, threads[1].frontend.ras)
        self.assertIsNot(threads[0].frontend.btq, threads[1].frontend.btq)
        self.assertIs(threads[0].frontend.predictors, threads[1].frontend.predictors)
        before = threads[1].frontend.ras.checkpoint()
        threads[0].frontend.ras.push(0x1234)
        self.assertEqual(threads[1].frontend.ras.checkpoint(), before)
        report = smt.run()
        self.assertEqual(report["threads"][0]["completed_iterations"], 1)

    def test_partitioned_predictors_and_shared_icache_bandwidth(self):
        smt = self.smt(smt_predictors="partitioned", icache={"request_width": 1})
        self.assertIsNot(smt.threads[0].frontend.predictors, smt.threads[1].frontend.predictors)
        requests = []
        icache = smt.core.shared.icache
        for _ in range(200):
            before = icache.requests if icache.cycle == smt.core.cycle + 1 else 0
            smt.step()
            requests.append(icache.requests)
            if smt.finished:
                break
        self.assertLessEqual(max(requests), 1)

    def test_unlimited_and_ideal_variants_run(self):
        program = loop_with_call(30)
        timings = [Timing(1, "", 0, False, 0) for _ in program]
        base = configure({"architectures": {"enabled": ["basic_block_ooo_commit"]}})
        for variant in ("ideal_frontend", "ideal_backend", "ideal_both", "unlimited_tage", "unlimited_ras",
                        "perfect_ras", "no_ras", "unlimited_btq", "ideal_icache", "len5"):
            for architecture in ("normal_ooo", "basic_block_ooo_commit", "ideal_commit_ooo"):
                with self.subTest(variant=variant, architecture=architecture):
                    report = Simulator(f"{architecture}@{variant}", base, program, timings, seed=1).run()
                    self.assertEqual(report["committed"], len(program))
        report = Simulator("normal_ooo@ideal_both", base, program, timings, seed=1).run()
        self.assertEqual(report["counts"].get("mispredictions", 0), 0)
        self.assertIsNone(report["cdb_utilization"])
        self.assertEqual(report["occupancy"]["rob"]["capacity"], "unlimited")
        self.assertIsNone(report["occupancy"]["rob"]["mean_percent"])

    def test_unlimited_capacity_is_not_perfect_prediction(self):
        cfg = variant_config(configure({"architectures": {"enabled": ["normal_ooo@unlimited_tage"]}}),
                             "normal_ooo@unlimited_tage")
        self.assertEqual(cfg["frontend"]["predictor"], "tage")
        self.assertFalse(cfg["frontend"]["ras"]["perfect"])
        report = run(loop_with_call(60), tage={"tables": cfg["frontend"]["tage"]["tables"]})
        self.assertGreater(report["counts"]["mispredictions"], 0)

    def test_invalid_variant_is_rejected(self):
        with self.assertRaises(ValueError):
            configure({"architectures": {"enabled": ["normal_ooo@missing"]}})
        with self.assertRaises(ValueError):
            configure({"frontend": {"variants": {"bad": {"workload": {}}}},
                       "architectures": {"enabled": ["normal_ooo@bad"]}})

    def test_frontend_settings_are_ignored_when_disabled(self):
        program = loop_with_call(30)
        timings = [Timing(1, "", 0, False, 0) for _ in program]
        a = Simulator("normal_ooo", configure(), program, timings).run()
        b = Simulator("normal_ooo", configure({"frontend": {"predictor": "gshare", "fetch_width": 2}}),
                      program, timings).run()
        self.assertEqual((a["cycles"], a["counts"]), (b["cycles"], b["counts"]))
        self.assertNotIn("frontend", a)


class WarmupTests(unittest.TestCase):
    def test_warmup_keeps_predictor_state_and_restarts_statistics(self):
        program = loop_with_call(120)
        cold = run(program)
        warm = run(program, simulation={"warmup_instructions": 300})
        self.assertEqual(warm["warmup"]["instructions"], 300)
        self.assertEqual(warm["committed"], len(program) - 300)
        self.assertEqual(warm["cycles"] + warm["warmup"]["cycles"], cold["cycles"])
        self.assertLess(warm["counts"].get("mispredictions", 0), cold["counts"]["mispredictions"])
        self.assertEqual(warm["occupancy"]["rob"]["cycles"], warm["cycles"])


class OccupancyTests(unittest.TestCase):
    def test_time_weighted_average(self):
        record = Occupancy()
        record.add(4, 8, cycles=3)
        record.add(0, 8, cycles=1)
        record.add(8, 8, cycles=4)
        report = record.report()
        self.assertEqual(report["mean"], (4 * 3 + 8 * 4) / 8)
        self.assertEqual(report["mean_percent"], 100 * report["mean"] / 8)
        self.assertEqual((report["peak"], report["empty_cycles"], report["full_cycles"]), (8, 1, 4))
        self.assertEqual(report["histogram"], {"0": 1, "4": 3, "8": 4})
        unlimited = Occupancy()
        unlimited.add(3, float("inf"))
        self.assertEqual(unlimited.report()["capacity"], "unlimited")
        self.assertIsNone(unlimited.report()["full_percent"])

    def test_every_backend_and_frontend_queue_is_reported(self):
        report = run(loop_with_call(30), "basic_block_ooo_commit")
        expected = {"rob", "store_buffer", "load_buffer", "outstanding_loads", "mshr", "basic_blocks",
                    "integer_prf", "fp_prf", "fetch_fifo", "issue_queue", "btq", "btq_confirmed",
                    "icache_outstanding", "ras_logical_depth", "ras_valid_entries", "rs:alu", "rs:branch"}
        self.assertLessEqual(expected, set(report["occupancy"]))
        for record in report["occupancy"].values():
            self.assertEqual(record["cycles"], report["cycles"])  # Includes idle cycles.


if __name__ == "__main__":
    unittest.main()
