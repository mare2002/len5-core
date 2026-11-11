#!/usr/bin/env python3
"""Check the existing ALU C++ driver with bounded, serial RS-tag configurations."""
import argparse
from collections import deque
import os
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "depth1": ["--ALU_RS_DEPTH=1", "--ALU_SPILL_SKIP=0"],
    "depth3-bypass": ["--ALU_RS_DEPTH=3", "--ALU_SPILL_SKIP=1"],
    "default": [],
}


def invoke(command, cwd, log, seconds):
    with log.open("w") as output:
        result = subprocess.run(["timeout", "-k", "5s", f"{seconds}s", *map(str, command)],
                                cwd=cwd, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        with log.open() as output:
            tail = deque(output, maxlen=12)
        raise RuntimeError(f"exit {result.returncode}: {log}\n" + "".join(tail))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", default=",".join(CASES))
    parser.add_argument("--fusesoc", default=os.environ.get("FUSESOC", "fusesoc"))
    parser.add_argument("--verilator", default=os.environ.get(
        "VERILATOR", str(ROOT.parent / "tool/verilator/5.040/bin/verilator")))
    parser.add_argument("--build-timeout", type=int, default=180)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    selected = args.cases.split(",")
    if args.build_timeout < 1 or any(name not in CASES for name in selected):
        parser.error("unknown case or invalid timeout")
    build = Path(os.environ.get("BUILD_DIR", ROOT / "build/alu-rs-tags")).resolve()
    try:
        for name in selected:
            directory = build / ("alu-" + name)
            directory.mkdir(parents=True, exist_ok=True)
            invoke([args.fusesoc, "--cores-root=.", "run", "--no-export", "--target=sim",
                    "--tool=verilator", "--setup", "--build-root=" + str(directory),
                    "polito:len5:alu-tb", *CASES[name]], ROOT, directory / "setup.log", 60)
            model = directory / "sim-verilator"
            options = next(line.split(":=", 1)[1] for line in (model / "config.mk").read_text().splitlines()
                           if line.startswith("VERILATOR_OPTIONS"))
            common = [args.verilator, "-f", "polito_len5_alu-tb_0.1.0.vc", *shlex.split(options),
                      "-Werror-UNOPTFLAT", "-Werror-LATCH", "-Werror-MULTIDRIVEN", "-Werror-IMPLICIT"]
            invoke([common[0], "--lint-only", *common[1:]], model, directory / "lint.log", 60)
            invoke([*common, "--output-split", "10000"], model, directory / "generate.log", 60)
            invoke(["make", "--no-print-directory", "-j1", "-f", "Valu_tb.mk", "OPT_FAST=-O0",
                    "OPT_SLOW=-O0", "OPT_GLOBAL=-O0", "OBJCACHE=", "CXX=" + os.environ.get("CXX", "/usr/bin/g++")],
                   model, directory / "build.log", args.build_timeout)
            invoke([model / "Valu_tb", "--max_cycles=10000", "--dump_waves=false", "--log_level=LOG_NONE",
                    f"--seed={args.seed}"],
                   model, directory / "run.log", 15)
            if "TEST SUCCEEDED" not in (directory / "run.log").read_text():
                raise RuntimeError(f"ALU test did not report success: {directory / 'run.log'}")
            print(f"PASS standalone ALU RS tags: {name}", flush=True)
    except (RuntimeError, OSError, StopIteration) as error:
        print(str(error), flush=True)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
