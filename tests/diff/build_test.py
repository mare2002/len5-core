#!/usr/bin/env python3
"""Regression tests for local Spike dependency caching, using real Make rules."""
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tb/verilator/diff'))
import bootstrap_spike as builder


class DependencyBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='len5-spike-build-test-')
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.source = root / 'spike'
        self.build = root / 'output'
        self.source.mkdir()
        self.lock = root / 'spike.lock.hjson'
        self.lock.write_text(json.dumps({'upstream': {'rev': builder.PIN}}))
        (self.source / 'input.h').write_text('initial')
        (self.source / 'build_one.py').write_text(
            "from pathlib import Path\nimport sys\n"
            "data=Path(sys.argv[1]).read_text()\n"
            "if data=='FAIL': raise SystemExit(1)\n"
            "Path(sys.argv[2]).write_text(data)\n"
            "with Path('build_calls').open('a') as log: log.write(sys.argv[2]+'\\n')\n")
        makefile = ('LIBS = ' + ' '.join(builder.LIBRARIES) + '\nall: $(LIBS)\n' +
                    '%.a: ' + str(self.source / 'input.h') + '\n' +
                    '\t@python3 ' + str(self.source / 'build_one.py') + ' ' +
                    str(self.source / 'input.h') + ' $@\n')
        configure = (
            '#!/usr/bin/env python3\nfrom pathlib import Path\n'
            "with Path('configure_calls').open('a') as log: log.write('configured\\n')\n"
            "Path('config.h').write_text('#define RISCV_ENABLE_COMMITLOG 1\\n')\n"
            "Path('Makefile').write_text(" + repr(makefile) + ')\n')
        (self.source / 'configure').write_text(configure)
        (self.source / 'configure').chmod(0o755)

    def ensure(self):
        with contextlib.redirect_stdout(io.StringIO()):
            builder.ensure_spike(self.source, self.build, jobs=2)

    def configure_count(self):
        return len((self.build / 'configure_calls').read_text().splitlines())

    def test_first_build_and_repeated_build_does_nothing(self):
        self.ensure()
        before = {name: builder.file_signature(self.build / name) for name in builder.LIBRARIES}
        with mock.patch.object(builder.subprocess, 'run', wraps=subprocess.run) as run:
            self.ensure()
            # Python versions may implement check_output through run; compiler
            # version queries are expected, configure and Make are not.
            commands = [call.args[0] for call in run.call_args_list]
            self.assertTrue(all(command[-1] == '--version' for command in commands))
        self.assertEqual(self.configure_count(), 1)
        self.assertEqual(before, {name: builder.file_signature(self.build / name)
                                  for name in builder.LIBRARIES})

    def test_backdated_header_change_rebuilds_without_reconfigure(self):
        self.ensure()
        header = self.source / 'input.h'
        header.write_text('changed')
        os.utime(header, (1, 1))
        self.ensure()
        self.assertEqual(self.configure_count(), 1)
        for name in builder.LIBRARIES:
            self.assertEqual((self.build / name).read_text(), 'changed')

    def test_deleted_library_is_restored(self):
        self.ensure()
        (self.build / builder.LIBRARIES[0]).unlink()
        self.ensure()
        self.assertEqual(self.configure_count(), 1)
        self.assertTrue(all((self.build / name).is_file() for name in builder.LIBRARIES))

    def test_changed_flags_reconfigure_and_rebuild(self):
        self.ensure()
        with mock.patch.dict(os.environ, {'CXXFLAGS': '-O0 -g'}):
            self.ensure()
        self.assertEqual(self.configure_count(), 2)
        self.assertEqual(len((self.build / 'build_calls').read_text().splitlines()), 8)

    def test_changed_configuration_input_reconfigures(self):
        self.ensure()
        (self.source / 'config.h.in').write_text('new configure input')
        self.ensure()
        self.assertEqual(self.configure_count(), 2)

    def test_missing_commit_logging_is_reconfigured(self):
        self.ensure()
        (self.build / 'config.h').write_text('/* commit logging disabled */')
        self.ensure()
        self.assertEqual(self.configure_count(), 2)
        self.assertIn('#define RISCV_ENABLE_COMMITLOG', (self.build / 'config.h').read_text())

    def test_failed_build_does_not_record_success(self):
        self.ensure()
        stamp = self.build / '.len5-spike-build.json'
        previous = stamp.read_text()
        (self.source / 'input.h').write_text('FAIL')
        with self.assertRaises(subprocess.CalledProcessError):
            self.ensure()
        self.assertEqual(stamp.read_text(), previous)
        (self.source / 'input.h').write_text('recovered')
        self.ensure()
        self.assertEqual((self.build / builder.LIBRARIES[0]).read_text(), 'recovered')

    def test_wrong_pin_is_rejected(self):
        self.lock.write_text(json.dumps({'upstream': {'rev': '0' * 40}}))
        with self.assertRaisesRegex(RuntimeError, 'Unsupported Spike revision'):
            self.ensure()
        self.assertFalse(self.build.exists())

    def test_missing_source_never_downloads(self):
        self.source = self.source / 'absent'
        with mock.patch.object(builder.subprocess, 'run') as run:
            with self.assertRaisesRegex(RuntimeError, 'Local Spike source is missing'):
                self.ensure()
            run.assert_not_called()

    def test_build_inside_vendor_tree_is_rejected(self):
        self.build = self.source / 'build'
        with self.assertRaisesRegex(RuntimeError, 'outside the vendored source'):
            self.ensure()


if __name__ == '__main__':
    unittest.main(verbosity=2)
