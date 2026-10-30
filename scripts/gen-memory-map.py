#!/usr/bin/env python3
"""Generate firmware MMIO constants and linker regions from the testbench configuration."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def build_arguments(kind="rtl", environ=None, output="fusesoc", exclude=()):
    """Forward explicit overrides; configuration values are built by SystemVerilog."""
    result = subprocess.run(["bash", str(ROOT / "scripts/sim/config-args.sh"), kind, output,
                             ",".join(exclude)], env=os.environ if environ is None else environ,
                            capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr.strip())
    return result.stdout.splitlines()


def elaborated_configuration(kind="rtl", environ=None, source=None):
    """Read a cached SV probe result, without parsing or evaluating SV expressions."""
    environment = os.environ if environ is None else environ
    sources = [ROOT / "rtl/packages/len5_config_pkg.sv", ROOT / "rtl/packages/len5_pkg.sv",
               Path(source) if source and kind == "tb" else ROOT / "tb/packages/tb_config_pkg.sv",
               ROOT / "tb/tb_bare.sv", ROOT / "tb/config/len5_config_probe.sv"]
    if source and kind == "rtl":
        sources[0] = Path(source)
    arguments = build_arguments("all", environment, "verilator")
    executable = environment.get("VERILATOR") or shutil.which("verilator", path=environment.get("PATH"))
    if not executable:
        raise ValueError("Verilator is required to elaborate the selected SV configuration")
    version = subprocess.check_output([executable, "--version"], text=True)
    digest = hashlib.sha256(json.dumps([arguments, executable, version]).encode())
    contents = [path.read_bytes() for path in sources]
    for content in contents:
        digest.update(content)
    directory = ROOT / "build/config-probe" / digest.hexdigest()
    directory.mkdir(parents=True, exist_ok=True)
    (ROOT / "build/FUSESOC_IGNORE").touch()
    receipt = directory / "configuration.json"
    with (directory / "lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not receipt.exists():
            compiled_sources = []
            for index in (0, 1, 2, len(sources) - 1):
                snapshot = directory / ("source-" + str(index)) / sources[index].name
                snapshot.parent.mkdir(exist_ok=True)
                snapshot.write_bytes(contents[index])
                compiled_sources.append(str(snapshot))
            command = [executable, "--binary", "--top-module", "len5_config_probe",
                       "--Mdir", str(directory), "-j", "2", "-MAKEFLAGS",
                       "OBJCACHE= CXX=/usr/bin/g++ LINK=/usr/bin/g++",
                       "+incdir+" + str(ROOT / "tb/packages"), *arguments,
                       *compiled_sources]
            with (directory / "build.log").open("w") as log:
                build_environment = dict(os.environ)
                build_environment.setdefault("PATH", os.defpath)
                result = subprocess.run(command, env=build_environment, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                raise ValueError("SV configuration elaboration failed: " + str(directory / "build.log"))
            result = subprocess.check_output([str(directory / "Vlen5_config_probe")], text=True)
            selected = json.loads(next(line for line in result.splitlines() if line.startswith('{"rtl":')))
            temporary = receipt.with_suffix(".tmp")
            temporary.write_text(json.dumps(selected, sort_keys=True) + "\n")
            temporary.replace(receipt)
    return json.loads(receipt.read_text())[kind]


def settings(config):
    selected = elaborated_configuration("tb", source=config)
    values = {name: selected[name] for name in (
        "IMEM_BASE_ADDR", "DMEM_BASE_ADDR", "SERIAL_ADDR", "EXIT_ADDR", "IMEM_SIZE_BYTES", "DMEM_SIZE_BYTES")}
    for name in ("IMEM_SIZE_BYTES", "DMEM_SIZE_BYTES"):
        if not 8 <= values[name] < 1 << 32 or values[name] % 8:
            raise ValueError(f"{name} must be a positive multiple of eight fitting 32 bits")
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
    except (OSError, ValueError) as error:
        parser.error(str(error))
    lines = ["/* Generated from the selected TB configuration; do not edit. */"]
    for name in ("SERIAL_ADDR", "EXIT_ADDR"):
        lines.extend([f"#ifndef LEN5_{name}", f"#define LEN5_{name} 0x{values[name]:x}UL", "#endif"])
    write_if_changed(args.output, "\n".join(lines) + "\n")
    if args.linker:
        lines = ["/* Generated from the selected TB configuration; do not edit. */", "MEMORY", "{"]
        for region, name in (("ROM (rx)", "IMEM"), ("RAM (rw)", "DMEM")):
            lines.append(f"  {region} : ORIGIN = 0x{values[name + '_BASE_ADDR']:x}, LENGTH = 0x{values[name + '_SIZE_BYTES']:x}")
        lines.append("}")
        write_if_changed(args.linker, "\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
