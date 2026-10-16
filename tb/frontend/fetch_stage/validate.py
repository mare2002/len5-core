#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Pure units, native confidence, public journal audit and deterministic replay.

Adapted from fetch_mem_if/validate.py and validate_random.py. The journal audit
uses public inputs/outputs and the immutable image, never native expected values.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import configuration as cfg

def native(binary,root,label,flags=(),expected=0):
    d=root/label;d.mkdir()
    command=[str(binary),'--scenario=FE-T18','--log_level=LOG_LOW','--run_dir='+str(d),*flags]
    with (d/'console.log').open('w') as f:r=subprocess.run(command,stdout=f,stderr=subprocess.STDOUT)
    p=d/'logs/report.json';report=json.loads(p.read_text()) if p.exists() else {}
    ok=r.returncode==expected and (expected==2 or report.get('exit_status')==expected)
    if expected==0:ok=ok and report.get('field_checks',0)>0 and report.get('updates',0)>0
    if not ok:raise AssertionError('%s: expected exit%d, got%d; %s'%(label,expected,r.returncode,d))
    print('PASS: %s expected_exit=%d comparisons=%d errors=%d'%(label,expected,report.get('field_checks',0),report.get('field_errors',0)),flush=True)
    return dict(label=label,exit=r.returncode,report=report,artifacts=str(d))

def units(root):
    includes=[cfg.HERE,cfg.HERE.parent/'pc_gen',cfg.HERE.parent/'early_jump_unit',cfg.HERE.parent/'fetch_mem_if']
    sources=[cfg.HERE/(n+'.cpp') for n in ['fetch_stage_components','fetch_stage_program','fetch_stage_composition','fetch_stage_unit']]
    sources += [cfg.HERE.parent/(n+'.cpp') for n in ['pc_gen/pc_gen_model','early_jump_unit/early_jump_instructions','early_jump_unit/early_jump_model','fetch_mem_if/fetch_mem_model']]
    command=['/usr/bin/g++','-std=c++17','-O2','-Wall','-Wextra','-Werror',*['-I'+str(p) for p in includes],*map(str,sources),'-o',str(root/'unit')]
    subprocess.run(command,check=True)
    r=subprocess.run([str(root/'unit')],capture_output=True,text=True)
    (root/'unit.log').write_text(r.stdout+r.stderr);print(r.stdout,end='')
    if r.returncode:raise AssertionError('independent units failed: '+r.stderr)
    inherited={
        'pc-gen':['pc_gen/pc_gen_model','pc_gen/pc_gen_environment','pc_gen/pc_gen_unit'],
        'early-jump':['pc_gen/pc_gen_model','early_jump_unit/early_jump_instructions','early_jump_unit/early_jump_model','early_jump_unit/early_jump_environment','early_jump_unit/early_jump_unit'],
        'fetch-mem':['pc_gen/pc_gen_model','early_jump_unit/early_jump_instructions','fetch_mem_if/fetch_mem_model','fetch_mem_if/fetch_mem_environment','fetch_mem_if/fetch_mem_unit']}
    for label,names in inherited.items():
        command=['/usr/bin/g++','-std=c++17','-O2','-Wall','-Wextra','-Werror',*['-I'+str(p) for p in includes],*[str(cfg.HERE.parent/(n+'.cpp')) for n in names],'-o',str(root/('unit-'+label))]
        subprocess.run(command,check=True)
        r=subprocess.run([str(root/('unit-'+label))],capture_output=True,text=True)
        (root/('unit-'+label+'.log')).write_text(r.stdout+r.stderr);print(r.stdout,end='',flush=True)
        if r.returncode:raise AssertionError('inherited pure model units failed: '+label+' '+r.stderr)

def signed(x,bits):return x-(1<<bits) if x&(1<<(bits-1)) else x
MASK=(1<<64)-1
def semantics(w,pc,regs):
    op=w&127;rd=(w>>7)&31;a=regs[(w>>15)&31];b=regs[(w>>20)&31];f=(w>>12)&7
    value=None;taken=False;target=0
    if op==0x13:
        imm=signed(w>>20,12)&MASK
        if f==0:value=a+imm
        elif f==7:value=a&imm
        elif f==6:value=a|imm
        elif f==4:value=a^imm
        else:raise AssertionError('journal semantic subset: unsupported immediate')
    elif op in (0x17,0x37):value=signed(w&0xfffff000,32)+(pc if op==0x17 else 0)
    elif op==0x6f:
        imm=((w>>31)<<20)|(((w>>12)&255)<<12)|(((w>>20)&1)<<11)|(((w>>21)&1023)<<1)
        target=(pc+signed(imm,21))&MASK;taken=True;value=pc+4
    elif op==0x67:target=(a+signed(w>>20,12))&MASK&~1;taken=True;value=pc+4
    elif op==0x63:
        imm=((w>>31)<<12)|(((w>>7)&1)<<11)|(((w>>25)&63)<<5)|(((w>>8)&15)<<1)
        target=(pc+signed(imm,13))&MASK
        taken={0:a==b,1:a!=b,4:signed(a,64)<signed(b,64),5:signed(a,64)>=signed(b,64),6:a<b,7:a>=b}[f]
    else:raise AssertionError('journal unsupported instruction')
    return rd,None if value is None else value&MASK,op in (0x63,0x67,0x6f),taken,target

