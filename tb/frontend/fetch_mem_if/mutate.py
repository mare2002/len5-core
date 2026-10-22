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
import tempfile
import time
import yaml
from configuration import ROOT, configuration, fingerprint, write_manifest


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path('build/fetch-mem-if/mutation'))
    p.add_argument('--jobs',type=int,default=2)
    p.add_argument('--only',default='',help='comma-separated mutation names for a focused audit')
    args=p.parse_args()
    if args.jobs<1:p.error('jobs must be positive')
    source=Path(__file__).resolve().parent; binary=args.binary.resolve()
    files={'fetch_mem_if.sv':ROOT/'rtl/frontend/fetch_mem_if.sv','spill_cell_flush_cu.sv':ROOT/'rtl/common/spill_cell_flush_cu.sv','completion_fifo.sv':ROOT/'rtl/common/completion_fifo.sv'}
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
        ('current-predictions','14','FM05','fetch_mem_if.sv','response_metadata.pred_data;','fetch_pred_i;',1),
        ('current-mask','14','FM05','fetch_mem_if.sv','response_metadata.valid_instr;','valid_instr_i;',1),
        ('pop-on-offer','11','FM08','completion_fifo.sv','valid_o && ready_i;','valid_o && (ready_i || result_valid_i);',1),
        ('drop-error','15','FM11','fetch_mem_if.sv','ans_reg_in.except_raised = response_result.except_raised;',"ans_reg_in.except_raised = '0;",1),
        ('wrong-cause-zero','16','FM11','fetch_mem_if.sv','ans_reg_in.except_code = response_result.except_code;',"ans_reg_in.except_code = {LEN5_MULTIPLE_ISSUES{len5_pkg::E_UNKNOWN}};",1),
        ('delayed-error','18','FM12','fetch_mem_if.sv','assign ans_reg_in.except_raised = response_result.except_raised;',
         "logic [LEN5_MULTIPLE_ISSUES-1:0] delayed_errors; always_ff @(posedge clk_i or negedge rst_ni) if (!rst_ni) delayed_errors <= '0; else delayed_errors <= instr_except_raised_i; assign ans_reg_in.except_raised = delayed_errors;",1),
        ('wrong-saved-fault-pc','15','FM05','fetch_mem_if.sv','issue_pred_o[i]          = ans_reg_out.pred_data[i];',"issue_pred_o[i]          = ans_reg_out.pred_data[i]; issue_pred_o[i].pc = ans_reg_out.pred_data[i].pc + 64'd4;",1),
        ('lane-word-swap','03','FM06','fetch_mem_if.sv','issue_instr_o[i].raw     = ans_reg_out.instr[i];','issue_instr_o[i].raw     = ans_reg_out.instr[(i+1)%LEN5_MULTIPLE_ISSUES];',1),
        ('lost-error-response','15','FM07','fetch_mem_if.sv','.result_valid_i(instr_valid_i),','.result_valid_i(instr_valid_i && !instr_except_raised_i[0]),',1),
        ('missing-answer-flush','26','FM14','fetch_mem_if.sv','.flush_i,\n      .valid_i(response_valid)',".flush_i(1'b0),\n      .valid_i(response_valid)",1),
        ('missing-metadata-flush','25','FM14','completion_fifo.sv','.clr_i  (clear_pointers),\n    .en_i   (allocate_entry),', ".clr_i  (1'b0),\n    .en_i   (allocate_entry),",1),
        ('ready-on-flush','25','FM09','completion_fifo.sv','active && (pending_result || allocate_i);','rst_ni && (pending_result || allocate_i);',1),
        ('ready-on-full','11','FM09','spill_cell_flush_cu.sv',"ready_o = 1'b0;  // do not accept new data","ready_o = 1'b1;  // deliberately admit while full",2),
        ('duplicate-answer','03','FM07','spill_cell_flush_cu.sv','else if (!valid_i && ready_i) next_state = NO_DATA;','else if (!valid_i && ready_i) next_state = curr_state;',2),
        ('wrong-request-address','05','FM02','fetch_mem_if.sv','request_metadata.pred_data[0].pc;',"request_metadata.pred_data[0].pc + 64'd4;",1),
        ('instruction-write','03','FM01','fetch_mem_if.sv',"instr_we_o   = 1'b0;","instr_we_o   = 1'b1;",1),
    ]
    exclusions=[]
    if config['bundle_instructions']==1:
        mutations=[m for m in mutations if m[0]!='lane-word-swap']
        exclusions.append(dict(mutation='lane-word-swap',reason='one lane: permutation is equivalent'))
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
        core=yaml.safe_load((source/'fetch_mem_tb.core').read_text())
        # Resolve existing files once; only the two DUT source files point to private copies.
        core['name']='polito:len5:fetch-mem-if-mutant:0.1.0'
        for fileset in core['filesets'].values():
            resolved=[]
            for entry in fileset.get('files',[]):
                name=next(iter(entry)) if isinstance(entry,dict) else entry
                path=(d/Path(name).name) if Path(name).name in originals else (source/name).resolve()
                resolved.append({str(path):entry[name]} if isinstance(entry,dict) else str(path))
            fileset['files']=resolved
        (d/'fetch_mem_mutant.core').write_text('CAPI=2:\n'+yaml.safe_dump({k:v for k,v in core.items() if k!='CAPI=2'},sort_keys=False))
        # Export dependencies into this isolated build: deeply nested relative
        # source names can otherwise resolve through Verilator include paths to
        # a different checkout's package. The elaboration guard caught this at N=2.
        command=[os.environ.get('FUSESOC','fusesoc'),'--cores-root',str(d),'run','--target','sim','--tool','verilator','--build-root',str(d/'model'),'--setup','--build','polito:len5:fetch-mem-if-mutant','--MEM_DEPTH='+str(config['metadata_depth'])]
        with (d/'build.log').open('w') as log:built=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        result=dict(mutation=label,behavior=f'{old} -> {new}',requirement=req,scenario='FM-T'+scenario,build_status=built.returncode,artifacts=str(d))
        if built.returncode:
            result.update(status='not_executed_build_failed'); print('Test failed: mutation '+label+' did not compile',flush=True); return result
        executable=d/'model/sim-verilator/Vfetch_mem_tb'
        # Preserve normal source/config audit, with mutant provenance recorded separately here.
        write_manifest(executable.parent,config)
        (d/'compiled-variant.json').write_text(json.dumps(dict(production_fingerprint=config['fingerprint'],mutated_file=file,source_sha256=hashlib.sha256((d/file).read_bytes()).hexdigest(),source=str(d/file)),indent=2)+'\n')
        with (d/'console.log').open('w') as log:r=subprocess.run([str(executable),'--scenario=FM-T'+scenario,'--seed=7','--log_level=LOG_LOW','--run_dir='+str(d/'run')],stdout=log,stderr=subprocess.STDOUT)
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
    print('Test successfully passed: fetch_mem mutations' if passed else 'Test failed: fetch_mem mutations',flush=True)
    return 0 if passed else 1

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: fetch_mem mutations',flush=True)
        raise
