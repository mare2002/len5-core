#!/usr/bin/env python3
"""Check testbench's elaboration errors using a FuseSoC source list."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("file_list", type=Path, help="FuseSoC-generated polito_len5_len5_0.1.1.vc")
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
file_list = a.file_list.resolve()
sources = []
for line in file_list.read_text().splitlines():
    if line.startswith("+incdir+"):
        sources.append("+incdir+" + str((file_list.parent / line[8:]).resolve()))
    elif line.endswith((".sv", ".v", ".vlt")) and not line.startswith("-"):
        sources.append(str((file_list.parent / line).resolve()))
config_index = next(i for i, s in enumerate(sources) if s.endswith("/tb_config_pkg.sv"))
original = Path(sources[config_index]).read_text()
cpu_index = next(i for i, s in enumerate(sources) if s.endswith("/len5_config_pkg.sv"))
cpu_original = Path(sources[cpu_index]).read_text()
build = root / "build/memory-backend-selection"
results = []
for name, setting, drain, fetch_drain, message in (
        ("legacy", "MEM_BACKEND_LEGACY", False, False, ""),
        ("tc-sram", "MEM_BACKEND_TC_SRAM", True, True, ""),
        ("axi", "MEM_BACKEND_AXI_SIM", True, True, ""),
        ("invalid", "memory_backend_t'(2'd3)", False, False, "Invalid MEMORY_BACKEND"),
        ("axi-without-retained-tags", "MEM_BACKEND_AXI_SIM", False, True, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("sram-without-retained-tags", "MEM_BACKEND_TC_SRAM", False, True, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("legacy-with-retained-tags", "MEM_BACKEND_LEGACY", True, False, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("sram-without-fetch-drain", "MEM_BACKEND_TC_SRAM", True, False, "FETCH_MEM_DRAIN_ON_FLUSH"),
        ("legacy-with-fetch-drain", "MEM_BACKEND_LEGACY", False, True, "FETCH_MEM_DRAIN_ON_FLUSH")):

    out = build / name
    out.mkdir(parents=True, exist_ok=True)
    config = out / "tb_config_pkg.sv"
    config.write_text(re.sub(r"(localparam memory_backend_t MEMORY_BACKEND = )[^;]+;",
                             r"\g<1>" + setting + ";", original))
    sources[config_index] = str(config)
    cpu_config = out / "len5_config_pkg.sv"
    cpu_config.write_text(re.sub(r"(LOAD_BUFFER_DRAIN_ON_FLUSH\s*=\s*)1'b[01]",
                                 r"\g<1>1'b" + ("1" if drain else "0"), cpu_original))
    cpu_config.write_text(re.sub(r"(FETCH_MEM_DRAIN_ON_FLUSH\s*=\s*)1'b[01]",
                                 r"\g<1>1'b" + ("1" if fetch_drain else "0"), cpu_config.read_text()))
    sources[cpu_index] = str(cpu_config)
    cmd = [os.environ.get("VERILATOR", "verilator"), "--lint-only", "--timing", "--timescale", "1ps/1ps", "-fno-dfg",
           "--Mdir", str(out), "--top-module", "tb_bare"] + sources
    run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / "build.log").write_text(run.stdout)
    assert (run.returncode != 0 and message in run.stdout) if message else run.returncode == 0, run.stdout
    results.append({"selection": name, "status": "passed", "diagnostic": message})
    print(f"PASS {name}: {'rejected' if message else 'accepted'}", flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
