import csv
import json
from pathlib import Path
import unittest

from system_level.analysis import experiment, write_tables
from system_level.config import (ARCHITECTURES, DEFAULT_ARCHITECTURES, IDEAL_ARCHITECTURES,
                                 configure, distribution, fixed, load_config)
from system_level.instruction import Instruction
from system_level.spike import decode, read_spike
from system_level.storage import estimate
from system_level.workload import make_workload, sample_timing

from test_integration import temporary_build

PACKAGE = Path(__file__).resolve().parents[1]
TRACE = Path(__file__).parent / "fixtures" / "hello-world.spike.log"


class WorkloadsTests(unittest.TestCase):
    def test_execution_latency_distributions_sample_zero(self):
        for spec, expected in (
            (fixed(0), {0}),
            ({"type": "uniform", "min": 0, "max": 3}, {0, 1, 2, 3}),
            ({"type": "weighted", "values": [0, 2], "weights": [0.8, 0.2]}, {0, 2}),
        ):
            with self.subTest(spec=spec):
                config = configure({"execution": {"units": {"alu": {"latency": spec}}}})
                timings = sample_timing([Instruction("alu")] * 100, config, 42)
                self.assertEqual({t.execution for t in timings}, expected)

    def test_real_len5_log_and_commit_address(self):
        p = read_spike(TRACE)
        self.assertEqual(len(p), 9)
        self.assertEqual((p[4].pc, p[4].kind, p[4].sources, p[4].address, p[4].size),
                         (0x10238, "store", (("x", 2), ("x", 1)), 0x80628, 8))
        self.assertEqual((p[5].pc, p[5].taken, p[5].next_pc, p[5].destination),
                         (0x1023c, True, 0x107ac, ("x", 1)))
        self.assertEqual((p[-1].kind, p[-1].destination, p[-1].address),
                         ("load", ("x", 15), 0x502d0))
        self.assertEqual(read_spike(TRACE, start_pc=0x1023c, limit=1), [p[5]])
        c = configure({"workload": {"type": "spike", "trace": str(TRACE), "instructions": None}})
        self.assertTrue(all(row["committed"] == 9 for row in experiment(c, [42])["runs"]))

    def test_decoder_fp_forms_compressed_and_unsupported_system(self):
        self.assertEqual(decode(0, 0x023100d3, "fadd.d").sources, (("f", 2), ("f", 3)))
        self.assertEqual(decode(0, 0x00312087, "flw").destination, ("f", 1))
        self.assertEqual(decode(0, 0xa23120d3, "feq.d").destination, ("x", 1))
        self.assertEqual(decode(0, 0x0305, "c.addi").sources, (("x", 6),))
        for word in (0xf1402573, 0x73, 0x100f, 0x9002):
            with self.assertRaisesRegex(ValueError, "unsupported Spike instruction"):
                decode(0x1008, word, "unsupported")

    def test_fetch_only_branch_direction_and_uncommitted_trap(self):
        with temporary_build() as tmp:
            path = Path(tmp) / "trace.log"
            path.write_text("core   0: 0x1000 (0x00000463) beqz zero, pc + 8\n"
                            "core   0: 0x1008 (0x0000006f) j pc + 0\n")
            p = read_spike(path, stop_at_self_jump=True)
            self.assertEqual((len(p), p[0].taken, p[0].next_pc), (1, True, 0x1008))
            path.write_text("core   0: 3 0x1000 (0x00000013)\n"
                            "core   0: 0x1004 (0x00000073) ecall\n")
            with self.assertRaisesRegex(ValueError, "unsupported Spike instruction at PC 0x1004"):
                read_spike(path)

    def test_random_and_timing_are_paired_across_hardware_parameters(self):
        c = configure({"workload": {"instructions": 150}})
        b = configure({"workload": {"instructions": 150}, "basic_block": {"flushing": {"width": 4}}})
        p = make_workload(c, 42)
        self.assertEqual(p, make_workload(b, 42))
        self.assertEqual(sample_timing(p, c, 42), sample_timing(p, b, 42))
        self.assertNotEqual(p, make_workload(c, 43))
        self.assertTrue(any(len(insn.sources) > 1 for insn in p))


