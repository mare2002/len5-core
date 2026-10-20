#!/usr/bin/env python3
"""Exercise both SRAM loaders, native initialization, absolute addresses and malformed images."""
import json
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
os.chdir(root)
build = Path(os.environ.get("TC_SRAM_LOADER_BUILD_DIR", root / "build/tc-sram-loader"))
build.mkdir(parents=True, exist_ok=True)
sources = ["rtl/misc/packages-waivers.vlt", "tb/memory/tc_sram/waivers.vlt",
           "rtl/packages/util_pkg.sv", "rtl/packages/len5_config_pkg.sv", "rtl/packages/len5_pkg.sv",
           "tb/packages/tb_config_pkg.sv", "tb/memory/tc_sram/memory_backend_pkg.sv",
           "rtl/vendor/tech_cells_generic/tc_sram.sv", "+incdir+tb/memory",
           "tb/memory/tc_sram_storage.sv", "tb/memory/tc_sram/tc_sram_loader_tb.sv"]
results = []
for width, ilat, dlat in ((64, 0, 3), (128, 1, 1), (256, 4, 0)):
    image_dir = build / f"width-{width}"
    image_dir.mkdir(exist_ok=True)
    last = 0x4000 + width // 8 * 3 - 1
    images = {
        "image.hex": f"// split byte image\n@4000 11 22 33 44 /* endian */ 55 66 77 88\n"
                     f"@4010 aa bb cc dd\n@{last:x} a5\n@8000 80 70 60 50 40 30 20 10\n@8010 78 56 34 12\n@8017 5a\n",
        "image.txt": f"4000 44332211\n4004 88776655\n4010 ddccbbaa\n{last-3:x} a5000000\n"
                     "8000 50607080\n8004 10203040\n8010 12345678\n8014 5a000000\n",
        "below.hex": "@3fff 11\n",
        "gap.hex": "@7000 11\n",
        "above.hex": "@8018 11\n",
        "cross.txt": f"{last-1:x} 12345678\n",
        "alias.hex": "@10000000000004000 11\n",
        "bad.hex": "@4000 g1\n",
        "wide.hex": "@4000 123\n",
        "overflow.hex": "@ffffffffffffffff 11 22\n",
        "empty.hex": "// nothing\n",
    }
    for name, data in images.items():
        (image_dir / name).write_text(data)
    (image_dir / "image.bin").write_bytes(bytes.fromhex("1122334455667788"))
    for mode in ("ones", "zeros", "none", "random"):
        out = image_dir / mode
        out.mkdir(exist_ok=True)
        cmd = [os.environ.get("VERILATOR", "verilator"), "--binary", "--timing", "--assert", "-j", "4",
               "-MAKEFLAGS", "OBJCACHE= CXX=/usr/bin/g++", "--Mdir", str(out), "--top-module", "tc_sram_loader_tb",
               "-Wall", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM", f'-GSIM_INIT="{mode}"',
               f"-GI_WIDTH={width}", f"-GI_LATENCY={ilat}", f"-GD_LATENCY={dlat}"] + sources
        with (out / "build.log").open("w") as log:
            subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
        for name in ("image.hex", "image.txt", "image.bin") + (tuple(images)[2:] if mode == "ones" else ()):
            good = name.startswith("image.")
            args = [str(out / "Vtc_sram_loader_tb"), f"+firmware={image_dir / name}"]
            if name.endswith(".bin"):
                args += ["+firmware_base=4000", "+binary_image"]
            run = subprocess.run(args, capture_output=True, text=True)
            text = run.stdout + run.stderr
            (out / (name + ".log")).write_text(text)
            assert (run.returncode == 0 and "PASS firmware" in text) if good else (
                run.returncode != 0 and ("Firmware" in text or "firmware" in text)), text
            results.append({"width": width, "imem_latency": ilat, "dmem_latency": dlat,
                            "mode": mode, "image": name, "status": "passed", "rejected": not good})
            print(f"PASS width={width} {mode}/{name}" + (" (rejected)" if not good else ""), flush=True)
(build / "report.json").write_text(json.dumps(results, indent=2) + "\n")
