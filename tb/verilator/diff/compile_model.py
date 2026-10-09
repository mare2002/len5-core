#!/usr/bin/env python3
"""Reuse FuseSoC's manifest and incrementally build the optional checker and Spike."""
import argparse
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
from bootstrap_spike import (LIBRARIES, compiler_identity, digest_files, ensure_spike,
                             file_signature, read_state, write_state)
from layout import generate

ROOT = Path(__file__).resolve().parents[3]


def model_sources():
    paths = list(ROOT.glob('*.core')) + [ROOT / 'makefile', ROOT / 'fusesoc.conf']
    suffixes = {'.core', '.sv', '.svh', '.v', '.vlt', '.cpp', '.hh', '.h', '.py'}
    for directory in ('rtl', 'rtl-vm', 'tb'):
        paths.extend(p for p in (ROOT / directory).rglob('*') if p.suffix in suffixes)
    return paths


def build_model(args):
    args.spike_src = args.spike_src.resolve()
    args.spike_build = args.spike_build.resolve()
    args.build_dir = args.build_dir.resolve()
    version = subprocess.check_output([args.verilator, '--version'], text=True)
    if 'Verilator 5.040' not in version:
        raise RuntimeError('This adapter requires Verilator 5.040 (XML API); found: ' + version.strip())
    ensure_spike(args.spike_src, args.spike_build, args.j)
    env = os.environ.copy()
    env['CCACHE_DISABLE'] = '1'
    inputs = {
        'schema': 1, 'files': digest_files(model_sources()),
        'spike_source': str(args.spike_src), 'spike_build': str(args.spike_build),
        'spike_configuration': digest_files([args.spike_build / 'config.h',
                                            args.spike_build / '.len5-spike-build.json']),
        'libraries': {name: file_signature(args.spike_build / name) for name in LIBRARIES},
        'verilator': [shutil.which(args.verilator), version],
        'fusesoc': [shutil.which(args.fusesoc), subprocess.check_output(
            [args.fusesoc, '--version'], text=True).strip()],
        'fusesoc_flags': args.fusesoc_flags,
        'compilers': compiler_identity(env),
        'environment': {key: env.get(key, '') for key in
                        ('CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS')},
    }
    args.build_dir.mkdir(parents=True, exist_ok=True)
    with (args.build_dir / '.len5-model.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp = args.build_dir / '.len5-model-build.json'
        previous = read_state(stamp)
        model = args.build_dir / 'model/sim-verilator'
        executable = model / 'Vtb_bare'
        if executable.is_file() and (model / 'diff_layout.hh').is_file() and \
                previous.get('inputs') == inputs and \
                previous.get('executable') == file_signature(executable):
            print('Differential simulator up to date: ' + str(executable), flush=True)
            return
        subprocess.run([args.fusesoc, 'run', '--no-export', '--target', 'sim',
                        '--tool', 'verilator', '--setup', '--build-root',
                        str(args.build_dir / 'model'), *shlex.split(args.fusesoc_flags),
                        'polito:len5:len5'], cwd=ROOT, check=True)
        vc = next(model.glob('*.vc'))
        config = (model / 'config.mk').read_text()
        options = shlex.split(next(line.split(':=', 1)[1] for line in config.splitlines()
                                   if line.startswith('VERILATOR_OPTIONS')))
        # Edalize already lists the testbench in the manifest.
        for index in range(len(options) - 1, 0, -1):
            if options[index] == 'len5_tb.cpp':
                del options[index]
        options += ['--vpi', str(ROOT / 'tb/verilator/diff/signals.vlt')]
        subprocess.run([args.verilator, '-f', vc.name, *options, '-Wno-DEPRECATED',
                        '--xml-only'], cwd=model, check=True)
        vpi_words = generate(model / 'Vtb_bare.xml', model / 'diff_layout.hh')
        flags = ['-std=c++17', '-DLEN5_DIFF', '-DVL_VALUE_STRING_MAX_WORDS=' + str(vpi_words),
                 '-I' + str(model), '-I' + str(args.spike_build), '-I' + str(args.spike_src),
                 '-I' + str(args.spike_src / 'riscv'), '-I' + str(args.spike_src / 'softfloat')]
        links = [str(args.spike_build / name) for name in LIBRARIES] + ['-ldl', '-lpthread', '-lz']
        sources = [str(ROOT / 'tb/verilator/diff' / name) for name in
                   ('checker.cpp', 'spike_adapter.cpp', 'monitor.cpp', 'annotate.cpp')]
        subprocess.run([args.verilator, '-f', vc.name, *options, '-CFLAGS', ' '.join(flags),
                        '-LDFLAGS', ' '.join(links), *sources], cwd=model, check=True)
        command = ['make', '-f', 'Vtb_bare.mk', '-j', str(args.j)]
        # Verilator may retain older objects when only toolchain/flags change.
        if previous and previous.get('inputs') != inputs:
            command.append('-B')
        subprocess.run(command, cwd=model, env=env, check=True)
        write_state(stamp, {'inputs': inputs, 'executable': file_signature(executable)})
        print('Differential simulator: ' + str(executable), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--spike-src', type=Path, default=ROOT / 'sw/vendor/riscv-isa-sim')
    parser.add_argument('--spike-build', type=Path, default=ROOT / 'build/spike-build')
    parser.add_argument('--build-dir', type=Path, default=ROOT / 'build/diff')
    parser.add_argument('--fusesoc', default='fusesoc')
    parser.add_argument('--fusesoc-flags', default='')
    parser.add_argument('--verilator', default='verilator')
    parser.add_argument('-j', type=int, default=4)
    args = parser.parse_args()
    try:
        build_model(args)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
