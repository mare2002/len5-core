#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Explicit ordinary-contract scope; full-specification target retains its meaning."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import tempfile
import configuration as cfg
import run
import widths_smoke
from confidence import execute
import results as policy
from confidence import validate_receipt

# Declared before evaluating results. Deferred exception or
# alternative-memory protocols are outside this scope. FE-T54 is executed as a
# composite validator, not by accepting the native catalog's placeholder.
EXCLUDED={'FE-T43':'exception recovery policy',
          'FE-T48':'delayed data-fault/retirement context','FE-T49':'exception redirect window',
          'FE-T50':'faulting jump policy','FE-T51':'alternative memory protocols'}
SCENARIOS=['FE-T%02d'%i for i in range(1,55) if 'FE-T%02d'%i not in EXCLUDED and i!=54]

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/core');p.add_argument('--jobs',type=int,default=2)
    a=p.parse_args()
    if a.jobs<1:raise ValueError('positive jobs required')
    a.output.mkdir(parents=True,exist_ok=True);root=Path(tempfile.mkdtemp(prefix='ordinary-',dir=a.output.resolve()))
    def case(s):
        flags=run.flags(root/s)
        flags=[f for f in flags if not f.startswith(('--run_dir=','--scenario='))]
        directory=root/s;directory.mkdir()
        command=[str(a.binary.resolve()),'--run_dir='+str(directory),*flags,'--scenario='+s]
        with (directory/'console.log').open('w') as log:status=policy.process(command,log)
        try:report=json.loads((directory/'logs/report.json').read_text())
        except (OSError,ValueError):report={}
        return dict(label=s,exit=status,command=command,artifacts=str(directory),report=report)
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:results=list(pool.map(case,SCENARIOS))
    cases=[]
    reference=cfg.configuration();reference['fingerprint']=cfg.fingerprint(reference)
    config={'LEN5_MULTIPLE_ISSUES':reference['bundle_instructions'],'boot_pc':'0x%016x'%reference['boot_pc'],'fingerprint':reference['fingerprint']}
    selected_variant=__import__('os').environ.get('VARIANT')
    for r in results:
        expected=[(r['label'],v) for v in ([int(selected_variant,0)] if selected_variant is not None else policy.variants(r['label'],config['LEN5_MULTIPLE_ISSUES']))]
        cases+=policy.native_cases(r,expected,config)
    try:
        execute(a.binary.resolve(),root/'FE-T54')
        cases.append(validate_receipt(root/'FE-T54',a.binary.resolve(),config))
    except (Exception, SystemExit) as error:
        cases.append(policy.failure('FE-T54 composite validation failed: '+str(error),root/'FE-T54','FE-T54'))
    summary=policy.aggregate(cases,policy.strict_completion(),scope='ordinary-supported-exact-predictor',excluded=EXCLUDED,
                             results=results,confidence_evidence=str(root/'FE-T54/summary.json'),
                             native_cycles_executed=sum(r['report'].get('cycles_executed',0) for r in results),
                             confidence_cycles_executed=sum(c.get('cycles_executed',0) for c in cases if c['scenario']=='FE-T54'),
                             cycles_executed=sum(r['report'].get('cycles_executed',0) for r in results)+sum(c.get('cycles_executed',0) for c in cases if c['scenario']=='FE-T54'))
    policy.write_summary(root/'summary.json',summary);policy.display(summary,'ORDINARY FRONTEND VERIFICATION')
    print('Evidence:',root/'summary.json');return summary['exit_status']
if __name__=='__main__':raise SystemExit(policy.run_cli(main))
