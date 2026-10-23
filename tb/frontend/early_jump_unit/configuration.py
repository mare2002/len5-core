#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""pc_gen source-parser/cache policy adapted for the real early-jump/RAS DUT."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('pc_gen_source_configuration', HERE.parent/'pc_gen/configuration.py')
pc_config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc_config)
literal = pc_config.literal  # Reuse the existing production-literal parser unchanged.


def configuration():
    config = pc_config.configuration(0)
    config.pop('boot_pc')
    config['ras_depth'] = literal((ROOT/'rtl/packages/len5_config_pkg.sv').read_text(), 'RAS_DEPTH')
    if config['ras_depth'] != 4:
        raise ValueError('initial RAS verification supports source-selected RAS_DEPTH=4 only (EQ09)')
    return config


def sources():
    paths = set((ROOT/'rtl/packages').glob('*.sv'))
    paths.update([ROOT/'rtl/packages.core', ROOT/'rtl/misc/packages-waivers.vlt',
                  ROOT/'rtl/frontend/early_jump_unit.sv', ROOT/'rtl/frontend/ras.sv',
                  ROOT/'rtl/common/prio_enc.sv', ROOT/'tb/verilator/verilator-common.core', ROOT/'rtl/frontend.core', ROOT/'rtl/common.core',
                  ROOT/'tb/verilator/tb_macros.cpp', ROOT/'tb/verilator/tb_macros.hh',
                  ROOT/'tb/frontend/pc_gen/pc_gen_model.cpp', ROOT/'tb/frontend/pc_gen/pc_gen_model.hh',
                  ROOT/'tb/frontend/pc_gen/configuration.py', ROOT/'scripts/sim/check-early-jump.sh'])
    paths.update(p for p in HERE.iterdir() if p.suffix in ('.cpp', '.hh', '.sv', '.core', '.vlt') and not p.name.endswith('_unit.cpp'))
    paths.add(Path(__file__).resolve())
    return sorted(paths)


def fingerprint(config):
    digest = hashlib.sha256(json.dumps(config, sort_keys=True).encode())
    for path in sources():
        digest.update(str(path.relative_to(ROOT)).encode()+b'\0'+path.read_bytes()+b'\0')
    return digest.hexdigest()


def model_directory(build):
    config = configuration()
    config['fingerprint'] = fingerprint(config)
    return build.resolve()/'early-jump/model'/('issues-%d-ras-%d-%s' %
            (config['bundle_instructions'], config['ras_depth'], config['fingerprint'])), config


def write_manifest(directory, config):
    directory.mkdir(parents=True, exist_ok=True)
    lines = ['%s=%s' % (key,value) for key,value in sorted(config.items())]
    for index,path in enumerate(sources()):
        snapshot = 'early_jump_source_%d.snapshot' % index
        destination = directory/snapshot
        if not destination.exists() or destination.read_bytes() != path.read_bytes():
            temporary = directory/(snapshot+'.tmp')
            temporary.write_bytes(path.read_bytes()); temporary.replace(destination)
        lines += ['source_file=%s' % path.resolve(), 'snapshot=%s' % snapshot]
    destination = directory/'early_jump_build.cfg'
    text = '\n'.join(lines)+'\n'
    if not destination.exists() or destination.read_text() != text:
        temporary = directory/'early_jump_build.cfg.tmp'
        temporary.write_text(text); temporary.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('BUILD_DIR', ROOT/'build')))
    parser.add_argument('--binary', action='store_true')
    parser.add_argument('--model-dir', action='store_true')
    parser.add_argument('--write-manifest', type=Path)
    parser.add_argument('--expect-fingerprint')
    args = parser.parse_args()
    try:
        model,config = model_directory(args.build_dir)
        if args.expect_fingerprint and args.expect_fingerprint != config['fingerprint']:
            raise ValueError('configuration/source changed during build; rebuild before running')
        if args.write_manifest: write_manifest(args.write_manifest, config)
        elif args.binary: print(model/'sim-verilator/Vearly_jump_tb')
        elif args.model_dir: print(model)
        else: print(json.dumps(config,sort_keys=True))
    except (ValueError,OSError) as error:
        parser.exit(2,'early_jump build/configuration failure: %s\n' % error)


if __name__ == '__main__':
    main()
