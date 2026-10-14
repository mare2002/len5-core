#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Validate an already built native harness, keeping successful and failing evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("build/pc-gen/validation"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="directed-", dir=args.output.resolve()))
    source = Path(__file__).resolve().parent
    compiler = os.environ.get("PC_GEN_CXX", "/usr/bin/g++")
    unit = directory / "pc-gen-unit"
    command = [compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror", "-O2",
               str(source / "pc_gen_model.cpp"), str(source / "pc_gen_environment.cpp"),
               str(source / "pc_gen_unit.cpp"), "-o", str(unit)]
    with (directory / "unit-build.log").open("w") as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
    unit_result = subprocess.run([str(unit)], text=True, capture_output=True, check=True)
    (directory / "unit.log").write_text(unit_result.stdout + unit_result.stderr)
    print(unit_result.stdout.strip())
    results = []

    def run(label, options=(), status=0):
        case_dir = directory / label
        case_dir.mkdir()
        argv = [str(binary), "--run_dir", str(case_dir), "--log_level", "LOG_LOW", "--seed", "7", *options]
        with (case_dir / "console.log").open("w") as log:
            completed = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        report = json.loads((case_dir / "logs/report.json").read_text())
        assert report['sampled_records'] >= report['transactions']
        assert report['pre_edge_records'] >= report['cycles_executed']
        assert completed.returncode == report["exit_status"]
        if status is None:
            assert completed.returncode in (0, 1), (label, report)
            assert not report['environment_errors'] and not report['framework_errors']
        else:
            assert completed.returncode == status, (label, completed.returncode, report)
        assert report["full_contract_signoff"] is False
        assert report["unresolved_questions"] == ["Q1", "Q3", "Q4", "Q5", "Q9"]
        console = (case_dir / "console.log").read_text()
        assert "\x1b[1m[CONFIG]" in console
        quiet = "LOG_NONE" in options
        if completed.returncode:
            assert "\x1b[1;31m[ERR!  ]" in console and "TEST FAILED > errors:" in console
        else:
            if not quiet:
                assert "\x1b[1;32m[OK!   ]" in console and "TEST SUCCEEDED > errors: 0/" in console
            else:
                assert "[OK!   ]" not in console and "[LOG   ]" not in console
            assert report["field_checks"] > 0
        if not quiet:
            assert re.search(r"\[LOG   \] \w+\.cpp:\d+ >\s+\[\s*\d+\] Starting simulation", console)
        results.append({"case": label, "command": argv, "exit_status": completed.returncode,
                        "field_checks": report["field_checks"], "field_errors": report["field_errors"],
                        "dut_failure": status is None and completed.returncode == 1})
        print(f"CHECKED: {label}: exit={completed.returncode}, checks={report['field_checks']}, errors={report['field_errors']}")
        return report, case_dir

    baseline, base_dir = run("proposed", status=None)
    coverage = json.loads((base_dir / "logs/coverage.json").read_text())
    assert coverage["matrix_holes"] == coverage["reset_holes"] == 0
    assert len(coverage["matrix"]) == 48 and all(row["count"] for row in coverage["matrix"])
    assert len(coverage["reset_matrix"]) == 32 and all(row["count"] for row in coverage["reset_matrix"])
    assert len(baseline["scenario_samples"]) == 22
    assert baseline["requirement_checks"].get("C9/D", 0) > 0
    assert baseline["unknown_output_samples"]
    assert baseline["provisional_mismatches"] == 0
    assert baseline["specification_status"]["Q2"]["status"] == "resolved"
    assert baseline["dont_care_output_samples"]
    selected = baseline['config']['bundle_instructions']
    assert 'LEN5_MULTIPLE_ISSUES=%d' % selected in (base_dir/'console.log').read_text()
    # Guards are negative build/configuration cases, not simulated DUT errors.
    configuration_checks = []
    wrong = 1 if selected != 1 else 2
    guard_dir = directory/'wrong-replay-config'
    guard = subprocess.run([str(binary), '--expect_issues=%d' % wrong, '--run_dir='+str(guard_dir)], text=True, capture_output=True)
    (directory/'wrong-replay-config.log').write_text(guard.stdout+guard.stderr)
    assert guard.returncode == 2 and 'replay configuration mismatch' in guard.stderr
    configuration_checks.append('incompatible replay width rejected')
    # Disposable evidence copies only. The production packages remain untouched.
    for label, modification, diagnostic in [
        ('stale-package', 'snapshot', 'stale pc_gen binary'),
        ('elaboration-disagreement', 'manifest', 'source constants disagree')]:
        copied = directory/label
        copied.mkdir()
        for path in binary.parent.glob('pc_gen_*'):
            if path.suffix == '.snapshot' or path.name == 'pc_gen_build.cfg':
                shutil.copyfile(path, copied/path.name)
        shutil.copyfile(binary, copied/binary.name)
        (copied/binary.name).chmod(0o755)
        if modification == 'snapshot':
            snapshot = next(copied.glob('*.snapshot'))
            snapshot.write_bytes(snapshot.read_bytes()+b'\n// disposable stale snapshot\n')
        else:
            manifest = copied/'pc_gen_build.cfg'
            manifest.write_text(manifest.read_text()
                .replace('bundle_instructions=%d\n' % selected, 'bundle_instructions=%d\n' % wrong)
                .replace('bundle_bytes=%d\n' % (4*selected), 'bundle_bytes=%d\n' % (4*wrong)))
        guard = subprocess.run([str(copied/binary.name), '--run_dir='+str(copied/'run')], text=True, capture_output=True)
        (copied/'console.log').write_text(guard.stdout+guard.stderr)
        assert guard.returncode == 2 and diagnostic in guard.stderr, (label,guard.stderr)
        configuration_checks.append(label+' rejected')
    strict, strict_dir = run("strict", ["--contract", "strict"], status=None)
    assert not any("unresolved-transition" in q for q in strict["unknown_output_samples"])
    strict_samples = [json.loads(line) for line in (strict_dir / "logs/samples.jsonl").read_text().splitlines()]
    assert any(s["phase"] == "post" and s["inputs"]["J"] and s["expected"]["pc"]["known"] for s in strict_samples)
    assert any(s["phase"] == "post" and not s["inputs"]["rst_n"] and s["expected"]["pc"]["known"] for s in strict_samples)
    assert strict["requirement_checks"].get("C9/D", 0) > 0
    _, replay_dir = run("replay", ["--dump_waves", "true"], status=None)
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    assert digest(base_dir / "logs/samples.jsonl") == digest(replay_dir / "logs/samples.jsonl")
    assert (replay_dir / "logs/waves.fst").stat().st_size > 0
    _, verbose_dir = run("verbose", ["--scenario", "T09", "--log_level", "LOG_HIGH"])
    verbose = (verbose_dir / "console.log").read_text()
    assert "REQ > id=T09" in verbose and "RSP > id=T09" in verbose
    assert re.search(r"--> pc: 0x[0-9a-f]{16} \(expected: 0x[0-9a-f]{16}\)", verbose)
    fault, _ = run("injected-pc", ["--scenario", "T01", "--inject_failure", "pc"], 1)
    assert fault["injected_failures"] > 0 and fault["confirmed_mismatches"] == fault["provisional_mismatches"] == 0
    assert fault["field_errors"] == 1  # monitor-only fault must not alter subsequent expected state
    fault, _ = run("injected-valid", ["--scenario", "T01", "--inject_failure", "valid"], 1)
    assert fault["injected_failures"] > 0
    fault, _ = run("invalid-environment", ["--scenario", "T02", "--inject_failure", "environment"], 2)
    assert fault["environment_errors"] == 1
    fault, _ = run("framework-error", ["--scenario", "T01", "--inject_failure", "framework"], 2)
    assert fault["framework_errors"] == 1
    assert fault['pre_edge_records'] == 1 and fault['cycles_executed'] == 0
    empty, _ = run("empty", ["--inject_failure", "empty"], 3)
    assert empty["field_checks"] == 0
    run("timeout", ["--max_cycles", "1"], 3)
    for option, value, question in [('early_accept', 'ready', 'Q3'), ('early_accept', 'unknown', 'Q3'),
                                    ('early_target', 'arithmetic', 'Q4'), ('early_target', 'unknown', 'Q4')]:
        guard = subprocess.run([str(binary), '--'+option+'='+value], text=True, capture_output=True)
        assert guard.returncode == 2 and question+' approved' in guard.stderr
        configuration_checks.append('obsolete '+option+'='+value+' rejected')
    quiet, quiet_dir = run("quiet", ["--scenario", "T01", "--log_level", "LOG_NONE"])
    # LOG_NONE still emits CONFIG, but intentionally suppresses LOG_LOW summaries.
    assert quiet["field_checks"] > 0
    failed = [r for r in results if r["dut_failure"]]
    summary = {"status": "framework_checks_passed_dut_failed" if failed else "passed", "dut_failures": failed, "binary": str(binary), "config": baseline['config'], "configuration_checks": configuration_checks,
               "unit_checks": unit_result.stdout.strip(), "results": results,
               "baseline_field_checks": baseline["field_checks"], "baseline_coverage": coverage,
               "log_compatibility": "shared TbLogger, ANSI prefixes and timestamps verified",
               "replay_sha256": digest(base_dir / "logs/samples.jsonl")}
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"Validation evidence: {directory}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
