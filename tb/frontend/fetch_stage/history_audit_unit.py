#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Hand-calculated attribution fixtures, independent of RTL/native predictions."""
import unittest
from history_audit import check_attribution


class AttributionTests(unittest.TestCase):
    def setUp(self):
        counters = [2]*16
        counters[0] = 3
        self.snapshots = {(1, 29): (0x40, 1, counters, 4)}
        self.dispatched = {(1, 36, 0x44): (3, dict(taken=1))}
        self.controls = {(1, 56): (3, 0x44, 2, 3, 2)}
        self.event = dict(instance=1, request_cycle=29, dispatch=36, id=3,
                          pc='0x44', prediction_history=1, prediction_index=0,
                          prediction_counter=3, rewritten=False, update_cycle=56,
                          resolution_history=2, update_index=3, counter_before=2)

    def verify(self, **changes):
        event = dict(self.event, **changes)
        check_attribution(event, self.snapshots, self.dispatched, self.controls)

    def test_valid_different_histories(self):
        self.verify()

    def test_wrong_lookup_index(self):
        with self.assertRaisesRegex(AssertionError, 'snapshot/index'):
            self.verify(prediction_index=1)

    def test_consistent_but_wrong_history(self):
        with self.assertRaisesRegex(AssertionError, 'snapshot/index'):
            self.verify(prediction_history=2, prediction_index=3)

    def test_wrong_dynamic_id(self):
        with self.assertRaisesRegex(AssertionError, 'identity'):
            self.verify(id=2)

    def test_resolution_history_cannot_replace_lookup(self):
        with self.assertRaisesRegex(AssertionError, 'resolution attribution'):
            self.verify(update_index=0)

    def test_public_direction_must_agree(self):
        self.dispatched[(1, 36, 0x44)] = (3, dict(taken=0))
        with self.assertRaisesRegex(AssertionError, 'saved direction'):
            self.verify()

    def test_same_edge_read_is_old_counter(self):
        self.snapshots[(1, 29)] = (0x40, 0, [2]*16, 4)
        self.controls[(1, 29)] = (2, 0x4, 0, 1, 2)  # older A trains on B's lookup edge
        self.controls[(1, 56)] = (3, 0x44, 1, 0, 2)
        self.event.update(prediction_history=0, prediction_index=1,
                          prediction_counter=2, update_cycle=56,
                          resolution_history=1, update_index=0)
        self.verify()
        with self.assertRaisesRegex(AssertionError, 'snapshot/index'):
            self.verify(prediction_counter=3)


if __name__ == '__main__':
    unittest.main()
