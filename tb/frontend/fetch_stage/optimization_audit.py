#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Compare simulator optimizations using identical saved public stimuli only."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import yaml

REPLAY_CPP=r'''// Public-port-only standalone reproducer: no oracle, backend, or feedback calculation.
#include "Vfetch_stage_tb.h"
#include <verilated.h>
#include <fstream>
#include <iostream>
#include <cstdint>
int main(int argc,char** argv) {
    if(argc<2)return 2;
    VerilatedContext context; context.randSeed(1);
    Vfetch_stage_tb d(&context);
    std::ifstream f(argv[1]);uint64_t v[128],row=0;
    while(f>>v[0]) {
        unsigned n=unsigned(v[0]);for(unsigned k=1;k<25+3*n;k++)if(!(f>>v[k]))return 2;
        unsigned phase=unsigned(v[1]);
        if(phase==0 || phase==1) {
            d.clk_i=0; d.rst_ni=v[2];d.flush_i=v[3];d.flush_bpu_i=v[4];d.instr_ready_i=v[5];
            d.instr_valid_i=v[6];d.issue_ready_i=v[7];d.bu_bpu_valid_i=v[8];d.bu_pcgen_valid_i=v[9];
            d.bu_call_confirm_i=v[10];d.bu_ret_confirm_i=v[11];d.res_pc_i=v[12];d.res_target_i=v[13];
            d.res_taken_i=v[14];d.res_mispredict_i=v[15];d.bu_link_addr_i=v[16];
            d.comm_except_raised_i=v[17];d.comm_except_pc_i=v[18];d.instr_except_raised_i=v[19];
            for(unsigned k=0;k<n;k++){d.instr_words_i[k]=v[25+3*k];d.instr_causes_i[k]=v[26+3*k];}
        } else d.clk_i=phase==2;
        context.timeInc(1);d.eval();
        if(argc>2)for(unsigned k=0;k<4;k++)d.eval(); // settling-control experiment
        std::cout<<row++<<' '<<unsigned(d.instr_valid_o)<<' '<<d.instr_addr_o<<' '<<unsigned(d.instr_ready_o)
          <<' '<<unsigned(d.issue_valid_o)<<' '<<unsigned(d.early_jump_mem_flush_o)<<' '<<unsigned(d.issue_valid_instr_o);
        for(unsigned k=0;k<n;k++) std::cout<<' '<<d.issue_words_o[k]<<' '<<d.issue_pc_o[k]<<' '<<d.issue_target_o[k]
          <<' '<<unsigned((d.issue_hit_o>>k)&1)<<' '<<unsigned((d.issue_taken_o>>k)&1)
          <<' '<<unsigned((d.issue_except_raised_o>>k)&1)<<' '<<unsigned(d.issue_causes_o[k]);
        std::cout<<'\n';
    }
    d.final();return 0;
}
'''
def inputs(journal,path):
    records=[json.loads(s) for s in journal.read_text().splitlines()]
    with path.open('w') as f:
        for s in records:
            i=s['inputs'];n=len(i['words']);phase={'async':0,'pre':1,'post':2,'falling':3}[s['phase']]
            v=[n,phase,not i['reset'],i['flush'],i['flush_bpu'],i['grant'],i['response_valid'],i['ready'],i['train'],i['redirect'],i['call'],i['ret'],int(i['res_pc'],16),int(i['res_target'],16),i['res_taken'],i['res_mispredict'],int(i['link'],16),i['commit'],int(i['commit_pc'],16),i['errors'],0,0,0,0,0]
            for w,c in zip(i['words'],i['causes']):v += [w,c,0]
            f.write(' '.join(str(int(x)) for x in v)+'\n')
    return records

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source',type=Path,required=True);p.add_argument('--journal',type=Path,required=True);p.add_argument('--output',type=Path,required=True);p.add_argument('--resume',type=Path);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);(a.output/'FUSESOC_IGNORE').touch()
    root=a.resume.resolve() if a.resume else Path(tempfile.mkdtemp(prefix='dfg-',dir=a.output.resolve()));print('Optimization evidence:',root,flush=True)
    stimulus=root/'public-inputs.txt';records=inputs(a.journal,stimulus);results={}
    for policy in ('default','O0','no-dfg'):
        source=root/policy/'source'
        if not source.exists():shutil.copytree(a.source,source,ignore=shutil.ignore_patterns('__pycache__'))
        here=source/'tb/frontend/fetch_stage';(here/'reproduce_dfg.cpp').write_text(REPLAY_CPP)
        core=here/'fetch_stage_tb.core';data=yaml.safe_load(core.read_text().split('\n',1)[1]);
        data['filesets']['harness']={'files':['reproduce_dfg.cpp'],'file_type':'cppSource'}
        options=data['targets']['sim']['tools']['verilator']['verilator_options'];options[:]=[x for x in options if x not in ('-fno-dfg','-O0')]
        if '-Wno-UNOPTFLAT' not in options:options.append('-Wno-UNOPTFLAT') # identical diagnostic-only waiver for O0's coarse graph
        if policy!='default':options.append('-O0' if policy=='O0' else '-fno-dfg')
        core.write_text('CAPI=2:\n'+yaml.safe_dump(data,sort_keys=False))
        build=root/policy/'model';command=['fusesoc','run','--target','sim','--tool','verilator','--build-root',str(build),'--setup','--build','polito:len5:fetch-stage-tb']
        if not (build/'sim-verilator/Vfetch_stage_tb').exists():
            with (root/(policy+'-build.log')).open('w') as f:r=subprocess.run(command,cwd=source,stdout=f,stderr=subprocess.STDOUT)
            if r.returncode:raise RuntimeError('build failed '+policy)
        binary=build/'sim-verilator/Vfetch_stage_tb'
        for settle in (False,True):
            name=policy+('-extra-eval' if settle else '');out=root/(name+'.txt')
            with out.open('w') as f:subprocess.run([str(binary),str(stimulus),*(['settle'] if settle else [])],check=True,stdout=f)
            results[name]=out.read_text().splitlines()
    def compare(left,right):
        for k,(l,r) in enumerate(zip(results[left],results[right])):
            s=records[k];lv=list(map(int,l.split()));rv=list(map(int,r.split()));meaningful={1,2,3,4,5}
            if rv[4] and not s['inputs']['flush']:
                meaningful.add(6)
                for lane in range((len(rv)-7)//7):
                    if (rv[6]>>lane)&1:
                        at=7+7*lane;meaningful.update([at+1,at+3,at+4,at+5])
                        if not rv[at+5]:meaningful.add(at)
                        if rv[at+3]:meaningful.add(at+2)
                        if rv[at+5]:meaningful.add(at+6)
            cols=[j for j in sorted(meaningful) if lv[j]!=rv[j]]
            if cols:
                return {'row':k,'cycle':s['cycle'],'phase':s['phase'],'columns':cols,'left':l,'right':r,'public_sample':s}
        return None
    summary={'source':str(a.source),'journal':str(a.journal),'samples':len(records),
             'default_vs_no_dfg':compare('default','no-dfg'),'O0_vs_no_dfg':compare('O0','no-dfg'),
             'extra_eval':{p:compare(p,p+'-extra-eval') for p in ('default','O0','no-dfg')}}
    (root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps({k:v for k,v in summary.items() if k!='default_vs_no_dfg'},indent=2));print('Summary:',root/'summary.json')
    if summary['default_vs_no_dfg']:print('First divergence:',summary['default_vs_no_dfg']['cycle'],summary['default_vs_no_dfg']['phase'],summary['default_vs_no_dfg']['columns'])
    return 0
if __name__=='__main__':raise SystemExit(main())
