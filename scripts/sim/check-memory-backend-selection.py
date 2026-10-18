#!/usr/bin/env python3
"""Check datapath's elaboration errors using a FuseSoC source list."""
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
config_index = next(i for i, s in enumerate(sources) if s.endswith("/len5_config_pkg.sv"))
original = Path(sources[config_index]).read_text()
build = root / "build/memory-backend-selection"
results = []
for name, setting, message in (("axi", "MEM_BACKEND_AXI_SIM", "not implemented"),
                               ("invalid", "memory_backend_t'(2'd3)", "Invalid MEMORY_BACKEND")):
    out = build / name
    out.mkdir(parents=True, exist_ok=True)
    config = out / "len5_config_pkg.sv"
    config.write_text(re.sub(r"(localparam memory_backend_t MEMORY_BACKEND = )[^;]+;",
                             r"\g<1>" + setting + ";", original))
    sources[config_index] = str(config)
    cmd = [os.environ.get("VERILATOR", "verilator"), "--lint-only", "--timing", "-fno-dfg",
           "--Mdir", str(out), "--top-module", "tb_bare"] + sources
    run = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (out / "build.log").write_text(run.stdout)
    assert run.returncode != 0 and message in run.stdout, run.stdout
    results.append({"selection": name, "status": "passed", "diagnostic": message})
    print(f"PASS rejected {name}", flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
