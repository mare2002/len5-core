#!/usr/bin/env python3
"""Run identical firmware under both Spike-enabled simulators and collect evidence."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--legacy", type=Path, required=True, help="legacy sim-diff Vtb_bare")
p.add_argument("--tc-sram", type=Path, required=True, help="TC_SRAM sim-diff Vtb_bare")
p.add_argument("--firmware", action="append", required=True, help="NAME=path.hex (repeatable)")
p.add_argument("--output", type=Path, default=Path("build/memory-backend/comparison"))
p.add_argument("--max-cycles", type=int, default=10000000)
a = p.parse_args()
output = a.output.resolve()
output.mkdir(parents=True, exist_ok=True)
results = []
(output / "report.json").write_text(json.dumps({"status": "running", "runs": results}, indent=2) + "\n")
for item in a.firmware:
    name, file_name = item.split("=", 1)
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        p.error("firmware name must contain letters, digits, underscores or hyphens")
    firmware = Path(file_name).resolve()
    records = []
    for backend, executable in (("legacy", a.legacy), ("tc_sram", a.tc_sram)):
        run_dir = output / (backend + "-" + name)
        run_dir.mkdir(exist_ok=True)
        cmd = [str(executable.resolve()), "--diff", "--run_dir", str(run_dir),
               "--dump_waves", "false", "--dump_trace", "true", "--max_cycles", str(a.max_cycles),
               "+firmware=" + str(firmware)]
        with (run_dir / "console.log").open("w") as log:
            subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, check=True)
        console = (run_dir / "console.log").read_text()
        assert "(SUCCESS)" in console, f"{backend}/{name}: no successful program exit"
        diff = json.loads((run_dir / "logs/diff/report.json").read_text())
        assert diff["status"] == "passed" and not diff["discrepancies"], diff
        record = {"backend": backend, "firmware": name, "command": cmd,
                  "sha256": hashlib.sha256(firmware.read_bytes()).hexdigest(),
                  "diff": diff, "performance": json.loads((run_dir / "memory-performance.json").read_text()),
                  "serial": re.findall(r'received string:.*?"(.*)"', console)}
        records.append(record)
        print(f"PASS {backend}/{name}: {diff['committed']} commits", flush=True)
    assert records[0]["serial"] == records[1]["serial"], f"{name}: serial output differs"
    # The existing TB runs EXIT_TIMEOUT extra cycles after MMIO termination.
    # Its idle loop can retire different counts at different fetch latencies.
    # Compare the common termination sample, not the trailing idle-loop count.
    assert records[0]["performance"]["retired"] == records[1]["performance"]["retired"], f"{name}: exit retirement counts differ"
    results.extend(records)
    (output / "report.json").write_text(json.dumps({"status": "running", "runs": results}, indent=2) + "\n")
(output / "report.json").write_text(json.dumps({"status": "passed", "runs": results}, indent=2) + "\n")
