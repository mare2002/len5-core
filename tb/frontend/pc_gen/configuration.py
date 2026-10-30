#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Read elaborated SV configuration and fingerprint the production sources."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SOURCE = ROOT / 'rtl/packages/len5_config_pkg.sv'
PACKAGES = ROOT / 'rtl/packages/len5_pkg.sv'
spec = importlib.util.spec_from_file_location('len5_elaborated_configuration', ROOT/'scripts/gen-memory-map.py')
config_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config_tools)


def rtl_configuration(source=SOURCE):
    return config_tools.elaborated_configuration('rtl', source=source)


def build_arguments(kind='rtl', environ=None, output='fusesoc', exclude=()):
    return config_tools.build_arguments(kind, environ, output, exclude)


def configuration(boot=0, source=SOURCE, packages=PACKAGES):
    selected = rtl_configuration(source)
    n = selected['LEN5_MULTIPLE_ISSUES']
    if n not in (1, 2, 4, 8):
        raise ValueError('unsupported LEN5_MULTIPLE_ISSUES=%d; supported values: 1, 2, 4, 8' % n)
    if not 0 <= boot < 2**64:
        raise ValueError('BOOT_PC must be an unsigned 64-bit address')
    architecture = config_tools.elaborated_configuration('architecture')
    xlen, alen, ilen = [architecture[field] for field in ('XLEN', 'ALEN', 'ILEN')]
    if (xlen, alen, ilen) != (64, 64, 32) or selected['LEN5_C_EN']:
        raise ValueError('pc_gen verification supports XLEN=ALEN=64, ILEN=32, C disabled (Q6/Q7)')
    return dict(boot_pc=boot, bundle_instructions=n, instruction_bytes=ilen//8,
                xlen=xlen, alen=alen, issue_bits=n.bit_length()-1,
                instruction_bits=2, bundle_bytes=n*(ilen//8), lwidth=architecture['WWIDTH']*n,
                source=str(source.resolve()))


def sources():
    # All compiled sources, package/core definitions and harness headers enter
    # the key. No generated evidence or file timestamps enter it.
    paths = set((ROOT / 'rtl/packages').glob('*.sv'))
    paths.update((ROOT/'rtl/packages').glob('*.svh'))
    paths.update([ROOT/'rtl/packages.core', ROOT/'rtl/misc/packages-waivers.vlt',
                  ROOT/'scripts/gen-memory-map.py', ROOT/'scripts/sim/config-args.sh',
                  ROOT/'tb/config/len5_config_probe.sv', ROOT/'tb/tb_bare.sv',
                  ROOT/'tb/packages/tb_config_pkg.sv',
                  ROOT/'rtl/frontend/pc_gen.sv', ROOT/'tb/verilator/verilator-common.core', ROOT/'rtl/frontend.core', ROOT/'rtl/common.core',
                  ROOT/'tb/verilator/tb_macros.cpp', ROOT/'tb/verilator/tb_macros.hh',
                  ROOT/'scripts/sim/check-pc-gen.sh'])
    paths.update(p for p in HERE.iterdir()
                 if p.suffix in ('.cpp', '.hh', '.sv', '.core') and not p.name.endswith('_unit.cpp'))
    paths.add(Path(__file__).resolve())
    return sorted(paths)


def fingerprint(config):
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    digest.update(json.dumps(rtl_configuration(Path(config['source'])), sort_keys=True).encode())
    for path in sources():
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
    paths = sorted([*(ROOT/'rtl/packages').glob('*.sv'), *(ROOT/'rtl/packages').glob('*.svh'),
                    ROOT/'scripts/gen-memory-map.py', ROOT/'scripts/sim/config-args.sh',
                    ROOT/'tb/config/len5_config_probe.sv', ROOT/'tb/tb_bare.sv',
                    ROOT/'tb/packages/tb_config_pkg.sv'])
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
