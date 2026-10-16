#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Parallel isolated native processes and schema-aware coverage merge, adapted from FM."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import configuration as cfg
from run import flags
import results as policy

def regression(binary,output,seeds,cycles,jobs,require_matrix):
    root=Path(tempfile.mkdtemp(prefix='regression-',dir=output));started=time.monotonic()
    def run(seed):
        directory=root/('seed-%d'%seed);directory.mkdir()
        command=[str(binary),*flags(directory),'--random','--seed='+str(seed),'--cycles='+str(cycles),'--journal=failures','--campaign='+os.environ.get('CAMPAIGN','all'),'--guided='+os.environ.get('GUIDED','true'),'--weights='+os.environ.get('WEIGHTS','')]
        with (directory/'console.log').open('w') as f:status=policy.process(command,f)
        path=directory/'logs/report.json';report=json.loads(path.read_text()) if path.exists() else {}
        cov=directory/'logs/coverage.json';coverage=json.loads(cov.read_text()) if cov.exists() else {}
        return dict(seed=seed,exit=status,report=report,coverage=coverage,command=command,artifacts=str(directory))
    with ThreadPoolExecutor(max_workers=jobs) as pool:runs=list(pool.map(run,seeds))
    totals=Counter();coverage=Counter();scenarios=[]
    keys=['cycles_executed','field_checks','field_errors','confirmed_mismatches','provisional_mismatches','updates','confirmations','executions','recoveries','requests','responses','delivered','canceled','dynamic_instructions','retired','backend_canceled']
    for run in runs:
        totals.update({k:run['report'].get(k,0) for k in keys});coverage.update(run['coverage'].get('counters',{}));scenarios+=run['report'].get('scenarios',[])
    gaps=[i for i in range(16) if not any(v for k,v in coverage.items() if k.endswith('/FEV01/row/'+str(i)))]
    cases=[];config=runs[0]['report'].get('config',{})
    for result in runs:
        cases += [dict(c,scenario='seed-%d/'%result['seed']+c['scenario']) for c in policy.native_cases(result,config=config)]
        if not result['coverage']:cases.append(policy.failure('required coverage report missing',result['artifacts']))
    if require_matrix and gaps:
        cases.append(dict(scenario='required-channel-matrix',variant=0,verification_status=policy.INCOMPLETE,comparisons=0,field_errors=0,reason='required matrix rows unwitnessed',missing_witnesses=gaps,evidence=str(root/'summary.json')))
    summary=policy.aggregate(cases,policy.strict_completion(),seconds=time.monotonic()-started,seed_count=len(seeds),cycles_per_seed=cycles,config=config,totals=dict(totals),coverage=dict(coverage),matrix_hit=16-len(gaps),matrix_required=16,matrix_gaps=gaps,feature_closure='not complete: consult per-scenario and README obligations',runs=runs)
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    policy.display(summary,'FRONTEND REGRESSION')
    print('Evidence:',root/'summary.json');return summary['exit_status']

def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/regression');p.add_argument('--seeds',type=int,default=100);p.add_argument('--seed',type=int,default=1);p.add_argument('--cycles',type=int,default=10000);p.add_argument('--jobs',type=int,default=4);p.add_argument('--require-matrix',action='store_true');a=p.parse_args()
    if min(a.seeds,a.cycles,a.jobs)<1:p.error('positive seed count/cycles/jobs required')
    a.output.mkdir(parents=True,exist_ok=True);return regression(a.binary.resolve(),a.output,range(a.seed,a.seed+a.seeds),a.cycles,a.jobs,a.require_matrix)
if __name__=='__main__':raise SystemExit(policy.run_cli(main))
