#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Run every fetch_mem_if verification group against one already built DUT."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time


def run_groups(groups, root, jobs):
    """Keep running independent groups after a failure; serialize console output."""
    def run(group):
        name, command = group
        started = time.monotonic()
        log_path = root / (name + '.log')
        with log_path.open('w') as log:
            try:
                status = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
                error = ''
            except OSError as exception:
                status, error = 2, str(exception)
                log.write(error + '\n')
        return dict(name=name, passed=status == 0, exit_status=status,
                    seconds=time.monotonic()-started, command=shlex.join(command),
                    log=str(log_path), error=error)

    results = {}
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(run, group) for group in groups]
        for future in as_completed(futures):
            result = future.result()
            results[result['name']] = result
            # Print one complete group at a time, so concurrent logs never mix.
            print(f"\n## fetch_mem_if {result['name']} output", flush=True)
            with Path(result['log']).open() as log:
                for line in log:
                    sys.stdout.write(line)
            verdict = 'Test successfully passed' if result['passed'] else 'Test failed'
            print(f"{verdict}: {result['name']}; exit={result['exit_status']}; log={result['log']}", flush=True)
    return [results[name] for name, _ in groups]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/fetch-mem-if/suite'))
    parser.add_argument('--test-jobs', type=int, default=4, help='concurrent verification groups')
    parser.add_argument('--jobs', type=int, default=4, help='parallel regression seeds and mutation builds')
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--seeds', type=int, default=100)
    parser.add_argument('--cycles', type=int, default=10000)
    parser.add_argument('--max-cycles', type=int, default=50000)
    parser.add_argument('--campaign', choices=['all', 'architectural', 'stress', 'characterization'], default='all')
    parser.add_argument('--contract', choices=['integrated', 'established'], default='integrated')
    parser.add_argument('--weights', default='')
    parser.add_argument('--guided', choices=['true', 'false'], default='true')
    parser.add_argument('--journal', choices=['auto', 'full', 'failures'], default='auto')
    parser.add_argument('--log-level', default='LOG_LOW')
    parser.add_argument('--waves', choices=['true', 'false'], default='false')
    parser.add_argument('--require-matrix', choices=['true', 'false'], default='true')
    parser.add_argument('--inject-failure', default='', help='intentional monitor fault in native directed/random groups')
    args = parser.parse_args()
    if min(args.test_jobs, args.jobs, args.seeds, args.cycles, args.max_cycles) < 1 or args.seed < 0 or args.seed+args.seeds > 2**64:
        parser.error('positive jobs/cycles/seeds and uint64 seed range required')
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error('build fetch_mem_if before starting the full suite: ' + str(binary))
    source = Path(__file__).resolve().parent
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='all-', dir=args.output.resolve()))
    print(f'## fetch_mem_if full suite: {root}; parallel groups={args.test_jobs}, seed/mutation jobs={args.jobs}', flush=True)

    native = [str(binary), '--seed='+str(args.seed), '--contract='+args.contract,
              '--log_level='+args.log_level, '--dump_waves='+args.waves]
    if args.inject_failure:
        native.append('--inject_failure='+args.inject_failure)
    random = ['--random', '--cycles='+str(args.cycles), '--campaign='+args.campaign,
              '--guided='+args.guided, '--weights='+args.weights, '--journal='+args.journal]
    regression = [sys.executable, str(source/'regress.py'), '--binary', str(binary),
                  '--output', str(root/'regression'), '--seed='+str(args.seed), '--seeds='+str(args.seeds),
                  '--cycles='+str(args.cycles), '--jobs='+str(args.jobs), '--campaign='+args.campaign,
                  '--contract='+args.contract, '--log-level='+args.log_level, '--waves='+args.waves,
                  '--guided='+args.guided, '--weights='+args.weights, '--journal='+args.journal]
    if args.require_matrix == 'true':
        regression.append('--require-matrix')
    groups = [
        ('orchestration', [sys.executable, str(source/'suite_unit.py'), '--output', str(root/'orchestration')]),
        ('directed', native + ['--scenario=all', '--max_cycles='+str(args.max_cycles), '--run_dir='+str(root/'directed')]),
        ('framework', [sys.executable, str(source/'validate.py'), '--binary', str(binary), '--output', str(root/'framework')]),
        ('random-framework', [sys.executable, str(source/'validate_random.py'), '--binary', str(binary), '--output', str(root/'random-framework')]),
        ('random', native + random + ['--max_cycles='+str(args.cycles), '--run_dir='+str(root/'random')]),
        ('regression', regression),
        ('mutations', [sys.executable, str(source/'mutate.py'), '--binary', str(binary), '--output', str(root/'mutations'), '--jobs='+str(args.jobs)]),
    ]
    started = time.monotonic()
    results = run_groups(groups, root, args.test_jobs)
    passed = all(result['passed'] for result in results)
    configuration = json.loads((root/'directed/logs/report.json').read_text()).get('config') if (root/'directed/logs/report.json').exists() else None
    summary = dict(status='passed' if passed else 'failed', binary=str(binary), config=configuration,
                   seconds=time.monotonic()-started, test_jobs=args.test_jobs, jobs=args.jobs,
                   passed=sum(result['passed'] for result in results), total=len(results), groups=results)
    (root/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(f"\n## fetch_mem_if suite result: {summary['passed']}/{summary['total']} groups passed; report={root}/summary.json", flush=True)
    print('All tests passed' if passed else 'Test failed', flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    try:
        result = main()
    except SystemExit as error:
        if error.code:
            print('Test failed: fetch_mem_if full suite', flush=True)
        raise
    except Exception:
        print('Test failed: fetch_mem_if full suite', flush=True)
        raise
    raise SystemExit(result)
