#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Short isolated production-width tests; never edits the live source selection."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import configuration as cfg

ROOT=cfg.ROOT

def protected():
    paths=list((ROOT/'rtl').rglob('*'))
    for name in ('pc_gen','early_jump_unit','fetch_mem_if'):
        paths+=list((ROOT/'tb/frontend'/name).rglob('*'))
    return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in paths if p.is_file() and '__pycache__' not in p.parts}

def snapshot(parent,n,optimization='no-dfg'):
    """Content addressed, independent full package/library tree and native manifest."""
    source_hash=cfg.fingerprint(cfg.configuration())
    target=parent/('n%d-%s-%s'%(n,optimization,source_hash[:16]))
    source=target/'source'
    if not source.exists():
        target.mkdir(parents=True,exist_ok=True)
        staging=Path(tempfile.mkdtemp(prefix='export-',dir=target))
        for folder in ('rtl','tb'):
            shutil.copytree(ROOT/folder,staging/folder,ignore=shutil.ignore_patterns('__pycache__'))
        (staging/'fusesoc.conf').write_text('[library.len5]\nlocation = .\nsync-type = local\n')
        config=staging/'rtl/packages/len5_config_pkg.sv'
        text,count=re.subn(r'(\bLEN5_MULTIPLE_ISSUES\s*=\s*)[^;]+',r'\g<1>'+"32'd"+str(n),config.read_text())
        if count!=1:raise ValueError('expected exactly one production width definition')
        config.write_text(text)
        core=staging/'tb/frontend/fetch_stage/fetch_stage_tb.core'
        if optimization!='no-dfg':
            core.write_text(core.read_text().replace('        - -fno-dfg\n','        - -O0\n' if optimization=='O0' else ''))
        staging.rename(source)
    return target,source

def build(parent,n,optimization='no-dfg'):
    target,source=snapshot(parent,n,optimization)
    env={**os.environ,'BUILD_DIR':str(target/'build')}
    script=source/'tb/frontend/fetch_stage/run.py'
    with (target/'build-console.log').open('w') as f:
        r=subprocess.run(['python3',str(script),'--build-only'],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT)
    result={'N':n,'optimization':optimization,'source':str(source),'build_exit':r.returncode}
    if not r.returncode:
        binary=subprocess.check_output(['python3',str(source/'tb/frontend/fetch_stage/configuration.py'),'--binary','--build-dir',env['BUILD_DIR']],cwd=source,text=True).strip()
        result['binary']=binary
    else:result['build_log']=str(target/'build-console.log')
    return result

def simulate(binary,parent,label,args):
    d=parent/label;d.mkdir()
    command=[binary,'--run_dir='+str(d),'--log_level=LOG_LOW','--journal=full',*args]
    with (d/'console.log').open('w') as f:r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT)
    report=d/'logs/report.json'
    return {'label':label,'exit':r.returncode,'command':command,'artifacts':str(d),
            'report':json.loads(report.read_text()) if report.exists() else {}}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--widths',default=os.environ.get('N_VALUES','1,2,4,8'))
    p.add_argument('--output',type=Path,default=ROOT/'build/fetch-stage/widths-smoke')
    p.add_argument('--scenario',default=os.environ.get('SCENARIO',''))
    p.add_argument('--seeds',type=int,default=int(os.environ.get('SMOKE_SEEDS','3')))
    p.add_argument('--cycles',type=int,default=int(os.environ.get('SMOKE_CYCLES','1500')))
    p.add_argument('--build-only',action='store_true')
    p.add_argument('--optimization',choices=['default','O0','no-dfg'],default='no-dfg')
    a=p.parse_args();a.scenario='' if a.scenario=='all' else a.scenario; widths=[int(n) for n in a.widths.split(',')]
    if not widths or any(n not in (1,2,4,8) for n in widths) or a.seeds<0 or a.cycles<1:raise ValueError('invalid smoke configuration')
    a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True);(a.output/'FUSESOC_IGNORE').touch()
    before=protected();out=Path(tempfile.mkdtemp(prefix='evidence-',dir=a.output));print('Evidence:',out,flush=True)
    rows=[]
    try:
        for n in widths:
            print('Compiling isolated N=%d (%s)'%(n,a.optimization),flush=True)
            row=build(a.output,n,a.optimization);rows.append(row);row['runs']=[]
            if row['build_exit'] or a.build_only:continue
            binary=row['binary'];runs=out/('n%d'%n);runs.mkdir()
            common=['--expect_issues='+str(n),'--directed_repetitions=8','--exec_latency_max=8']
            if a.scenario:
                row['runs'].append(simulate(binary,runs,a.scenario,[*common,'--scenario='+a.scenario,'--directed_cycles=3000']))
                continue
            stage_a=simulate(binary,runs,'reset-sequential',[*common,'--scenario=FE-T01','--program=short-sequential','--directed_cycles=250'])
            row['runs'].append(stage_a)
            if stage_a['exit']:continue
            for scenario in ('FE-T02','FE-T06','FE-T07','FE-T17','FE-T18','FE-T19','FE-T09','FE-T28','FE-T30','FE-T33','FE-T34'):
                result=simulate(binary,runs,scenario,[*common,'--scenario='+scenario,'--directed_cycles=2000'])
                row['runs'].append(result)
                if result['exit']:break
            else:
                for seed in range(1,a.seeds+1):
                    dist=('uniform','triangular-early','bimodal')[ (seed-1)%3 ]
                    row['runs'].append(simulate(binary,runs,'random-%d'%seed,[*common,'--random','--campaign=architectural','--seed='+str(seed),'--cycles='+str(a.cycles),'--repetitions=8','--exec_latency_dist='+dist]))
    finally:
        after=protected();changed=[p for p,h in before.items() if after.get(p)!=h]
        summary={'rows':rows,'protected_before':before,'protected_changed':changed,'full_regression_run':False}
        (out/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
        for row in rows:
            print('N=%d build=%d %s'%(row['N'],row['build_exit'],', '.join('%s:%d'%(r['label'],r['exit']) for r in row['runs'])),flush=True)
        print('Summary:',out/'summary.json',flush=True)
        if changed:raise RuntimeError('protected source changed: '+str(changed))
    return int(any(row['build_exit'] or any(r['exit'] for r in row['runs']) for row in rows))
if __name__=='__main__':raise SystemExit(main())
