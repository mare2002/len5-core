#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Compose native directed results with the executed external FE-T54 validators."""
import argparse
import json
from pathlib import Path
import subprocess
from confidence import execute
from run import flags

def complete(binary,directory,status):
    native_status=status
    confidence=execute(binary,directory/'FE-T54-confidence')
    path=directory/'logs/report.json';report=json.loads(path.read_text())
    (directory/'logs/report.native.json').write_text(json.dumps(report,indent=2)+'\n')
    for scenario in report['scenarios']:
        if scenario['scenario']=='FE-T54':
            scenario.update(status=confidence['status'],reason='executed composite confidence validators',missing_witnesses=[],evidence=str(directory/'FE-T54-confidence/summary.json'))
    # Preserve every other native error/incomplete classification.
    status=2 if report['environment_errors'] or report['framework_errors'] else 1 if report['field_errors'] else 3 if any(s['status']!='passed' for s in report['scenarios']) else 0
    if native_status not in (0,3):status=native_status
    report.update(exit_status=status,status='passed' if status==0 else 'incomplete' if status==3 else 'failed',confidence_evidence=str(directory/'FE-T54-confidence/summary.json'))
    path.write_text(json.dumps(report,indent=2)+'\n');return status

def main():
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,required=True);p.add_argument('--run-dir',type=Path,required=True);a=p.parse_args()
    a.run_dir.mkdir(parents=True,exist_ok=True)
    status=subprocess.run([str(a.binary.resolve()),*flags(a.run_dir),'--scenario=all']).returncode
    if (a.run_dir/'logs/report.json').exists():status=complete(a.binary.resolve(),a.run_dir,status)
    print('All tests passed' if not status else 'Test failed: full specification incomplete or mismatched')
    return status
if __name__=='__main__':raise SystemExit(main())
