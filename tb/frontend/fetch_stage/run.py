#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Source-fingerprinted FuseSoC build and isolated native invocation, adapted from FM."""
import argparse
import fcntl
import os
from pathlib import Path
import subprocess
import tempfile
import configuration as cfg
import results

def build(build_dir):
    root,c=cfg.model_directory(build_dir);root.mkdir(parents=True,exist_ok=True)
    binary=root/'sim-verilator/Vfetch_stage_tb'
    with (root/'build.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        if not binary.exists() or not (binary.parent/'fetch_stage_build.cfg').exists():
            print('## Building real fetch_stage with Verilator...',flush=True)
            command=[os.environ.get('FUSESOC','fusesoc'),'run','--target','sim','--tool','verilator','--build-root',str(root),'--setup','--build','polito:len5:fetch-stage-tb','--MEM_DEPTH='+str(c['metadata_depth']),'--BOOT_PC='+str(c['boot_pc'])]
            with (root/'build.log').open('w') as f:r=subprocess.run(command,cwd=cfg.ROOT,stdout=f,stderr=subprocess.STDOUT)
            if r.returncode:
                print('\n'.join((root/'build.log').read_text().splitlines()[-65:]));raise RuntimeError('fetch_stage build failed: '+str(root/'build.log'))
            if cfg.fingerprint(cfg.configuration())!=c['fingerprint']:raise RuntimeError('source changed during build')
            cfg.write_manifest(binary.parent,c)
    print('## fetch_stage build complete.',flush=True)
    return binary,c

def flags(directory):
    env=os.environ
    f=['--run_dir='+str(directory),'--seed='+env.get('SEED','1'),'--scenario='+env.get('SCENARIO','all'),'--log_level='+env.get('LOG_LEVEL','LOG_LOW'),'--dump_waves='+env.get('DUMP_WAVES','false'),'--profile='+env.get('FETCH_STAGE_PROFILE','exact-I'),'--max_cycles='+env.get('MAX_CYCLES','1000000'),'--strict_completion='+str(results.strict_completion()).lower()]
    for e,k,default in [('EXEC_LATENCY_MIN','exec_latency_min',None),('EXEC_LATENCY_MAX','exec_latency_max',None),('EXEC_LATENCY_DIST','exec_latency_dist',None),('EXEC_LATENCY_FIXED','exec_latency_fixed',None),('EXEC_LATENCY_MODE','exec_latency_mode',None),('EXEC_GEO_U','exec_geo_u',None),('EXEC_GEO_V','exec_geo_v',None),('EXEC_SHORT_U','exec_short_u',None),('EXEC_SHORT_V','exec_short_v',None),('EXEC_SHORT_MIN','exec_short_min',None),('EXEC_SHORT_MAX','exec_short_max',None),('EXEC_LONG_MIN','exec_long_min',None),('EXEC_LONG_MAX','exec_long_max',None),('PROGRAM','program',None),('REPETITIONS','repetitions',None),('INJECT_FAILURE','inject_failure',None),('JOURNAL','journal',None),('RAS_ORDER','ras_order',None),('DIRECTED_CYCLES','directed_cycles',None),('DIRECTED_REPETITIONS','directed_repetitions',None),('VARIANT','variant',None)]:
        if env.get(e,default) is not None:f+=['--'+k+'='+env.get(e,default)]
    return f

def main():
    p=argparse.ArgumentParser();p.add_argument('--build-only',action='store_true');p.add_argument('--random',action='store_true');a=p.parse_args()
    build_dir=Path(os.environ.get('BUILD_DIR',cfg.ROOT/'build'));binary,c=build(build_dir)
    if a.build_only:return 0
    if os.environ.get('SCENARIO')=='FE-T54' and not a.random:
        from confidence import execute
        parent=build_dir/'fetch-stage/confidence';parent.mkdir(parents=True,exist_ok=True)
        from confidence import validate_receipt
        directory=Path(tempfile.mkdtemp(prefix='FE-T54-',dir=parent))
        execute(binary,directory)
        receipt=validate_receipt(directory,binary,results.binary_config(binary))
        summary=results.aggregate([receipt],results.strict_completion(),scope='FE-T54 composite confidence')
        results.write_summary(directory/'execution-summary.json',summary);results.display(summary)
        return 0
    parent=build_dir/'fetch-stage/run';parent.mkdir(parents=True,exist_ok=True);directory=Path(tempfile.mkdtemp(prefix=os.environ.get('SCENARIO','random' if a.random else 'all')+'-',dir=parent))
    args=flags(directory)
    if a.random:args+=['--random','--cycles='+os.environ.get('CYCLES','10000'),'--campaign='+os.environ.get('CAMPAIGN','all'),'--weights='+os.environ.get('WEIGHTS',''),'--guided='+os.environ.get('GUIDED','true')]
    with (directory/'console.log').open('w') as f:status=results.process([str(binary),*args],f)
    print((directory/'console.log').read_text(),end='');print('Evidence:',directory)
    if not a.random and os.environ.get('SCENARIO','all')=='all':
        from catalog import complete
        status=complete(binary,directory,status)
    else:
        import json
        path=directory/'logs/report.json'
        report=json.loads(path.read_text()) if path.exists() else {}
        config=results.binary_config(binary)
        selected=os.environ.get('SCENARIO','all')
        expected=None if a.random else [(selected,v) for v in ([int(os.environ['VARIANT'],0)] if 'VARIANT' in os.environ else results.variants(selected,config['LEN5_MULTIPLE_ISSUES']))]
        summary=results.aggregate(results.native_cases(dict(exit=status,report=report,artifacts=str(directory)),expected,config),results.strict_completion())
        results.write_summary(directory/'summary.json',summary)
        results.display(summary)
        status=summary['exit_status']
    return status
if __name__=='__main__':raise SystemExit(results.run_cli(main))
