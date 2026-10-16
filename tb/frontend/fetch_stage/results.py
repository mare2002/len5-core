# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Frontend result policy. Completion is independent of process success.

No comparison is waived here: field_errors are hard unless a producer supplies
an explicit, reviewed unresolved-contract disposition for each discrepancy.
"""
import json
import os
import subprocess
from collections import Counter
from pathlib import Path

PASS = 'PASS'
INCOMPLETE = 'WARN_INCOMPLETE'
PROVISIONAL = 'WARN_PROVISIONAL'
MISMATCH = 'FAIL_MISMATCH'
ENVIRONMENT = 'FAIL_ENVIRONMENT'
FRAMEWORK = 'FAIL_FRAMEWORK'
STATUSES = {PASS, INCOMPLETE, PROVISIONAL, MISMATCH, ENVIRONMENT, FRAMEWORK}
DEFERRED = {'FE-T43', 'FE-T48', 'FE-T49', 'FE-T50', 'FE-T51'}


def strict_completion():
    value = os.environ.get('STRICT_COMPLETION', 'false')
    if value not in ('true', 'false'):
        raise ValueError('STRICT_COMPLETION requires true or false')
    return value == 'true'


def process(command, log, timeout=120):
    """Wall-clock watchdog is a framework error, unlike a bounded cycle stop."""
    try:
        return subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=timeout).returncode
    except (subprocess.TimeoutExpired, OSError) as error:
        log.write('\nFAIL_FRAMEWORK: unexpected process failure/watchdog: '+str(error)+'\n')
        return 124


def exit_code(statuses, strict=False):
    statuses = set(statuses)
    if not statuses or not statuses <= STATUSES:
        return 2
    # Infrastructure failures take precedence: their evidence may be unreliable.
    if statuses & {ENVIRONMENT, FRAMEWORK}:
        return 2
    if MISMATCH in statuses:
        return 1
    if strict and statuses & {INCOMPLETE, PROVISIONAL}:
        return 3
    return 0


def variants(scenario, n):
    if scenario.startswith("BP0") or scenario == "GH01":
        return [0]
    k = int(scenario[4:]) - 1
    if scenario in ('FE-T02', 'FE-T17', 'FE-T22'):
        return list(range(n))
    if scenario == 'FE-T21':
        return [0, 1, 5]
    if scenario == 'FE-T32':
        return list(range(5))  # selected supported RAS depth=4
    if scenario == 'FE-T38':
        return list(range(7))
    return [k % n]


def binary_config(binary):
    fields = dict(line.split('=',1) for line in (Path(binary).parent/'fetch_stage_build.cfg').read_text().splitlines())
    return dict(LEN5_MULTIPLE_ISSUES=int(fields['bundle_instructions']),
                boot_pc='0x%016x'%int(fields['boot_pc']),fingerprint=fields['fingerprint'])


def failure(reason, evidence='', scenario='orchestration'):
    return dict(scenario=scenario, variant=0, verification_status=FRAMEWORK,
                status='invalid', completion=False, reason=reason, comparisons=0,
                evidence=str(evidence), missing_witnesses=[])


def native_cases(run, expected=None, config=None):
    """Validate a subprocess receipt; absent/crashed/malformed is never coverage."""
    report = run.get('report', {})
    evidence = str(Path(run.get('artifacts', '.')) / 'logs/report.json')
    errors = []
    if not isinstance(report, dict) or not report or run.get('exit') not in (0, 1, 2, 3):
        return [failure('missing/malformed report or unexpected simulator termination', evidence)]
    cases = report.get('scenarios', [])
    if not isinstance(cases, list) or any(not isinstance(c, dict) for c in cases):
        return [failure('malformed scenario results', evidence)]
    if any(type(report.get(k)) is not int or report[k]<0 for k in ('field_checks','field_errors','environment_errors','framework_errors')):
        return [failure('missing/invalid native comparison/error counters', evidence)]
    if any(type(c.get(k)) is not int or c[k]<0 for c in cases for k in ('comparisons','field_errors')):
        return [failure('missing/invalid per-variant counters', evidence)]
    if sum(c['comparisons'] for c in cases)!=report['field_checks'] or sum(c['field_errors'] for c in cases)!=report['field_errors']:
        errors.append(failure('native scenario/total comparison conservation failed', evidence))
    if report.get('exit_status') != run.get('exit'):
        errors.append(failure('process/report exit disagreement', evidence))
    if config is not None and report.get('config') != config:
        errors.append(failure('source fingerprint or elaborated configuration differs', evidence))
    if not report.get('field_checks', 0) and not (report.get('environment_errors') or report.get('framework_errors')):
        errors.append(failure('zero useful comparisons', evidence))
    if expected is not None:
        actual = [(c.get('scenario'), c.get('variant')) for c in cases]
        if Counter(actual) != Counter(expected):
            errors.append(failure('missing, duplicate or unexpected scenario/variant execution result', evidence))
    output = []
    for item in cases:
        c = dict(item, evidence=evidence)
        status = c.get('verification_status')
        if status not in STATUSES:
            errors.append(failure('missing/invalid structured verification status', evidence))
            continue
        if c.get('field_errors', 0) and status not in (MISMATCH, ENVIRONMENT, FRAMEWORK):
            # Only individually justified Q-dependent discrepancies may warn.
            ds = report.get('discrepancies', [])
            justified = status == PROVISIONAL and ds and all(d.get('unresolved_contract') for d in ds)
            if not justified:
                c['verification_status'] = MISMATCH
        c['completion'] = c['verification_status'] == PASS
        output.append(c)
    if report.get('environment_errors') and not any(c['verification_status']==ENVIRONMENT for c in output):
        output.append(dict(failure('invalid causal environment', evidence), verification_status=ENVIRONMENT))
    if report.get('framework_errors') and not any(c['verification_status']==FRAMEWORK for c in output):
        output.append(failure('native framework failure', evidence))
    if report.get('field_errors') and not any(c['verification_status'] == MISMATCH for c in output):
        output.append(dict(failure('unaccounted comparison mismatches', evidence), verification_status=MISMATCH))
    computed = exit_code([c['verification_status'] for c in output + errors], report.get('strict_completion', False))
    if computed != run['exit']:
        errors.append(failure('native status/exit policy disagreement', evidence))
    return output + errors


def aggregate(cases, strict=False, **metadata):
    cases = list(cases)
    if not cases or not sum(c.get('comparisons', 0) for c in cases):
        cases.append(failure('empty suite or zero useful comparisons'))
    counts = Counter(c['verification_status'] for c in cases)
    scenario_states = {}
    rank = {PASS: 0, PROVISIONAL: 1, INCOMPLETE: 2, MISMATCH: 3, ENVIRONMENT: 4, FRAMEWORK: 5}
    for c in cases:
        name = c['scenario']
        if name not in scenario_states or rank[c['verification_status']] > rank[scenario_states[name]]:
            scenario_states[name] = c['verification_status']
    sc = Counter(scenario_states.values())
    code = exit_code(counts, strict)
    warnings = [c for c in cases if c['verification_status'] in (INCOMPLETE, PROVISIONAL)]
    complete = not warnings and not code
    result = dict(metadata, status='failed' if code in (1, 2) else 'incomplete' if warnings else 'passed',
                  execution_status='failed' if code else 'success_with_warnings' if warnings else 'success',
                  verification_status=next((s for s in (FRAMEWORK, ENVIRONMENT, MISMATCH, INCOMPLETE, PROVISIONAL) if counts[s]), PASS),
                  exit_status=code, strict_completion=strict, specification_complete=complete,
                  all_required_checks_executed=complete, scenario_count=len(scenario_states),
                  scenario_counts=dict(sc), variant_counts=dict(counts), cases=cases,
                  comparisons=sum(c.get('comparisons', 0) for c in cases),
                  comparison_mismatches=sum(c.get('field_errors', 0) for c in cases),
                  deferred_incomplete=sum(c['verification_status'] == INCOMPLETE and c['scenario'] in DEFERRED for c in cases),
                  unexpected_incomplete=sum(c['verification_status'] == INCOMPLETE and c['scenario'] not in DEFERRED for c in cases),
                  missing_witnesses=sum(len(c.get('missing_witnesses', [])) for c in cases),
                  full_contract_signoff=False)
    return result


def display(summary, title='FRONTEND DIRECTED VERIFICATION'):
    print('\n' + title, flush=True)
    for name in dict.fromkeys(c['scenario'] for c in summary['cases']):
        cs = [c for c in summary['cases'] if c['scenario'] == name]
        ws = [c for c in cs if c['verification_status'].startswith('WARN')]
        fs = [c for c in cs if c['verification_status'].startswith('FAIL')]
        if fs:
            print('[FAIL] %s — %s; evidence: %s' % (name, fs[0]['reason'], fs[0].get('evidence', '')))
        elif ws:
            reasons = sorted(set(c.get('reason') or 'required temporal witness not reached' for c in ws))
            missing = sorted(set(w for c in ws for w in c.get('missing_witnesses', [])))
            print('[WARN] %s %s%s — %s; missing: %s; variants=%s; comparisons=%d; evidence: %s' %
                  (name, 'INCOMPLETE' if any(c['verification_status']==INCOMPLETE for c in ws) else 'PROVISIONAL',
                   ' (unexpected completeness gap)' if name not in DEFERRED and any(c['verification_status']==INCOMPLETE for c in ws) else '',
                   '; '.join(reasons), ', '.join(map(str,missing)) or 'see reason/obligations',
                   ','.join(str(c.get('variant', '?')) for c in ws), sum(c.get('comparisons', 0) for c in cs), ws[0].get('evidence', '')))
        else:
            print('[OK] %s PASSED (%d variant%s)' % (name, len(cs), '' if len(cs)==1 else 's'))
    counts = summary['scenario_counts']
    print('Executed scenarios: %d; passed: %d; incomplete: %d; provisional: %d; failed: %d' %
          (summary['scenario_count'], counts.get(PASS,0), counts.get(INCOMPLETE,0), counts.get(PROVISIONAL,0),
           sum(counts.get(k,0) for k in (MISMATCH,ENVIRONMENT,FRAMEWORK))))
    print('Invalid environments: %d; framework failures: %d; missing witnesses: %d; deferred incomplete variants: %d; unexpected incomplete variants: %d' %
          (summary['variant_counts'].get(ENVIRONMENT,0),summary['variant_counts'].get(FRAMEWORK,0),
           summary['missing_witnesses'],summary['deferred_incomplete'],summary['unexpected_incomplete']))
    verdict = 'FAIL' if summary['exit_status'] in (1,2) else 'INCOMPLETE (strict completion)' if summary['exit_status']==3 else 'PASS WITH WARNINGS' if not summary['specification_complete'] else 'PASS'
    print('Result: %s; exit code: %d; comparisons: %d; mismatches: %d' %
          (verdict, summary['exit_status'], summary['comparisons'], summary['comparison_mismatches']))
    print('Verification completion: ' + ('COMPLETE for selected scope' if summary['specification_complete'] else 'INCOMPLETE'))


def write_summary(path, summary):
    Path(path).write_text(json.dumps(summary, indent=2) + '\n')


def run_cli(main):
    try:
        return main()
    except (Exception, KeyboardInterrupt) as error:
        print('[FAIL] FAIL_FRAMEWORK — '+str(error), flush=True)
        return 2
