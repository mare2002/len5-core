#!/usr/bin/env python3
"""Create an isolated, reproducible source snapshot for a memory backend build."""
import argparse
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
drain = int(a.backend != "LEGACY")
(dest / "config.mk").write_text(
    f"MEMORY_BACKEND = {a.backend}\n"
    f"LOAD_BUFFER_DRAIN_ON_FLUSH = {drain}\n"
    f"FETCH_MEM_DRAIN_ON_FLUSH = {drain}\n"
)
makefile = dest / "makefile"
text = makefile.read_text()
if not any(line.strip() in ("include config.mk", "-include config.mk") for line in text.splitlines()):
    makefile.write_text("-include config.mk\n\n" + text)
print(dest)
