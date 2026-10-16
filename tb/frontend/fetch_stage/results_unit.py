#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Synthetic orchestration fixtures; no RTL or real FE-T54 evidence claimed."""
import copy
import hashlib
import json
import tempfile
import io
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch
import results as r
import confidence
import catalog


def case(status=r.PASS, scenario='FE-T01', variant=0, **kw):
    return dict(scenario=scenario, variant=variant, verification_status=status,
                comparisons=20, field_errors=int(status==r.MISMATCH), missing_witnesses=[],
                reason='synthetic fixture', **kw)


def run(cases, code=0, **kw):
    return dict(exit=code,artifacts='fixture-only',report=dict(scenarios=cases,
                field_checks=sum(c['comparisons'] for c in cases),
                field_errors=sum(c['field_errors'] for c in cases),exit_status=code,
                environment_errors=0,framework_errors=0,strict_completion=False,**kw))


class Policy(unittest.TestCase):
    def verdict(self, cases, expected, strict=False):
        s=r.aggregate(cases,strict);self.assertEqual(s['exit_status'],expected);return s
    def test_all_pass(self):self.assertTrue(self.verdict([case()],0)['specification_complete'])
    def test_deferred(self):
        s=self.verdict([case(),case(r.INCOMPLETE,'FE-T48')],0)
        self.assertEqual(s['deferred_incomplete'],1);self.assertFalse(s['specification_complete'])
    def test_unexpected(self):self.assertEqual(self.verdict([case(r.INCOMPLETE)],0)['unexpected_incomplete'],1)
    def test_only_incomplete_useful(self):self.assertEqual(self.verdict([case(r.INCOMPLETE)],0)['status'],'incomplete')
    def test_strict(self):self.verdict([case(r.INCOMPLETE)],3,True);self.verdict([case()],0,True)
    def test_mismatch(self):self.verdict([case(r.MISMATCH)],1)
    def test_mismatch_incomplete(self):self.verdict([case(r.MISMATCH),case(r.INCOMPLETE)],1)
    def test_environment(self):self.verdict([case(r.ENVIRONMENT),case(r.INCOMPLETE)],2)
    def test_environment_with_comparison_failure(self):
        a=run([dict(case(r.ENVIRONMENT),field_errors=1)],2)
        a['report']['environment_errors']=1
        cs=r.native_cases(a);self.assertEqual(cs[0]['verification_status'],r.ENVIRONMENT)
        self.verdict(cs,2)
    def test_precedence(self):self.verdict([case(r.ENVIRONMENT),case(r.MISMATCH)],2,True)
    def test_composite_and_deferred(self):self.verdict([case(scenario='FE-T54'),case(r.INCOMPLETE,'FE-T48')],0)
    def test_missing_case(self):self.verdict(r.native_cases(run([case()]),[('FE-T01',0),('FE-T02',0)]),2)
    def test_duplicate_case(self):self.verdict(r.native_cases(run([case(),case()]),[('FE-T01',0)]),2)
    def test_variants(self):
        s=self.verdict([case(scenario='FE-T02'),case(r.INCOMPLETE,'FE-T02',1)],0)
        self.assertEqual(s['scenario_count'],1);self.assertEqual(s['variant_counts'],{r.PASS:1,r.INCOMPLETE:1})
    def test_empty(self):self.verdict([],2);self.verdict([dict(case(),comparisons=0)],2)
    def test_clean_budget(self):self.verdict(r.native_cases(run([case(r.INCOMPLETE)])),0)
    def test_crash(self):self.verdict(r.native_cases(run([case()],-6)),2)
    def test_watchdog(self):self.verdict(r.native_cases(run([case()],124)),2)
    def test_absent_report(self):self.verdict(r.native_cases(dict(exit=0)),2)
    def test_exit_disagreement(self):self.verdict(r.native_cases(run([case()],3)),2)
    def test_field_cannot_be_hidden(self):
        a=run([dict(case(r.INCOMPLETE),field_errors=1)])
        a['report']['field_errors']=1;a['exit']=a['report']['exit_status']=1
        self.verdict(r.native_cases(a),1)
    def test_inferred_provenance_no_waiver(self):
        a=run([dict(case(r.PROVISIONAL),field_errors=1)],1)
        a['report']['field_errors']=1;a['report']['discrepancies']=[{'evidence':'I'}]
        self.verdict(r.native_cases(a),1)
    def test_provisional(self):self.verdict([case(r.PROVISIONAL)],0);self.verdict([case(r.PROVISIONAL)],3,True)
    def test_wrong_fingerprint(self):self.verdict(r.native_cases(run([case()],config={'fingerprint':'old'}),config={'fingerprint':'new'}),2)
    def test_malformed_counters(self):
        a=run([case()]);a['report']['field_checks']='20';self.verdict(r.native_cases(a),2)
    def test_comparison_conservation(self):
        a=run([case()]);a['report']['field_checks']+=1;self.verdict(r.native_cases(a),2)
    def test_watchdog_exception(self):
        with patch.object(subprocess,'run',side_effect=subprocess.TimeoutExpired('synthetic',1)):
            log=io.StringIO();self.assertEqual(r.process(['synthetic'],log),124);self.assertIn('FAIL_FRAMEWORK',log.getvalue())
    def test_default_and_override_flags(self):
        import run as runner
        with patch.dict('os.environ',{},clear=True):
            fs=runner.flags(Path('synthetic'));self.assertIn('--strict_completion=false',fs)
            self.assertFalse(any(f.startswith('--exec_') for f in fs))
        with patch.dict('os.environ',{'STRICT_COMPLETION':'true','EXEC_LATENCY_MAX':'31'},clear=True):
            fs=runner.flags(Path('synthetic'));self.assertIn('--strict_completion=true',fs);self.assertIn('--exec_latency_max=31',fs)


