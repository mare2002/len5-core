#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Seed replay, causal constraints, observed coverage and random failure-path checks."""
import argparse
from collections import Counter
import hashlib
from itertools import groupby
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('build/pc-gen/validation'))
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix='random-', dir=args.output.resolve()))
    binary = args.binary.resolve()
    results = []
    source = Path(__file__).resolve().parent
    verifier_root = Path(subprocess.check_output([os.environ.get('VERILATOR', 'verilator'), '--getenv', 'VERILATOR_ROOT'], text=True).strip())
    confidence_binary = root / 'scoreboard-confidence'
    with (root / 'confidence-build.log').open('w') as log:
        subprocess.run([os.environ.get('PC_GEN_CXX', '/usr/bin/g++'), '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror',
            '-DVL_TIME_CONTEXT', '-I'+str(source), '-I'+str(source.parents[1] / 'verilator'),
            '-isystem', str(verifier_root / 'include'), str(source / 'pc_gen_scoreboard_unit.cpp'),
            str(source / 'pc_gen_scoreboard.cpp'), str(source / 'pc_gen_model.cpp'),
            str(source.parents[1] / 'verilator/tb_macros.cpp'), '-o', str(confidence_binary)],
            stdout=log, stderr=subprocess.STDOUT, check=True)
    for case in ['unverified', 'matched', 'definitive']:
        evidence = root / ('synthetic-confidence-'+case)
        with (root / ('confidence-'+case+'.log')).open('w') as log:
            result = subprocess.run([str(confidence_binary), str(evidence), case], stdout=log, stderr=subprocess.STDOUT)
        report = json.loads((evidence / 'report.json').read_text())
        assert result.returncode == 1 and report['exit_status'] == 1
        assert report['confirmed_mismatches'] == (0 if case=='unverified' else 1)
        assert report['provisional_mismatches'] == (2 if case=='unverified' else 0 if case=='definitive' else 1)
        assert report['field_errors'] == (1 if case=='definitive' else 2)
    print('PASS: synthetic scoreboard evidence preserves provisional versus confirmed priority classification')
    coverage_fixtures = root/'synthetic-coverage-configurations'
    subprocess.run([str(confidence_binary), str(coverage_fixtures), 'coverage'], check=True)
    for width in [1, 2, 4, 8]:
        cov = json.loads((coverage_fixtures/str(width)/'coverage.json').read_text())
        assert cov['LEN5_MULTIPLE_ISSUES'] == width and cov['bundle_bytes'] == width*4
        bins = [g['bin'] for g in cov['campaigns']['architectural']['feature_goals']]
        assert any('/same_bundle' in b for b in bins) == (width > 1)
        assert any('/length/3..N' in b for b in bins) == (width >= 3)
        assert any('/distance/2..N' in b for b in bins) == (width >= 2)
        counters = cov['counters']
        prefix = 'V05/architectural/sequential/expected_start_lane/'
        assert {int(b[len(prefix):]) for b in counters if b.startswith(prefix)} == set(range(width))
        assert all(counters[prefix+str(lane)] == 1 for lane in range(width))
        assert counters.get('V10/architectural/onset/hold') == 2
        assert counters.get('V10/architectural/length/1') == 1
        assert not counters.get('V10/architectural/length/2')
        assert counters.get('V10/architectural/interrupted_stall/1') == 1
        assert counters.get('V09/architectural/hold->prediction') == 1
        assert not counters.get('V09/architectural/hold->hold')
    print('PASS: four pure coverage fixtures adapt lane counters, goals and exclusions; no alternate DUT was built')

    def run(label, flags=(), status=None, cycles=2048):
        directory = root / label
        directory.mkdir()
        command = [str(binary), '--random', '--seed=17', f'--cycles={cycles}', f'--max_cycles={cycles}',
                   '--log_level=LOG_LOW', f'--run_dir={directory}', *flags]
        with (directory / 'console.log').open('w') as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=60)
        report = json.loads((directory / 'logs/report.json').read_text())
        cov = json.loads((directory / 'logs/coverage.json').read_text())
        assert result.returncode == report['exit_status'], (label, report)
        if status is None:
            assert result.returncode in (0, 1) and not report['environment_errors'] and not report['framework_errors'], (label, report)
        else:
            assert result.returncode == status and report['confirmed_mismatches'] == 0, (label, report)
        assert not report['full_contract_signoff']
        assert report['unresolved_questions'] == ['Q1', 'Q3', 'Q4', 'Q5', 'Q9']
        assert report['field_checks'] > 0
        if result.returncode in (0, 1):
            assert report['cycles_executed'] == cycles
        if result.returncode == 0:
            assert report['field_errors'] == 0
        console = (directory / 'console.log').read_text()
        assert '[CONFIG]' in console and 'Starting simulation' in console
        assert ('TEST FAILED > errors:' if result.returncode else 'TEST SUCCEEDED > errors: 0/') in console
        assert 'campaign=' in console and 'seed=' in console
        results.append({'case': label, 'command': command, 'checks': report['field_checks'], 'errors': report['field_errors'], 'status': result.returncode, 'dut_failure': status is None and result.returncode == 1})
        print(f'CHECKED: {label}: checks={report["field_checks"]}, errors={report["field_errors"]}')
        return report, cov, directory

    first, coverage, directory = run('all-full', ['--journal=full'])
    assert coverage['requirement_checks'] == first['campaign_requirement_checks']
    assert coverage['assumption_checks'] == first['assumption_checks']
    assert coverage['unknown_output_samples'] == first['unknown_output_samples']
    assert coverage['unresolved_questions'] == first['unresolved_questions']
    replay, _, replay_dir = run('all-replay-fst', ['--journal=full', '--dump_waves=true'])
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    assert first['stimulus_digest'] == replay['stimulus_digest']
    assert digest(directory / 'logs/samples.jsonl') == digest(replay_dir / 'logs/samples.jsonl')
    assert (replay_dir / 'logs/waves.fst').stat().st_size > 0
    compact, _, compact_dir = run('all-compact')
    assert compact['stimulus_digest'] == first['stimulus_digest'] and compact['field_checks'] == first['field_checks']
    assert bool((compact_dir / 'logs/samples.jsonl').stat().st_size) == bool(compact['field_errors'])
    assert compact['field_errors'] == first['field_errors']
    assert compact['characterization_observations'] > 0 and (compact_dir / 'logs/characterization.jsonl').stat().st_size > 0
    medium, _, medium_dir = run('medium-concise', ['--log_level=LOG_MEDIUM'])
    assert medium['stimulus_digest'] == first['stimulus_digest']
    text = (medium_dir / 'console.log').read_text()
    assert 'REQ > id=' not in text and 'RSP > id=' not in text
    run('uint64-seed', ['--seed=18446744073709551615'])
    other, _, _ = run('different-seed', ['--seed=18'])
    assert other['stimulus_digest'] != first['stimulus_digest']
    for campaign in ['architectural', 'stress', 'characterization']:
        run(campaign, [f'--campaign={campaign}'])
    strict, _, _ = run('strict', ['--contract=strict'])
    assert strict['unknown_output_samples'] and strict['cycles_executed'] == 2048
    injected, _, fault_dir = run('injected', ['--campaign=architectural', '--inject_failure=pc'], 1)
    same_fault, _, _ = run('injected-replay', ['--campaign=architectural', '--inject_failure=pc', '--journal=full', '--dump_waves=true'], 1)
    assert injected['discrepancies'][0] == same_fault['discrepancies'][0]
    assert injected['injected_failures'] == 1 and injected['field_errors'] == 1
    assert injected['discrepancies'][0]['history'] and 'Replay:' in (fault_dir / 'console.log').read_text()
    assert 'NEW_REPLAY_DIRECTORY' in injected['replay_command'] and '--seed=17' in injected['replay_command']
    obsolete_guards=[]
    for option, value, question in [('early_accept', 'ready', 'Q3'), ('early_target', 'arithmetic', 'Q4')]:
        guard=subprocess.run([str(binary), '--random', '--'+option+'='+value], text=True, capture_output=True)
        assert guard.returncode == 2 and question+' approved' in guard.stderr
        obsolete_guards.append(option+'='+value)
    run('environment-failure', ['--campaign=architectural', '--inject_failure=environment'], 2)
    run('framework-failure', ['--inject_failure=framework'], 2)
    weighted, _, _ = run('custom-weights', ['--weights=normal=5,stall=25,branch=30,early=25,commit=5,overlap=8,reset=2,prediction=75,ready=50'])
    assert 'prediction=75' in weighted['random_configuration']['weights']
    run('unguided', ['--guided=false'])

    # Reconstruct the independently accepted architectural ledger from pre-edge
    # journal records. Never use actual.pc as a stimulus/expected address source.
    samples = [json.loads(line) for line in (directory / 'logs/samples.jsonl').read_text().splitlines()]
    observed = Counter()
    records = {}
    next_id = 1
    epoch = None
    previous_arch = None
    for sample in samples:
        if sample['phase'] != 'pre':
            continue
        i = sample['inputs']
        campaign = sample['campaign']
        row = i['E']*8 + (i['branch_valid'] and i['mispredict'])*4 + i['J']*2+i['P']
        taken = int(bool(row & 4) and i['taken'])
        observed[(campaign, bool(i['rst_n']), row, i['M'], taken)] += 1
        if epoch != sample['epoch']:
            records.clear()
            epoch = sample['epoch']
        if campaign != 'architectural' or not i['rst_n']:
            previous_arch = None
            continue
        assert sum([i['E'], bool(row&4), i['J']]) <= 1
        for qualifier, identity in [('E', 'commit_id'), ('J', 'early_id'), ('branch_valid', 'branch_id')]:
            if not i[qualifier]:
                continue
            record = records[sample[identity]]
            assert sample['cycle']-record['cycle'] >= 2
            if qualifier == 'branch_valid':
                assert int(i['branch_pc'], 16) == record['pc']
                if not i['taken']:
                    displacement = (int(i['branch_target'], 16)-record['pc']) % 2**64
                    displacement = displacement if displacement < 2**63 else displacement-2**64
                    assert -4096 <= displacement <= 4094 and displacement % 4 == 0
            if qualifier == 'J' and sample['early_source'] == 'decoded_jal':
                assert int(i['early_base'], 16) == record['pc']
                offset = int(i['early_offset'], 16)
                offset = offset if offset < 2**63 else offset-2**64
                assert -1048576 <= offset <= 1048574 and offset % 4 == 0
            assert sample['record_age'] == sample['cycle']-record['cycle']
        if previous_arch:
            p = previous_arch['inputs']
            if not p['M'] and not p['E'] and not (p['branch_valid'] and p['mispredict']) and not p['J']:
                # Q8 permits prediction changes. The cursor must still hold
                # unless a higher-priority correction appears at this edge.
                if not i['E'] and not (i['branch_valid'] and i['mispredict']) and not i['J'] and not i['M']:
                    assert sample['next_expected_pc']['value'] == sample['expected']['pc']['value']
            if p['J'] and i['J'] and previous_arch['early_id'] == sample['early_id']:
                assert (p['early_base'], p['early_offset']) == (i['early_base'], i['early_offset'])
        previous_arch = sample
        if sample['ordinary_accepted'] and sample['expected']['pc']['known']:
            pc = int(sample['expected']['pc']['value'], 16)
            # The journal currently records the generated prediction lane below.
            instruction_bytes = first['config']['instruction_bytes']
            bundle_bytes = first['config']['bundle_bytes']
            first_lane = pc % bundle_bytes // instruction_bytes
            last_lane = sample['prediction_lane'] if i['P'] else first['config']['bundle_instructions']-1
            for lane in range(first_lane, last_lane+1):
                records[next_id] = {'pc': (pc//bundle_bytes*bundle_bytes+lane*instruction_bytes) % 2**64, 'cycle': sample['cycle']}
                next_id += 1
        if sample['control_accepted'] and sample['next_expected_pc']['known']:
            identity = sample['commit_id'] if i['E'] else sample['branch_id'] if row&4 else sample['early_id']
            records = {identity_: value for identity_, value in records.items() if identity_ <= identity}
    for campaign, cov in coverage['campaigns'].items():
        for entry in cov['matrix']:
            assert entry['count'] == observed[campaign, True, entry['row'], entry['ready'], entry['taken']]
        for entry in cov['reset_matrix']:
            assert entry['count'] == sum(observed[campaign, False, entry['row'], entry['ready'], t] for t in [0, 1])
    # Independently partition actual edge records into contiguous campaign
    # windows. Other campaigns break consecutive transitions and stall bursts.
    temporal = Counter()
    for campaign, group in groupby((s for s in samples if s['phase']=='pre'), key=lambda s:s['campaign']):
        stalled = 0
        for sample in group:
            ready = sample['inputs']['M']
            stage = ('inside' if stalled else 'onset') if not ready else ('release' if stalled else 'ready')
            temporal[f'V10/{campaign}/{stage}/{sample["selected_event"]}'] += 1
            if not ready:
                stalled += 1
            elif stalled:
                width = first['config']['bundle_instructions']
                length = '1' if stalled==1 else '2' if stalled==2 else '3..N' if stalled<=width else '>N' if stalled<=32 else 'long'
                temporal[f'V10/{campaign}/length/{length}'] += 1
                stalled = 0
    for campaign, group in groupby((s for s in samples if s['phase']=='post'), key=lambda s:s['campaign']):
        def matched(s):
            # Reconstruct checked outcomes from public samples, including real
            # DUT errors. Actual values never establish the expected ledger.
            for field, e in s['expected'].items():
                if e['known']:
                    actual=s['actual'][field]
                    if (int(actual, 16) if isinstance(actual, str) else actual) != int(e['value'], 16):
                        return False
            return s['expected']['pc']['known']
        outcomes = [s['selected_event'] if matched(s) else 'unresolved_or_failing' for s in group]
        for before, after in zip(outcomes, outcomes[1:]):
            temporal[f'V09/{campaign}/{before}->{after}'] += 1
    actual_temporal = {}
    for key, value in coverage['counters'].items():
        parts = key.split('/')
        if len(parts)==4 and parts[0]=='V10' and parts[2] in ['onset','inside','release','ready','length']:
            actual_temporal[key] = value
        elif len(parts)==3 and parts[0]=='V09':
            actual_temporal[key] = value
    assert dict(temporal) == actual_temporal
    print('PASS: contiguous journal windows reproduce stall/transition counters without bridging campaigns')
    regression_output = root / 'incomplete-regression'
    with (root / 'incomplete-regression.log').open('w') as log:
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('regress.py')),
            '--binary', str(binary), '--output', str(regression_output), '--seeds=1', '--cycles=1', '--require-matrix'],
            stdout=log, stderr=subprocess.STDOUT, timeout=60)
    aggregate = json.loads(next(regression_output.glob('*/summary.json')).read_text())
    assert result.returncode == 1 and aggregate['status'] == 'incomplete'
    assert aggregate['coverage_requirement_failed'] and aggregate['totals']['field_errors'] == 0
    assert aggregate['assumptions'] and aggregate['unknown_output_samples']
    print('PASS: aggregate coverage completion detects gaps without classifying a DUT mismatch')
    failed=[r for r in results if r['dut_failure']]
    (root / 'summary.json').write_text(json.dumps({'status': 'framework_checks_passed_dut_failed' if failed else 'passed',
                                                 'dut_failures': failed, 'obsolete_policy_guards': obsolete_guards, 'config': first['config'], 'results': results, 'replay_sha256': digest(directory / 'logs/samples.jsonl'),
                                                 'causal_and_coverage_reconstruction': 'passed', 'synthetic_confidence_checks': 3,
                                                 'synthetic_coverage_configurations': [1, 2, 4, 8]}, indent=2)+'\n')
    print(f'Validation evidence: {root}/summary.json')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
