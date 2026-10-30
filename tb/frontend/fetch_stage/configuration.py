#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Reuse elaborated SV metadata; fingerprint the complete actual frontend."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
spec=importlib.util.spec_from_file_location('len5_pc_configuration',HERE.parent/'pc_gen/configuration.py')
pc=importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)

def configuration():
    selected=pc.rtl_configuration()
    architecture=pc.config_tools.elaborated_configuration('architecture')
    boot=int(os.environ.get('BOOT_PC', '0'),0)
    c=pc.configuration(boot)
    c.update(hlen=selected['BPU_HLEN'],btb_bits=selected['BPU_BTB_BITS'],ras_depth=selected['RAS_DEPTH'],
             metadata_depth=int(os.environ.get('MEM_DEPTH', '2'),0),request_skip=selected['FETCH_REQ_SPILL_SKIP'],answer_skip=selected['FETCH_ANS_SPILL_SKIP'],
             cause_bits=architecture['EXCEPT_TYPE_LEN'],iq=selected['IQ_DEPTH'],rob=selected['ROB_DEPTH'],branch_capacity=selected['BU_RS_DEPTH'],alu_capacity=selected['ALU_RS_DEPTH'])
    c['initial']=selected['BPU_INIT_C2B']
    if (c['metadata_depth'],c['request_skip'],c['answer_skip'],c['ras_depth'])!=(2,1,0,4) or c['hlen']<=c['issue_bits'] or not 2<=c['hlen']<=16 or not 1<=c['btb_bits']<=16 or boot%4:
        raise ValueError('FE01/FEQ11: unsupported selected timing/predictor configuration')
    return c

def sources():
    paths=set((ROOT/'rtl/packages').glob('*.sv*'))
    paths.update([ROOT/'scripts/gen-memory-map.py', ROOT/'scripts/sim/config-args.sh', ROOT/'tb/config/len5_config_probe.sv', ROOT/'tb/tb_bare.sv', ROOT/'tb/packages/tb_config_pkg.sv'])
    paths.update((ROOT/'rtl/frontend').glob('*.sv'))
    for name in ['modn_counter','modn_counter_updown','completion_fifo','spill_cell_flush','spill_cell_flush_cu','prio_enc']:
        paths.add(ROOT/('rtl/common/'+name+'.sv'))
    for name in ['pc_gen/pc_gen_model','early_jump_unit/early_jump_model','early_jump_unit/early_jump_instructions','fetch_mem_if/fetch_mem_model']:
        for suffix in ['.hh','.cpp']: paths.add(HERE.parent/(name+suffix))
    paths.update([HERE.parent/'pc_gen/configuration.py',ROOT/'rtl/packages.core',ROOT/'rtl/misc/packages-waivers.vlt',ROOT/'tb/verilator/verilator-common.core', ROOT/'rtl/frontend.core', ROOT/'rtl/common.core',
                  ROOT/'rtl/misc/frontend-waivers.vlt',ROOT/'tb/verilator/tb_macros.hh',ROOT/'tb/verilator/tb_macros.cpp'])
    paths.update(p for p in HERE.iterdir() if p.suffix in ['.hh','.cpp','.sv','.core','.vlt','.py'])
    return sorted(paths)

def fingerprint(c):
    h=hashlib.sha256(json.dumps([c,pc.rtl_configuration()],sort_keys=True).encode())
    for p in sources():h.update(str(p.relative_to(ROOT)).encode()+b'\0'+p.read_bytes()+b'\0')
    return h.hexdigest()

def model_directory(build):
    c=configuration();c['fingerprint']=fingerprint(c)
    return Path(build).resolve()/'fetch-stage/model'/('issues-%d-boot-%x-%s'%(c['bundle_instructions'],c['boot_pc'],c['fingerprint'])),c

def write_manifest(directory,c):
    directory=Path(directory);directory.mkdir(parents=True,exist_ok=True)
    lines=['%s=%s'%(k,v) for k,v in sorted(c.items())]
    for k,p in enumerate(sources()):
        name='fetch_stage_source_%d.snapshot'%k
        (directory/name).write_bytes(p.read_bytes())
        lines+=['source_file='+str(p.resolve()),'snapshot='+name]
    (directory/'fetch_stage_build.cfg').write_text('\n'.join(lines)+'\n')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build-dir',default=os.environ.get('BUILD_DIR',str(ROOT/'build')))
    p.add_argument('--binary',action='store_true');p.add_argument('--model-dir',action='store_true')
    args=p.parse_args();d,c=model_directory(args.build_dir)
    print(d/'sim-verilator/Vfetch_stage_tb' if args.binary else d if args.model_dir else json.dumps(c,sort_keys=True))
if __name__=='__main__':main()
