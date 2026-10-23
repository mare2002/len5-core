#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run isolated native seeded campaigns after the existing FuseSoC build."""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def read_coverage(path, active):
    """A missing or truncated denominator is invalid evidence, never zero gaps."""
    try:
        coverage = json.loads(path.read_text())
        expected = {(row, ready, taken) for row in range(16) for ready in range(2)
                    for taken in range(2 if row & 4 else 1)}
        fields = ('row', 'ready', 'taken')
        for campaign in active:
            matrix = coverage['campaigns'][campaign]['matrix']
            keys = {tuple(entry[field] for field in fields) for entry in matrix}
            if len(matrix) != len(expected) or keys != expected:
                raise ValueError(campaign + ': incomplete or duplicate coverage matrix')
            for entry in matrix:
                key = tuple(entry[field] for field in fields)
                required = campaign != 'architectural' or sum(bool(key[0] & bit) for bit in (8, 4, 2)) <= 1
                if (any(type(value) is not int for value in key) or
                        type(entry['required']) is not bool or entry['required'] != required or
                        type(entry['count']) is not int or entry['count'] < 0):
                    raise ValueError(campaign + ': invalid coverage matrix entry')
        return coverage, ''
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {}, str(error)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/pc-gen/regression'))
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--seeds', type=int, default=100)
    parser.add_argument('--cycles', type=int, default=10000)
    parser.add_argument('--campaign', choices=['all', 'architectural', 'stress', 'characterization'], default='all')
    parser.add_argument('--contract', choices=['proposed', 'strict'], default='proposed')
    parser.add_argument('--weights', default='')
    parser.add_argument('--guided', choices=['true', 'false'], default='true')
    parser.add_argument('--journal', choices=['auto', 'full', 'failures'], default='auto')
    parser.add_argument('--log-level', default='LOG_LOW')
    parser.add_argument('--waves', choices=['true', 'false'], default='false')
    parser.add_argument('--early-accept', choices=['level', 'ready', 'unknown'])
    parser.add_argument('--early-target', choices=['relevant', 'arithmetic', 'unknown'])
    parser.add_argument('--jobs', type=int, default=1)
    parser.add_argument('--require-matrix', action='store_true', help='fail if required nonreset matrix bins remain empty')
    args = parser.parse_args()
    if min(args.seeds, args.cycles, args.jobs) < 1 or args.seed < 0 or args.seed+args.seeds > 2**64:
        parser.error('positive seeds/cycles/jobs and uint64 seed range required')
    binary = args.binary.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=f'{args.campaign}-{args.contract}-', dir=args.output.resolve()))
    start = time.monotonic()
    active = ['architectural', 'interface_stress', 'characterization'] if args.campaign == 'all' else [dict(stress='interface_stress').get(args.campaign, args.campaign)]

    def run(seed):
        directory = root / f'seed-{seed}'
        directory.mkdir()
        command = [str(binary), '--random', f'--seed={seed}', f'--cycles={args.cycles}',
                   f'--max_cycles={args.cycles}', f'--campaign={args.campaign}', f'--contract={args.contract}',
                   f'--guided={args.guided}', f'--weights={args.weights}', f'--journal={args.journal}',
                   f'--log_level={args.log_level}', f'--dump_waves={args.waves}', f'--run_dir={directory}']
        if args.early_accept:
            command += [f'--early_accept={args.early_accept}']
        if args.early_target:
            command += [f'--early_target={args.early_target}']
        begin = time.monotonic()
        with (directory / 'console.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
        report_path = directory / 'logs/report.json'
        report = json.loads(report_path.read_text()) if report_path.exists() else {}
        coverage_path = directory / 'logs/coverage.json'
        coverage, coverage_error = read_coverage(coverage_path, active)
        ok = not coverage_error and result.returncode == 0 and report.get('exit_status') == 0 and report.get('cycles_executed') == args.cycles and report.get('field_checks', 0) > 0
        return {'seed': seed, 'passed': ok, 'exit_status': result.returncode,
                'seconds': time.monotonic()-begin, 'command': shlex.join(command),
                'report': report, 'coverage': coverage, 'coverage_error': coverage_error,
                'artifacts': str(directory)}

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run, seed) for seed in range(args.seed, args.seed+args.seeds)]
        runs = []
        for future in as_completed(futures):
            result = future.result()
            runs.append(result)
            verdict = 'Test successfully passed' if result['passed'] else 'Test failed'
            print(f"{verdict}: random seed {result['seed']}: exit={result['exit_status']}, checks={result['report'].get('field_checks', 0)}, errors={result['report'].get('field_errors', 0)}", flush=True)
    runs.sort(key=lambda result: result['seed'])
    counters = Counter()
    requirements = Counter()
    campaign_requirements = Counter()
    unknowns = Counter()
    dont_cares = Counter()
    totals = Counter()
    matrices, resets = {}, {}
    exclusions = {}
    feature_goals = {}
    for run in runs:
        counters.update(run['coverage'].get('counters', {}))
        requirements.update(run['report'].get('requirement_checks', {}))
        campaign_requirements.update(run['report'].get('campaign_requirement_checks', {}))
        unknowns.update(run['report'].get('unknown_output_samples', {}))
        dont_cares.update(run['report'].get('dont_care_output_samples', {}))
        totals['guided_choices'] += (run['report'].get('random_configuration') or {}).get('guided_choices', 0)
        for key in ['cycles_executed', 'field_checks', 'field_errors', 'confirmed_mismatches', 'provisional_mismatches', 'environment_errors', 'framework_errors']:
            totals[key] += run['report'].get(key, 0)
        for campaign, cov in run['coverage'].get('campaigns', {}).items():
            exclusions[campaign] = cov['exclusions']
            goals = feature_goals.setdefault(campaign, {})
            for goal in cov.get('feature_goals', []):
                goals.setdefault(goal['bin'], dict(goal, count=0))['count'] += goal['count']
            matrix = matrices.setdefault(campaign, {})
            reset = resets.setdefault(campaign, {})
            for entry in cov['matrix']:
                key = (entry['row'], entry['ready'], entry['taken'])
                matrix.setdefault(key, dict(entry, count=0))['count'] += entry['count']
            for entry in cov['reset_matrix']:
                key = (entry['row'], entry['ready'])
                reset.setdefault(key, dict(entry, count=0))['count'] += entry['count']
    coverage = {}
    gaps = []
    for campaign in active:
        bins = list(matrices.get(campaign, {}).values())
        required = [b for b in bins if b['required']]
        missing = [b for b in required if b['count'] == 0]
        reset_bins = list(resets.get(campaign, {}).values())
        coverage[campaign] = {'matrix_hit': sum(b['count'] > 0 for b in required), 'matrix_required': len(required),
                              'matrix_gaps': missing, 'matrix': bins,
                              'reset_hit': sum(b['count'] > 0 for b in reset_bins), 'reset_observed_bins': reset_bins,
                              'exclusions': exclusions.get(campaign, []),
                              'feature_hit': sum(g['count'] > 0 for g in feature_goals.get(campaign, {}).values()),
                              'feature_total': len(feature_goals.get(campaign, {})),
                              'feature_gaps': [g for g in feature_goals.get(campaign, {}).values() if not g['count']]}
        coverage[campaign]['transition_exclusions'] = (
            'Architectural Z/E -> E/R/J and R -> R/J immediate transitions excluded: reset discards histories, '
            'commit chooses oldest eligible ordinary record and cancels younger records, branch waits backend resume Q5/Q9; older commit may interrupt recovery; '
            'distance 0/1 excluded by minimum latency 2. Reset raw combinations tracked but not architectural denominator.'
            if campaign == 'architectural' else 'No pin-level exclusivity; unresolved outcomes retain unknown status.')
        gaps += [{'campaign': campaign, **b} for b in missing]
    # Characterization denominators describe observations; they never imply
    # correctness of unspecified outputs or architectural reachability.
    native_passed = all(r['passed'] for r in runs)
    config = runs[0]['report'].get('config')
    native_passed = native_passed and bool(config) and all(r['report'].get('config') == config for r in runs)
    coverage_failed = bool(args.require_matrix and gaps)
    passed = native_passed and not coverage_failed
    summary = {'status': 'passed' if passed else 'incomplete' if native_passed else 'failed',
               'reason': 'required combination coverage is incomplete' if native_passed and coverage_failed
                         else '' if passed else 'native run failure or missing/incomplete evidence',
               'coverage_requirement_failed': coverage_failed, 'full_contract_signoff': False,
               'configuration': {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
               'rtl_configuration': config,
               'configuration_exclusions': runs[0]['coverage'].get('configuration_exclusions', []),
               'seconds': time.monotonic()-start, 'seeds': args.seeds, 'totals': dict(totals),
               'coverage': coverage, 'coverage_gaps': gaps, 'counters': dict(sorted(counters.items())),
               'requirement_checks': dict(requirements), 'campaign_requirement_checks': dict(campaign_requirements),
               'unknown_output_samples': dict(unknowns), 'assumptions': runs[0]['report'].get('assumptions', []),
               'resolved_random_configuration': runs[0]['report'].get('random_configuration'), 'unresolved_questions': runs[0]['report'].get('unresolved_questions', []),
               'specification_status': runs[0]['report'].get('specification_status'), 'dont_care_output_samples': dict(dont_cares),
               'runs': [{**{k: v for k, v in r.items() if k not in ['report', 'coverage']}, **{
                   'stimulus_digest': r['report'].get('stimulus_digest'), 'checks': r['report'].get('field_checks', 0),
                   'first_discrepancy': next(iter(r['report'].get('discrepancies', [])), None)}} for r in runs]}
    (root / 'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(f"{'PASS' if passed else 'FAIL'}: {sum(r['passed'] for r in runs)}/{args.seeds} seeds; "
          f"cycles={totals['cycles_executed']} checks={totals['field_checks']} mismatches={totals['field_errors']}; "
          f"seconds={summary['seconds']:.3f}; LEN5_MULTIPLE_ISSUES={(config or {}).get('bundle_instructions', 'unknown')}")
    for campaign, cov in coverage.items():
        print(f"Coverage {campaign}: combinations={cov['matrix_hit']}/{cov['matrix_required']}; reset rows={cov['reset_hit']}/32; feature goals={cov['feature_hit']}/{cov['feature_total']}")
    if coverage_failed:
        print(f'Coverage requirement incomplete: {len(gaps)} combination bins remain uncovered')
    for run in runs:
        if not run['passed']:
            print(f"FAILED seed {run['seed']}: {run['artifacts']}; replay: {run['command']}")
            if run['coverage_error']:
                print('Invalid coverage evidence: ' + run['coverage_error'])
    print(f'Regression evidence: {root}/summary.json')
    print('Test successfully passed: pc_gen regression' if passed else 'Test failed: pc_gen regression', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    try:
        result = main()
    except Exception:
        print('Test failed: pc_gen regression', flush=True)
        raise
    raise SystemExit(result)
