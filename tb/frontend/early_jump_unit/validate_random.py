#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Random replay, sampled coverage and confidence validation adapted from pc_gen."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from validate import case


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path('build/early-jump/validation'))
    args=p.parse_args(); binary=args.binary.resolve(); args.output.mkdir(parents=True,exist_ok=True)
    root=Path(tempfile.mkdtemp(prefix='random-',dir=args.output.resolve())); source=Path(__file__).resolve().parent
    verifier=Path(subprocess.check_output([os.environ.get('VERILATOR','verilator'),'--getenv','VERILATOR_ROOT'],text=True).strip())
    confidence=root/'scoreboard-confidence'
    command=[os.environ.get('EARLY_JUMP_CXX','/usr/bin/g++'),'-std=c++17','-O2','-Wall','-Wextra','-Werror','-DVL_TIME_CONTEXT',
             '-I'+str(source.parent/'pc_gen'),'-I'+str(source.parents[1]/'verilator'),'-isystem',str(verifier/'include')]
    command += [str(source/f'early_jump_{part}.cpp') for part in ['instructions','model','scoreboard','scoreboard_unit']]
    command += [str(source.parent/'pc_gen/pc_gen_model.cpp'),str(source.parents[1]/'verilator/tb_macros.cpp'),'-o',str(confidence)]
    with (root/'confidence-build.log').open('w') as log: subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True)
    subprocess.run([str(confidence),str(root/'buffered-output-failure'),'output-failure'],check=True)
    print('PASS: buffered report write failure is rejected',flush=True)
    for kind in ['unverified','matched','definitive']:
        d=root/('confidence-'+kind)
        with (root/('confidence-'+kind+'.log')).open('w') as log: result=subprocess.run([str(confidence),str(d),kind],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((d/'report.json').read_text())
        assert result.returncode==1 and report['confirmed_mismatches']==(0 if kind=='unverified' else 1),(kind,report)
        assert report['field_checks']>0
        print('Test successfully passed: synthetic scoreboard confidence '+kind,flush=True)
    subprocess.run([str(confidence),str(root/'coverage-fixtures'),'coverage'],check=True)
    for n in [1,2,4,8]:
        cov=json.loads((root/f'coverage-fixtures/{n}/coverage.json').read_text())
        assert cov['LEN5_MULTIPLE_ISSUES']==n
        goals=cov['campaigns']['architectural']['feature_goals']
        lanes={int(g['bin'].split('/start/')[-1]) for g in goals if '/start/' in g['bin']}
        assert lanes==set(range(n))
        assert all(cov['counters'][f'architectural/EV02/start/{lane}']==1 for lane in lanes)
    results=[]
    def run(label,flags=(),status=0,cycles=4096):
        r,d,result=case(binary,root,label,['--random',f'--cycles={cycles}',f'--max_cycles={cycles}','--seed=17',*flags],status)
        results.append(result)
        if status<2: assert r['cycles_executed']==cycles
        return r,json.loads((d/'logs/coverage.json').read_text()),d
    baseline,cov,d=run('all-full',['--journal=full'])
    replay,_,rd=run('replay-fst',['--journal=full','--dump_waves=true'])
    digest=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
    assert baseline['stimulus_digest']==replay['stimulus_digest']
    assert digest(d/'logs/samples.jsonl')==digest(rd/'logs/samples.jsonl')
    assert (rd/'logs/waves.fst').stat().st_size>0
    compact,_,cd=run('compact')
    assert compact['stimulus_digest']==baseline['stimulus_digest'] and compact['field_checks']==baseline['field_checks']
    assert (cd/'logs/samples.jsonl').stat().st_size==0
    assert (cd/'logs/characterization.jsonl').stat().st_size>0
    for campaign in ['architectural','stress','characterization']:run(campaign,['--campaign='+campaign])
    run('established',['--contract=established'])
    different,_,_=run('different-seed',['--seed=18']); assert different['stimulus_digest']!=baseline['stimulus_digest']
    run('maximum-seed',['--seed=18446744073709551615'])
    run('unguided',['--guided=false'])
    weighted,_,_=run('weighted',['--weights=ordinary=50,call=20,jump=10,return=20,branch=15,confirm=40,restore=12,stall=35,reset=2'])
    assert 'stall=35' in weighted['random_configuration']['weights']
    run('environment-error',['--campaign=architectural','--inject_failure=environment'],2)
    run('framework-error',['--inject_failure=framework'],2)
    fault,_,fd=run('injected',['--inject_failure=missed-jal'],1)
    same,_,_=run('injected-replay',['--inject_failure=missed-jal','--dump_waves=true','--journal=full'],1)
    assert fault['discrepancies'][0]==same['discrepancies'][0]
    assert fault['injected_failures']>0 and not fault['confirmed_mismatches'] and not fault['provisional_mismatches']
    assert 'NEW_REPLAY_DIRECTORY' in fault['replay_command'] and 'Replay:' in (fd/'console.log').read_text()
    # Reconstruct observed bins from sampled public inputs, never actual outputs.
    samples=[json.loads(line) for line in (d/'logs/samples.jsonl').read_text().splitlines()]
    matrix=Counter(); starts=Counter(); classes=Counter(); confirmations=0; recoveries=0; previous={}
    for s in samples:
        if s['phase']!='pre':continue
        i=s['inputs']; campaign=s['campaign']
        if i['rst_n']:
            if not(i['C+'] and i['C-']):
                op={'none':0,'push':1,'pop':2}[s['speculative_operation']]
                # Offered operation counts even when not accepted: derive from decoded selection.
                op=0 if not i['V'] else {'call':1,'return':2}.get(s['selected_class'],0)
                confirm=1 if i['C+'] else 2 if i['C-'] else 0
                matrix[campaign,op,confirm,int(i['F'])]+=1
            if i['V']:
                n=baseline['config']['bundle_instructions']; lane=(int(s['request_pc'],16)%(4*n))//4
                starts[f'{campaign}/EV02/start/{lane}']+=1
                for k,word in enumerate(i['lanes']):
                    state=int(word['hit'])*2+int(word['taken']); eligibility='eligible' if i['mask']&(1<<k) else 'inactive'
                    classes[f'{campaign}/EV03/{eligibility}/{word["class"]}/lane={k}/pred={state}']+=1
            if campaign=='architectural':
                if i['V']:assert s['cycle']>=s['available_cycle']>=s['requested_cycle']+s['response_delay']
                if i['C+'] or i['C-']:assert s['confirmation_id']>0; confirmations+=1
                if i['F'] and s['recovery_reason']=='misprediction':
                    assert s['recovery_id']>0
                    recoveries+=1
                last=previous.get(campaign)
                if last and last['epoch']==s['epoch'] and not last['inputs']['F'] and last['cycle']+1==s['cycle'] and last['inputs']['V'] and not last['inputs']['R'] and not i['F']:
                    assert i['lanes']==last['inputs']['lanes'] and i['mask']==last['inputs']['mask']
        previous[campaign]=s if i['rst_n'] else None
    assert confirmations>0 and recoveries>0
    for campaign,section in cov['campaigns'].items():
        for row in section['matrix']:
            assert row['count']==matrix[campaign,row['operation'],row['confirmation'],row['flush']]
    for key,value in (starts+classes).items():assert cov['counters'][key]==value,(key,value,cov['counters'].get(key))
    print('Test successfully passed: coverage reconstructed from public pre-edge samples; causal timing and held metadata checked',flush=True)
    # Missing coverage is incomplete evidence, not a DUT discrepancy.
    with (root/'coverage-incomplete.log').open('w') as log:
        incomplete=subprocess.run(['python3',str(source/'regress.py'),'--binary',str(binary),'--output',str(root/'incomplete'),'--seeds=1','--cycles=1','--require-matrix'],stdout=log,stderr=subprocess.STDOUT)
    summary=json.loads(next((root/'incomplete').glob('*/summary.json')).read_text())
    assert incomplete.returncode==1 and summary['status']=='incomplete' and not summary['totals']['field_errors']
    (root/'summary.json').write_text(json.dumps(dict(status='passed',config=baseline['config'],results=results,
        confidence_checks=3,configuration_fixtures=[1,2,4,8],replay_sha256=digest(d/'logs/samples.jsonl'),
        reconstructed_coverage_bins=len(starts+classes)+len(matrix),architectural_confirmation_samples=confirmations,architectural_recovery_samples=recoveries),indent=2)+'\n')
    print('Random framework evidence:',root)
    print('Test successfully passed: early_jump random framework',flush=True)
    return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: early_jump random framework',flush=True)
        raise
