#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Replay, public-journal transaction reconstruction and confidence checks adapted from EJU."""
import argparse
from collections import Counter, deque
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from validate import case


def reconstruct(path, lanes):
    """A second queue oracle from public pre-edge ports, not C++ expected/model labels."""
    requests=deque();answers=deque();counts=Counter();known=True;released=False
    for line in path.read_text().splitlines():
        s=json.loads(line)
        if s['phase']!='pre':continue
        i=s['inputs'];a=s['actual'];c=s['campaign'];counts[c+'/sampled']+=1
        if not i['rst_n']:
            requests.clear();answers.clear();known=True;released=False
            continue
        if s['malformed']:
            known=False
            continue
        if not known:continue
        assert a['valid']==bool(released and answers),(s['cycle'],'public output valid')
        assert a['response_ready']==bool(released and not i['flush'] and len(answers)<2),(s['cycle'],'ready/full timing')
        assert a['request_valid']==i['fetch_valid'] and a['fetch_ready']==i['grant'] and not a['write']
        if i['fetch_valid']:
            assert a['request_address']==i['lanes'][0]['pc']
        k=a['request_valid'] and i['grant'];r=i['response_valid'] and a['response_ready'];d=a['valid'] and i['consumer_ready']
        if not i['flush']:
            counts[c+'/row/'+str(int(k)*4+int(r)*2+int(d))]+=1
        counts[c+f'/FV04/cross/a={len(answers)}/K={int(k)}/R={int(r)}']+=1
        error_role=int(bool(i['response_valid'] and i['errors'])) | (2*int(bool(a['valid'] and (a['errors'] & a['mask']))))
        counts[c+f'/FV14/cross/error={error_role}/flush={int(i["flush"])}/q={len(requests)}']+=1
        if d:
            assert answers
            old=answers.popleft()
            assert a['mask']==old['mask']
            for lane in range(lanes):
                expected=old['pred'][lane];actual=a['lanes'][lane]
                for key in ['pc','target','hit','taken']:
                    assert actual[key]==expected[key],(s['cycle'],lane,key,actual,expected)
                assert actual['word']==old['words'][lane]
                assert ((a['errors']>>lane)&1)==((old['errors']>>lane)&1)
                assert actual['cause']==old['causes'][lane]
            counts[c+'/delivered']+=1
            hitmask=sum(1<<lane for lane,pred in enumerate(old['pred']) if pred['hit'])
            latency='short' if old['arrived']-old['accepted']<=4 else 'delayed'
            counts[c+f'/FV09/cross/hitmask={hitmask}/latency={latency}/metadata=matched']+=1
        if i['flush']:
            assert not k and not r
            counts[c+'/canceled']+=len(requests)+len(answers)
            requests.clear();answers.clear();released=True
            continue
        if r:
            assert requests,'no old metadata for memory completion'
            old=requests.popleft()
            answers.append(dict(**old,words=[v['word'] for v in i['lanes']],causes=[v['cause'] for v in i['lanes']],errors=i['errors'],arrived=s['cycle']))
            counts[c+'/responded']+=1
        if k:
            assert len(requests)<2
            requests.append(dict(mask=i['mask'],pred=[dict(v) for v in i['lanes']],accepted=s['cycle']))
            counts[c+'/accepted']+=1
        assert len(requests)<=2 and len(answers)<=2
        released=True
    assert not requests and not answers,'journal ends with unresolved reliable obligations'
    return counts


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=Path('build/fetch-mem-if/validation'))
    args=p.parse_args();binary=args.binary.resolve();args.output.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='random-',dir=args.output.resolve()));source=Path(__file__).resolve().parent
    verifier=Path(subprocess.check_output([os.environ.get('VERILATOR','verilator'),'--getenv','VERILATOR_ROOT'],text=True).strip())
    confidence=root/'confidence'
    cmd=['/usr/bin/g++','-std=c++17','-O2','-Wall','-Wextra','-Werror','-DVL_TIME_CONTEXT','-I'+str(source.parent/'pc_gen'),'-I'+str(source.parent/'early_jump_unit'),'-I'+str(source.parents[1]/'verilator'),'-isystem',str(verifier/'include')]
    cmd += [str(source/f'fetch_mem_{part}.cpp') for part in ['model','scoreboard','scoreboard_unit']]
    cmd += [str(source.parent/'pc_gen/pc_gen_model.cpp'),str(source.parent/'early_jump_unit/early_jump_instructions.cpp'),str(source.parents[1]/'verilator/tb_macros.cpp'),'-o',str(confidence)]
    with (root/'confidence-build.log').open('w') as log:subprocess.run(cmd,stdout=log,stderr=subprocess.STDOUT,check=True)
    for kind in ['unverified','matched','definitive']:
        d=root/('confidence-'+kind)
        with (root/(kind+'.log')).open('w') as log:r=subprocess.run([str(confidence),str(d),kind],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((d/'report.json').read_text());assert r.returncode==1 and report['confirmed_mismatches']==(0 if kind=='unverified' else 1)
        assert report['field_checks']>0
        if kind=='unverified':
            assert report['provisional_mismatches']>=3 and report['requirement_checks']['FM06/D']>0
        print('Test successfully passed: synthetic confidence '+kind,flush=True)
    subprocess.run([str(confidence),str(root/'coverage-fixtures'),'coverage'],check=True)
    for n in [1,2,4,8]:
        cov=json.loads((root/f'coverage-fixtures/{n}/coverage.json').read_text());assert cov['LEN5_MULTIPLE_ISSUES']==n
        goals=cov['campaigns']['architectural']['feature_goals'];starts={int(g['bin'].split('/start/')[-1]) for g in goals if '/start/' in g['bin']}
        assert starts==set(range(n))
        assert all(cov['counters'][f'architectural/FV07/start/{k}']==1 for k in range(n))
    results=[]
    def run(label,flags=(),status=0):
        r,d,meta=case(binary,root,label,['--random','--seed=17','--cycles=4096','--max_cycles=4096',*flags],status);results.append(meta);return r,d
    base,bd=run('all-full',['--journal=full']);replay,rd=run('replay-fst',['--journal=full','--dump_waves=true'])
    digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    assert digest(bd/'logs/samples.jsonl')==digest(rd/'logs/samples.jsonl') and base['stimulus_digest']==replay['stimulus_digest']
    assert (rd/'logs/waves.fst').stat().st_size>0
    counts=reconstruct(bd/'logs/samples.jsonl',base['config']['bundle_instructions'])
    cov=json.loads((bd/'logs/coverage.json').read_text())
    for c,data in cov['campaigns'].items():
        for row in data['matrix']:
            assert counts[c+'/row/'+str(row['row'])]==row['count'],(c,row)
    crosses=0
    for key,value in cov['counters'].items():
        if any('/'+category+'/cross/' in key for category in ['FV04','FV09','FV14']):
            assert counts[key]==value,(key,counts[key],value)
            crosses+=1
    assert crosses>0
    for c in ['architectural','interface_stress','characterization']:
        assert counts[c+'/accepted'] and counts[c+'/responded'] and counts[c+'/delivered']
    arch,ad=run('architectural',['--campaign=architectural','--journal=full'])
    ac=reconstruct(ad/'logs/samples.jsonl',base['config']['bundle_instructions'])
    assert ac['architectural/delivered']==arch['obligations']['delivered']
    for label,flags in [('stress',['--campaign=stress']),('characterization',['--campaign=characterization']),('established',['--contract=established']),('seed18',['--seed=18']),('seed-max',['--seed=18446744073709551615']),('unguided',['--guided=false']),('weights',['--weights=request=90,error=70,ready=90,reset=0'])]:run(label,flags)
    fault,fd=run('injected',['--inject_failure=pc','--journal=full'],1)
    repeated,frd=run('injected-replay',['--inject_failure=pc','--journal=full','--dump_waves=true'],1)
    assert fault['discrepancies'][0]==repeated['discrepancies'][0]
    assert digest(fd/'logs/samples.jsonl')==digest(frd/'logs/samples.jsonl')
    assert 'Replay:' in (fd/'console.log').read_text()
    run('invalid-environment',['--inject_failure=environment'],2);run('framework-error',['--inject_failure=framework'],2)
    command=[os.sys.executable,str(source/'regress.py'),'--binary',str(binary),'--output',str(root/'incomplete'),'--seeds=1','--cycles=1','--require-matrix']
    with (root/'coverage-incomplete.log').open('w') as log:r=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT)
    assert r.returncode!=0
    summary=dict(status='passed',config=base['config'],results=results,confidence_checks=3,configuration_fixtures=[1,2,4,8],replay_sha256=digest(bd/'logs/samples.jsonl'),reconstructed_public_counts=dict(counts),reconstructed_architectural_obligations=dict(ac),coverage_bins_verified=sum(len(v['matrix']) for v in cov['campaigns'].values()),cross_bins_verified=crosses)
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');print('Random framework evidence:',root/'summary.json');print('Test successfully passed: fetch_mem_if random framework',flush=True);return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: fetch_mem_if random framework',flush=True)
        raise
