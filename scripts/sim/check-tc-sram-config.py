#!/usr/bin/env python3
"""Verify supported configuration and explicit rejection of unsafe SRAM settings."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = root / "build/tc-sram-config"
build.mkdir(parents=True, exist_ok=True)
cases = ["valid", "latency-zero", "latency-two", "sram-mmio-overlap", "unaligned-base",
         "overflow-window", "fractional-word", "forwarding-mask", "mmio-overlap", "unaligned-mmio",
         "doubleword-mode", "compressed-mode", "latency-eight", "response-capacity"]
results = []
for index, name in enumerate(cases):
    out = build / name
    out.mkdir(exist_ok=True)
    config = root / "rtl/packages/len5_config_pkg.sv"
    if index in (10, 11):
        content = config.read_text()
        setting = "ONLY_DOUBLEWORD_MEM_ACCESSES" if index == 10 else "LEN5_C_EN"
        content = content.replace(f"{setting} = 1'b0", f"{setting} = 1'b1")
        config = out / "len5_config_pkg.sv"
        config.write_text(content)
    sources = ["rtl/packages/util_pkg.sv", str(config), "rtl/packages/len5_pkg.sv",
               "tb/packages/tb_config_pkg.sv", "tb/memory/tc_sram/memory_backend_pkg.sv", "tb/memory/tc_sram/memory_access_check.sv",
               "tb/memory/tc_sram/memory_response_buffer.sv", "tb/memory/tc_sram/tc_sram_adapter.sv",
               "tb/memory/tc_sram/tc_sram_config_tb.sv"]
    cmd = [os.environ.get("VERILATOR", "verilator"), "--binary", "--timing", "--assert", "-j", "4",
           "-MAKEFLAGS", "OBJCACHE= CXX=/usr/bin/g++", "--Mdir", str(out),
           "--top-module", "tc_sram_config_tb", f"-GTEST_CASE={0 if index in (10, 11) else index}"] + sources
    with (out / "build.log").open("w") as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
    run = subprocess.run([str(out / "Vtc_sram_config_tb")], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    (out / "run.log").write_text(run.stdout)
    valid = index in (0, 2, 12)
    assert (run.returncode == 0 and "PASS valid" in run.stdout) if valid else (
        run.returncode != 0 and "tc_sram_adapter.sv" in run.stdout), run.stdout
    results.append({"case": name, "status": "passed", "rejected": not valid})
    print(f"PASS {name}", flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
