#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Audit attributed branch histories; compare policies on the SAME feedback trace.

Policy B is counterfactual saved-index training, not the production oracle and
not a closed-loop prediction-accuracy experiment. GHR/index/counter values are
independent model quantities; public accepted metadata is their external witness.
"""
import argparse
import json
from pathlib import Path


def public_histories(directory, hlen):
    """Reconstruct from public pins, without native golden-PC/ID/state fields."""
    snapshots, dispatched, controls = {}, {}, {}
    history, counters, instance, dynamic = 0, [2]*(1 << hlen), None, 0
    for sample in map(json.loads, (directory/'logs/samples.jsonl').open()):
        if sample['phase'] != 'pre':
            continue
        inputs, actual = sample['inputs'], sample['actual']
        cycle, current = sample['cycle'], sample['instance']
        if current != instance or inputs['reset']:
            instance, history, counters, dynamic = current, 0, [2]*(1 << hlen), 0
            if inputs['reset']:
                continue
        # Save reads BEFORE this edge's training, including read/write overlap.
        if actual['request'] and inputs['grant']:
            snapshots[(current, cycle)] = (int(actual['address'], 16), history,
                                            counters.copy(), len(inputs['words']))
        if actual['valid'] and inputs['ready'] and not inputs['flush']:
            for lane, payload in enumerate(actual['bundle']['lanes']):
                if actual['bundle']['mask'] >> lane & 1:
                    dynamic += 1
                    dispatched[(current, cycle, int(payload['pc'], 16))] = (dynamic, payload)
        if inputs['flush_bpu']:
            history, counters = 0, [2]*(1 << hlen)
        elif inputs['train']:
            pc = int(inputs['res_pc'], 16)
            index = history ^ ((pc//4) & ((1 << hlen)-1))
            controls[(current, cycle)] = (inputs['feedback_id'], pc, history, index, counters[index])
            counters[index] = max(0, min(3, counters[index] + (1 if inputs['res_taken'] else -1)))
            history = ((history << 1) | inputs['res_taken']) & ((1 << hlen)-1)
    return snapshots, dispatched, controls


def check_attribution(event, snapshots, dispatched, controls, hlen=4):
    pc = int(event['pc'], 16)
    base, history, counters, lanes = snapshots[(event['instance'], event['request_cycle'])]
    index = history ^ ((pc//4) & ((1 << hlen)-1))
    assert base <= pc < base + 4*lanes, 'wrong request/source PC association'
    assert (event['prediction_history'], event['prediction_index'], event['prediction_counter']) == (
        history, index, counters[index]), 'wrong prediction-time snapshot/index'
    dynamic, payload = dispatched[(event['instance'], event['dispatch'], pc)]
    assert dynamic == event['id'], 'wrong dynamic branch identity'
    if not event['rewritten']:
        assert payload['taken'] == (counters[index] >= 2), 'wrong public saved direction'
    assert controls[(event['instance'], event['update_cycle'])] == (
        dynamic, pc, event['resolution_history'], event['update_index'], event['counter_before']), 'wrong resolution attribution'


def audit(directory, hlen=4):
    events = [json.loads(line) for line in (directory/'logs/training.jsonl').open()]
    updates = [e for e in events if e['event'] == 'history-attribution']
    if not updates:
        raise AssertionError('no attributed updates')
    public = public_histories(directory, hlen)
    a, b, history, window = [], [], 0, None
    rows, candidates = [], []
    for e in updates:
        check_attribution(e, *public, hlen)
        key = (e['instance'], e.get('window', 0))
        if key != window:
            a, b, history, window = [2]*(1 << hlen), [2]*(1 << hlen), 0, key
        idx = history ^ ((int(e['pc'], 16)//4) & ((1 << hlen)-1))
        assert history == e['resolution_history'] and idx == e['update_index'], e
        assert (e['prediction_history'] ^ ((int(e['pc'], 16)//4) & ((1 << hlen)-1))) == e['prediction_index'], e
        assert a[idx] == e['counter_before'], e
        before_b = b[e['prediction_index']]
        change = 1 if e['taken'] else -1
        a[idx] = max(0, min(3, a[idx] + change))
        b[e['prediction_index']] = max(0, min(3, before_b + change))
        assert a[idx] == e['counter_after'] and a[e['prediction_index']] == e['lookup_counter_after'], e
        history = ((history << 1) | e['taken']) & ((1 << hlen)-1)
        row = dict(e, policy_A='resolution-indexed-gshare-v1', policy_B='saved-index-experiment',
                   policy_B_before=before_b, policy_B_after=b[e['prediction_index']],
                   differing_entries=[i for i in range(len(a)) if a[i] != b[i]])
        rows.append(row)
        if e['index_differs']:
            older = [o for o in rows[:-1] if (o['instance'], o.get('window', 0)) == key
                     and o['id'] < e['id'] and not o['mispredict']
                     and e['request_cycle'] < o['update_cycle'] < e['update_cycle']]
            if older:
                candidates.append(dict(older=older[-1], younger=row))
    result = dict(policy_B_scope='fixed feedback trace; no alternative RTL/performance claim',
                  public_attributions_verified=len(rows),
                  updates=len(rows), distinct_lookup_update=sum(e['index_differs'] for e in rows),
                  legal_overlapping_correct_older=len(candidates),
                  first_two_inflight=candidates[0] if candidates else None,
                  threshold_witnesses=[e for e in events if e['event'] == 'public-threshold-witness'],
                  rows=rows)
    (directory/'history-policy-comparison.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--hlen', type=int, default=4)
    args = parser.parse_args()
    result = audit(args.directory, args.hlen)
    print(json.dumps({k: v for k, v in result.items() if k != 'rows'}, indent=2))
