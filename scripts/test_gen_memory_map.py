#!/usr/bin/env python3
"""Check firmware map geometry and explicit overrides against independent values."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent / "tb/packages/tb_config_pkg.sv"
spec = importlib.util.spec_from_file_location("memory_map", HERE / "gen-memory-map.py")
memory_map = importlib.util.module_from_spec(spec)
spec.loader.exec_module(memory_map)


class MemoryMapTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)

    def test_default(self):
        self.assertEqual(memory_map.settings(SOURCE), {
            "IMEM_BASE_ADDR": 0x10000, "IMEM_SIZE_BYTES": 0x40000,
            "DMEM_BASE_ADDR": 0x50000, "DMEM_SIZE_BYTES": 0xc0000,
            "SERIAL_ADDR": 0x20000000, "EXIT_ADDR": 0x20000100})

    def test_environment_relocation_sizes_and_mmio(self):
        with patch.dict(os.environ, {"IMEM_BASE_ADDR": "0x400000", "IMEM_SIZE_BYTES": "512 * 1024",
                                    "DMEM_BASE_ADDR": "0x600000", "DMEM_SIZE_BYTES": "32'd65536",
                                    "SERIAL_ADDR": "0x30000000", "EXIT_ADDR": "0x30000100"}):
            self.assertEqual(memory_map.settings(SOURCE), {
                "IMEM_BASE_ADDR": 0x400000, "IMEM_SIZE_BYTES": 0x80000,
                "DMEM_BASE_ADDR": 0x600000, "DMEM_SIZE_BYTES": 0x10000,
                "SERIAL_ADDR": 0x30000000, "EXIT_ADDR": 0x30000100})

    def test_custom_source_and_environment_precedence(self):
        custom = self.path / "tb_config_pkg.sv"
        custom.write_text(SOURCE.read_text().replace("64'h0001_0000", "64'h0040_0000"))
        self.assertEqual(memory_map.settings(custom)["IMEM_BASE_ADDR"], 0x400000)
        with patch.dict(os.environ, {"IMEM_BASE_ADDR": "0x800000"}):
            self.assertEqual(memory_map.settings(custom)["IMEM_BASE_ADDR"], 0x800000)

    def test_invalid_geometry(self):
        cases = [
            {"IMEM_BASE_ADDR": "0xfffffffffffffff8"},
            {"DMEM_BASE_ADDR": "0xfffffffffffffff8"},
            {"IMEM_BASE_ADDR": "0x10001"}, {"DMEM_BASE_ADDR": "0x50001"},
            {"IMEM_SIZE_BYTES": "0"}, {"DMEM_SIZE_BYTES": "0"},
            {"IMEM_SIZE_BYTES": "9"}, {"DMEM_SIZE_BYTES": "9"},
            {"IMEM_SIZE_BYTES": "4294967296"}, {"DMEM_SIZE_BYTES": "-1"},
            {"DMEM_BASE_ADDR": "0x10000"},
            {"SERIAL_ADDR": "0x10000"}, {"EXIT_ADDR": "0x50000"},
            {"SERIAL_ADDR": "0x20000100"}, {"EXIT_ADDR": "0x20000101"},
            {"IMEM_BASE_ADDR": "0x10000000000000000"},
        ]
        for changes in cases:
            with self.subTest(changes=changes), patch.dict(os.environ, changes), self.assertRaises(ValueError):
                memory_map.settings(SOURCE)

    def test_adjacent_regions_and_last_address(self):
        with patch.dict(os.environ, {"DMEM_BASE_ADDR": "0x50000", "IMEM_SIZE_BYTES": "0x40000",
                                    "EXIT_ADDR": "0xfffffffffffffff8"}):
            self.assertEqual(memory_map.settings(SOURCE)["EXIT_ADDR"], 2**64 - 8)
        with patch.dict(os.environ, {"IMEM_BASE_ADDR": "0xfffffffffffffff8", "IMEM_SIZE_BYTES": "8"}):
            self.assertEqual(memory_map.settings(SOURCE)["IMEM_SIZE_BYTES"], 8)

    def test_cli_generates_selected_header_and_linker(self):
        header, linker = self.path / "map.h", self.path / "regions.ld"
        command = [sys.executable, str(HERE / "gen-memory-map.py"), str(header),
                   "--config", str(SOURCE), "--linker", str(linker)]
        environment = {"IMEM_BASE_ADDR": "0x400000", "DMEM_BASE_ADDR": "0x600000", "SERIAL_ADDR": "0x30000000"}
        result = subprocess.run(command, env=environment, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("#define LEN5_SERIAL_ADDR 0x30000000UL", header.read_text())
        self.assertIn("ROM (rx) : ORIGIN = 0x400000, LENGTH = 0x40000", linker.read_text())
        self.assertIn("RAM (rw) : ORIGIN = 0x600000, LENGTH = 0xc0000", linker.read_text())
        timestamp = header.stat().st_mtime_ns
        subprocess.run(command, env=environment, capture_output=True, text=True, check=True)
        self.assertEqual(header.stat().st_mtime_ns, timestamp)


if __name__ == "__main__":
    unittest.main()
