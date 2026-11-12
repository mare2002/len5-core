#!/usr/bin/env python3
"""Bounded full-core checks using the existing LEN5/Spike differential checker."""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import runpy
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "default": {},
    "fifo-mixed": dict(ISSUE_WIDTH=4, ALU_ISSUE_WIDTH=2, MULT_ISSUE_WIDTH=4, BU_ISSUE_WIDTH=2,
                       ALU_USE_FIFO=1, MULT_USE_FIFO=1, DIV_USE_FIFO=1, FPU_USE_FIFO=1,
                       BU_USE_FIFO=1, LSU_USE_FIFO=1, ALU_FIFO_DEPTH=4, MULT_FIFO_DEPTH=8,
                       DIV_FIFO_DEPTH=1, FPU_FIFO_DEPTH=2, BU_FIFO_DEPTH=4, LSU_FIFO_DEPTH=4),
    "alu-mult": dict(ALU_NUM_UNITS=2, MULT_NUM_UNITS=2, ISSUE_WIDTH=4,
                     ALU_RR_ARBITER=0, MULT_RR_ARBITER=0),
    "alu-div": dict(ALU_NUM_UNITS=2, DIV_NUM_UNITS=2, ISSUE_WIDTH=2),
    "alu-fpu": dict(ALU_NUM_UNITS=2, FPU_NUM_UNITS=2, ISSUE_WIDTH=4,
                    ALU_RR_ARBITER=0, FPU_RR_ARBITER=0),
    "all-two": dict(ALU_NUM_UNITS=2, MULT_NUM_UNITS=2, DIV_NUM_UNITS=2,
                    FPU_NUM_UNITS=2, ISSUE_WIDTH=4, LEN5_MULT_SERIAL=1, FPU_PIPE_DEPTH=2),
    "three-alu": dict(ALU_NUM_UNITS=3, MULT_NUM_UNITS=2, ISSUE_WIDTH=2,
                      ALU_RR_ARBITER=0, MULT_RR_ARBITER=0, MULT_PIPE_DEPTH=2),
    "fp32-only": dict(ALU_NUM_UNITS=2, FPU_NUM_UNITS=2, ISSUE_WIDTH=2,
                      LEN5_D_EN=0, FPU_PIPE_DEPTH=2),
    "disabled-zero": dict(ALU_NUM_UNITS=1, MULT_NUM_UNITS=0, DIV_NUM_UNITS=0,
                          FPU_NUM_UNITS=0, LEN5_M_EN=0, LEN5_DIV_EN=0, LEN5_F_EN=0, LEN5_D_EN=0),
}
CRITICAL = ["-Werror-UNOPTFLAT", "-Werror-LATCH", "-Werror-MULTIDRIVEN",
            "-Werror-IMPLICIT", "-Werror-SELRANGE"]


