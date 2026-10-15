#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Execute actual firmware and require concrete EQ08 evidence; no DUT forcing."""
import argparse, csv, hashlib, json, shutil, subprocess, tempfile
from pathlib import Path
from run import run, HERE

def analyze(directory, kind, width):
    rows=[]
    for r in csv.DictReader((directory/'cycles.csv').open()):
        if r['phase']=='pre': rows.append({k:int(v,16) for k,v in r.items() if k!='phase'})
    nm=subprocess.check_output(['riscv64-unknown-elf-nm','-n',str(directory/'firmware.elf')],text=True)
    symbols={v[2]:int(v[0],16) for line in nm.splitlines() if len(v:=line.split())==3}
    checks={}; evidence={}
    def check(label, value): checks[label]=bool(value)
    def first(label, predicate):
        found=next((r for r in rows if predicate(r)),None)
        check(label,found is not None)
        if found: evidence[label]=found['cycle']
        return found
    def history(r,prefix): return [r[prefix+str(k)] for k in range(4) if r[prefix+'_valid']&(1<<k)]
    def resident(r,pc): return any(r[k] and r[k.replace('_valid','_pc')]==pc for k in r if k.startswith('rob') and k.endswith('_valid'))
    check('elaborated width',bool(rows) and all(r['width']==width for r in rows))
    if kind=='empty_return':
        ret=symbols['empty_ret']; target=symbols['destination']
        first('empty return accepted without EJU prediction',lambda r:r['eju_valid'] and r['eju_ready'] and r['eju_pc']==ret and not r['p_valid'] and not r['early'])
        resolved=first('BU resolves empty-RAS return',lambda r:r['bu_valid'] and r['bu_pc']==ret and r['bu_target']==target and r['bu_mis'])
        first('branch restoration remains empty',lambda r:r['mis_flush'] and not r['p_valid'] and not r['c_valid'])
        first('correct destination issued',lambda r:r['issue_valid'] and r['issue_pc']==target and (not resolved or r['cycle']>resolved['cycle']))
        first('correct destination committed',lambda r:r['commit_rd_valid'] and r['commit_pc']==target)
        check('no call or exception injected',not any(r['call_confirm'] or r['exception_flush'] for r in rows))
    else:
        older=symbols['older_call']; younger=symbols['younger_call' if kind=='exception_call' else 'younger_return']; fault=symbols['fault']
        link=younger+4; oldlink=older+4
        committed=first('older call writes architectural link',lambda r:r['commit_rd_valid'] and r['commit_pc']==older)
        confirm=first('younger instruction confirms',lambda r:r['confirm_pc']==younger and r['call_confirm' if kind=='exception_call' else 'ret_confirm'])
        flush=first('older load precise exception flush',lambda r:r['exception_flush'] and r['commit_except'] and r['commit_pc']==fault and r['commit_code']==4)
        if flush and confirm:
            after=next(r for r in rows if r['cycle']==flush['cycle']+1)
            check('confirmation before older exception',confirm['cycle']<flush['cycle'])
            check('older call committed before recovery',committed is not None and committed['cycle']<flush['cycle'])
            check('younger operation resident before squash',resident(flush,younger))
            check('younger operation removed by squash',not resident(after,younger))
            check('younger operation never retired before squash',not any(r['cycle']<=flush['cycle'] and r['rob_pop'] and r['rob_pc']==younger for r in rows))
            check('exception edge suppresses confirmation',not flush['call_confirm'] and not flush['ret_confirm'])
            evidence['before_exception']={'C':history(flush,'c'),'P':history(flush,'p')}
            evidence['after_exception']={'C':history(after,'c'),'P':history(after,'p')}
            if kind=='exception_call':
                check('squashed link retained in C and restored P',link in history(after,'c') and link in history(after,'p'))
                check('older committed link also retained',oldlink in history(after,'c'))
                first('trap RET consumes stale predicted target',lambda r:r['cycle']>flush['cycle'] and r['eju_valid'] and r['eju_ready'] and r['eju_pc']==symbols['trap'] and r['early'] and r['early_target']==link)
                # Report separately: extra frontend/exception issues must not erase EQ08 evidence.
                recovery=next((r for r in rows if r['bu_valid'] and r['bu_pc']==symbols['trap'] and r['bu_target']==oldlink and r['bu_mis']),None)
                evidence['later_RET_corrected_by_BU_cycle']=recovery['cycle'] if recovery else None
            else:
                check('old link existed before younger pop',oldlink in history(confirm,'c'))
                check('squashed pop is not undone in C or P',oldlink not in history(after,'c') and oldlink not in history(after,'p'))
                first('younger return causes earlier branch recovery',lambda r:r['mis_flush'] and confirm['cycle']<r['cycle']<flush['cycle'])
    result={'status':'reproduced' if all(checks.values()) and kind!='empty_return' else 'passed' if all(checks.values()) else 'not_reproduced','kind':kind,'width':width,'checks':checks,'evidence':evidence,'symbols':symbols,'cycles':len(rows),'trace_sha256':hashlib.sha256((directory/'cycles.csv').read_bytes()).hexdigest()}
    (directory/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(kind,result['status'],evidence,flush=True)
    return result

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--root',type=Path,required=True);a=p.parse_args()
    root=a.root.resolve();width=json.loads((root/'configuration.json').read_text())['width']
    (root/'experiments').mkdir(exist_ok=True)
    experiment=Path(tempfile.mkdtemp(prefix='cases-',dir=root/'experiments'))
    print('Experiment:',experiment,flush=True)
    for source in ['exercise.py','run.py']:
        shutil.copy2(HERE/source,experiment/source)
    results=[]
    for kind in ['exception_call','exception_return','empty_return']:
        directory=experiment/kind;directory.mkdir(exist_ok=True);(directory/'logs').mkdir(exist_ok=True)
        asm=directory/(kind+'.S');shutil.copy2(HERE/(kind+'.S'),asm)
        run(['riscv64-unknown-elf-gcc','-march=rv64im_zicsr','-mabi=lp64','-nostdlib','-nostartfiles','-Wl,-Ttext=0x1000,--no-relax','-o',directory/'firmware.elf',asm],directory,directory/'firmware-build.log')
        run(['riscv64-unknown-elf-objcopy','-O','verilog',directory/'firmware.elf',directory/'firmware.hex'],directory,directory/'objcopy.log')
        run(['riscv64-unknown-elf-objdump','-d',directory/'firmware.elf'],directory,directory/'firmware.disassembly')
        run([root/'model/sim-verilator/Vrecovery_tb','+firmware='+str(directory/'firmware.hex')],directory,directory/'console.log')
        results.append(analyze(directory,kind,width))
    (experiment/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    (root/'latest-experiment.txt').write_text(str(experiment)+'\n')
    return 1 if any(r['status']=='not_reproduced' for r in results) else 0
if __name__=='__main__':raise SystemExit(main())
