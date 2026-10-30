#!/usr/bin/env python3
"""Check testbench's elaboration errors using a FuseSoC source list."""
import argparse
import json
import os
from pathlib import Path
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
build = root / "build/memory-backend-selection"
results = []
for name, setting, drain, fetch_drain, message in (
        ("legacy", 0, False, False, ""),
        ("tc-sram", 1, True, True, ""),
        ("axi", 2, True, True, ""),
        ("invalid", 3, False, False, "Invalid MEMORY_BACKEND"),
        ("axi-without-retained-tags", 2, False, True, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("sram-without-retained-tags", 1, False, True, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("legacy-with-retained-tags", 0, True, False, "LOAD_BUFFER_DRAIN_ON_FLUSH"),
        ("sram-without-fetch-drain", 1, True, False, "FETCH_MEM_DRAIN_ON_FLUSH"),
        ("legacy-with-fetch-drain", 0, False, True, "FETCH_MEM_DRAIN_ON_FLUSH")):

    out = build / name
    out.mkdir(parents=True, exist_ok=True)
    cmd = [os.environ.get("VERILATOR", "verilator"), "--lint-only", "--timing", "--timescale", "1ps/1ps", "-fno-dfg",
           "--Mdir", str(out), "--top-module", "tb_bare", f"-GMEMORY_BACKEND={setting}",
           f"-GLOAD_BUFFER_DRAIN_ON_FLUSH={int(drain)}", f"-GFETCH_MEM_DRAIN_ON_FLUSH={int(fetch_drain)}"] + sources
    run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / "build.log").write_text(run.stdout)
    assert (run.returncode != 0 and message in run.stdout) if message else run.returncode == 0, run.stdout
    results.append({"selection": name, "status": "passed", "diagnostic": message})
    print(f"PASS {name}: {'rejected' if message else 'accepted'}", flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
