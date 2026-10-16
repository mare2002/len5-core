#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Concurrent groups adapted from fetch_mem_if/suite.py; incomplete groups fail."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
import configuration as cfg
from run import flags
def run_groups(groups, root, jobs):
    """Keep running independent groups after a failure; serialize console output."""
    def run(group):
        name, command = group
        started = time.monotonic()
        log_path = root / (name + '.log')
        with log_path.open('w') as log:
            try:
                status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
                error = ''
            except OSError as exception:
                status, error = 2, str(exception)
                log.write(error + '\n')
        return dict(name=name, passed=status == 0, exit_status=status,
                    seconds=time.monotonic()-started, command=shlex.join(command),
                    log=str(log_path), error=error)

    results = {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, group) for group in groups]
        for future in as_completed(futures):
            result = future.result()
            results[result['name']] = result
            # Print one complete group at a time, so concurrent logs never mix.
            print(f"\n## fetch_stage {result['name']} output", flush=True)
            with Path(result['log']).open() as log:
                for line in log:
                    sys.stdout.write(line)
            verdict = 'Test successfully passed' if result['passed'] else 'Test failed'
            print(f"{verdict}: {result['name']}; exit={result['exit_status']}; log={result['log']}", flush=True)
    return [results[name] for name, _ in groups]


def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/suite');p.add_argument('--jobs',type=int,default=4);p.add_argument('--test-jobs',type=int,default=3);a=p.parse_args()
    if min(a.jobs,a.test_jobs)<1:p.error('jobs and test-jobs must be positive')
    a.output.mkdir(parents=True,exist_ok=True);root=Path(tempfile.mkdtemp(prefix='all-',dir=a.output));native=[str(a.binary.resolve()),*flags(root/'directed')]
    regression=[sys.executable,str(cfg.HERE/'regress.py'),'--binary',str(a.binary.resolve()),'--output',str(root/'regression'),'--jobs='+str(a.jobs),'--seeds='+os.environ.get('SEEDS','100'),'--cycles='+os.environ.get('CYCLES','10000'),'--seed='+os.environ.get('SEED','1')]
    if os.environ.get('REQUIRE_MATRIX','true')=='true':regression.append('--require-matrix')
    groups=[('directed',[sys.executable,str(cfg.HERE/'catalog.py'),'--binary',str(a.binary.resolve()),'--run-dir',str(root/'directed')]),
            ('framework',[sys.executable,str(cfg.HERE/'validate.py'),'--binary',str(a.binary.resolve()),'--output',str(root/'framework')]),
            ('random-framework',[sys.executable,str(cfg.HERE/'validate.py'),'--random','--binary',str(a.binary.resolve()),'--output',str(root/'random-framework')]),
            ('regression',regression),
            ('mutations',[sys.executable,str(cfg.HERE/'mutate.py'),'--binary',str(a.binary.resolve()),'--output',str(root/'mutations'),'--jobs='+str(min(a.jobs,2))])]
    results=run_groups(groups,root,a.test_jobs);passed=all(r['passed'] for r in results)
    (root/'summary.json').write_text(json.dumps(dict(status='passed' if passed else 'failed',groups=results,full_contract_signoff=False),indent=2)+'\n')
    print('All tests passed' if passed else 'Test failed');print('Evidence:',root);return 0 if passed else 1
if __name__=='__main__':raise SystemExit(main())
