#!/usr/bin/env python3
"""Actual LEN5+Spike integration tests; nonzero status is required for injected faults."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[2]
p=argparse.ArgumentParser()
p.add_argument('--simulator',type=Path,required=True)
p.add_argument('--output',type=Path,required=True)
p.add_argument('--riscv-prefix',default='riscv64-unknown-elf')
a=p.parse_args();a.simulator=a.simulator.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)


def verify_waveform(directory, report, require_result=True):
    wave=directory/'logs/diff/annotated.fst'
    # Use the independent GTKWave converter to check the entire FST, including RTL aliases.
    vcd=directory/'annotated.vcd'
    with vcd.open('w') as stream:
        subprocess.run(['fst2vcd',str(wave)],stdout=stream,check=True)
    scopes=[];signals={};values={};time=0;observed=[]
    failures=[x for x in report['discrepancies'] if x['confirmed']]
    first=min(failures,key=lambda x:x['event_time']) if failures else None
    relevant={}
    def snapshot():
        if not first or time!=first['event_time']:
            return
        for scope in relevant:
            state={field:values.get(code) for field,code in relevant[scope].items()}
            if state.get('event_valid')==1 and state.get('mismatch')==1:
                observed.append(state)
    with vcd.open() as stream:
        for line in stream:
            parts=line.split()
            if not parts:
                continue
            if parts[0]=='$scope':scopes.append(parts[2])
            elif parts[0]=='$upscope':scopes.pop()
            elif parts[0]=='$var':
                path='.'.join(scopes+[parts[4]])
                signals[path]=parts[3]
                if path.startswith('verification.') and '.lane' in path:
                    relevant.setdefault('.'.join(scopes),{})[parts[4]]=parts[3]
            elif line[0]=='#':snapshot();time=int(line[1:])
            elif line[0]=='b' and len(parts)==2:
                if not any(x in parts[0] for x in 'xz'):values[parts[1]]=int(parts[0][1:],2)
            elif line[0] in '01':values[line.strip()[1:]]=int(line[0])
    snapshot()
    assert any(x.startswith('TOP.tb_bare.') for x in signals),'original RTL missing'
    if require_result:
        assert any(x.endswith('.expected_result') for x in signals),'expected results missing'
        assert any(x.endswith('.actual_result') for x in signals),'actual results missing'
    assert 'verification.overall.verification_failed' in signals
    if first:
        assert any(v.get('instruction_id')==first['instruction_id'] and v.get('expected_value')==first['expected'] and v.get('actual_value')==first['actual'] for v in observed),'failure values absent at original event timestamp'
        save=(directory/'logs/diff/annotated.gtkw').read_text()
        marker=re.search(r'^\*[^ ]+ (-?\d+)',save,re.M)
        assert marker and int(marker[1])==first['event_time'],'GTKWave marker timestamp'
        assert values[signals['verification.overall.verification_failed']]==1
    else:
        assert values[signals['verification.overall.verification_failed']]==0
    vcd.unlink()  # Converter output is disposable; keep FSTs, journals and JSON reports.


for program in ('smoke','memory_branch','csr','branch_pc4','unsupported','unsupported_smc',
                'unsupported_trap','unsupported_mmio','csr_register_bug'):
    image=a.output/(program+'.hex');elf=a.output/(program+'.elf')
    subprocess.run([a.riscv_prefix+'-gcc','-march=rv64im_zicsr','-mabi=lp64','-nostdlib','-nostartfiles','-Wl,-Ttext=0x10180','-Wl,--no-relax',str(ROOT/'tests/diff'/(program+'.S')),'-o',str(elf)],check=True)
    subprocess.run([a.riscv_prefix+'-objcopy','-O','verilog',str(elf),str(image)],check=True)
    faults=['','operand','cdb','register','store'] if program=='smoke' else ['']
    for fault in faults:
        label=program+('-fault-'+fault if fault else '')
        directory=a.output/label;directory.mkdir(exist_ok=True)
        command=[str(a.simulator),'--diff','--max_cycles','20000','--log_level','LOG_LOW','+firmware='+str(image)]
        if fault:command+=['--diff-fault',fault]
        with (directory/'run.log').open('w') as log:
            result=subprocess.run(command,cwd=directory,stdout=log,stderr=subprocess.STDOUT)
        expected=2 if program.startswith('unsupported') else 1 if fault or program=='csr_register_bug' else 0
        assert result.returncode==expected,(label,result.returncode,expected,str(directory/'run.log'))
        report=json.loads((directory/'logs/diff/report.json').read_text())
        assert report['status']==('unsupported' if expected==2 else 'failed' if expected==1 else 'passed'),report
        if expected==0:
            assert not report['discrepancies'],'correct fixture produced a mismatch flag'
        if program=='memory_branch':
            assert report['out_of_order_commits']>0 and report['frontend_recoveries']>0
            assert report['squashed']>0
        if program=='branch_pc4':
            assert report['frontend_recoveries']>0
        if fault:
            fields={'operand':'rs1_value','cdb':'result','register':'result','store':'unauthorized_store'}
            failures=[d for d in report['discrepancies'] if d['confirmed']]
            assert failures and failures[0]['field']==fields[fault]
            if fault in ('operand','cdb'):
                assert failures[0]['instruction_id']==1 and failures[0]['confirmation_time']>failures[0]['event_time']
        if program=='csr_register_bug':
            failures=[d for d in report['discrepancies'] if d['confirmed']]
            assert failures[0]['pc']==0x10184 and failures[0]['field']=='rs1_value'
            assert failures[0]['expected']==256 and failures[0]['actual']==0
        if expected==2:
            reasons={'unsupported':'CSR','unsupported_smc':'self-modifying',
                     'unsupported_trap':'trap','unsupported_mmio':'MMIO reads'}
            assert reasons[program] in report['reason'],report
        verify_waveform(directory,report,require_result=expected!=2)
        print('PASS',label,'commits=',report['committed'],flush=True)
print('All actual LEN5/Spike differential integration tests passed.')
