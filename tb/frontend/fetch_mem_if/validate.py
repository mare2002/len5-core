#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Independent units, directed/native confidence, logger/replay/config guards; adapted from EJU validate.py."""
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
    d=root/label
    d.mkdir()
    argv=[str(binary),'--run_dir='+str(d),'--log_level=LOG_LOW','--seed=7',*flags]
    with (d/'console.log').open('w') as log:
        result=subprocess.run(argv,stdout=log,stderr=subprocess.STDOUT,timeout=120)
    report=json.loads((d/'logs/report.json').read_text())
    assert result.returncode==report['exit_status']==status,(label,result.returncode,report)
    assert report['sampled_records']>=report['transactions']
    assert report['pre_edge_records']>=report['cycles_executed']
    assert report['full_contract_signoff'] is False and len(report['unresolved_questions'])==12
    assert 'FQ03' not in report['unresolved_questions'] and report['specification_status']['FQ03']['status']=='supported'
    text=(d/'console.log').read_text()
    assert '\x1b[1m[CONFIG]' in text
    if status:
        assert '\x1b[1;31m[ERR!  ]' in text and 'TEST FAILED > errors:' in text
    elif '--log_level=LOG_NONE' not in flags:
        assert '\x1b[1;32m[OK!   ]' in text and 'TEST SUCCEEDED > errors: 0/' in text
    else:
        assert '[LOG   ]' not in text and '[OK!   ]' not in text
    if not status:
        assert report['field_checks']>0 and not report['field_errors']
        assert report['obligations']['pending']==0 and report['obligations_conserved']
    if '--log_level=LOG_NONE' not in flags:
        assert re.search(r'\[LOG   \] \w+\.cpp:\d+ >\s+\[\s*\d+\] Starting simulation',text)
    print(f'Test successfully passed: {label}: expected exit={status}, comparisons={report["field_checks"]}, mismatches={report["field_errors"]}',flush=True)
    return report,d,dict(case=label,command=argv,expected_exit=status,checks=report['field_checks'],errors=report['field_errors'])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path('build/fetch-mem-if/validation'))
    args=p.parse_args();binary=args.binary.resolve();args.output.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='framework-',dir=args.output.resolve()));source=Path(__file__).resolve().parent
    unit=root/'model-unit'
    command=['/usr/bin/g++','-std=c++17','-O2','-Wall','-Wextra','-Werror','-I'+str(source.parent/'pc_gen'),'-I'+str(source.parent/'early_jump_unit')]
    command += [str(source/f'fetch_mem_{part}.cpp') for part in ['model','environment','unit']]
    command += [str(source.parent/'pc_gen/pc_gen_model.cpp'),str(source.parent/'early_jump_unit/early_jump_instructions.cpp'),'-o',str(unit)]
    with (root/'unit-build.log').open('w') as log:subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    result=subprocess.run([str(unit)],capture_output=True,text=True,check=True)
    (root/'unit.log').write_text(result.stdout+result.stderr);print(result.stdout.strip(),flush=True)
    cases=[]
    def run(label,flags=(),status=0):
        r,d,c=case(binary,root,label,flags,status);cases.append(c);return r,d
    baseline,d=run('integrated')
    assert len(baseline['scenario_samples'])==44
    coverage=json.loads((d/'logs/coverage.json').read_text())['counters']
    for event in ('reserved-full','completed-full','arriving-head-bypass',
                  'older-result-with-return','full-release-bubble',
                  'flush-mixed-with-return','reset-mixed'):
        assert coverage.get('architectural/FV23/'+event,0)>0, event
    assert baseline['requirement_checks']['FM05/D']>0 and baseline['requirement_checks']['FM11/D']>0
    assert baseline['obligations']['fault_deliveries']>0 and baseline['obligations']['fault_cancellations']>0
    assert baseline['dont_care_output_samples']
    zero,_=run('zero-latency',['--scenario=FM-T34'])
    assert zero['obligations']['delivered']==3 and zero['requirement_checks']['FM05/D']>0
    assert not any('FQ03' in q for q in zero['unknown_output_samples'])
    established,_=run('established',['--contract=established'])
    assert established['field_checks']<baseline['field_checks'] and established['requirement_checks']['FM11/D']>0
    _,rd=run('replay-fst',['--dump_waves=true'])
    digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest(d/'logs/samples.jsonl')==digest(rd/'logs/samples.jsonl')
    assert (rd/'logs/waves.fst').stat().st_size>0
    _,vd=run('verbose',['--scenario=FM-T15','--log_level=LOG_HIGH'])
    assert 'REQ > id=FM-T15' in (vd/'console.log').read_text()
    for injection,scenario in [('request','03'),('ready','03'),('valid','03'),('word','03'),('pc','03'),('target','03'),('mask','03'),('error','15'),('cause','16')]:
        r,negative_dir=run('injected-'+injection,['--scenario=FM-T'+scenario,'--inject_failure='+injection],1)
        assert r['injected_failures'] and not r['confirmed_mismatches'] and not r['provisional_mismatches']
        if injection=='request':
            coverage=json.loads((negative_dir/'logs/coverage.json').read_text())
            assert r['obligations']['accepted']==0
            assert not sum(v for k,v in coverage['counters'].items() if k.endswith('FV01/request-accepted'))
    r,_=run('invalid-environment',['--scenario=FM-T03','--inject_failure=environment'],2);assert r['environment_errors']==1
    r,_=run('framework-error',['--scenario=FM-T03','--inject_failure=framework'],2);assert r['framework_errors']==1
    r,_=run('empty',['--inject_failure=empty'],3);assert r['field_checks']==0
    r,_=run('incomplete',['--inject_failure=incomplete'],3);assert r['obligations']['pending']==1
    run('timeout',['--max_cycles=1'],3)
    run('quiet',['--scenario=FM-T01','--log_level=LOG_NONE'])
    guards=[];selected=baseline['config']['bundle_instructions'];wrong=1 if selected!=1 else 2
    r=subprocess.run([str(binary),'--expect_issues='+str(wrong)],capture_output=True,text=True)
    assert r.returncode==2 and 'replay configuration mismatch' in r.stdout+r.stderr;guards.append('wrong replay width')
    r=subprocess.run([str(binary),'--expect_depth=1'],capture_output=True,text=True)
    assert r.returncode==2;guards.append('wrong replay depth')
    for label in ['stale-snapshot','wrong-elaboration']:
        copied=root/label;copied.mkdir();shutil.copyfile(binary,copied/binary.name);(copied/binary.name).chmod(0o755)
        for f in binary.parent.glob('fetch_mem_*'):
            if f.suffix=='.snapshot' or f.name=='fetch_mem_build.cfg':shutil.copyfile(f,copied/f.name)
        if label=='stale-snapshot':
            snapshot=next(copied.glob('*.snapshot'));snapshot.write_bytes(snapshot.read_bytes()+b'\n// stale disposable snapshot\n')
        else:
            manifest=copied/'fetch_mem_build.cfg';text=manifest.read_text().replace('bundle_instructions='+str(selected)+'\n','bundle_instructions='+str(wrong)+'\n').replace('bundle_bytes='+str(selected*4)+'\n','bundle_bytes='+str(wrong*4)+'\n').replace('issue_bits='+str(selected.bit_length()-1)+'\n','issue_bits='+str(wrong.bit_length()-1)+'\n');manifest.write_text(text)
        r=subprocess.run([str(copied/binary.name)],capture_output=True,text=True);(copied/'console.log').write_text(r.stdout+r.stderr)
        assert r.returncode==2,(label,r.stdout,r.stderr);guards.append(label)
    summary=dict(status='passed',config=baseline['config'],unit_result=result.stdout.strip(),results=cases,guards=guards,replay_sha256=digest(d/'logs/samples.jsonl'),log_compatibility='shared TbLogger ANSI, cycle/tick, summaries, REQ and replay/error diagnostics')
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print('Framework evidence:',root/'summary.json');print('Test successfully passed: fetch_mem_if framework',flush=True)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: fetch_mem_if framework',flush=True)
        raise
