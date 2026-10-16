#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""FE-T54 composite: execute real positive/expected-negative validators, never a stub PASS."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import validate
import configuration as cfg
import results

VALIDATORS = {'baseline','replay','waves','inject-request','inject-valid','inject-early',
              'inject-word','inject-pc','inject-target','inject-taken','inject-error','inject-mask',
              'cause-zero','inject-request-replay','backend-real-rejections','invalid-feedback',
              'wrong-width','replay-fingerprint','invalid-latency','empty','timeout',
              'missing-training-witness','stale-rejected','unknown-dependent'}

def validate_receipt(root,binary,config=None):
    """A matching receipt is evidence of executed validators, not a PASS switch."""
    root=Path(root).resolve();binary=Path(binary).resolve()
    summary=json.loads((root/'summary.json').read_text())
    assert summary['status']=='passed' and summary['units_executed'] is True
    assert summary['binary']==str(binary), 'unrelated confidence binary'
    assert summary['manifest_sha256']==hashlib.sha256((binary.parent/'fetch_stage_build.cfg').read_bytes()).hexdigest(), 'stale confidence manifest'
    assert config is None or summary['config']==config, 'confidence source/configuration mismatch'
    runs=summary['runs'];assert len(runs)==len(VALIDATORS) and {r['label'] for r in runs}==VALIDATORS, 'missing/duplicate confidence validator'
    for label in ('unit','unit-pc-gen','unit-early-jump','unit-fetch-mem'):
        log=root/(label+'.log')
        assert log.is_file() and 'PASS:' in log.read_text(), 'missing successful independent units'
    for r in runs:
        d=Path(r['artifacts']).resolve();assert d==root/r['label'], 'unrelated validator artifacts'
        actual=json.loads((d/'logs/report.json').read_text())
        assert actual==r['report'] and r['validator_status']=='PASS', 'invalid confidence receipt/report'
        expected=0 if r['label'] in ('baseline','replay','waves','backend-real-rejections') else 1 if r['label'].startswith('inject-') or r['label']=='cause-zero' else 3 if r['label'] in ('timeout','missing-training-witness','unknown-dependent') else 2
        assert r['exit']==r['expected_exit']==actual['exit_status']==expected, 'negative validator did not detect expected outcome'
        expected_class={0:results.PASS,1:results.MISMATCH,2:results.FRAMEWORK if r['label']=='empty' else results.ENVIRONMENT,3:results.INCOMPLETE}[expected]
        assert actual['verification_status']==r['expected_verification_status']==expected_class, 'wrong negative failure classification'
        if expected==0:assert actual['field_checks']>0 and actual['updates']>0, 'positive validator did not execute useful training'
        if expected==1:assert actual['injected_failures']>0 and actual['discrepancies'], 'missing injected discrepancy'
        if r['label']=='cause-zero':assert any(d.get('field','').endswith('.cause') for d in actual['discrepancies'])
    assert 'jal-cold-to-warm' in next(r for r in runs if r['label']=='missing-training-witness')['report']['scenarios'][0]['missing_witnesses']
    return dict(scenario='FE-T54',variant=0,status='passed',verification_status=results.PASS,completion=True,
                comparisons=sum(r['report'].get('field_checks',0) for r in runs),field_errors=0,
                expected_negative_mismatches=sum(r['report'].get('field_errors',0) for r in runs),
                cycles_executed=sum(r['report'].get('cycles_executed',0) for r in runs),
                validators=len(runs),reason='24 executed positive/expected-negative validators',missing_witnesses=[],
                evidence=str(root/'summary.json'),config=summary['config'])