def reconstruct(directory,n):
    """Check physical association + immutable tuples + independent feedback semantics.

    Internal A/spill occupancy and overwritten raw BPU metadata are intentionally
    not reconstructed as observations. Native IDs/expected fields are ignored.
    """
    images={}
    fault_maps={}
    for p in directory.glob('program-*.json'):
        image=json.loads(p.read_text());images[image.get('scenario','FE-T18')]={int(pc,16):w for pc,w in image['words']};fault_maps[image.get('scenario','FE-T18')]={int(pc,16):cause for pc,cause in image['faults']}
    records={};next_id=0;pending=[];sampled=None;count=0;updates=set();confirmations=set();reset=True
    for line in (directory/'logs/samples.jsonl').open():
        s=json.loads(line)
        if s['phase']=='pre':sampled=s;continue
        if s['phase']!='post' or sampled is None:continue
        s=sampled;sampled=None;i=s['inputs'];a=s['actual'];cycle=s['cycle']
        if i['reset']:
            pending.clear();records.clear();next_id=0;updates.clear();confirmations.clear();reset=True;continue
        if reset:reset=False
        image=images[s['scenario']];faults=fault_maps[s['scenario']]
        flush=i['flush'] or a['early_flush']
        if i['response_valid'] and a['response_ready']:
            assert pending,'orphan response'
            address,accepted=pending.pop(0);assert cycle>accepted,'non-positive latency'
            for k,w in enumerate(i['words']):assert w==image.get(address+4*k,0x13),'wrong response-to-request words'
            count+=n
        if i['train'] or i['call'] or i['ret']:
            ident=i['feedback_id'];assert ident in records,'feedback lacks public dispatched source'
            r=records[ident];assert not r['canceled'],'squashed feedback'
            assert int(i['res_pc'],16)==r['pc'] and int(i['res_target'],16)==r['target'] and bool(i['res_taken'])==r['taken'],'feedback semantic disagreement'
            assert bool(i['res_mispredict'])==r['wrong'],'wrong misprediction decision'
            if i['train']:assert ident not in updates,'duplicate update';updates.add(ident)
            if i['call'] or i['ret']:assert ident not in confirmations,'duplicate confirmation';confirmations.add(ident)
            count+=5
        if i['flush']:
            source=i['feedback_id']
            for ident,r in records.items():
                if ident>source:r['canceled']=True
        if a['valid'] and i['ready'] and not i['flush']:
            for k,l in enumerate(a['bundle']['lanes']):
                if not(a['bundle']['mask']>>k)&1:continue
                pc=int(l['pc'],16);assert l['word']==image.get(pc,0x13),'word/PC mixer misalignment'
                assert bool(l['error'])==(pc in faults),'fault/PC mixer misalignment'
                if l['error']:assert l['cause']==faults[pc],'wrong fault cause'
                regs=[0]*32
                for r in records.values():
                    if not r['canceled'] and r['rd'] and r['value'] is not None:regs[r['rd']]=r['value']
                rd,value,control,taken,target=semantics(l['word'],pc,regs)
                next_id+=1;pred=l['hit'] and l['taken'];wrong=control and (pred!=taken or pred and int(l['target'],16)!=target)
                records[next_id]=dict(pc=pc,rd=rd,value=value,control=control,taken=taken,target=target,wrong=wrong,canceled=False)
                count+=2
        if flush:pending.clear()
        if a['request'] and i['grant']:
            assert not flush,'grant on active cancel edge';assert len(pending)<2,'physical overcapacity'
            pending.append((int(a['address'],16),cycle));count+=1
    return dict(public_checks=count,updates=len(updates),scope='physical ordered words, immutable output tuples, independent integer feedback; internal A/raw rewritten BPU not observed')

