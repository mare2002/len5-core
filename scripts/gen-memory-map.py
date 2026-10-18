#!/usr/bin/env python3
"""Generate firmware MMIO constants from the RTL configuration (no duplicate defaults)."""
import argparse
import re
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "tb/packages/tb_config_pkg.sv")
args = parser.parse_args()
source = args.config.read_text()
lines = ["/* Generated from tb_config_pkg.sv; do not edit. */"]
for name in ("SERIAL_ADDR", "EXIT_ADDR"):
    match = re.search(r"localparam\s+logic\s*\[63:0\]\s+" + name + r"\s*=\s*64'h([0-9a-fA-F_]+)\s*;", source)
    if not match:
        parser.error(f"{name} must be a literal 64-bit hex address in {args.config}")
    value = int(match[1].replace("_", ""), 16)
    lines.extend([f"#ifndef LEN5_{name}", f"#define LEN5_{name} 0x{value:x}UL", "#endif"])
args.output.parent.mkdir(parents=True, exist_ok=True)
text = "\n".join(lines) + "\n"
if not args.output.exists() or args.output.read_text() != text:
    args.output.write_text(text)
