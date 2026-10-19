#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Disposable integration mutations, adapted from existing PC/EJU/FM audits."""
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
    p.add_argument('--output',type=Path,default=Path('build/fetch-stage/mutation'))
    p.add_argument('--jobs',type=int,default=2)
    p.add_argument('--only',default='',help='comma-separated mutation names for a focused audit')
    args=p.parse_args()
    if args.jobs<1:p.error('jobs must be positive')
    source=Path(__file__).resolve().parent; binary=args.binary.resolve()
    files={name+'.sv':ROOT/('rtl/frontend/'+name+'.sv') for name in ['fetch_stage','gshare','btb','gen_valid_instr','fetch_mem_if']}
    originals={name:path.read_bytes() for name,path in files.items()}
    config=configuration(); config['fingerprint']=fingerprint(config)
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'FUSESOC_IGNORE').touch()
    root=Path(tempfile.mkdtemp(prefix='audit-',dir=args.output.resolve())); started=time.monotonic()
    def baseline(label):
        d=root/label
        with (root/(label+'.log')).open('w') as log:r=subprocess.run([str(binary),'--scenario=FE-T09','--seed=7','--log_level=LOG_LOW','--run_dir='+str(d)],stdout=log,stderr=subprocess.STDOUT)
        report=json.loads((d/'logs/report.json').read_text())
        return dict(exit_status=r.returncode,checks=report['field_checks'],errors=report['field_errors'],digest=report['stimulus_digest'])
    before=baseline('original-before')
    # All edits are applied to private copies. Count guards prevent accidental edits at changed sites.
    mutations=[
        ('lost-training','09','FE05','fetch_stage.sv','.bu_res_valid_i(bu_bpu_valid_i)',".bu_res_valid_i(1'b0)",1),
        ('wrong-integrated-initial','08','FE05','fetch_stage.sv','.INIT_C2B(INIT_C2B)','.INIT_C2B(fetch_pkg::WNT)',1),
        ('invert-history','13','FE05','gshare.sv','history[HLEN-2:0], res_taken_i','history[HLEN-2:0], ~res_taken_i',1),
        ('wrong-btb-target','18','FE04','btb.sv','res_target_i[XLEN-1:OFFSET];',"res_target_i[XLEN-1:OFFSET] + 1'b1;",1),
        ('take-without-hit','08','FE03','gen_valid_instr.sv','pred_i[i].hit & pred_i[i].taken','pred_i[i].taken',1),
        ('current-predictions','05','FE06','fetch_mem_if.sv','response_metadata.pred_data;','fetch_pred_i;',1),
        ('wrong-eju-ready','25','FE10','fetch_stage.sv','.issue_ready_i      (spill_ready)','.issue_ready_i      (issue_ready_i)',1),
        ('lost-call-confirm','34','FE11','fetch_stage.sv','.call_confirm_i     (bu_call_confirm_i)',".call_confirm_i     (1'b0)",1),
        ('lost-eju-metadata','30','FE12','fetch_stage.sv','.pred_i(early_pred_mixer)','.pred_i(mem_if_pred)',1),
        ('early-flush-drops-current-answer','46','FE14','fetch_stage.sv','.valid_i(issue_valid),','.valid_i(issue_valid && !early_jump_mem_flush_o),',1),
        ('drop-error','07','FM11','fetch_mem_if.sv','ans_reg_in.except_raised = response_result.except_raised;',"ans_reg_in.except_raised = '0;",1),
        ('wrong-fault-pc','07','FM11','fetch_mem_if.sv','issue_pred_o[i]          = ans_reg_out.pred_data[i];',"issue_pred_o[i] = ans_reg_out.pred_data[i]; issue_pred_o[i].pc = ans_reg_out.pred_data[i].pc + 64'd4;",1),
    ]
    exclusions=[dict(mutation='early-flush-clears-output',
        reason='Rejected cyclic mutation: feeding early flush into spill flush creates ready/flush combinational oscillation. Prior disposable execution compiled but aborted without checked discrepancy; not a kill. The noncyclic drop-current-answer mutation tests loss instead.')]
    if config['bundle_instructions']==1:
        mutations=[m for m in mutations if m[0]!='take-without-hit']
        exclusions.append(dict(mutation='take-without-hit',reason='N=1 gen_valid bypasses multi-lane cutoff'))
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
        core=yaml.safe_load((source/'fetch_stage_tb.core').read_text())
        # Resolve existing files once; only the two DUT source files point to private copies.
        core['name']='polito:len5:fetch-stage-mutant:0.1.0'
        # Deliberate disconnections introduce unused-input/coarse-dependency
        # warnings. Mutants still must compile and fail checked public outputs;
        # a warning/build failure is never counted as detection.
        core['targets']['sim']['tools']['verilator']['verilator_options'].append('-Wno-fatal')
        for fileset in core['filesets'].values():
            resolved=[]
            for entry in fileset.get('files',[]):
                name=next(iter(entry)) if isinstance(entry,dict) else entry
                path=(d/Path(name).name) if Path(name).name in originals else (source/name).resolve()
                resolved.append({str(path):entry[name]} if isinstance(entry,dict) else str(path))
            fileset['files']=resolved
        (d/'fetch_stage_mutant.core').write_text('CAPI=2:\n'+yaml.safe_dump({k:v for k,v in core.items() if k!='CAPI=2'},sort_keys=False))
        # Export dependencies into this isolated build: deeply nested relative
        # source names can otherwise resolve through Verilator include paths to
        # a different checkout's package. The elaboration guard caught this at N=2.
        command=[os.environ.get('FUSESOC','fusesoc'),'--cores-root',str(d),'run','--target','sim','--tool','verilator','--build-root',str(d/'model'),'--setup','--build','polito:len5:fetch-stage-mutant','--MEM_DEPTH='+str(config['metadata_depth']),'--BOOT_PC='+str(config['boot_pc'])]
        with (d/'build.log').open('w') as log:built=subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
        result=dict(mutation=label,behavior=f'{old} -> {new}',requirement=req,scenario='FE-T'+scenario,build_status=built.returncode,artifacts=str(d))
        if built.returncode:
            result.update(status='not_executed_build_failed'); print('Test failed: mutation '+label+' did not compile',flush=True); return result
        executable=d/'model/sim-verilator/Vfetch_stage_tb'
        # Preserve normal source/config audit, with mutant provenance recorded separately here.
        write_manifest(executable.parent,config)
        (d/'compiled-variant.json').write_text(json.dumps(dict(production_fingerprint=config['fingerprint'],mutated_file=file,source_sha256=hashlib.sha256((d/file).read_bytes()).hexdigest(),source=str(d/file)),indent=2)+'\n')
        with (d/'console.log').open('w') as log:r=subprocess.run([str(executable),'--scenario=FE-T'+scenario,'--seed=7','--log_level=LOG_LOW','--run_dir='+str(d/'run')],stdout=log,stderr=subprocess.STDOUT)
        report_path=d/'run/logs/report.json'
        if not report_path.exists():
            result.update(status='invalid_execution',exit_status=r.returncode,reason='native execution produced no report; assertion/abort is not a checked mutation kill')
            print('Test failed: mutation '+label+' invalid execution (no report)',flush=True)
            return result
        report=json.loads(report_path.read_text())
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
    print('Test successfully passed: fetch_stage mutations' if passed else 'Test failed: fetch_stage mutations',flush=True)
    return 0 if passed else 1

if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception:
        print('Test failed: fetch_stage mutations',flush=True)
        raise