def audit_obligations(directory,report):
    memory=[];backend=[];learning=[]
    for path in directory.glob('logs/obligations-*.json'):
        o=json.loads(path.read_text());memory+=o['memory'];backend+=o['backend'];learning+=o['training']
        assert not o['memory_totals']['pending'],'unclosed memory obligation'
        assert len(o['memory'])==o['memory_totals']['accepted'],'missing per-request obligation'
    assert len(memory)==report['requests'],'accepted request ledger count'
    assert sum(m['status']=='delivered' for m in memory)==report['delivered'],'delivery ledger count'
    assert sum(m['status']=='canceled' for m in memory)==report['canceled'],'cancellation ledger count'
    assert len({(m['window'],m['id']) for m in memory})==len(memory),'duplicate memory identity'
    for m in memory:
        stages=[m[k] for k in ('accepted','response','transfer','delivery') if m[k] is not None]
        assert all(a<b for a,b in zip(stages,stages[1:])),'non-positive registered transport timing'
        if m['status']=='delivered':assert m['delivery'] is not None and not m['cancellation'],'canceled delivery'
        else:assert m['status']=='canceled' and m['cancellation'],'unjustified missing delivery'
    assert len(backend)==report['dynamic_instructions'],'missing dynamic instruction obligation'
    assert len({(b['window'],b['id']) for b in backend})==len(backend),'duplicate dynamic ID'
    assert sum(b['status']=='retired' for b in backend)==report['retired'],'retirement ledger count'
    assert sum(b['status'].startswith('canceled-') for b in backend)==report['backend_canceled'],'backend cancellation ledger count'
    assert sum(b['trained'] for b in backend)==report['updates'],'duplicate/missing training obligation'
    assert sum(b['confirmed'] for b in backend)==report['confirmations'],'duplicate/missing confirmation obligation'
    assert len(learning)==report['updates'],'missing training obligation across reset windows'
    assert len({(g.get('window',0),g['id'],g['update_cycle']) for g in learning})==len(learning),'duplicate training identity'
    return dict(requests=len(memory),dynamic=len(backend),learning=len(learning),pending=0)

def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--output',type=Path,default=cfg.ROOT/'build/fetch-stage/validation');p.add_argument('--random',action='store_true');a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);root=Path(tempfile.mkdtemp(prefix='random-' if a.random else 'framework-',dir=a.output));binary=a.binary.resolve();runs=[]
    if not a.random:units(root)
    flags=['--random','--cycles=4096','--journal=full'] if a.random else ['--journal=full']
    runs.append(native(binary,root,'baseline',flags))
    runs.append(native(binary,root,'replay',flags))
    runs.append(native(binary,root,'waves',[*flags,'--dump_waves=true']))
    journals=[(Path(r['artifacts'])/'logs/samples.jsonl').read_bytes() for r in runs]
    assert journals[0]==journals[1]==journals[2],'deterministic replay changed public sequence'
    audits=[reconstruct(Path(r['artifacts']),r['report']['config']['LEN5_MULTIPLE_ISSUES']) for r in runs]
    obligations=[audit_obligations(Path(r['artifacts']),r['report']) for r in runs]
    for fault in (['word','request'] if a.random else ['request','valid','early','word','pc','target','error','mask']):
        runs.append(native(binary,root,'injected-'+fault,[*flags,'--inject_failure='+fault],1))
    if not a.random:runs.append(native(binary,root,'injected-cause',['--scenario=FE-T07','--journal=full','--inject_failure=cause'],1))
    if not a.random:
        runs.append(native(binary,root,'EQ07-previous',['--scenario=FE-T41','--ras_order=previous'],1))
        runs.append(native(binary,root,'EQ07-unknown',['--scenario=FE-T41','--ras_order=unknown'],3))
    runs.append(native(binary,root,'invalid-environment',['--inject_failure=environment'],2))
    runs.append(native(binary,root,'framework-failure',['--inject_failure=framework'],2))
    runs.append(native(binary,root,'incomplete',['--random','--cycles=1'],3))
    runs.append(native(binary,root,'wrong-width',['--expect_issues=99'],2))
    if not a.random:
        for label,flag in [('bad-campaign','--campaign=invalid'),('bad-bool','--guided=invalid'),('bad-weight','--weights=grant=1junk'),('bad-latency','--exec_latency_min=0')]:
            runs.append(native(binary,root,label,[flag],2))
    runs.append(native(binary,root,'wrong-fingerprint',['--expect_fingerprint=invalid'],2))
    if not a.random:
        stale=root/'stale-model';stale.mkdir()
        shutil.copy2(binary,stale/binary.name)
        for path in binary.parent.glob('fetch_stage_*.snapshot'):shutil.copy2(path,stale/path.name)
        shutil.copy2(binary.parent/'fetch_stage_build.cfg',stale/'fetch_stage_build.cfg')
        snapshot=next(stale.glob('fetch_stage_*.snapshot'));snapshot.write_bytes(snapshot.read_bytes()+b'changed')
        runs.append(native(stale/binary.name,root,'stale-source',expected=2))
        runs.append(native(binary,root,'agnostic-incomplete',['--profile=predictor-agnostic'],3))
    replay_fault=native(binary,root,'injected-replay',[*flags,'--inject_failure=request'],1)
    original_fault=next(r for r in runs if r['label']=='injected-request')
    assert replay_fault['report']['discrepancies'][0]==original_fault['report']['discrepancies'][0], 'first injected failure not reproducible'
    runs.append(replay_fault)
    if a.random:
        for seed in (2,7,19):runs.append(native(binary,root,'seed-'+str(seed),[*flags,'--seed='+str(seed)]))
    summary=dict(status='passed',runs=runs,public_audits=audits,obligation_audits=obligations,replay_sha256=hashlib.sha256(journals[0]).hexdigest(),full_contract_signoff=False)
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Test successfully passed: frontend framework; evidence:',root)
    return 0
if __name__=='__main__':raise SystemExit(main())
