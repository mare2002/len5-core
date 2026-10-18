#!/usr/bin/env python3
"""Exercise native initialization, all firmware formats, bounds and malformed input."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = root / "build/tc-sram-loader"
build.mkdir(parents=True, exist_ok=True)
images = {
    "image.hex": "// byte image\n@4000 11 22 33 44 /* little endian */ 55 66 77 88\n@4010 aa bb cc dd\n",
    "image.txt": "4000 44332211\n4004 88776655\n4010 ddccbbaa\n",
    "below.hex": "@3fff 11\n",
    "above.hex": "@4018 11\n",
    "cross.txt": "4016 12345678\n",
    "alias.hex": "@10000000000004000 11\n",
    "bad.hex": "@4000 g1\n",
    "wide.hex": "@4000 123\n",
    "empty.hex": "// nothing\n",
}
for name, data in images.items():
    (build / name).write_text(data)
(build / "image.bin").write_bytes(bytes.fromhex("1122334455667788"))
sources = ["rtl/misc/packages-waivers.vlt", "tb/memory/tc_sram/waivers.vlt",
           "rtl/packages/util_pkg.sv", "rtl/packages/len5_config_pkg.sv", "rtl/packages/len5_pkg.sv",
           "tb/packages/tb_config_pkg.sv", "tb/memory/tc_sram/memory_backend_pkg.sv", "rtl/vendor/tech_cells_generic/tc_sram.sv",
           "+incdir+tb/memory", "tb/memory/tc_sram_storage.sv", "tb/memory/tc_sram/tc_sram_loader_tb.sv"]
for mode in ("ones", "zeros", "none", "random"):
    out = build / mode
    out.mkdir(exist_ok=True)
    cmd = [os.environ.get("VERILATOR", "verilator"), "--binary", "--timing", "--assert", "-j", "4",
           "-MAKEFLAGS", "OBJCACHE= CXX=/usr/bin/g++", "--Mdir", str(out), "--top-module", "tc_sram_loader_tb",
           "-Wall", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM", f'-GSIM_INIT="{mode}"'] + sources
    with (out / "build.log").open("w") as log:
        subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
    for name in ("image.hex", "image.txt", "image.bin") + (tuple(images)[2:] if mode == "ones" else ()):
        good = name.startswith("image.")
        args = [str(out / "Vtc_sram_loader_tb"), f"+firmware={build / name}"]
        if name.endswith(".bin"):
            args += ["+firmware_base=4000", "+binary_image"]
        run = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        (out / (name + ".log")).write_text(run.stdout)
        if good:
            assert run.returncode == 0 and "PASS firmware" in run.stdout, run.stdout
        else:
            assert run.returncode != 0 and ("Firmware" in run.stdout or "firmware" in run.stdout), run.stdout
        print(f"PASS {mode}/{name}" + (" (rejected)" if not good else ""), flush=True)
