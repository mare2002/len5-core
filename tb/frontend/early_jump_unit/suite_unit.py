#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""DUT-independent tests of full-suite concurrency and failure propagation."""
import argparse
import copy
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import subprocess
import tempfile
from unittest.mock import patch
import suite


def check_coverage_receipts(root, suite_source):
    """Exercise the real regression CLI with independent complete/broken receipts."""
    directory = root/'coverage-receipts'
    directory.mkdir()
    suite_name = suite_source.parent.name
    if suite_name == 'pc_gen':
        matrix = [dict(row=row, ready=ready, taken=taken,
                       required=sum(bool(row & bit) for bit in (8, 4, 2)) <= 1,
                       count=1)
                  for row in range(16) for ready in range(2) for taken in range(2 if row & 4 else 1)]
    elif suite_name == 'early_jump_unit':
        matrix = [dict(operation=op, confirmation=confirmation, flush=flush,
                       required=not (confirmation and flush), count=1)
                  for op in range(3) for confirmation in range(3) for flush in range(2)]
    else:
        matrix = [dict(row=row, required=True, count=1) for row in range(8)]
    coverage = dict(counters={}, campaigns={})
    for campaign in ['architectural', 'interface_stress', 'characterization']:
        entries = copy.deepcopy(matrix)
        if campaign != 'architectural':
            for entry in entries:
                entry['required'] = True
        coverage['campaigns'][campaign] = dict(matrix=entries, feature_goals=[], exclusions=[],
            reset_matrix=[dict(row=row, ready=ready, count=0) for row in range(16) for ready in range(2)])
    fake = directory/'producer.py'
    fake.write_text('#!'+sys.executable+'\n' + """import json
from pathlib import Path
import sys
flags = dict(arg[2:].split('=', 1) for arg in sys.argv[1:] if arg.startswith('--') and '=' in arg)
logs = Path(flags['run_dir'])/'logs'
logs.mkdir(parents=True, exist_ok=True)
(logs/'report.json').write_text(json.dumps(dict(exit_status=0, cycles_executed=int(flags['cycles']),
    field_checks=1, config=dict(bundle_instructions=4), obligations_conserved=True, obligations=dict(pending=0))))
fixture = Path(__file__).with_name('coverage-fixture.json')
if fixture.exists():
    (logs/'coverage.json').write_bytes(fixture.read_bytes())
""")
    fake.chmod(0o755)
    variants = dict(valid=coverage, missing=None, empty={}, malformed='{', no_campaigns=dict(campaigns={}))
    for name in ['empty-matrix', 'truncated', 'duplicate', 'negative-count', 'invalid-count', 'invalid-required']:
        broken = copy.deepcopy(coverage)
        entries = broken['campaigns']['architectural']['matrix']
        if name == 'empty-matrix':
            entries.clear()
        elif name == 'truncated':
            entries.pop()
        elif name == 'duplicate':
            entries[-1] = dict(entries[0])
        elif name == 'negative-count':
            entries[0]['count'] = -1
        elif name == 'invalid-count':
            entries[0]['count'] = True
        else:
            entries[0]['required'] = not entries[0]['required']
        variants[name] = broken
    fixture = fake.with_name('coverage-fixture.json')
    for name, value in variants.items():
        if value is None:
            fixture.unlink(missing_ok=True)
        else:
            fixture.write_text(value if isinstance(value, str) else json.dumps(value))
        for require in (False, True):
            output = directory/(name+('-required' if require else '-optional'))
            command = [sys.executable, str(suite_source.with_name('regress.py')), '--binary', str(fake),
                       '--output', str(output), '--seeds=1', '--cycles=1']
            if require:
                command.append('--require-matrix')
            process = subprocess.run(command, capture_output=True, text=True, timeout=10)
            summaries = list(output.glob('*/summary.json'))
            assert len(summaries) == 1, (name, process.stdout, process.stderr)
            summary = json.loads(summaries[0].read_text())
            assert process.returncode == (0 if name == 'valid' else 1), (name, process.stdout, process.stderr)
            assert summary['status'] == ('passed' if name == 'valid' else 'failed'), (name, summary)
            assert bool(summary['runs'][0]['coverage_error']) == (name != 'valid'), (name, summary)
    print('Test successfully passed: complete coverage accepted; absent, malformed and truncated coverage rejected')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('build/early-jump/validation'))
    output = parser.parse_args().output
    output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='suite-checks-', dir=output.resolve()))
    # Each process waits for the other to start. Serial execution cannot pass.
    def partner(name, other):
        code = ('from pathlib import Path\nimport time\n'
                f'root=Path({str(root)!r})\n(root/{name!r}).touch()\n'
                'deadline=time.monotonic()+5\n'
                f'while not (root/{other!r}).exists() and time.monotonic()<deadline: time.sleep(0.01)\n'
                f'assert (root/{other!r}).exists(), "groups did not overlap"\n')
        return [sys.executable, '-c', code]
    groups = [('first', partner('first-started', 'second-started')),
              ('second', partner('second-started', 'first-started')),
              ('failure', [sys.executable, '-c', 'raise SystemExit(1)']),
              ('after-failure', [sys.executable, '-c', 'print("continued")']),
              ('missing-program', [str(root/'does-not-exist')])]
    with redirect_stdout(io.StringIO()):
        results = suite.run_groups(groups, root, 2)
    assert [r['name'] for r in results] == [name for name, _ in groups]
    assert [r['exit_status'] for r in results] == [0, 0, 1, 0, 2]
    assert 'continued' in (root/'after-failure.log').read_text()
    print('Test successfully passed: concurrent groups and continuation after errors')

    # Check final reporting with synthetic child outcomes, not a simulated DUT.
    binary = root/'synthetic-binary'
    binary.touch()
    for failed in [False, True]:
        def synthetic_results(groups, directory, jobs):
            assert jobs == 2
            assert {name for name, _ in groups} >= {'directed', 'framework', 'random-framework', 'random', 'regression', 'mutations'}
            return [dict(name=name, passed=not (failed and name=='directed'),
                         exit_status=1 if failed and name=='directed' else 0)
                    for name, _ in groups]
        captured = io.StringIO()
        with patch.object(sys, 'argv', ['suite.py', '--binary', str(binary), '--output', str(root/'aggregate'), '--test-jobs=2']), \
                patch.object(suite, 'run_groups', synthetic_results), redirect_stdout(captured):
            status = suite.main()
        assert status == (1 if failed else 0)
        assert captured.getvalue().splitlines()[-1] == ('Test failed' if failed else 'All tests passed')
        if failed:
            assert 'All tests passed' not in captured.getvalue()
    summaries = [json.loads(path.read_text()) for path in (root/'aggregate').glob('*/summary.json')]
    assert {r['status'] for r in summaries} == {'passed', 'failed'}
    print('Test successfully passed: aggregate success/failure messages and exit status')
    check_coverage_receipts(root, Path(suite.__file__).resolve())
    print('Test successfully passed: early_jump suite orchestration')
    print('Suite self-test evidence: '+str(root))
    return 0


if __name__ == '__main__':
    try:
        result = main()
    except Exception:
        print('Test failed: early_jump suite orchestration', flush=True)
        raise
    raise SystemExit(result)
