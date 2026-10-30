#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Build full-core recovery capture in disposable source copies; never edit live RTL."""
import argparse, hashlib, json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'scripts'))
import importlib.util
_spec = importlib.util.spec_from_file_location("memory_map", ROOT / "scripts/gen-memory-map.py")
_config = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_config)
build_arguments = _config.build_arguments

def run(command, cwd, log, env=None):
    with log.open('w') as f:
        result=subprocess.run([str(x) for x in command],cwd=cwd,env=env,stdout=f,stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError('command failed: %s; see %s' % (command,log))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--width',type=int,choices=[2,4],required=True)
    p.add_argument('--output',type=Path,default=ROOT/'build/early-jump/recovery')
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=True)
    (a.output/'FUSESOC_IGNORE').touch()  # Keep private libraries out of parent scans.
    out=Path(tempfile.mkdtemp(prefix='n%d-'%a.width,dir=a.output.resolve()))
    print('Recovery artifacts:',out,flush=True)
    protected={str(x.relative_to(ROOT)):hashlib.sha256(x.read_bytes()).hexdigest() for x in (ROOT/'rtl').rglob('*') if x.is_file()}
    (out/'production-baseline.json').write_text(json.dumps(protected,indent=2))
    copy=out/'source'; copy.mkdir()
    for folder in ['rtl','tb','scripts']:
        shutil.copytree(ROOT/folder,copy/folder,ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copy2(ROOT/'len5.core',copy/'len5.core')
    shutil.copy2(ROOT/'makefile',copy/'makefile')
    (copy/'fusesoc.conf').write_text('[library.len5]\nlocation = .\nsync-type = local\n')
    env={**os.environ,'LEN5_MULTIPLE_ISSUES':str(a.width)}
    config_args=[arg for kind in ('rtl','tb') for arg in build_arguments(kind,env)]
    (out/'configuration.json').write_text(json.dumps({'width':a.width,'production_config_sha256':protected['rtl/packages/len5_config_pkg.sv'],
        'elaboration_overrides':{'LEN5_MULTIPLE_ISSUES':a.width},'source_configuration_unchanged':True},indent=2))
    run([env.get('FUSESOC','fusesoc'),'run','--target','sim','--tool','verilator','--build-root',out/'model','--setup','--build','polito:len5:recovery-audit',*config_args],copy,out/'build.log',env=env)
    run(['python3',HERE/'exercise.py','--root',out],out,out/'exercise.log',env=env)
    changed=[p for p,h in protected.items() if hashlib.sha256((ROOT/p).read_bytes()).hexdigest()!=h]
    (out/'integrity.json').write_text(json.dumps({'changed':changed,'production_unchanged':not changed},indent=2))
    assert not changed
    print('Capture/analysis complete:',out/'latest-experiment.txt',flush=True)
if __name__=='__main__': main()
