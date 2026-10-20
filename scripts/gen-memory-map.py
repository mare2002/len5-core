#!/usr/bin/env python3
"""Generate firmware MMIO constants and linker regions from the testbench configuration."""
import argparse
import re
from pathlib import Path


def settings(config):
    source = config.read_text()
    values = {}
    for name in ("IMEM_BASE_ADDR", "DMEM_BASE_ADDR", "SERIAL_ADDR", "EXIT_ADDR"):
        match = re.search(r"localparam\s+logic\s*\[63:0\]\s+" + name + r"\s*=\s*64'h([0-9a-fA-F_]+)\s*;", source)
        if not match:
            raise ValueError(f"{name} must be a literal 64-bit hex address in {config}")
        values[name] = int(match[1].replace("_", ""), 16)
        if values[name] >= 1 << 64:
            raise ValueError(f"{name} exceeds 64 bits")
    for name in ("IMEM_SIZE_BYTES", "DMEM_SIZE_BYTES"):
        match = re.search(r"localparam\s+int\s+unsigned\s+" + name + r"\s*=\s*([^;]+);", source)
        if not match:
            raise ValueError(f"missing {name} in {config}")
        value = 1
        for factor in match[1].split("*"):
            number = re.fullmatch(r"(?:32'd)?([0-9_]+)", factor.strip())
            if not number:
                raise ValueError(f"{name} must be an unsigned decimal value or product in {config}")
            value *= int(number[1].replace("_", ""))
        if not 8 <= value < 1 << 32 or value % 8:
            raise ValueError(f"{name} must be a positive multiple of eight fitting 32 bits")
        values[name] = value
    windows = []
    for name in ("IMEM", "DMEM"):
        base, size = values[name + "_BASE_ADDR"], values[name + "_SIZE_BYTES"]
        if base % 8 or base + size > 1 << 64:
            raise ValueError(f"invalid {name} alignment or address overflow")
        windows.append((base, base + size))
    if max(windows[0][0], windows[1][0]) < min(windows[0][1], windows[1][1]):
        raise ValueError("IMEM and DMEM overlap")
    serial, exit_addr = values["SERIAL_ADDR"], values["EXIT_ADDR"]
    if serial % 8 or exit_addr % 8 or serial == exit_addr:
        raise ValueError("MMIO addresses must be distinct and eight-byte aligned")
    for address in (serial, exit_addr):
        if any(address < end and address + 8 > base for base, end in windows):
            raise ValueError("MMIO overlaps IMEM or DMEM")
    return values


def write_if_changed(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text() != text:
        path.write_text(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--config", type=Path, default=Path(__file__).resolve().parents[1] / "tb/packages/tb_config_pkg.sv")
    parser.add_argument("--linker", type=Path, help="also generate the ROM/RAM MEMORY declaration")
    args = parser.parse_args()
    try:
        values = settings(args.config)
    except ValueError as error:
        parser.error(str(error))
    lines = ["/* Generated from tb_config_pkg.sv; do not edit. */"]
    for name in ("SERIAL_ADDR", "EXIT_ADDR"):
        lines.extend([f"#ifndef LEN5_{name}", f"#define LEN5_{name} 0x{values[name]:x}UL", "#endif"])
    write_if_changed(args.output, "\n".join(lines) + "\n")
    if args.linker:
        lines = ["/* Generated from tb_config_pkg.sv; do not edit. */", "MEMORY", "{"]
        for region, name in (("ROM (rx)", "IMEM"), ("RAM (rw)", "DMEM")):
            lines.append(f"  {region} : ORIGIN = 0x{values[name + '_BASE_ADDR']:x}, LENGTH = 0x{values[name + '_SIZE_BYTES']:x}")
        lines.append("}")
        write_if_changed(args.linker, "\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
