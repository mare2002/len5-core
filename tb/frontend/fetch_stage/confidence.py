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
    run('empty',['--scenario=empty'],3)
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
             'units_executed':with_units,'runs':runs,'public_audit':public,'obligations':obligations,
             'replay_sha256':hashlib.sha256(journals[0]).hexdigest(),'full_contract_signoff':False}
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    (root/'logs').mkdir(exist_ok=True)
    (root/'logs/report.json').write_text(json.dumps({'status':'passed','exit_status':0,'scenarios':[{'scenario':'FE-T54','status':'passed','validators':len(runs)}],
          'full_contract_signoff':False,'evidence':str(root/'summary.json'),'field_checks':sum(r['report'].get('field_checks',0) for r in runs)},indent=2)+'\n')
    print('Test successfully passed: FE-T54 (%d executed validators); evidence: %s'%(len(runs),root),flush=True)
    return summary

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/confidence');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);root=Path(tempfile.mkdtemp(prefix='FE-T54-',dir=a.output.resolve()))
    execute(a.binary.resolve(),root)
    return 0
if __name__=='__main__':raise SystemExit(main())
