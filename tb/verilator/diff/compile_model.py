#!/usr/bin/env python3
"""Reuse FuseSoC's simulation manifest, with an isolated optional checker build."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys
sys.dont_write_bytecode = True
from layout import generate

ROOT = Path(__file__).resolve().parents[3]
PIN = '530af85d83781a3dae31a4ace84a573ec255fefa'
p = argparse.ArgumentParser()
p.add_argument('--spike-src', required=True, type=Path)
p.add_argument('--spike-build', required=True, type=Path)
p.add_argument('--build-dir', type=Path, default=ROOT/'build/diff')
p.add_argument('--fusesoc', default='fusesoc')
p.add_argument('--verilator', default='verilator')
p.add_argument('-j', type=int, default=4)
a = p.parse_args()
a.spike_src=a.spike_src.resolve(); a.spike_build=a.spike_build.resolve();a.build_dir=a.build_dir.resolve()
revision=subprocess.check_output(['git','-C',str(a.spike_src),'rev-parse','HEAD'],text=True).strip()
if revision!=PIN:
    sys.exit('Unsupported Spike revision '+revision+'; adapter requires '+PIN)
for lib in ('libriscv.a','libdisasm.a','libsoftfloat.a','libfesvr.a'):
    if not (a.spike_build/lib).is_file():
        sys.exit('Build Spike --enable-commitlog first; missing '+lib)
if '#define RISCV_ENABLE_COMMITLOG' not in (a.spike_build/'config.h').read_text():
    sys.exit('Spike requires --enable-commitlog')
version=subprocess.check_output([a.verilator,'--version'],text=True)
if 'Verilator 5.040' not in version:
    sys.exit('This adapter generator is tested with Verilator 5.040 (XML API). Set VERILATOR to that binary. Found: '+version)
subprocess.run([a.fusesoc,'run','--no-export','--target','sim','--tool','verilator','--setup','--build-root',str(a.build_dir/'model'),'polito:len5:len5'],cwd=ROOT,check=True)
model=a.build_dir/'model/sim-verilator'
vc=next(model.glob('*.vc'))
config=(model/'config.mk').read_text()
options=shlex.split(next(x.split(':=',1)[1] for x in config.splitlines() if x.startswith('VERILATOR_OPTIONS')))
# Edalize's manifest already contains the testbench; the inherited --exe filename is redundant.
for i in range(len(options)-1,0,-1):
    if options[i]=='len5_tb.cpp':
        del options[i]
options += ['--vpi',str(ROOT/'tb/verilator/diff/signals.vlt')]
subprocess.run([a.verilator,'-f',vc.name,*options,'-Wno-DEPRECATED','--xml-only'],cwd=model,check=True)
vpi_words=generate(model/'Vtb_bare.xml',model/'diff_layout.hh')
flags=['-std=c++17','-DLEN5_DIFF','-DVL_VALUE_STRING_MAX_WORDS='+str(vpi_words),'-I'+str(model),'-I'+str(a.spike_build),'-I'+str(a.spike_src),'-I'+str(a.spike_src/'riscv'),'-I'+str(a.spike_src/'softfloat')]
links=[str(a.spike_build/x) for x in ('libriscv.a','libdisasm.a','libsoftfloat.a','libfesvr.a')]+['-ldl','-lpthread','-lz']
sources=[str(ROOT/'tb/verilator/diff'/x) for x in ('checker.cpp','spike_adapter.cpp','monitor.cpp','annotate.cpp')]
subprocess.run([a.verilator,'-f',vc.name,*options,'-CFLAGS',' '.join(flags),'-LDFLAGS',' '.join(links),*sources],cwd=model,check=True)
env=os.environ.copy();env['CCACHE_DISABLE']='1'
subprocess.run(['make','-f','Vtb_bare.mk','-j',str(a.j)],cwd=model,env=env,check=True)
print('Differential simulator:',model/'Vtb_bare')
