#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Native framework validation adapted from pc_gen/validate.py."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def case(binary, root, label, flags=(), status=0):
    directory = root / label
    directory.mkdir()
    argv = [str(binary), '--run_dir='+str(directory), '--log_level=LOG_LOW', '--seed=7', *flags]
    with (directory/'console.log').open('w') as log:
        result = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, timeout=120)
    report = json.loads((directory/'logs/report.json').read_text())
    assert result.returncode == report['exit_status'] == status, (label, result.returncode, report)
    assert report['sampled_records'] >= report['transactions']
    assert report['pre_edge_records'] >= report['cycles_executed']
    assert report['full_contract_signoff'] is False and 'EQ05' in report['unresolved_questions']
    text = (directory/'console.log').read_text()
    assert '\x1b[1m[CONFIG]' in text
    if status:
        assert '\x1b[1;31m[ERR!  ]' in text and 'TEST FAILED > errors:' in text
    elif '--log_level=LOG_NONE' not in flags:
        assert '\x1b[1;32m[OK!   ]' in text and 'TEST SUCCEEDED > errors: 0/' in text
    else:
        assert '[LOG   ]' not in text and '[OK!   ]' not in text
    if not status:
        assert report['field_checks'] > 0 and report['field_errors'] == 0
    if '--log_level=LOG_NONE' not in flags:
        assert re.search(r'\[LOG   \] \w+\.cpp:\d+ >\s+\[\s*\d+\] Starting simulation', text)
    print(f'Test successfully passed: {label}: expected exit={status}, checks={report["field_checks"]}, errors={report["field_errors"]}', flush=True)
    return report, directory, dict(case=label, command=argv, expected_exit=status,
                                   checks=report['field_checks'], errors=report['field_errors'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/early-jump/validation'))
    args = parser.parse_args()
    binary = args.binary.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='framework-', dir=args.output.resolve()))
    source = Path(__file__).resolve().parent
    unit = root/'model-unit'
    argv = [os.environ.get('EARLY_JUMP_CXX', '/usr/bin/g++'), '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
            '-I'+str(source.parent/'pc_gen')]
    argv += [str(source/f'early_jump_{part}.cpp') for part in ['instructions', 'model', 'environment', 'unit']]
    argv += [str(source.parent/'pc_gen/pc_gen_model.cpp'), '-o', str(unit)]
    with (root/'unit-build.log').open('w') as log:
        subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, check=True)
    tested = subprocess.run([str(unit)], capture_output=True, text=True, check=True)
    (root/'unit.log').write_text(tested.stdout+tested.stderr)
    print(tested.stdout.strip(), flush=True)
    results = []
    def run(label, flags=(), status=0):
        report, directory, result = case(binary, root, label, flags, status)
        results.append(result)
        return report, directory
    baseline, directory = run('len5-minimal')
    assert len(baseline['scenario_samples']) == 34
    assert baseline['requirement_checks']['EJ08/D'] > 0
    assert baseline['unknown_output_samples'] and baseline['dont_care_output_samples']
    run('established', ['--contract=established'])
    _, replay = run('replay-fst', ['--dump_waves=true'])
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    assert digest(directory/'logs/samples.jsonl') == digest(replay/'logs/samples.jsonl')
    assert (replay/'logs/waves.fst').stat().st_size > 0
    _, verbose = run('verbose', ['--scenario=EJ-T03', '--log_level=LOG_HIGH'])
    text = (verbose/'console.log').read_text()
    assert 'REQ > id=EJ-T03' in text and 'RSP > id=EJ-T03' in text
    assert re.search(r'base: 0x[0-9a-f]{16} offs: 0x[0-9a-f]{16}', text)
    for injection, scenario in [('missed-jal','03'),('false-jal','07'),('immediate','03'),('lane','03'),('target','03'),
                                ('predictive','15'),('confirmed','16'),('restore','19'),('return','15'),('arbitration','11')]:
        r, _ = run('injected-'+injection, ['--scenario=EJ-T'+scenario, '--inject_failure='+injection], 1)
        assert r['injected_failures'] > 0 and not r['confirmed_mismatches'] and not r['provisional_mismatches']
    r, _ = run('invalid-environment', ['--scenario=EJ-T17','--inject_failure=environment'], 2)
    assert r['environment_errors'] == 1
    r, _ = run('framework-error', ['--scenario=EJ-T01','--inject_failure=framework'], 2)
    assert r['framework_errors'] == 1
    r, _ = run('empty', ['--inject_failure=empty'], 3)
    assert r['field_checks'] == 0
    run('timeout', ['--max_cycles=1'], 3)
    run('quiet', ['--scenario=EJ-T01','--log_level=LOG_NONE'])
    alternative, _ = run('previous-confirmation-hypothesis', ['--scenario=EJ-T20','--order=previous'], 1)
    assert alternative['provisional_mismatches'] > 0 and alternative['confirmed_mismatches'] == 0
    run('unknown-restoration', ['--scenario=EJ-T20','--order=unknown'])
    # Stale build/replay negative cases: disposable copies, never source edits.
    selected = baseline['config']['bundle_instructions']
    wrong = 1 if selected != 1 else 2
    guards = []
    command = [str(binary), '--expect_issues='+str(wrong)]
    p = subprocess.run(command, capture_output=True, text=True)
    assert p.returncode == 2 and 'replay configuration mismatch' in p.stdout+p.stderr
    guards.append('incompatible replay width rejected')
    for label, mode in [('stale-source','snapshot'),('elaboration-disagreement','manifest')]:
        copied = root/label
        copied.mkdir()
        for f in binary.parent.glob('early_jump_*'):
            if f.suffix == '.snapshot' or f.name == 'early_jump_build.cfg':
                shutil.copyfile(f,copied/f.name)
        shutil.copyfile(binary,copied/binary.name)
        (copied/binary.name).chmod(0o755)
        if mode == 'snapshot':
            snapshot = next(copied.glob('*.snapshot'))
            snapshot.write_bytes(snapshot.read_bytes()+b'\n// disposable stale snapshot\n')
        else:
            manifest = copied/'early_jump_build.cfg'
            manifest.write_text(manifest.read_text().replace('bundle_instructions='+str(selected)+'\n', 'bundle_instructions='+str(wrong)+'\n').replace('bundle_bytes='+str(selected*4)+'\n', 'bundle_bytes='+str(wrong*4)+'\n'))
        p = subprocess.run([str(copied/binary.name)], capture_output=True, text=True)
        (copied/'console.log').write_text(p.stdout+p.stderr)
        assert p.returncode == 2, (label,p.stdout,p.stderr)
        guards.append(label+' rejected')
    summary = dict(status='passed', config=baseline['config'], unit_result=tested.stdout.strip(), results=results,
                   guards=guards, replay_sha256=digest(directory/'logs/samples.jsonl'),
                   log_compatibility='shared TbLogger ANSI prefixes, phase timestamps, 64-bit addresses and summaries checked')
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Framework evidence:',root)
    print('Test successfully passed: early_jump framework',flush=True)
    return 0

if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except Exception:
        print('Test failed: early_jump framework',flush=True)
        raise