def execute(binary,root,with_units=True):
    root.mkdir(parents=True,exist_ok=True)
    if with_units:validate.units(root)
    runs=[]
    common=['--directed_repetitions=8','--directed_cycles=1800','--exec_latency_max=8','--journal=full']
    def run(label,flags=(),exit=0):
        result=validate.native(binary,root,label,[*common,*flags],exit)
        runs.append(result)
        return result
    base=run('baseline');replay=run('replay');waves=run('waves',['--dump_waves=true'])
    journals=[(Path(r['artifacts'])/'logs/samples.jsonl').read_bytes() for r in (base,replay,waves)]
    assert journals[0]==journals[1]==journals[2], 'replay/FST public sequence differs'
    n=base['report']['config']['LEN5_MULTIPLE_ISSUES']
    public=validate.reconstruct(Path(base['artifacts']),n)
    obligations=validate.audit_obligations(Path(base['artifacts']),base['report'])
    for field in ('request','valid','early','word','pc','target','taken','error','mask'):
        r=run('inject-'+field,['--inject_failure='+field],1)
        assert r['report']['injected_failures']>0 and r['report']['discrepancies'], 'expected injected comparison absent'
    fault=run('cause-zero',['--scenario=FE-T07','--inject_failure=cause'],1)
    assert fault['report']['injected_failures'] and any(d.get('field','').endswith('.cause') for d in fault['report']['discrepancies'])
    repeat=run('inject-request-replay',['--inject_failure=request'],1)
    original=next(r for r in runs if r['label']=='inject-request')
    assert original['report']['discrepancies'][0]==repeat['report']['discrepancies'][0]
    run('backend-real-rejections',['--scenario=FE-T53'])
    run('invalid-feedback',['--inject_failure=environment'],2)
    run('wrong-width',['--expect_issues=99'],2)
    run('replay-fingerprint',['--expect_fingerprint=incompatible'],2)
    run('invalid-latency',['--exec_latency_min=0'],2)
    run('empty',['--scenario=empty'],2)
    run('timeout',['--max_cycles=8'],3)
    missing=run('missing-training-witness',['--directed_cycles=40','--exec_latency_max=64'],3)
    assert 'jal-cold-to-warm' in missing['report']['scenarios'][0]['missing_witnesses']
    stale=root/'stale';stale.mkdir()
    shutil.copy2(binary,stale/binary.name)
    shutil.copy2(binary.parent/'fetch_stage_build.cfg',stale/'fetch_stage_build.cfg')
    for p in binary.parent.glob('fetch_stage_*.snapshot'):shutil.copy2(p,stale/p.name)
    one=next(stale.glob('fetch_stage_*.snapshot'));one.write_bytes(one.read_bytes()+b'changed')
    result=validate.native(stale/binary.name,root,'stale-rejected',expected=2);runs.append(result)
    run('unknown-dependent',['--scenario=FE-T41','--ras_order=unknown'],3)
    summary={'scenario':'FE-T54','status':'passed','evidence':'executed independent units plus expected-negative native processes',
             'binary':str(binary.resolve()),'config':base['report']['config'],
             'manifest_sha256':hashlib.sha256((binary.parent/'fetch_stage_build.cfg').read_bytes()).hexdigest(),
             'units_executed':with_units,'runs':runs,'public_audit':public,'obligations':obligations,
             'replay_sha256':hashlib.sha256(journals[0]).hexdigest(),'full_contract_signoff':False}
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    case=validate_receipt(root,binary,base['report']['config'])
    (root/'logs').mkdir(exist_ok=True)
    report=results.aggregate([case],scope='FE-T54 composite confidence')
    report.update(scenarios=[case],field_checks=case['comparisons'],field_errors=0,config=base['report']['config'])
    results.write_summary(root/'logs/report.json',report)
    print('Test successfully passed: FE-T54 (%d executed validators); evidence: %s'%(len(runs),root),flush=True)
    return summary

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/confidence');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);root=Path(tempfile.mkdtemp(prefix='FE-T54-',dir=a.output.resolve()))
    execute(a.binary.resolve(),root)
    return 0
if __name__=='__main__':raise SystemExit(results.run_cli(main))
