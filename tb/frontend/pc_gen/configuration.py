#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Read the production configuration; never select or rewrite an issue width."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SOURCE = ROOT / 'rtl/packages/len5_config_pkg.sv'
PACKAGES = ROOT / 'rtl/packages/len5_pkg.sv'


def literal(text, name):
    text = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    matches = re.findall(r'\blocalparam\s+[^;=]*\b' + re.escape(name) + r'\s*=\s*([^;]+);', text)
    if len(matches) != 1:
        raise ValueError('configuration requires one localparam definition of ' + name)
    value = matches[0].strip().replace('_', '')
    match = re.fullmatch(r"(?:\d+)?'[sS]?([bBoOdDhH])([0-9a-fA-F]+)", value)
    if match:
        return int(match[2], {'b': 2, 'o': 8, 'd': 10, 'h': 16}[match[1].lower()])
    if re.fullmatch(r'\d+', value):
        return int(value, 10)
    raise ValueError(name + ' must use a supported integer literal; expression is not silently guessed: ' + value)


def configuration(boot=0, source=SOURCE, packages=PACKAGES):
    n = literal(source.read_text(), 'LEN5_MULTIPLE_ISSUES')
    if n not in (1, 2, 4, 8):
        raise ValueError('unsupported LEN5_MULTIPLE_ISSUES=%d; supported values: 1, 2, 4, 8' % n)
    if not 0 <= boot < 2**64:
        raise ValueError('BOOT_PC must be an unsigned 64-bit address')
    text = packages.read_text()
    xlen, alen, ilen = [literal(text, field) for field in ('XLEN', 'ALEN', 'ILEN')]
    if (xlen, alen, ilen) != (64, 64, 32) or literal(source.read_text(), 'LEN5_C_EN'):
        raise ValueError('pc_gen verification supports XLEN=ALEN=64, ILEN=32, C disabled (Q6/Q7)')
    return dict(boot_pc=boot, bundle_instructions=n, instruction_bytes=ilen//8,
                xlen=xlen, alen=alen, issue_bits=n.bit_length()-1,
                instruction_bits=2, bundle_bytes=n*(ilen//8), lwidth=literal(text, 'WWIDTH')*n,
                source=str(source.resolve()))


def fingerprint(config):
    # All compiled sources, package/core definitions and harness headers enter
    # the key. No generated evidence or file timestamps enter it.
    paths = set((ROOT / 'rtl/packages').glob('*.sv'))
    paths.update([ROOT/'rtl/packages.core', ROOT/'rtl/misc/packages-waivers.vlt',
                  ROOT/'rtl/frontend/pc_gen.sv', ROOT/'tb/verilator/verilator-common.core',
                  ROOT/'tb/verilator/tb_macros.cpp', ROOT/'tb/verilator/tb_macros.hh',
                  ROOT/'scripts/sim/check-pc-gen.sh'])
    paths.update(p for p in HERE.iterdir()
                 if p.suffix in ('.cpp', '.hh', '.sv', '.core') and not p.name.endswith('_unit.cpp'))
    paths.add(Path(__file__).resolve())
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes()+b'\0')
    return digest.hexdigest()


def model_directory(build, boot):
    config = configuration(boot)
    config['fingerprint'] = fingerprint(config)
    return build.resolve()/'pc-gen/model'/('boot-%d' % boot)/('issues-%d-%s' % (config['bundle_instructions'], config['fingerprint'])), config


def write_manifest(directory, config):
    directory.mkdir(parents=True, exist_ok=True)
    # Native startup compares these exact production sources to their snapshots,
    # then checks source-derived constants against the elaborated adapter.
    paths = sorted((ROOT/'rtl/packages').glob('*.sv'))
    lines = ['%s=%s' % (k, v) for k, v in sorted(config.items())]
    for index, path in enumerate(paths):
        snapshot = 'pc_gen_package_%d.snapshot' % index
        destination = directory/snapshot
        if not destination.exists() or destination.read_bytes() != path.read_bytes():
            temporary = directory/(snapshot+'.tmp')
            shutil.copyfile(path, temporary)
            temporary.replace(destination)
        lines += ['package=%s' % path.resolve(), 'snapshot=%s' % snapshot]
    manifest = '\n'.join(lines)+'\n'
    destination = directory/'pc_gen_build.cfg'
    if not destination.exists() or destination.read_text() != manifest:
        temporary = directory/'pc_gen_build.cfg.tmp'
        temporary.write_text(manifest)
        temporary.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boot', default=os.environ.get('BOOT_PC', '0'))
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('BUILD_DIR', ROOT/'build')))
    parser.add_argument('--binary', action='store_true')
    parser.add_argument('--model-dir', action='store_true')
    parser.add_argument('--write-manifest', type=Path)
    parser.add_argument('--expect-fingerprint')
    args = parser.parse_args()
    try:
        model, config = model_directory(args.build_dir, int(args.boot, 0))
        if args.expect_fingerprint and args.expect_fingerprint != config['fingerprint']:
            raise ValueError('configuration/source changed during build; rebuild before running')
        if args.write_manifest:
            write_manifest(args.write_manifest, config)
        elif args.binary:
            print(model/'sim-verilator/Vpc_gen_tb')
        elif args.model_dir:
            print(model)
        else:
            print(json.dumps(config, sort_keys=True))
    except (ValueError, OSError) as error:
        parser.exit(2, 'pc_gen build/configuration failure: %s\n' % error)


if __name__ == '__main__':
    main()
