#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""DUT-independent tests of full-suite concurrency and failure propagation."""
import argparse
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch
import suite


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('build/pc-gen/validation'))
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
    print('Test successfully passed: pc_gen suite orchestration')
    print('Suite self-test evidence: '+str(root))
    return 0


if __name__ == '__main__':
    try:
        result = main()
    except Exception:
        print('Test failed: pc_gen suite orchestration', flush=True)
        raise
    raise SystemExit(result)
