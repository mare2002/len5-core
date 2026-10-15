#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Reuse EJU orchestration tests against the fetch-memory suite, without changing EJU."""
import importlib.util
from pathlib import Path
import sys
import suite

spec = importlib.util.spec_from_file_location('reused_eju_suite_checks', Path(__file__).resolve().parent.parent/'early_jump_unit/suite_unit.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)
checks.suite = suite
if __name__ == '__main__':
    try:
        result = checks.main()
    except Exception:
        print('Test failed: fetch_mem_if suite orchestration', flush=True)
        raise
    print('Test successfully passed: fetch_mem_if suite orchestration', flush=True)
    raise SystemExit(result)
