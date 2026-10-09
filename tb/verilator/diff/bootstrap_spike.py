#!/usr/bin/env python3
"""Build cached Spike reference libraries from local, pinned sources; never download."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
PIN = '530af85d83781a3dae31a4ace84a573ec255fefa'
LIBRARIES = ('libriscv.a', 'libdisasm.a', 'libsoftfloat.a', 'libfesvr.a')
CONFIGURE_FLAGS = ('--enable-commitlog', '--without-boost', '--without-boost-asio',
                   '--without-boost-regex')


def digest_files(paths):
    """Content identity also detects edits whose timestamps were preserved."""
    digest = hashlib.sha256()
    for path in sorted(set(paths)):
        if path.is_file():
            digest.update(str(path).encode() + b'\0')
            digest.update(path.read_bytes())
            digest.update(b'\0')
    return digest.hexdigest()


def file_signature(path):
    stat = path.stat()
    return [stat.st_size, stat.st_mtime_ns]


def read_state(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def write_state(path, state):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, indent=2) + '\n')
    temporary.replace(path)


def compiler_identity(env):
    result = {}
    for variable, default in [('CC', 'gcc'), ('CXX', 'g++')]:
        command = shlex.split(env.get(variable) or default)
        result[variable] = [shutil.which(command[0]), subprocess.check_output(
            command + ['--version'], env=env, text=True).splitlines()[0]]
    return result


def validate_source(source):
    if not (source / 'configure').is_file():
        raise RuntimeError('Local Spike source is missing: ' + str(source) +
                           '. Restore sw/vendor/riscv-isa-sim or explicitly run '
                           'util/vendor.py -U sw/vendor/riscv-isa-sim.vendor.hjson.')
    if (source / '.git').exists():
        revision = subprocess.check_output(
            ['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    else:
        lock = source.with_name(source.name + '.lock.hjson')
        if not lock.is_file():
            raise RuntimeError('Vendored Spike requires its adjacent .lock.hjson: ' + str(lock))
        # util/vendor.py's lock has one upstream revision. Accept its HJSON
        # spelling and ordinary JSON without a build-time HJSON dependency.
        match = re.search(r'"?rev"?\s*:\s*"?([0-9a-f]{40})\b', lock.read_text())
        revision = match.group(1) if match else None
    if revision != PIN:
        raise RuntimeError('Unsupported Spike revision ' + str(revision) + '; requires ' + PIN)


def ensure_spike(source, build, jobs=4):
    source, build = Path(source).resolve(), Path(build).resolve()
    validate_source(source)
    if source == build or source in build.parents:
        raise RuntimeError('Spike build outputs must be outside the vendored source directory')
    env = os.environ.copy()
    env['CCACHE_DISABLE'] = '1'
    # Old Spike headers relied on a transitive include removed by modern GCC.
    env['CXXFLAGS'] = env.get('CXXFLAGS', '-O2') + ' -include cstdint'
    env['DTC'] = env.get('DTC') or shutil.which('dtc') or shutil.which('false')
    source_files = [p for p in source.rglob('*') if '.git' not in p.relative_to(source).parts]
    configuration = {
        'schema': 1, 'source': str(source), 'revision': PIN,
        'flags': list(CONFIGURE_FLAGS), 'compilers': compiler_identity(env),
        'environment': {k: env.get(k, '') for k in
                        ('CC', 'CXX', 'AR', 'CFLAGS', 'CXXFLAGS', 'CPPFLAGS', 'LDFLAGS', 'DTC')},
        'configure_inputs': digest_files([source / 'configure', source / 'configure.ac',
                                          source / 'config.h.in', source / 'Makefile.in'] +
                                         list(source.rglob('*.mk.in'))),
    }
    inputs = {'configuration': configuration, 'sources': digest_files(source_files)}
    build.mkdir(parents=True, exist_ok=True)
    with (build / '.len5-spike.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp = build / '.len5-spike-build.json'
        previous = read_state(stamp)
        products = [build / name for name in LIBRARIES]
        complete = all(p.is_file() for p in products)
        configured = (build / 'Makefile').is_file() and (build / 'config.h').is_file() and \
            '#define RISCV_ENABLE_COMMITLOG' in (build / 'config.h').read_text()
        outputs = {p.name: file_signature(p) for p in products if p.is_file()}
        if configured and complete and previous.get('inputs') == inputs and \
                previous.get('outputs') == outputs:
            print('Spike libraries up to date: ' + str(build), flush=True)
            return
        reconfigure = not configured or previous.get('inputs', {}).get('configuration') != configuration
        if reconfigure:
            print('Configuring local Spike reference libraries: ' + str(build), flush=True)
            if env['DTC'] == shutil.which('false'):
                print('dtc absent: building libraries only; standalone Spike CLI is not built.', flush=True)
            subprocess.run([str(source / 'configure'), *CONFIGURE_FLAGS], cwd=build, env=env,
                           check=True)
        command = ['make', '-j', str(jobs)]
        # Changed tools/flags or backdated edits cannot rely on timestamps.
        if previous and previous.get('inputs') != inputs:
            command.append('-B')
        subprocess.run(command + list(LIBRARIES), cwd=build, env=env, check=True)
        if '#define RISCV_ENABLE_COMMITLOG' not in (build / 'config.h').read_text():
            raise RuntimeError('Spike must be built with --enable-commitlog')
        if not all(p.is_file() for p in products):
            raise RuntimeError('Spike build did not produce all reference libraries')
        write_state(stamp, {'inputs': inputs,
                           'outputs': {p.name: file_signature(p) for p in products}})
        print('Spike reference libraries ready: ' + str(build), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'sw/vendor/riscv-isa-sim')
    parser.add_argument('--build', type=Path, default=ROOT / 'build/spike-build')
    parser.add_argument('-j', type=int, default=4)
    args = parser.parse_args()
    try:
        ensure_spike(args.source, args.build, args.j)
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