def invoke(command, cwd, log, seconds):
    with log.open("w") as output:
        result = subprocess.run(["timeout", "-k", "5s", f"{seconds}s", *map(str, command)],
                                cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        with log.open() as output:
            tail = deque(output, maxlen=12)
        raise RuntimeError(f"exit {result.returncode}: {log}\n" + "".join(tail))


def spike_options(model):
    # Reuse the recorded pinned archives; never start an unbounded Spike rebuild.
    build = Path(os.environ.get("SPIKE_BUILD", ROOT / "build/spike-build")).resolve()
    state = json.loads((build / ".len5-spike-build.json").read_text())
    reference = runpy.run_path(str(ROOT / "tb/verilator/diff/bootstrap_spike.py"))
    if state["inputs"]["configuration"]["revision"] != reference["PIN"]:
        raise RuntimeError("cached Spike revision differs from the checker pin")
    names = ("libriscv.a", "libdisasm.a", "libsoftfloat.a", "libfesvr.a")
    for name in names:
        stat = (build / name).stat()
        if [stat.st_size, stat.st_mtime_ns] != state["outputs"][name]:
            raise RuntimeError(f"cached Spike archive changed: {build / name}")
    if "#define RISCV_ENABLE_COMMITLOG" not in (build / "config.h").read_text():
        raise RuntimeError("cached Spike lacks commit logging")
    source = ROOT / "sw/vendor/riscv-isa-sim"
    sources = [path for path in source.rglob("*") if ".git" not in path.relative_to(source).parts]
    if reference["digest_files"](sources) != state["inputs"]["sources"]:
        raise RuntimeError("cached Spike sources changed; rebuild the reference separately")
    flags = f"-std=c++17 -DLEN5_DIFF -I. -I{build} -I{source} -I{source}/riscv -I{source}/softfloat"
    libs = " ".join(str(build / name) for name in names)
    (model / "diff-options.vc").write_text(f'-CFLAGS "{flags}"\n-LDFLAGS "{libs} -ldl -lpthread -lz"\n')


def firmware(args, directory, fp32):
    directory.mkdir(parents=True, exist_ok=True)
    name = "mixed-fp32" if fp32 else "mixed"
    elf, image = directory / f"{name}.elf", directory / f"{name}.hex"
    isa, abi = ("rv64imf_zicsr", "lp64f") if fp32 else ("rv64imfd_zicsr", "lp64d")
    invoke([args.riscv_prefix + "-gcc", "-march=" + isa, "-mabi=" + abi,
            *(["-DLEN5_FP32_ONLY"] if fp32 else []), "-nostdlib", "-nostartfiles",
            "-Wl,-Ttext=0x10000", "-Wl,-e,_start", "-Wl,--no-relax",
            ROOT / "tb/expipe/multiple_exec_integration.S", "-o", elf], ROOT,
           directory / f"{name}-compile.log", 30)
    invoke([args.riscv_prefix + "-objcopy", "-O", "verilog", "--verilog-data-width=1", elf, image],
           ROOT, directory / f"{name}-objcopy.log", 30)
    return image


def check_case(args, name, output):
    cfg = CASES[name]
    execute = args.simulate and name != "disabled-zero"
    directory = output / name
    directory.mkdir(parents=True, exist_ok=True)
    target = "sim-diff" if execute else "sim"
    invoke([args.fusesoc, "--cores-root=.", "run", "--no-export", "--target=" + target,
            "--tool=verilator", "--setup", "--build-root=" + str(directory), "polito:len5:len5",
            "--MEMORY_BACKEND=1", "--BOOT_PC_LO=65536", *[f"--{k}={v}" for k, v in cfg.items()]],
           ROOT, directory / "setup.log", 60)
    model = directory / (target + "-verilator")
    manifest = model / "polito_len5_len5_0.1.1.vc"
    options = next(line.split(":=", 1)[1] for line in (model / "config.mk").read_text().splitlines()
                   if line.startswith("VERILATOR_OPTIONS"))
    options = [*shlex.split(options), "-Wno-fatal", *CRITICAL]
    common = [args.verilator, "-f", manifest.name, *options]
    if execute:
        spike_options(model)
    invoke([common[0], "--lint-only", *common[1:]], model, directory / "lint.log", 60)
    result = dict(case=name, configuration=cfg, status="elaborated", artifacts=str(directory))
    if not execute:
        print(f"PASS elaboration {name}", flush=True)
        return result
    invoke([common[0], "--xml-only", *common[1:]], model, directory / "xml.log", 60)
    invoke(["python3", ROOT / "tb/verilator/diff/layout.py", "Vtb_bare.xml", "diff_layout.hh",
            "--words-output", "diff-vpi-words.txt"], model, directory / "layout.log", 30)
    words = (model / "diff-vpi-words.txt").read_text().strip()
    with (model / "diff-options.vc").open("a") as stream:
        stream.write(f'-CFLAGS "-DVL_VALUE_STRING_MAX_WORDS={words}"\n')
    invoke([*common, "--output-split", "10000"], model, directory / "generate.log", 60)
    invoke(["make", "--no-print-directory", "-j1", "-f", "Vtb_bare.mk", "OPT_FAST=-O0",
            "OPT_SLOW=-O0", "OPT_GLOBAL=-O0", "CXX=/usr/bin/g++", "OBJCACHE="], model,
           directory / "build.log", args.build_timeout)
    image = firmware(args, output / "firmware", cfg.get("LEN5_D_EN") == 0)
    run = directory / "run"
    (run / "logs").mkdir(parents=True, exist_ok=True)
    invoke([model / "Vtb_bare", "--diff", "--run_dir=" + str(run), "--max_cycles=5000",
            "--dump_waves=false", "--dump_trace=false", "--log_level=LOG_LOW", "+firmware=" + str(image)],
           ROOT, run / "console.log", 30)
    report = json.loads((run / "logs/diff/report.json").read_text())
    if report["status"] != "passed" or report["committed"] < 80 or "(SUCCESS)" not in (run / "console.log").read_text():
        raise RuntimeError(f"differential/program completion check failed: {run}")
    result.update(status="passed", committed=report["committed"])
    print(f"PASS Spike {name}: {report['committed']} commits", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--simulate", action="store_true")
    parser.add_argument("--fusesoc", default=os.environ.get("FUSESOC", "fusesoc"))
    parser.add_argument("--verilator", default=os.environ.get("VERILATOR", str(ROOT.parent / "tool/verilator/5.040/bin/verilator")))
    parser.add_argument("--riscv-prefix", default=str(ROOT.parent / "tool/riscv/bin/riscv64-unknown-elf"))
    parser.add_argument("--build-timeout", type=int, default=300)
    args = parser.parse_args()
    if args.simulate:
        version = subprocess.check_output(["timeout", "5s", args.verilator, "--version"], text=True)
        if not version.startswith("Verilator 5.040 "):
            parser.error("the existing differential checker requires Verilator 5.040 (XML API)")
    selected = args.cases.split(",")
    if args.build_timeout < 1 or any(name not in CASES for name in selected):
        parser.error("unknown case or invalid timeout")
    output = ROOT / "build/multiple-exec-integration"
    output.mkdir(parents=True, exist_ok=True)
    results = []
    try:
        for name in selected:
            results.append(check_case(args, name, output))
    except (RuntimeError, OSError, ValueError) as error:
        results.append(dict(case=name, status="failed", error=str(error)))
        print(str(error), flush=True)
        return 1
    finally:
        (output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
