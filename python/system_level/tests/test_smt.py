from collections import Counter
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from system_level.analysis import experiment, flatten
from system_level.analysis import program_for
from system_level.config import ARCHITECTURES, BLOCK_ARCHITECTURES, DEFAULT_ARCHITECTURES, IDEAL, configure, unit
from system_level.instruction import Instruction as I
from system_level.plots import COLOR, group_bars, plot_category
from system_level.results import benchmark_summary, metric_rows
from system_level.simulator import Simulator
from system_level.smt import SMT, next_dispatch_priority, paired_performance
from system_level.spike import read_spike
from system_level.storage import estimate
from system_level.workload import Timing, make_workload, sample_timing

from test_pipeline import x

NORMAL, LEN5, BLOCKS = DEFAULT_ARCHITECTURES


def timing(execution=1, memory=3, miss=False, redirect=0):
    return Timing(execution, "l1", memory, miss, redirect)


class DrainBothSMT(SMT):
    """Hardware assertions use one iteration from each thread."""

    def finish_cycle(self):
        for tid, replay in enumerate(self.replays):
            if replay.observe():
                self.completion[tid] = self.core.cycle
        self.finished = all(self.completion)


def core(program, architecture=NORMAL, timings=None, **changes):
    simulation = {"record_events": True, "max_cycles": 1000, **changes.pop("simulation", {})}
    smt = {"mode": "enabled", **changes.pop("smt", {})}
    cfg = configure(dict(changes, simulation=simulation, smt=smt))
    defaults = [timing()] * len(program)
    return DrainBothSMT(architecture, cfg, program, timings if timings is not None else (defaults, defaults),
                        reference_thread=0)


def events(report, event, thread=None, index=None):
    return [row for row in report["events"] if row["event"] == event
            and (thread is None or row.get("thread_id") == thread)
            and (index is None or row.get("index") == index)]


def cycles(report, event, thread=None, index=None):
    return [row["cycle"] for row in events(report, event, thread, index)]


