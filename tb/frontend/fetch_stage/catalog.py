#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Compose every native directed result with current executed FE-T54 evidence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from confidence import execute, validate_receipt
from run import flags
import results


def complete(binary, directory, status):
    path = directory/'logs/report.json'
    try:
        report = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        summary = results.aggregate([results.failure('required native report absent/corrupted: '+str(error), path)])
        results.write_summary(directory/'summary.json', summary)
        results.display(summary)
        return 2
    results.write_summary(directory/'logs/report.native.json', report)
    n = report.get('config', {}).get('LEN5_MULTIPLE_ISSUES', 0)
    expected = [(s, v) for s in ('FE-T%02d'%i for i in range(1,55))
                for v in ([int(os.environ['VARIANT'],0)] if 'VARIANT' in os.environ else results.variants(s,n))] if n else []
    cases = results.native_cases(dict(exit=status, report=report, artifacts=str(directory)), expected,results.binary_config(binary))
    try:
        execute(binary, directory/'FE-T54-confidence')
        receipt = validate_receipt(directory/'FE-T54-confidence', binary, report.get('config'))
    except (Exception, SystemExit) as error:
        receipt = results.failure('FE-T54 composite validation failed: '+str(error),directory/'FE-T54-confidence','FE-T54')
    # Only a valid placeholder is delegated. Native failures and absent executions
    # cannot be overwritten by successful unrelated confidence subprocesses.
    composed = []
    for c in cases:
        if c['scenario']=='FE-T54' and c['verification_status']==results.INCOMPLETE:
            composed.append(dict(receipt, variant=c['variant'], native_placeholder=c,
                                 comparisons=c['comparisons']+receipt.get('comparisons',0),
                                 native_delegate_comparisons=c['comparisons'],
                                 external_validator_comparisons=receipt.get('comparisons',0)))
        else:
            composed.append(c)
    summary = results.aggregate(composed, results.strict_completion(), scope='full-directed-catalog', excluded={},
                                native_report=str(directory/'logs/report.native.json'),
                                confidence_evidence=str(directory/'FE-T54-confidence/summary.json'),
                                native_cycles_executed=report.get('cycles_executed',0),
                                confidence_cycles_executed=receipt.get('cycles_executed',0),
                                cycles_executed=report.get('cycles_executed',0)+receipt.get('cycles_executed',0))
    # Preserve native field totals/obligations and expose one canonical composed list.
    report.update({k:v for k,v in summary.items() if k not in ('cases','comparisons','comparison_mismatches')})
    report['scenarios']=composed
    report['native_field_checks']=report['field_checks']
    report['field_checks']=summary['comparisons']
    results.write_summary(path,report)
    results.write_summary(directory/'summary.json',summary)
    results.display(summary)
    return summary['exit_status']


def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--run-dir',type=Path,required=True);a=p.parse_args()
    a.run_dir.mkdir(parents=True,exist_ok=True)
    with (a.run_dir/'console.log').open('w') as log:
        status=results.process([str(a.binary.resolve()),*flags(a.run_dir),'--scenario=all'],log)
    return complete(a.binary.resolve(),a.run_dir,status)
if __name__=='__main__':raise SystemExit(results.run_cli(main))
