#!/usr/bin/env python3
"""Verify independent SRAM configuration, linker generation, and explicit rejection of unsafe settings."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = Path(os.environ.get("TC_SRAM_CONFIG_BUILD_DIR", root / "build/tc-sram-config"))
build.mkdir(parents=True, exist_ok=True)
cases = [
    ("valid", {}, "", ""),
    ("latency-zero", {"I_LATENCY": "0", "D_LATENCY": "0"}, "", ""),
    ("async-instruction", {"I_LATENCY": "0", "D_LATENCY": "3"}, "", ""),
    ("async-data", {"I_LATENCY": "4", "D_LATENCY": "0"}, "", ""),
    ("latency-eight", {"I_LATENCY": "8", "D_LATENCY": "8"}, "", ""),
    ("instruction-latency-above-frontend-depth", {"I_LATENCY": "17", "D_LATENCY": "1"}, "", ""),
    ("long-instruction-async-data", {"I_LATENCY": "12", "D_LATENCY": "0"}, "", ""),
    ("nonbinary-words", {"I_SIZE": "48", "D_SIZE": "24"}, "", ""),
    ("memory-overlap", {"D_BASE": "64'h1000"}, "regions overlap", ""),
    ("unaligned-imem", {"I_BASE": "64'h1008"}, "Invalid IMEM", ""),
    ("unaligned-dmem", {"D_BASE": "64'h2001"}, "Invalid DMEM", ""),
    ("overflow-imem", {"I_BASE": "64'hfffffffffffffff0"}, "Invalid IMEM", ""),
    ("overflow-dmem", {"D_BASE": "64'hfffffffffffffff8"}, "Invalid DMEM", ""),
    ("fractional-imem", {"I_SIZE": "257"}, "Invalid IMEM", ""),
    ("fractional-dmem", {"D_SIZE": "9"}, "Invalid DMEM", ""),
    ("empty-imem", {"I_SIZE": "0"}, "Invalid IMEM", ""),
    ("empty-dmem", {"D_SIZE": "0"}, "Invalid DMEM", ""),
    ("imem-mmio-overlap", {"I_BASE": "64'h20000000"}, "overlapping SRAM/MMIO", ""),
    ("dmem-mmio-overlap", {"D_BASE": "64'h20000000"}, "overlapping SRAM/MMIO", ""),
    ("mmio-overlap", {"EXIT": "64'h20000000"}, "overlapping SRAM/MMIO", ""),
    ("unaligned-mmio", {"EXIT": "64'h20000101"}, "overlapping SRAM/MMIO", ""),
    ("forwarding-mask", {"SERIAL": "64'h4000"}, "MMAP_MASK", ""),
    ("response-capacity", {"D_LATENCY": "4", "CAPACITY": "4"}, "response capacity", ""),
    ("doubleword-mode", {}, "original load offsets", "ONLY_DOUBLEWORD_MEM_ACCESSES"),
    ("compressed-mode", {}, "original load offsets", "LEN5_C_EN"),
]
results = []
for name, parameters, diagnostic, cpu_setting in cases:
    out = build / name
    out.mkdir(exist_ok=True)
    config = root / "rtl/packages/len5_config_pkg.sv"
    if cpu_setting:
        content = config.read_text().replace(f"{cpu_setting} = 1'b0", f"{cpu_setting} = 1'b1")
        config = out / "len5_config_pkg.sv"
        config.write_text(content)
    sources = ["rtl/packages/util_pkg.sv", str(config), "rtl/packages/len5_pkg.sv",
               "tb/packages/tb_config_pkg.sv", "tb/memory/tc_sram/memory_backend_pkg.sv",
               "tb/memory/tc_sram/memory_access_check.sv", "tb/memory/tc_sram/memory_response_buffer.sv",
               "tb/memory/tc_sram/tc_sram_adapter.sv", "tb/memory/tc_sram/tc_sram_config_tb.sv"]
    cmd = [os.environ.get("VERILATOR", "verilator"), "--binary", "--timing", "--assert", "-j", "4",
           "-MAKEFLAGS", "OBJCACHE= CXX=/usr/bin/g++", "--Mdir", str(out), "--top-module", "tc_sram_config_tb"]
    cmd += [f"-G{key}={value}" for key, value in parameters.items()] + sources
    with (out / "build.log").open("w") as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
    run = subprocess.run([str(out / "Vtc_sram_config_tb")], capture_output=True, text=True)
    text = run.stdout + run.stderr
    (out / "run.log").write_text(text)
    assert (run.returncode != 0 and diagnostic in text) if diagnostic else (
        run.returncode == 0 and "PASS valid" in text), text
    results.append({"case": name, "status": "passed", "rejected": bool(diagnostic)})
    print(f"PASS {name}", flush=True)

# Exercise the actual generator with independent expected values, including a non-default map.
source = (root / "tb/packages/tb_config_pkg.sv").read_text()
for name, changes, valid in [
    ("default", {}, True),
    ("sized-values", {"256 * 1024": "32'd262144", "768 * 1024": "32'd786432"}, True),
    ("truncated-literal", {"256 * 1024": "8'd256"}, False),
    ("relocated", {"64'h0001_0000": "64'h0040_0000", "64'h0005_0000": "64'h0060_0000"}, True),
    ("overlap", {"64'h0005_0000": "64'h0001_0000"}, False),
    ("overflow", {"64'h0001_0000": "64'hffff_ffff_ffff_fff8"}, False),
    ("unaligned", {"64'h0001_0000": "64'h0001_0001"}, False),
    ("fractional", {"256 * 1024": "9"}, False),
    ("zero-size", {"768 * 1024": "0"}, False),
    ("mmio-overlap", {"64'h2000_0000": "64'h0001_0000"}, False),
]:
    directory = build / ("generator-" + name)
    directory.mkdir(exist_ok=True)
    content = source
    for old, new in changes.items():
        assert old in content
        content = content.replace(old, new)
    config = directory / "tb_config_pkg.sv"
    config.write_text(content)
    run = subprocess.run(["python3", "scripts/gen-memory-map.py", str(directory / "map.h"),
                          "--config", str(config), "--linker", str(directory / "regions.ld")], capture_output=True, text=True)
    assert (run.returncode == 0) == valid, run.stdout + run.stderr
    if valid:
        text = (directory / "regions.ld").read_text()
        bases = (0x400000, 0x600000) if name == "relocated" else (0x10000, 0x50000)
        assert f"ROM (rx) : ORIGIN = 0x{bases[0]:x}, LENGTH = 0x40000" in text
        assert f"RAM (rw) : ORIGIN = 0x{bases[1]:x}, LENGTH = 0xc0000" in text
    results.append({"case": "generator-" + name, "status": "passed", "rejected": not valid})
    print("PASS generator-" + name, flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
