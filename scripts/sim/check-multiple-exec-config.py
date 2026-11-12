#!/usr/bin/env python3
"""Elaborate physical-unit counts independently of issue/category counts."""
import argparse
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
COUNTS = (1, 2, 3, 4, 8)
FIELDS = ("ALU_NUM_UNITS", "MULT_NUM_UNITS", "DIV_NUM_UNITS", "FPU_NUM_UNITS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fusesoc", default=os.environ.get("FUSESOC", "fusesoc"))
    parser.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"))
    parser.add_argument("--cases", default="default,count-3-rr-1,disabled-zero")
    args = parser.parse_args()
    env = dict(os.environ, VERILATOR=args.verilator)
    build = ROOT / "build/multiple-exec-config-core"
    build.mkdir(parents=True, exist_ok=True)
    setup = [args.fusesoc, "--cores-root=.", "run", "--no-export", "--target=sim", "--tool=verilator", "--setup",
             "--build-root", str(build), "polito:len5:len5"]
    with (build / "setup.log").open("w") as log:
        subprocess.run(["timeout", "-k", "5s", "60s", *setup], cwd=ROOT, env=env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    model = build / "sim-verilator"
    manifest = model / "polito_len5_len5_0.1.1.vc"
    common = [args.verilator, "--lint-only", "--timing", "--assert", "-Wno-fatal", "-Werror-IMPLICIT", "-Werror-LATCH",
              "-Werror-UNOPTFLAT", "-Werror-MULTIDRIVEN", "-f", str(manifest)]
    cases = [("default", {})]
    for rr in (0, 1):
        for count in COUNTS:
            values = dict.fromkeys(FIELDS, count)
            values.update({f"{unit}_RR_ARBITER": rr for unit in ("ALU", "MULT", "DIV", "FPU")})
            values.update(ISSUE_WIDTH=1 if count % 2 else 2, LEN5_MULT_SERIAL=rr)
            cases.append((f"count-{count}-rr-{rr}", values))
    cases.append(("independent", dict(ALU_NUM_UNITS=2, MULT_NUM_UNITS=3, DIV_NUM_UNITS=4,
                                       FPU_NUM_UNITS=8, ISSUE_WIDTH=4)))
    cases.append(("disabled-zero", dict(ALU_NUM_UNITS=1, MULT_NUM_UNITS=0, DIV_NUM_UNITS=0,
                                         FPU_NUM_UNITS=0, LEN5_M_EN=0, LEN5_DIV_EN=0,
                                         LEN5_F_EN=0, LEN5_D_EN=0)))
    for width in (1, 2, 4, 8):
        values = dict(ISSUE_WIDTH=width, ALU_ISSUE_WIDTH=max(1, width // 2),
                      MULT_ISSUE_WIDTH=width, FPU_ISSUE_WIDTH=1, BU_ISSUE_WIDTH=width,
                      LSU_ISSUE_WIDTH=width)
        for unit in ("ALU", "MULT", "DIV", "FPU", "BU", "LSU"):
            values[unit + "_USE_FIFO"] = 1
            values[unit + "_FIFO_DEPTH"] = 4 if width > 1 else 1
        cases.append((f"fifo-width-{width}", values))
    selected = args.cases.split(",")
    if selected != ["all"] and set(selected) - {name for name, _ in cases}:
        parser.error("unknown configuration case")
    for name, values in cases:
        if selected != ["all"] and name not in selected:
            continue
        cmd = common + [f"-G{key}={value}" for key, value in values.items()]
        with (build / f"{name}.log").open("w") as log:
            result = subprocess.run(["timeout", "-k", "5s", "60s", *cmd], cwd=model, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(f"FAIL {name}: see {build / (name + '.log')}")
        print(f"PASS core elaboration {name}", flush=True)

    # check_build() runs at elaboration in the standalone probe target.
    for field in FIELDS:
        cmd = [args.fusesoc, "--cores-root=.", "run", "--no-export", "--target=checkbuild", "--setup", "--build",
               "--build-root", str(build / "invalid" / field), "polito:len5:len5", f"--{field}=0"]
        with (build / f"invalid-{field}.log").open("w") as log:
            result = subprocess.run(["timeout", "-k", "5s", "60s", *cmd], cwd=ROOT, env=env,
                                    stdout=log, stderr=subprocess.STDOUT)
        report = (build / f"invalid-{field}.log").read_text()
        if result.returncode == 0 or "enabled execution-unit categories require at least one physical unit" not in report:
            raise SystemExit(f"FAIL validation {field}: see {build / ('invalid-' + field + '.log')}")
        print(f"PASS rejected enabled {field}=0", flush=True)

    for unit in ("ALU", "MULT", "DIV", "FPU", "BU", "LSU"):
        invalid = [({unit + "_ISSUE_WIDTH": 0}, "ISSUE_WIDTH must be in"),
                   ({unit + "_ISSUE_WIDTH": 2}, "ISSUE_WIDTH must be in"),
                   ({unit + "_USE_FIFO": 1, unit + "_FIFO_DEPTH": 0}, "FIFO_DEPTH must be positive"),
                   ({unit + "_USE_FIFO": 1, unit + "_FIFO_DEPTH": 3}, "FIFO_DEPTH must be positive power of two")]
        for index, (values, diagnostic) in enumerate(invalid):
            case = f"invalid-{unit}-allocation-{index}"
            cmd = [args.fusesoc, "--cores-root=.", "run", "--no-export", "--target=checkbuild",
                   "--setup", "--build", "--build-root", str(build / case), "polito:len5:len5",
                   *[f"--{key}={value}" for key, value in values.items()]]
            log_path = build / (case + ".log")
            with log_path.open("w") as log:
                result = subprocess.run(["timeout", "-k", "5s", "60s", *cmd], cwd=ROOT, env=env,
                                        stdout=log, stderr=subprocess.STDOUT)
            if result.returncode == 0 or diagnostic not in log_path.read_text():
                raise SystemExit(f"FAIL validation {case}: see {log_path}")
            print(f"PASS rejected {case}", flush=True)


if __name__ == "__main__":
    main()
