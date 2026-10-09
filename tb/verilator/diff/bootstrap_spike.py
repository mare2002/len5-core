#!/usr/bin/env python3
"""Build the pinned reference libraries in user-selected, isolated directories."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
p=argparse.ArgumentParser()
p.add_argument('--source',type=Path,required=True)
p.add_argument('--build',type=Path,required=True)
p.add_argument('-j',type=int,default=4)
a=p.parse_args();a.source=a.source.resolve();a.build=a.build.resolve()
pin='530af85d83781a3dae31a4ace84a573ec255fefa'
if not a.source.exists():
    a.source.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['git','clone','--depth','1','--branch','v1.1.0','https://github.com/riscv-software-src/riscv-isa-sim.git',str(a.source)],check=True)
revision=subprocess.check_output(['git','-C',str(a.source),'rev-parse','HEAD'],text=True).strip()
if revision!=pin:
    raise SystemExit('Spike source must be pinned to '+pin+'; found '+revision)
a.build.mkdir(parents=True,exist_ok=True)
env=os.environ.copy();env['CCACHE_DISABLE']='1'
# Spike v1.1.0 relied on a transitive cstdint include removed by recent libstdc++.
env['CXXFLAGS']=env.get('CXXFLAGS','-O2')+' -include cstdint'
if not shutil.which('dtc'):
    # processor_t + simif_t never instantiate sim_t's device tree. Use an explicit
    # failing executable for this unused feature; building/running the Spike CLI
    # requires a real dtc and reconfiguration without this override.
    env['DTC']=shutil.which('false')
    print('Building processor libraries only: dtc absent; DTB generation disabled.',flush=True)
subprocess.run([str(a.source/'configure'),'--enable-commitlog','--without-boost','--without-boost-asio','--without-boost-regex'],cwd=a.build,env=env,check=True)
subprocess.run(['make','-j',str(a.j),'libriscv.a','libdisasm.a','libsoftfloat.a','libfesvr.a'],cwd=a.build,env=env,check=True)
print('Spike reference libraries ready at',a.build)
