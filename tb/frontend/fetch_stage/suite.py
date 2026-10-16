#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Concurrent groups; structured completion warnings preserve hard failures."""
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
import results as policy

def group_receipt(name,root,status):
    paths=sorted((root/name).rglob('summary.json'),key=lambda p:(len(p.parts),str(p)))
    if not paths:
        return [policy.failure('missing required group receipt or unexpected termination',root/(name+'.log'),name)]
    try:
        receipt=json.loads(paths[0].read_text())
        if 'cases' in receipt:
            cases=receipt['cases']
            if receipt['exit_status']!=status or status not in (0,1,2,3):
                return [*cases,policy.failure('group process/report disagreement',paths[0],name)]
            return cases
        if status or receipt['status']!='passed':
            return [policy.failure('required validator/mutation/coverage group failed',paths[0],name)]
        checks=receipt.get('totals',{}).get('field_checks',0)
        checks+=sum(x.get('report',{}).get('field_checks',0) for x in receipt.get('runs',[]))
        checks+=receipt.get('original_before',{}).get('checks',0)
        if not checks:return [policy.failure('group has no meaningful comparison evidence',paths[0],name)]
        return [dict(scenario=name,variant=0,verification_status=policy.PASS,comparisons=checks,field_errors=0,missing_witnesses=[],reason='executed validation group',evidence=str(paths[0]))]
    except (OSError,ValueError,KeyError,TypeError) as error:
        return [policy.failure('malformed group receipt: '+str(error),paths[0],name)]
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
        cases=group_receipt(name,root,status)
        summary=policy.aggregate(cases,policy.strict_completion())
        return dict(name=name, passed=summary['exit_status'] == 0, exit_status=summary['exit_status'],
                    native_exit_status=status,cases=cases,execution_status=summary['execution_status'],
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
            verdict = 'Executed checks passed with incomplete coverage' if result['execution_status']=='success_with_warnings' else 'Test successfully passed' if result['passed'] else 'Test failed'
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
    results=run_groups(groups,root,a.test_jobs)
    summary=policy.aggregate([c for r in results for c in r['cases']],policy.strict_completion(),groups=results,scope='full-suite')
    policy.write_summary(root/'summary.json',summary);policy.display(summary,'FRONTEND SUITE')
    print('Evidence:',root);return summary['exit_status']
if __name__=='__main__':raise SystemExit(policy.run_cli(main))