class AnalysisTests(unittest.TestCase):
    def test_validation_and_width_defaults(self):
        for changes, pattern in [
            ({"basic_block": {"merging": {"width": 0}}}, "merging.width"),
            ({"basic_block": {"flushing": {"width": True}}}, "flushing.width"),
            ({"basic_block": {"flushing": {"immediate_logical_invalidation": False}}}, "logical_invalidation"),
            ({"basic_block": {"registers": {"fp_physical": 32}}}, "fp_physical"),
            ({"simulation": {"unknown": 1}}, "unknown parameter"),
            ({"simulation": {"issue_width": 4}}, "unknown parameter simulation.issue_width"),
            ({"memory": {"l1": {"miss_probability": 2}}}, "miss_probability"),
            ({"memory": {"dram_latency": fixed(0)}}, "memory.dram_latency"),
            ({"execution": {"units": {"alu": {"latency": fixed(-1)}}}}, "execution.units.alu.latency"),
            ({"workload": {"type": "random", "instructions": None}}, "instructions"),
            ({"execution": {"units": {"fp": {"count": 0}}}}, "requires execution"),
        ]:
            with self.subTest(pattern=pattern), self.assertRaisesRegex(ValueError, pattern):
                configure(changes)
        with self.assertRaisesRegex(ValueError, "equal length"):
            distribution({"type": "weighted", "values": [1], "weights": []})
        with temporary_build() as tmp:
            path = Path(tmp) / "duplicate.yaml"
            path.write_text("simulation:\n  commit_width: 1\n  commit_width: 2\n")
            with self.assertRaisesRegex(ValueError, "duplicate YAML key"):
                load_config(path)
        self.assertIsNone(load_config(PACKAGE / "config.yaml")["simulation"]["cdb_width"])

    def test_storage_breakdown_and_independent_banks(self):
        c = configure({"basic_block": {"max_active_blocks": 4, "registers": {
            "integer_physical": 48, "fp_physical": 128}}})
        a, b, block = [estimate(c, name) for name in DEFAULT_ARCHITECTURES]
        for name in IDEAL_ARCHITECTURES:
            ideal = estimate(c, name)
            self.assertIsNone(ideal["rob_bits"])
            self.assertIsNone(ideal["total_bits"])
        self.assertEqual(a["register_file_bits"], (31 + 32) * 64)
        self.assertEqual(b["rob_bits"] - a["rob_bits"], 32 * 3)
        self.assertEqual(a["mapping_bits"], 0)
        self.assertEqual(block["register_file_bits"], (48 + 128) * 64)
        self.assertEqual(block["mapping_bits_per_block"], 31 * 6 + 32 * 7)
        self.assertEqual(block["ownership_bits"], (48 + 128) * 4)
        self.assertEqual(block["total_bits"], sum(v for k, v in block.items() if k in (
            "rob_bits", "register_file_bits", "mapping_bits", "ownership_bits",
            "checkpoint_bits", "additional_control_bits", "reservation_station_bits",
            "load_buffer_bits", "store_buffer_bits", "cdb_result_buffer_bits")))

    def test_paired_sweeps_and_serialization_with_identical_useful_work(self):
        c = configure({"workload": {"instructions": 100}, "branch": {"recovery_latency": fixed(1)}})
        grid = {"basic_block.merging.width": [1, 2], "basic_block.flushing.width": [1, 4]}
        r = experiment(c, [42, 43], grid)
        self.assertEqual(r, experiment(c, [42, 43], grid))
        self.assertEqual(len(r["runs"]), 24)
        self.assertEqual({run["committed"] for run in r["runs"]}, {100})
        self.assertEqual(len(r["paired_ipc_improvement"]), 12)
        self.assertTrue(all(row["ci_low"] <= row["mean"] <= row["ci_high"] for row in r["ipc_summary"]))
        self.assertEqual(len({row["ipc"] for row in r["runs"]
                              if row["architecture"] == ARCHITECTURES[0] and row["seed"] == 42}), 1)
        with temporary_build() as tmp:
            output = Path(tmp)
            write_tables(r, output)
            self.assertEqual(len(json.loads((output / "report.json").read_text())["runs"]), 24)
            with (output / "runs.csv").open() as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(len(rows), 24)
            self.assertIn("storage.total_bits", rows[0])