class Receipts(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.binary=self.root/'binary';self.binary.touch()
        (self.root/'fetch_stage_build.cfg').write_text('synthetic fixture only\n')
        self.receipt=self.root/'FE-T54';self.receipt.mkdir()
        self.config={'LEN5_MULTIPLE_ISSUES':2,'fingerprint':'synthetic-only'}
        self.runs=[]
        for label in sorted(confidence.VALIDATORS):
            e=0 if label in ('baseline','replay','waves','backend-real-rejections') else 1 if label.startswith('inject-') or label=='cause-zero' else 3 if label in ('timeout','missing-training-witness','unknown-dependent') else 2
            c=[r.PASS,r.MISMATCH,r.FRAMEWORK if label=='empty' else r.ENVIRONMENT,r.INCOMPLETE][e]
            p=self.receipt/label/'logs';p.mkdir(parents=True)
            report={'exit_status':e,'verification_status':c,'field_checks':20,'updates':1,'injected_failures':int(e==1),
                    'discrepancies':[{'field':'lane[0].cause' if label=='cause-zero' else 'synthetic'}] if e==1 else [],
                    'scenarios':[dict(case(c),missing_witnesses=['jal-cold-to-warm'] if label=='missing-training-witness' else [])]}
            r.write_summary(p/'report.json',report)
            self.runs.append(dict(label=label,exit=e,expected_exit=e,expected_verification_status=c,validator_status='PASS',report=report,artifacts=str(p.parent)))
        for label in ('unit','unit-pc-gen','unit-early-jump','unit-fetch-mem'):(self.receipt/(label+'.log')).write_text('PASS: synthetic fixture\n')
        self.summary=dict(status='passed',units_executed=True,binary=str(self.binary),config=self.config,runs=self.runs,
                          manifest_sha256=hashlib.sha256((self.root/'fetch_stage_build.cfg').read_bytes()).hexdigest())
        self.save()
    def save(self):r.write_summary(self.receipt/'summary.json',self.summary)
    def validate(self):return confidence.validate_receipt(self.receipt,self.binary,self.config)
    def test_receipt(self):self.assertEqual(self.validate()['validators'],24)
    def test_missing_validator(self):
        self.summary['runs'].pop();self.save()
        with self.assertRaises(AssertionError):self.validate()
    def test_negative_did_not_detect(self):
        x=next(x for x in self.runs if x['label']=='inject-pc');x['exit']=0;self.save()
        with self.assertRaises(AssertionError):self.validate()
    def test_missing_evidence(self):
        (self.receipt/'baseline/logs/report.json').unlink()
        with self.assertRaises(OSError):self.validate()
    def test_stale_receipt(self):
        (self.root/'fetch_stage_build.cfg').write_text('changed')
        with self.assertRaises(AssertionError):self.validate()
    def test_units_not_run(self):
        self.summary['units_executed']=False;self.save()
        with self.assertRaises(AssertionError):self.validate()
    def test_wrong_failure_kind(self):
        x=next(x for x in self.runs if x['label']=='invalid-feedback')
        x['report']['verification_status']=r.FRAMEWORK
        r.write_summary(Path(x['artifacts'])/'logs/report.json',x['report']);self.save()
        with self.assertRaises(AssertionError):self.validate()
    def test_missing_training_negative(self):
        x=next(x for x in self.runs if x['label']=='missing-training-witness');self.assertEqual(x['report']['verification_status'],r.INCOMPLETE);self.validate()
    def test_merge_preserves_deferred(self):
        # Full N2 catalog manifest, including every variant exactly once.
        cs=[case(r.INCOMPLETE if s in ('FE-T48','FE-T54') else r.PASS,s,v)
            for s in ('FE-T%02d'%i for i in range(1,55)) for v in r.variants(s,2)]
        report=run(cs,config=self.config)['report']
        d=self.root/'catalog';(d/'logs').mkdir(parents=True);r.write_summary(d/'logs/report.json',report)
        with patch.object(catalog,'execute',return_value=self.summary),patch.object(catalog,'validate_receipt',return_value=self.validate()),patch.object(r,'binary_config',return_value=self.config),patch.dict('os.environ',{'STRICT_COMPLETION':'false'}):
            self.assertEqual(catalog.complete(self.binary,d,0),0)
        merged=json.loads((d/'logs/report.json').read_text())
        self.assertEqual(next(c for c in merged['scenarios'] if c['scenario']=='FE-T54')['verification_status'],r.PASS)
        self.assertEqual(next(c for c in merged['scenarios'] if c['scenario']=='FE-T48')['verification_status'],r.INCOMPLETE)
        self.assertFalse(merged['specification_complete'])


if __name__=='__main__':unittest.main()
