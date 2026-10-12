#!/usr/bin/env python3
"""Benchmark an already-built checker; retain logs and enforce repeatability.

Use separate output directories for each binary/configuration. --reference points
to a previous summary.json and checks reports, exit status and RTL cycle counts.
Timing includes process startup and optional waveform annotation, excludes builds.
"""
import argparse
import hashlib
import json
import re
import statistics
import subprocess
import time
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("binary", type=Path)
    p.add_argument("firmware", type=Path)
    p.add_argument("output", type=Path)
    p.add_argument("--repeats", type=int, default=5)
    p.add_argument("--max-cycles", type=int, default=10000000)
    p.add_argument("--waves", action="store_true")
    p.add_argument("--trace", action="store_true")
    p.add_argument("--no-diff", action="store_true")
    p.add_argument("--fault", choices=["operand", "cdb", "register", "store"])
    p.add_argument("--expected-status", type=int, choices=range(4))
    p.add_argument("--reference", type=Path)
    args = p.parse_args()
    if args.repeats < 1:
        p.error("--repeats must be positive")
    args.output.mkdir(parents=True, exist_ok=True)
    reference = json.loads(args.reference.read_text()) if args.reference else None
    firmware_hash = hashlib.sha256(args.firmware.read_bytes()).hexdigest()
    if reference and reference.get("firmware_sha256", firmware_hash) != firmware_hash:
        p.error("reference used a different firmware image")
    runs = []
    for n in range(args.repeats):
        directory = (args.output / str(n)).resolve()
        directory.mkdir(exist_ok=True)
        cmd = [str(args.binary.resolve()), "--run_dir", str(directory),
               "--max_cycles", str(args.max_cycles), "--dump_waves", str(args.waves).lower(),
               "--dump_trace", str(args.trace).lower(),
               "+firmware=" + str(args.firmware.resolve())]
        if not args.no_diff:
            cmd.append("--diff")
        if args.fault:
            cmd += ["--diff-fault", args.fault]
        with (directory / "console.log").open("w") as log:
            start = time.perf_counter()
            result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT)
            elapsed = time.perf_counter() - start
        console = (directory / "console.log").read_text()
        cycles = re.search(r"total CPU cycles:\s+(\d+)", console)
        program_exit = re.search(r"Program exit with code:\s+0x([0-9a-fA-F]+)", console)
        report = json.loads((directory / "logs/diff/report.json").read_text()) if not args.no_diff else None
        signature = {"exit_status": result.returncode, "report": report,
                     "cpu_cycles": int(cycles[1]) if cycles else None}
        expected = reference["signature"] if reference else runs[0]["signature"] if runs else signature
        if signature != expected:
            raise SystemExit(f"Verification behavior differs: {directory}")
        expected_status = args.expected_status if args.expected_status is not None else (1 if args.fault else 0)
        if result.returncode != expected_status:
            raise SystemExit(f"Unexpected simulator status {result.returncode}: {directory}")
        if expected_status == 0 and (not program_exit or int(program_exit[1], 16) != 0):
            raise SystemExit(f"Program did not exit successfully: {directory}")
        runs.append({"seconds": elapsed, "signature": signature})
        print(f"{n}: {elapsed:.6f} s", flush=True)
    median = statistics.median(r["seconds"] for r in runs)
    summary = {"binary": str(args.binary.resolve()), "firmware": str(args.firmware.resolve()),
               "binary_sha256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
               "firmware_sha256": firmware_hash,
               "waves": args.waves, "trace": args.trace, "diff": not args.no_diff,
               "fault": args.fault, "seconds": [r["seconds"] for r in runs],
               "median_seconds": median, "signature": signature,
               "cpu_cycles_per_second": signature["cpu_cycles"] / median if signature["cpu_cycles"] else None,
               "checked_commits_per_second": report["committed"] / median if report else None}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "signature"}, indent=2))


if __name__ == "__main__":
    main()