class SMTTests(unittest.TestCase):
    def test_configuration_validation(self):
        self.assertEqual(configure()["smt"]["mode"], "disabled")
        for key, invalid in (("mode", "auto"), ("threads", 3), ("initial_priority", -1),
                             ("dispatch_policy", "round_robin"), ("tie_policy", "switch")):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "smt\\." + key):
                configure({"smt": {key: invalid}})

    def test_same_program_private_state_shared_resources(self):
        p = [I("alu", destination=x(1)), I("alu", (x(1),), x(2))]
        sim = core(p, simulation={"rob_size": 1, "dispatch_width": 2})
        sim.step()
        t0, t1 = sim.threads
        self.assertIs(t0.program, t1.program)
        for resource in ("rs", "lanes", "cdb", "memory", "executing"):
            self.assertIs(getattr(t0, resource), getattr(t1, resource))
        self.assertIsNot(t0.rob, t1.rob)
        self.assertIsNot(t0.rf, t1.rf)
        self.assertIsNot(t0.latest, t1.latest)
        self.assertIsNot(sim.memory.store_buffers[0], sim.memory.store_buffers[1])
        a, b = sim.core.rs.values()
        self.assertEqual((a.slot, b.slot, a.thread_id, b.thread_id), (0, 0, 0, 1))
        self.assertEqual(a.thread_sequence, b.thread_sequence)
        self.assertNotEqual(a.uid, b.uid)
        report = sim.run()
        self.assertEqual(report["committed"], 4)
        self.assertNotEqual(t0.rf[x(2)], t1.rf[x(2)])
        self.assertEqual(t0.rf[x(2)], events(report, "dispatch", 0, 1)[0]["uid"])
        self.assertEqual(t1.rf[x(2)], events(report, "dispatch", 1, 1)[0]["uid"])
        self.assertTrue(all(t["ipc"] == 2 / report["cycles"] for t in report["threads"]))
        self.assertEqual(report["ipc"], sum(t["ipc"] for t in report["threads"]))

    def test_majority_feedback_and_dispatch_fallback(self):
        for priority, counts, expected in ((0, [3, 1], 1), (1, [3, 1], 1), (1, [1, 3], 0),
                                           (0, [2, 2], 0), (0, [4, 0], 1), (1, [0, 0], 1)):
            self.assertEqual(next_dispatch_priority(priority, counts), expected)
        p = [I("alu")] * 6
        sim = core(p, smt={"initial_priority": 1}, simulation={"dispatch_width": 4, "rob_size": 3})
        report = sim.run()
        timeline = events(report, "dispatch_arbitration")
        self.assertEqual([e["thread_id"] for e in events(report, "dispatch")[:4]], [1, 1, 1, 0])
        self.assertEqual((timeline[0]["priority"], timeline[0]["next_priority"]), (1, 0))
        self.assertEqual((timeline[1]["thread_0"], timeline[1]["thread_1"]), (2, 0))
        self.assertTrue(all(e["thread_0"] + e["thread_1"] <= 4 for e in timeline))
        self.assertEqual(report["counts"]["smt_priority_dispatches"] + report["counts"]["smt_fallback_dispatches"], 12)
        self.assertEqual(sum(t["counts"]["smt_priority_cycles"] for t in report["threads"]), report["cycles"])

    def test_zero_cycle_and_oldest_ready_shared_execution_and_cdb_limits(self):
        p = [I("alu", destination=x(1))]
        t = ([timing(0)], [timing(0)])
        for lanes, interval, expected in ((1, 2, [2, 4]), (2, 1, [2, 2])):
            with self.subTest(lanes=lanes):
                sim = core(p, timings=t, simulation={"dispatch_width": 2, "cdb_width": 1},
                           execution={"units": {"alu": unit(lanes, 0, interval, 2, 2)}})
                report = sim.run()
                self.assertEqual(cycles(report, "issue"), expected)
                self.assertEqual([e["thread_id"] for e in events(report, "issue")], [0, 1])
                self.assertEqual(cycles(report, "execution_complete"), expected)
                self.assertEqual(cycles(report, "broadcast"), [3, 5 if lanes == 1 else 4])
                self.assertEqual(report["counts"]["cdb_contention_cycles"], int(lanes == 2))
                self.assertEqual(report["samples"]["rs_occupancy:alu"]["peak"], 2)
                self.assertEqual(report["samples"]["cdb_throughput"]["peak"], 1)
                self.assertIsNone(report["threads"][1]["counts"].get("cdb_contention_cycles"))

    def test_dependencies_and_commit_limits_all_architectures(self):
        p = [I("div", destination=x(1)), I("alu", (x(1),), x(2)), I("alu", destination=x(3))]
        for architecture in DEFAULT_ARCHITECTURES:
            with self.subTest(architecture=architecture):
                t = ([timing(8), timing(0), timing(0)], [timing(12), timing(0), timing(0)])
                sim = core(p, architecture, t, simulation={"dispatch_width": 3, "commit_width": 1})
                result = sim.run()
                self.assertEqual(result["committed"], 6)
                name = "local_retire" if architecture == BLOCKS else "commit"
                self.assertEqual(max(Counter(cycles(result, name)).values()), 1)
                if architecture != BLOCKS:
                    self.assertEqual(max(Counter(cycles(result, "commit_accept")).values()), 1)
                for thread in (0, 1):
                    div = events(result, "broadcast", thread, 0)[0]
                    wake = events(result, "wakeup", thread, 1)[0]
                    self.assertEqual(wake["producer"], div["uid"])
                    self.assertEqual(wake["cycle"], div["cycle"])
                    self.assertGreater(cycles(result, "issue", thread, 1)[0], wake["cycle"])
                    indices = [e["index"] for e in events(result, name, thread)]
                    self.assertEqual(sorted(indices), [0, 1, 2])
                    if architecture == NORMAL:
                        self.assertEqual(indices, [0, 1, 2])

    def test_global_multi_commit_widths_in_both_execution_modes(self):
        p = [I("alu")] * 8
        t = [timing(0)] * len(p)
        for mode in ("event_driven", "statistical"):
            for architecture in DEFAULT_ARCHITECTURES:
                for width in (2, 4, 8):
                    with self.subTest(mode=mode, architecture=architecture, width=width):
                        sim = core(p, architecture, (t, t), simulation={
                            "mode": mode, "commit_width": width, "dispatch_width": 16, "cdb_width": 16},
                            execution={"units": {"alu": unit(16, 0, 1, 16, 16)}})
                        result = sim.run()
                        name = "local_retire" if architecture == BLOCKS else "commit"
                        retires = Counter(cycles(result, name))
                        self.assertEqual(list(retires.values()), [width] * (16 // width))
                        for cycle in retires:
                            self.assertEqual(Counter(e["thread_id"] for e in events(result, name)
                                                     if e["cycle"] == cycle), {0: width // 2, 1: width // 2})

    def test_store_order_is_local_and_service_bandwidth_is_shared(self):
        p = [I("store", address=8, size=8), I("load", address=8, size=8)]
        for architecture in ARCHITECTURES:
            with self.subTest(architecture=architecture):
                times = ([timing(memory=30), timing()], [timing(memory=3), timing()])
                sim = core(p, architecture, times, simulation={"rob_size": 2},
                           memory={"response_width": 1, "store_drain_width": 1, "store_buffer_capacity": 1})
                result = sim.run()
                for thread in (0, 1):
                    auth = cycles(result, "store_authorize", thread, 0)[0]
                    drain = cycles(result, "store_drain", thread, 0)[0]
                    response = cycles(result, "store_complete", thread, 0)[0]
                    load = cycles(result, "issue", thread, 1)[0]
                    self.assertLessEqual(auth, drain)
                    self.assertLess(drain, response)
                    self.assertLessEqual(response, load)
                self.assertLess(cycles(result, "issue", 1, 1)[0], cycles(result, "store_complete", 0, 0)[0])
                self.assertEqual(result["samples"]["store_buffer_occupancy"]["peak"], 2)
                self.assertEqual(result["samples"]["store_drain_throughput"]["peak"], 1)
                self.assertEqual(result["samples"]["memory_response_throughput"]["peak"], 1)

    def test_single_load_buffer_capacity_and_thread_tags(self):
        sim = core([I("load", destination=x(1))], memory={"load_buffer_capacity": 1})
        sim.step()
        self.assertEqual([(e.thread_id, e.slot) for e in sim.memory.loads.values()], [(0, 0)])
        result = sim.run()
        self.assertEqual(result["samples"]["load_buffer_occupancy"]["peak"], 1)
        self.assertGreater(result["threads"][1]["counts"]["dispatch_stall:load_buffer_full"], 0)
        self.assertEqual([e["thread_id"] for e in events(result, "load_response")], [0, 1])
        self.assertEqual([e["slot"] for e in events(result, "dispatch")], [0, 0])

    def test_misprediction_and_outstanding_memory_isolate_threads(self):
        p = [I("div"), I("branch"), I("load", destination=x(1), address=8, size=8),
             I("store", (x(1),), address=16, size=8)]
        times = ([timing(15), timing(3, miss=True, redirect=3), timing(memory=30), timing()],
                 [timing(15), timing(), timing(memory=35), timing()])
        for architecture in ARCHITECTURES:
            with self.subTest(architecture=architecture):
                sim = core(p, architecture, times, simulation={"dispatch_width": 8})
                result = sim.run()
                miss = cycles(result, "mispredict", 0)[0]
                self.assertEqual(events(result, "mispredict", 1), [])
                if architecture in BLOCK_ARCHITECTURES:
                    self.assertEqual(cycles(result, "squash", 0, 2), [miss])
                    self.assertEqual(events(result, "backend_flush", 0), [])
                elif architecture == IDEAL:
                    self.assertEqual(cycles(result, "backend_flush", 0, 1), [miss + 1])
                    self.assertLess(miss + 1, cycles(result, "commit", 0, 0)[0])
                else:
                    accept = cycles(result, "commit_accept", 0, 1)[0]
                    flush = cycles(result, "backend_flush", 0, 1)[0]
                    self.assertLess(miss, accept)
                    self.assertEqual(flush, accept + 1)
                wrong, correct = [e["uid"] for e in events(result, "dispatch", 0, 2)]
                self.assertNotIn(wrong, [e["uid"] for e in events(result, "load_response")])
                self.assertIn(correct, [e["uid"] for e in events(result, "load_response")])
                self.assertEqual(len(events(result, "dispatch", 1, 2)), 1)
                self.assertEqual(len(events(result, "load_response", 1, 2)), 1)
                self.assertEqual(len(events(result, "store_complete", 1, 3)), 1)
                self.assertFalse(sim.memory.responses or sim.core.executing or sim.core.cdb or sim.core.rs)

    def test_len5_lookahead_respects_unresolved_head_and_keeps_legal_ooo(self):
        p = [I("branch"), I("alu", destination=x(1))]
        t = ([timing(9, miss=True), timing()], [timing(9), timing()])
        sim = core(p, LEN5, t, simulation={"dispatch_width": 2})
        for _ in range(7):
            sim.step()
        # A stale memory-clear bit must not authorize lookahead past an unresolved branch.
        for thread in sim.threads:
            candidate = next(iter(list(thread.rob.entries.values())[1:]))
            self.assertTrue(candidate.done)
            candidate.mem_clear = True
        report = sim.run()
        self.assertEqual([e["index"] for e in events(report, "commit", 0)], [0, 1])
        self.assertEqual(report["counts"].get("out_of_order_commits", 0), 0)
        p = [I("div", destination=x(1)), I("alu", destination=x(2))]
        times = [timing(12), timing()]
        report = core(p, LEN5, (times, times), simulation={"dispatch_width": 4}).run()
        self.assertEqual(report["counts"]["out_of_order_commits"], 2)
        for thread in (0, 1):
            self.assertEqual([e["index"] for e in events(report, "commit", thread)], [1, 0])

    def test_private_prf_shared_block_slots_and_merge_budget(self):
        p = [I("div", destination=x(1)), I("alu", destination=x(1)), I("branch"), *[I("branch")] * 5]
        t = [timing(30), timing(), *[timing(1)] * 6]
        sim = core(p, BLOCKS, (t, t), simulation={"dispatch_width": 2, "commit_width": 8},
                   basic_block={"max_active_blocks": 12, "merging": {"width": 1}},
                   execution={"units": {"branch": unit(8, 1, 1, 16, 8)}})
        first, second = [thread.blocks for thread in sim.threads]
        self.assertIs(first.pool, second.pool)
        self.assertEqual(len(sim.pool), 12)
        self.assertIsNot(first.prf, second.prf)
        for _ in range(3):
            sim.step()
        self.assertEqual([g.thread_id for g in sim.pool if g], [0, 1, 0])
        self.assertEqual(first.groups[0].spans[0].mapping, second.groups[0].spans[0].mapping)
        report = sim.run()
        self.assertGreater(report["counts"]["merges"], 0)
        self.assertEqual(report["samples"]["merge_operations_per_cycle"]["peak"], 1)
        self.assertLessEqual(report["samples"]["block_occupancy"]["peak"], 12)
        for tid, blocks in enumerate((first, second)):
            merges = events(report, "merge", tid)
            self.assertTrue(merges)
            self.assertTrue(all(e["older"] < e["younger"] for e in merges))
            local_dispatch = events(report, "dispatch", tid, 1)[0]["uid"]
            self.assertEqual(blocks.prf.values[blocks.prf.architectural[x(1)]], local_dispatch)
            self.assertEqual(report["threads"][tid]["counts"]["physical_destination_reuses"], 1)
            self.assertEqual(len(blocks.prf.refs), 63)
        self.assertEqual(sum(t["counts"]["merges"] for t in report["threads"]), report["counts"]["merges"])
        histogram = report["histograms"]["merges_per_cycle"]
        self.assertEqual(sum(histogram.values()), report["cycles"])
        self.assertEqual(sum(n * cycles for n, cycles in histogram.items()), report["counts"]["merges"])
        self.assertTrue(all(group is None for group in sim.pool))

    def test_shared_block_capacity_one_and_block_flush_bandwidth(self):
        p = [I("branch")] * 6
        good = [timing()] * len(p)
        sim = core(p, BLOCKS, (good, good), basic_block={"max_active_blocks": 1})
        report = sim.run()
        self.assertEqual(report["samples"]["block_occupancy"]["peak"], 1)
        self.assertEqual(report["committed"], 12)
        self.assertGreater(report["counts"]["dispatch_stall:block_capacity"], 0)
        t = [timing(8, miss=True, redirect=1)] + [timing(30)] * 5
        for width in (1, 2, 4):
            with self.subTest(width=width):
                sim = core(p, BLOCKS, (t, t), simulation={"dispatch_width": 4, "cdb_width": 2},
                           basic_block={"max_active_blocks": 12, "flushing": {"width": width}},
                           execution={"units": {"branch": unit(4, 1, 1, 16, 4)}})
                report = sim.run()
                self.assertEqual(report["counts"]["flush_operations"], 10)
                self.assertEqual(report["samples"]["flush_operations_per_cycle"]["peak"], width)
                for thread in (0, 1):
                    self.assertEqual(len(events(report, "flush", thread)), 5)
                    self.assertEqual(len(events(report, "mispredict", thread)), 1)
                self.assertEqual(report["committed"], 12)

    def test_checkpoint_inside_previous_merge_is_thread_local(self):
        p = [I("div", destination=x(1)), I("jump"), I("branch"), I("alu", destination=x(1)),
             I("alu", (x(1),), x(2))]
        miss = [timing(16), timing(), timing(8, miss=True, redirect=2), timing(), timing()]
        good = miss[:2] + [timing(8)] + miss[3:]
        sim = core(p, BLOCKS, (miss, good), simulation={"dispatch_width": 8},
                   execution={"units": {"branch": unit(8, 1, 1, 16, 8)}})
        report = sim.run()
        self.assertEqual(report["threads"][0]["counts"]["merged_groups_restored"], 1)
        self.assertEqual(report["threads"][1]["counts"]["merged_groups_restored"], 0)
        self.assertEqual(len(events(report, "dispatch", 0, 3)), 2)
        self.assertEqual(len(events(report, "dispatch", 1, 3)), 1)
        for tid, thread in enumerate(sim.threads):
            registers = thread.blocks.prf
            self.assertEqual(registers.values[registers.architectural[x(1)]],
                             events(report, "dispatch", tid, 3)[-1]["uid"])
            self.assertTrue(all(len(indices) == len(set(indices)) for indices in registers.free.values()))

    def test_private_and_shared_storage_components_and_required_subtotals(self):
        cfg = configure({"smt": {"mode": "enabled", "threads": 2}, "simulation": {"rob_size": 32}})
        for arch in DEFAULT_ARCHITECTURES:
            with self.subTest(architecture=arch):
                one, two = estimate(cfg, arch, 1), estimate(cfg, arch)
                for key in ("rob_bits", "register_file_bits", "store_buffer_bits"):
                    self.assertEqual(two[key], 2 * one[key])
                for key in ("reservation_station_bits", "load_buffer_bits", "mapping_bits", "ownership_bits",
                            "cdb_result_buffer_bits", "checkpoint_bits"):
                    self.assertEqual(two[key], one[key])
                self.assertEqual(two["rs_thread_tag_bits"], 50)
                self.assertEqual(two["load_thread_tag_bits"], 16)
                self.assertEqual(two["register_file_bits"], 16384 if arch == BLOCKS else 8064)
                self.assertNotIn("store_thread_tag_bits", two)
                self.assertNotIn("rob_thread_tag_bits", two)
                if arch == BLOCKS:
                    self.assertEqual(two["mapping_bits_per_block"], 378)
                    self.assertEqual(two["ownership_bits_per_block"], 128)
                    self.assertEqual(two["block_thread_tag_bits"], 16)
                    self.assertEqual(two["shared_block_mapping_ownership_bits"], 8112)
                    self.assertEqual(two["shared_block_mapping_ownership_bits"] // 8, 1014)

    def test_weighted_speedup_uses_core_elapsed_cycles(self):
        report = {"cycles": 10, "threads": [{"committed": 12, "ipc": 1.2}, {"committed": 12, "ipc": 1.2}]}
        paired_performance(report, [{"committed": 12, "cycles": 6, "ipc": 2},
                                    {"committed": 12, "cycles": 8, "ipc": 1.5}])
        self.assertEqual(report["sequential_cycles"], 14)
        self.assertAlmostEqual(report["weighted_speedup"], 1.4)
        self.assertAlmostEqual(report["smt_throughput_improvement"], 40)
        self.assertAlmostEqual(report["threads"][1]["slowdown"], 1.25)

    def test_independent_pairs_and_single_thread_reporting(self):
        config = configure({"architectures": {"enabled": list(ARCHITECTURES)},
                            "smt": {"mode": "both"}, "workload": {"instructions": 85}})
        program = make_workload(config, 42)
        first = sample_timing(program, config, 42)
        second = sample_timing(program, config, 42, thread_id=1)
        self.assertEqual(first, sample_timing(program, config, 42, thread_id=0))
        self.assertEqual(second, sample_timing(program, config, 42, thread_id=1))
        self.assertNotEqual(first, second)
        results = experiment(config, [42])
        self.assertEqual(results, experiment(config, [42]))
        self.assertEqual(len(results["runs"]), 2 * len(ARCHITECTURES))
        for arch in ARCHITECTURES:
            original = configure({"workload": {"instructions": 85}})
            isolated = Simulator(arch, original, program, first).run()
            single, multi = [run for run in results["runs"] if run["architecture"] == arch]
            self.assertEqual({key: single[key] for key in isolated}, isolated)
            self.assertNotIn("weighted_speedup", single)
            self.assertEqual(multi["reference_thread"], 0)
            self.assertEqual(multi["threads"][0]["committed"], len(program))
            self.assertEqual(flatten(multi)["threads.1.committed"], multi["threads"][1]["committed"])
            self.assertEqual(multi["threads"][0]["isolated_cycles"], isolated["cycles"])
            self.assertEqual(multi["threads"][1]["isolated_cycles"], Simulator(arch, config, program, second).run()["cycles"])
            self.assertEqual(SMT(arch, config, program, (first, second), reference_thread=0).threads[1].timings, second)
            self.assertAlmostEqual(multi["weighted_speedup"], sum(t["ipc"] / t["isolated_ipc"] for t in multi["threads"]))
        rows = [row for row in metric_rows(results) if row["metric"] == "weighted_speedup"]
        self.assertEqual({row["smt_mode"] for row in rows}, {"enabled"})
        self.assertEqual(len(rows), len(ARCHITECTURES))

    def test_spike_workload_is_parsed_once_and_benchmark_plot_grouping(self):
        fixture = Path(__file__).parent / "fixtures" / "hello-world.spike.log"
        config = configure({"smt": {"mode": "both"}, "workload": {"type": "spike", "trace": str(fixture)},
                            "simulation": {"parallel": {"workers": 1}}})
        program_for.cache_clear()
        with patch("system_level.workload.read_spike", wraps=read_spike) as reader:
            result = experiment(config, [42, 43], {"simulation.rob_size": [8, 16]})
            self.assertEqual(reader.call_count, 1)
        result = experiment(config, [42, 43])
        report = benchmark_summary("embench", {"example": result})
        rows = [row for row in report["metrics"] if row["metric"] == "ipc"]
        self.assertEqual(len(rows), 6)
        self.assertEqual(len(report["ipc_speedup"]), 6)
        ax = Mock()
        group_bars(ax, ["example"], rows, "benchmark")
        self.assertEqual(ax.bar.call_count, 6)
        self.assertEqual([call.kwargs["color"] for call in ax.bar.call_args_list],
                         [COLOR[architecture] for architecture in DEFAULT_ARCHITECTURES for _ in range(2)])
        self.assertEqual([call.kwargs["hatch"] for call in ax.bar.call_args_list], [None, "//"] * 3)
        self.assertEqual(plot_category("thread_1:rs_occupancy:alu"), "reservation_stations")
        self.assertEqual(plot_category("weighted_speedup"), "speedup")
