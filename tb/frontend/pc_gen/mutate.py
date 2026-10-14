#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Mutation audit in disposable DUT copies, using the selected production packages."""
import argparse
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import time
from configuration import ROOT, configuration, fingerprint, write_manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True, help='original selected-configuration binary')
    parser.add_argument('--output', type=Path, default=Path('build/pc-gen/mutation'))
    parser.add_argument('--jobs', type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('jobs must be positive')
    source = ROOT/'tb/frontend/pc_gen'
    rtl = ROOT/'rtl/frontend/pc_gen.sv'
    original = rtl.read_bytes()
    built_boot = next(line.split('=', 1)[1] for line in
                      (args.binary.resolve().parent/'pc_gen_build.cfg').read_text().splitlines() if line.startswith('boot_pc='))
    config = configuration(int(built_boot))
    config['fingerprint'] = fingerprint(config)
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='audit-', dir=args.output.resolve()))
    started = time.monotonic()
    def original_run(label):
        directory = root/label
        command = [str(args.binary.resolve()), '--scenario=all', '--seed=7', '--log_level=LOG_LOW', '--run_dir='+str(directory)]
        with (root/(label+'.log')).open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        report = json.loads((directory/'logs/report.json').read_text())
        return dict(exit_status=result.returncode, comparisons=report['field_checks'], field_errors=report['field_errors'],
                    confirmed=report['confirmed_mismatches'], provisional=report['provisional_mismatches'],
                    stimulus_digest=report['stimulus_digest'], artifacts=str(directory))
    original_before = original_run('original-before-mutations')
    increment = "pc_increase = -{1'b1, pc_o[ILEN_BIT_SUFF+LEN5_MULTIPLE_ISSUES_BITS-1:ILEN_BIT_SUFF]};"
    one = "pc_increase = {{LEN5_MULTIPLE_ISSUES_BITS{1'b0}}, 1'b1};"
    mutations = [
        ('sequential_step', 'T02', 'C3', 'ordinary PC+4 instead of bundle successor', increment, one),
        ('bundle_boundary', 'T02', 'C3', 'PC+B instead of interval successor from a partial bundle', increment,
         "pc_increase = {1'b1, {LEN5_MULTIPLE_ISSUES_BITS{1'b0}}};"),
        ('prediction_priority', 'T09', 'C9', 'current prediction overrides older early correction',
         'pred_taken_i && !early_jump_valid_i', 'pred_taken_i'),
        ('stall_hold', 'T03', 'C2', 'ordinary progression even when memory is stalled',
         '|| mem_ready_i || early_jump_valid_i', '|| mem_ready_i || !mem_ready_i || early_jump_valid_i'),
        ('not_taken_recovery', 'T06', 'C5', 'recover to branch PC instead of instruction fallthrough',
         'next_pc = adder_out;', 'next_pc = bu_res_i.pc;'),
        ('early_base', 'T09', 'C6', 'early target is based on the following instruction instead of supplied older PC',
         'add_pc_offset     = early_jump_base_i;', "add_pc_offset     = early_jump_base_i + 64'd4;"),
        ('reset_value', 'T01', 'C1', 'reset to a different instruction address',
         'pc_o <= BOOT_PC;', "pc_o <= BOOT_PC ^ 64'h4;"),
        ('fetch_suppression', 'T05', 'C4', 'fail to suppress fetch valid during branch recovery',
         'rst_ni & !(bu_res_valid_i & bu_res_i.mispredict) & !comm_except_raised_i', 'rst_ni & !comm_except_raised_i'),
    ]
    exclusions = []
    if config['bundle_instructions'] == 1:
        # PC+4 == PC+B == the bundle successor at N=1, so that defect is
        # mathematically equivalent. Use no progression for the first mutation.
        mutations[0] = ('sequential_step', 'T02', 'C3', 'fail to advance a single instruction',
                        "assign pc_increase = -1'b1;", "assign pc_increase = 1'b0;")
        mutations.pop(1)
        exclusions.append(dict(mutation='bundle_boundary', reason='N=1: aligned PC+B equals bundle successor; equivalent mutation excluded'))

    def run(mutation):
        label, scenario, requirement, behavior, before, after = mutation
        directory = root/label
        directory.mkdir()
        text = original.decode()
        # The recovery mutation intentionally changes the first of two next-PC
        # assignments; all other replacement sites must be unique.
        expected_sites = 2 if label == 'not_taken_recovery' else 1
        if text.count(before) != expected_sites:
            raise ValueError('mutation site changed: '+label)
        (directory/'pc_gen.sv').write_text(text.replace(before, after, 1))
        core = (source/'pc_gen_tb.core').read_text()
        name = 'polito:len5:pc-gen-mut-'+root.name+'-'+label
        core = core.replace('polito:len5:pc-gen-tb:0.1.0', name+':0.1.0')
        def absolute_file(match):
            filename, suffix = match[1], match[2] or ''
            path = directory/'pc_gen.sv' if filename == '../../../rtl/frontend/pc_gen.sv' else (source/filename).resolve()
            return '    - '+str(path)+suffix
        core = re.sub(r'^    - ([^ :]+\.(?:sv|cpp|hh))(:.*)?$', absolute_file, core, flags=re.M)
        (directory/'mutation.core').write_text(core)
        model = directory/'model'
        command = [os.environ.get('FUSESOC', 'fusesoc'), '--cores-root', str(directory), 'run', '--no-export',
                   '--target', 'sim', '--tool', 'verilator', '--build-root', str(model), '--setup', '--build', name,
                   '--BOOT_PC_HI='+str(config['boot_pc']>>32), '--BOOT_PC_LO='+str(config['boot_pc'] & 0xffffffff)]
        with (directory/'build.log').open('w') as log:
            built = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        result = dict(mutation=label, behavior=behavior, scenario=scenario, requirement=requirement,
                      build_command=shlex.join(command), build_status=built.returncode, artifacts=str(directory),
                      mutation_source_sha256=hashlib.sha256((directory/'pc_gen.sv').read_bytes()).hexdigest())
        if built.returncode:
            result['status'] = 'not_executed_build_failure'
            return result
        binary = model/'sim-verilator/Vpc_gen_tb'
        write_manifest(binary.parent, config)
        command = [str(binary), '--scenario='+scenario, '--seed=7', '--log_level=LOG_LOW',
                   '--expect_issues='+str(config['bundle_instructions']), '--run_dir='+str(directory/'run')]
        with (directory/'console.log').open('w') as log:
            tested = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        report = json.loads((directory/'run/logs/report.json').read_text())
        errors = [d for d in report['discrepancies'] if d.get('requirement') == requirement]
        detected = tested.returncode == 1 and report['field_checks'] > 0 and bool(errors)
        # early base arithmetic has a C9 PC check and a C6 sideband check; C6
        # definitively detects the approved selected-metadata defect.
        result.update(status='detected' if detected else 'survived_or_audit_failure',
                      command=shlex.join(command), exit_status=tested.returncode,
                      comparisons=report['field_checks'], field_errors=report['field_errors'],
                      confirmed=report['confirmed_mismatches'], provisional=report['provisional_mismatches'],
                      first_detection=next(iter(errors), None))
        print('%s: %s req=%s scenario=%s comparisons=%d' % (result['status'], label, requirement, scenario, report['field_checks']), flush=True)
        return result

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(run, mutations))
    # Original production source was never edited; execute the original binary
    # again after every disposable mutant build to check the baseline.
    if rtl.read_bytes() != original:
        raise RuntimeError('production RTL changed during mutation audit')
    original_after = original_run('original-after-mutations')
    baseline_identical = all(original_before[k] == original_after[k] for k in original_before if k != 'artifacts')
    mutations_detected = all(r['status'] == 'detected' for r in results)
    baseline_passed = original_after['exit_status'] == 0
    passed = baseline_passed and baseline_identical and mutations_detected
    summary = dict(status='passed' if passed else 'mutations_detected_baseline_failed' if mutations_detected and baseline_identical else 'failed',
                   config=config, seconds=time.monotonic()-started,
                   mutations=results, exclusions=exclusions, compiled=sum(r['build_status']==0 for r in results),
                   detected=sum(r['status']=='detected' for r in results),
                   original_before=original_before, original_after=original_after, baseline_identical=baseline_identical,
                   production_rtl_unchanged=True, original_rtl_sha256=hashlib.sha256(original).hexdigest())
    (root/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('Mutation evidence: '+str(root/'summary.json'))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
