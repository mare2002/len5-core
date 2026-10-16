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

# Declared before evaluating results. EQ07 same-edge and deferred exception or
# alternative-memory protocols are outside this scope. FE-T54 is executed as a
# composite validator, not by accepting the native catalog's placeholder.
EXCLUDED={'FE-T41':'unapproved same-edge EQ07 alternatives','FE-T43':'exception recovery policy',
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
        return widths_smoke.simulate(str(a.binary.resolve()),root,s,[*flags,'--scenario='+s])
    with ThreadPoolExecutor(max_workers=a.jobs) as pool:results=list(pool.map(case,SCENARIOS))
    confidence=execute(a.binary.resolve(),root/'FE-T54')
    status=0 if confidence['status']=='passed' and all(r['exit']==0 for r in results) else 3
    summary={'scope':'ordinary-supported-exact-predictor','full_contract_signoff':False,'excluded':EXCLUDED,
             'results':results,'FE-T54':str(root/'FE-T54/summary.json'),'exit_status':status}
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('All tests passed: ordinary frontend scope' if not status else 'Test failed: ordinary frontend scope incomplete or mismatched')
    print('Evidence:',root/'summary.json');return status
if __name__=='__main__':raise SystemExit(main())
