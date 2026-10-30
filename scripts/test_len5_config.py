#!/usr/bin/env python3
"""Check the SV configuration builder and the scalar tool boundary."""
import importlib.util
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("memory_map", ROOT / "scripts/gen-memory-map.py")
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigurationTests(unittest.TestCase):
    def test_default_builder(self):
        c = config.elaborated_configuration(environ={})
        self.assertEqual((c["LEN5_MULTIPLE_ISSUES"], c["ROB_DEPTH"], c["FLEN"]), (8, 32, 64))
        self.assertEqual((c["ROB_IDX_LEN"], c["BUFF_IDX_LEN"], c["REGSTAT_CNT_W"]), (5, 4, 6))

    def test_derived_fields_follow_selected_inputs(self):
        c = config.elaborated_configuration(environ={"ROB_DEPTH": "64", "LDBUFF_DEPTH": "4",
            "STBUFF_DEPTH": "8", "LEN5_MULTIPLE_ISSUES": "2", "LEN5_D_EN": "0"})
        self.assertEqual((c["ROB_IDX_LEN"], c["BUFF_IDX_LEN"], c["REGSTAT_CNT_W"]), (6, 3, 7))
        self.assertEqual((c["LEN5_MULTIPLE_ISSUES_BITS"], c["LWIDTH"], c["FLEN"]), (1, 64, 32))
        self.assertEqual((c["IMEM_DATA_WIDTH"], c["TAG_COUNT"]), (64, 8))

    def test_tb_geometry_is_built_with_selected_cpu(self):
        c = config.elaborated_configuration("tb", environ={"LEN5_MULTIPLE_ISSUES": "4",
            "IMEM_SIZE_BYTES": "256", "DMEM_SIZE_BYTES": "512", "IMEM_LATENCY": "7", "DMEM_LATENCY": "3"})
        self.assertEqual((c["IMEM_DATA_WIDTH"], c["IMEM_ADDR_WIDTH"], c["DMEM_ADDR_WIDTH"]), (128, 4, 6))
        self.assertEqual((c["SRAM_RESPONSE_DEPTH"], c["SRAM_COUNT_WIDTH"]), (4, 3))

    def test_lossless_wide_fusesoc_transport(self):
        self.assertEqual(config.build_arguments(environ={"BOOT_PC": "0x100000180"}),
                         ["--BOOT_PC_HI=1", "--BOOT_PC_LO=384"])
        self.assertEqual(config.build_arguments(environ={"MMAP_MASK": "0xffffffffffffffff"}),
                         ["--MMAP_MASK_HI=4294967295", "--MMAP_MASK_LO=4294967295"])

    def test_only_explicit_settings_are_forwarded(self):
        self.assertEqual(config.build_arguments(environ={}), [])
        self.assertEqual(config.build_arguments(environ={"ROB_DEPTH": "16"}), ["--ROB_DEPTH=16"])
        self.assertEqual(config.build_arguments(environ={"BOOT_PC": "384"}, exclude=["BOOT_PC"]), [])

    def test_enums_and_booleans(self):
        self.assertEqual(config.build_arguments("tb", {"MEMORY_BACKEND": "TC_SRAM"}), ["--MEMORY_BACKEND=1"])
        self.assertEqual(config.build_arguments(environ={"LEN5_D_EN": "false"}), ["--LEN5_D_EN=0"])

    def test_direct_compiler_values_are_sized(self):
        self.assertEqual(config.build_arguments(environ={"BOOT_PC": "0x100000180"}, output="verilator"),
                         ["-GBOOT_PC=64'h100000180"])

    def test_invalid_override_values_fail(self):
        for name, value in [("ROB_DEPTH", "-1"), ("ROB_DEPTH", "4294967296"),
            ("BOOT_PC", "0x10000000000000000"), ("BPU_INIT_C2B", "4"),
            ("LEN5_D_EN", "2"), ("MEMORY_BACKEND", "INVALID"),
            ("ROB_DEPTH", "8'd256"), ("ROB_DEPTH", "__import__('os')")]:
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                config.build_arguments("all", {name: value})

    def test_no_python_configuration_parser(self):
        self.assertFalse((ROOT / "scripts/len5_config.py").exists())
        source = (ROOT / "scripts/sim/build-verilator.sh").read_text()
        self.assertIn("config-args.sh", source)
        self.assertNotIn("python3", source)


if __name__ == "__main__":
    unittest.main()
