#!/usr/bin/env python3
"""Create an isolated, reproducible source snapshot for a memory backend build."""
import argparse
import re
import shutil
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("backend", choices=("LEGACY", "TC_SRAM", "AXI_SIM"))
p.add_argument("destination", type=Path)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
dest = a.destination.resolve()
if dest == root or dest in root.parents:
    p.error("destination must not contain the source repository")
if dest.exists():
    p.error("use a new destination to preserve previous results")
dest.mkdir(parents=True)
# Prevent the parent repository library from discovering cores in this snapshot.
if root in dest.parents:
    (root / "build").mkdir(exist_ok=True)
    (root / "build/FUSESOC_IGNORE").touch()
for name in ("rtl", "tb", "scripts", "sw"):
    shutil.copytree(root / name, dest / name, ignore=shutil.ignore_patterns("__pycache__", "build", ".git"))
for name in ("len5.core", "fusesoc.conf", "makefile"):
    shutil.copy2(root / name, dest / name)
config = dest / "tb/packages/tb_config_pkg.sv"
config.write_text(re.sub(r"(localparam memory_backend_t MEMORY_BACKEND = )\w+;",
                         r"\g<1>MEM_BACKEND_" + a.backend + ";", config.read_text()))
cpu_config = dest / "rtl/packages/len5_config_pkg.sv"
cpu_config.write_text(re.sub(r"(LOAD_BUFFER_DRAIN_ON_FLUSH\s*=\s*)1'b[01]",
                            r"\g<1>1'b" + ("1" if a.backend == "AXI_SIM" else "0"),
                            cpu_config.read_text()))
cpu_config.write_text(re.sub(r"(FETCH_MEM_DRAIN_ON_FLUSH\s*=\s*)1'b[01]",
                            r"\g<1>1'b" + ("0" if a.backend == "LEGACY" else "1"),
                            cpu_config.read_text()))
print(dest)
