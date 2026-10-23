#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Disposable RTL mutation audit adapted from pc_gen/mutate.py; real EJU and RAS."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import time
from configuration import ROOT, configuration, fingerprint, write_manifest, sources


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path('build/early-jump/mutation'))
    p.add_argument('--jobs',type=int,default=2)
    p.add_argument('--only',default='',help='comma-separated mutation names for a focused audit')
    args=p.parse_args()
    if args.jobs<1:p.error('jobs must be positive')
    binary=args.binary.resolve()
    files={name:ROOT/'rtl/frontend'/name for name in ['early_jump_unit.sv','ras.sv']}
    originals={name:path.read_bytes() for name,path in files.items()}
    config=configuration(); config['fingerprint']=fingerprint(config)
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'FUSESOC_IGNORE').touch()
    root=Path(tempfile.mkdtemp(prefix='audit-',dir=args.output.resolve())); started=time.monotonic()
    def baseline(label):
        d=root/label
        with (root/(label+'.log')).open('w') as log:r=subprocess.run([str(binary),'--scenario=all','--seed=7','--log_level=LOG_LOW','--run_dir='+str(d)],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((d/'logs/report.json').read_text())
        return dict(exit_status=r.returncode,checks=report['field_checks'],errors=report['field_errors'],digest=report['stimulus_digest'])
    before=baseline('original-before')
    # All edits are applied to private copies. Count guards prevent accidental edits at changed sites.
    mutations=[
        ('missed-jal','03','EJ01','early_jump_unit.sv','JAL[OPCODE_LEN-1:0]',"7'b0000000",4),
        ('false-positive-call','07','EJ08','early_jump_unit.sv',
         'instr_i[i].j.opcode == JAL[OPCODE_LEN-1:0] && instr_i[i].j.rd == 5\'b00001',
         "instr_i[i].j.rd == 5'b00001",1),
        ('wrong-immediate-sign','04','EJ03','early_jump_unit.sv',
         'instr_i[jump_location].j.imm20,',"1'b0,",1),
        ('wrong-lane-selection','11','EJ02','early_jump_unit.sv',
         'for(int i = LEN5_MULTIPLE_ISSUES-1; i >= 0; i--)','for(int i = 0; i < LEN5_MULTIPLE_ISSUES; i++)',1),
        ('wrong-jal-base','03','EJ03','early_jump_unit.sv',
         'early_jump_base = mem_if_pred_i[jump_location].pc;',"early_jump_base = mem_if_pred_i[jump_location].pc + 64'd4;",1),
        ('predicted-call-not-pushed','14','RA02','early_jump_unit.sv',
         'ras_push = instr_valid_i & issue_ready_i;','ras_push = instr_valid_i & issue_ready_i & target_valid;',1),
        ('push-while-stalled','21','RA04','early_jump_unit.sv',
         'ras_push = instr_valid_i & issue_ready_i;','ras_push = instr_valid_i;',1),
        ('wrong-confirmed-link','16','RA01','ras.sv',
         '= res_link_addr_i;',"= res_link_addr_i + 64'd4;",2),
        ('missing-restoration','19','RA08','ras.sv',
         'ras_valid_q <= ras_valid_confirmed_d;','ras_valid_q <= ras_valid_q;',1),
        ('old-confirmation-restoration','20','RA10','ras.sv',
         'ras_valid_q <= ras_valid_confirmed_d;\n      ras_addr_q  <= ras_addr_confirmed_d;',
         'ras_valid_q <= ras_valid_confirmed_q;\n      ras_addr_q  <= ras_addr_confirmed_q;',1),
        ('wrong-return-target','15','RA03','early_jump_unit.sv',
         'early_jump_offs = ras_addr;',"early_jump_offs = ras_addr + 64'd4;",1),
        ('silent-ordinary-push','07','EJ08','early_jump_unit.sv',
         "default: begin\n        ras_push = 1'b0;\n        ras_pop  = 1'b0;",
         "default: begin\n        ras_push = instr_valid_i & issue_ready_i & (instr_i[0].raw[11:7] == 5'b00001);\n        ras_pop  = 1'b0;",1),
        ('forbidden-x5-push','03','EJ08','early_jump_unit.sv',
         "== 5'b00001", "inside {5'b00001, 5'b00101}",2),
        ('wrong-metadata-target','13','EJ06','early_jump_unit.sv',
         '? early_jump_target_i :','? (early_jump_target_i + 64\'d4) :',1),
    ]
    exclusions=[]
    if config['bundle_instructions']==1:
        mutations=[m for m in mutations if m[0]!='wrong-lane-selection']
        exclusions.append(dict(mutation='wrong-lane-selection',reason='one lane: reverse priority is equivalent'))
        mutations=[(name,scenario,req,file,old.replace('instr_i[i]','instr_i[0]'),new.replace('instr_i[i]','instr_i[0]'),count) for name,scenario,req,file,old,new,count in mutations]
    if args.only:
        selected=set(args.only.split(','))
        if not selected <= {m[0] for m in mutations}: p.error('unknown or configuration-excluded mutation name')
        exclusions += [dict(mutation=m[0],reason='not selected for this focused audit') for m in mutations if m[0] not in selected]
        mutations=[m for m in mutations if m[0] in selected]
    def run(mutation):
        label,scenario,req,file,old,new,count=mutation; d=root/label; d.mkdir()
        for name,data in originals.items():(d/name).write_bytes(data)
        text=originals[file].decode()
        if text.count(old)!=count:raise ValueError(f'{label}: expected {count} sites, found {text.count(old)}')
        (d/file).write_text(text.replace(old,new))
        staging=d/'source'
        for path in sources():
            dest=staging/path.relative_to(ROOT); dest.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,dest)
        for name,path in files.items():(staging/path.relative_to(ROOT)).write_bytes((d/name).read_bytes())
        (staging/'fusesoc.conf').write_text('[library.len5]\nlocation = .\nsync-type = local\n')
        command=[os.environ.get('FUSESOC','fusesoc'),'run','--target','sim','--tool','verilator','--build-root',str(d/'model'),'--setup','--build','polito:len5:early-jump-tb']
        with (d/'build.log').open('w') as log:built=subprocess.run(command,cwd=staging,stdout=log,stderr=subprocess.STDOUT)
        result=dict(mutation=label,behavior=f'{old} -> {new}',requirement=req,scenario='EJ-T'+scenario,build_status=built.returncode,artifacts=str(d))
        if built.returncode:
            result.update(status='not_executed_build_failed'); print('Test failed: mutation '+label+' did not compile',flush=True); return result
        executable=d/'model/sim-verilator/Vearly_jump_tb'
        # Preserve normal source/config audit, with mutant provenance recorded separately here.
        write_manifest(executable.parent,config)
        with (d/'console.log').open('w') as log:r=subprocess.run([str(executable),'--scenario=EJ-T'+scenario,'--seed=7','--log_level=LOG_LOW','--run_dir='+str(d/'run')],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((d/'run/logs/report.json').read_text())
        detected=r.returncode==1 and report['field_checks']>0 and report['field_errors']>0 and not report['environment_errors'] and not report['framework_errors']
        result.update(status='detected' if detected else 'survived' if not r.returncode else 'invalid_execution',exit_status=r.returncode,checks=report['field_checks'],mismatches=report['field_errors'],confirmed=report['confirmed_mismatches'],provisional=report['provisional_mismatches'],first_discrepancy=next(iter(report['discrepancies']),None),detected_requirements=sorted({x.get('requirement','') for x in report['discrepancies']}))
        print(('Test successfully passed' if detected else 'Test failed')+': mutation '+label+' '+result['status']+f' checks={report["field_checks"]} confirmed={report["confirmed_mismatches"]} provisional={report["provisional_mismatches"]}',flush=True)
        return result
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:results=list(pool.map(run,mutations))
    assert all(files[name].read_bytes()==data for name,data in originals.items()),'production DUT source changed'
    after=baseline('original-after'); passed=before==after and after['exit_status']==0 and all(r['status']=='detected' for r in results)
    summary=dict(status='passed' if passed else 'failed',config=config,seconds=time.monotonic()-started,mutations=results,
        compiled=sum(r['build_status']==0 for r in results),detected=sum(r['status']=='detected' for r in results),
        surviving=[r['mutation'] for r in results if r['status']=='survived'],exclusions=exclusions,
        original_before=before,original_after=after,baseline_identical=before==after,
        production_rtl_unchanged=True,source_sha256={name:hashlib.sha256(data).hexdigest() for name,data in originals.items()})
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print('Mutation evidence:',root/'summary.json')
    print('Test successfully passed: early_jump mutations' if passed else 'Test failed: early_jump mutations',flush=True)
    return 0 if passed else 1

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: early_jump mutations',flush=True)
        raise
