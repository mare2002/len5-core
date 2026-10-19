#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""pc_gen source-parser/cache policy adapted for the real fetch-memory DUT."""
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
    import re
    rtl = (ROOT/'rtl/frontend/fetch_mem_if.sv').read_text()
    match = re.search(r'parameter\s+int\s+unsigned\s+MAX_MEM_OUTSTANDING_REQUESTS\s*=\s*([^\n,)]+)', rtl)
    if not match:
        raise ValueError('cannot parse production MAX_MEM_OUTSTANDING_REQUESTS default')
    config['metadata_depth'] = literal('localparam int unsigned D = '+match[1]+';', 'D')
    config['request_skip'] = literal((ROOT/'rtl/packages/len5_config_pkg.sv').read_text(), 'FETCH_REQ_SPILL_SKIP')
    config['answer_skip'] = literal((ROOT/'rtl/packages/len5_config_pkg.sv').read_text(), 'FETCH_ANS_SPILL_SKIP')
    config['cause_bits'] = literal((ROOT/'rtl/packages/len5_pkg.sv').read_text(), 'EXCEPT_TYPE_LEN')
    if (config['metadata_depth'],config['request_skip'],config['answer_skip'],config['cause_bits']) != (2,1,0,5):
        raise ValueError('FQ08: initial transport profile supports source depth=2, request bypass, registered answer, 5-bit causes')
    return config


def sources():
    paths = set((ROOT/'rtl/packages').glob('*.sv'))
    paths.update([ROOT/'rtl/packages.core', ROOT/'rtl/misc/packages-waivers.vlt',
                  ROOT/'rtl/frontend/fetch_mem_if.sv', ROOT/'rtl/common/completion_fifo.sv',
                  ROOT/'rtl/common/spill_cell_flush.sv', ROOT/'rtl/common/spill_cell_flush_cu.sv', ROOT/'rtl/common/modn_counter.sv',
                  ROOT/'tb/frontend/early_jump_unit/early_jump_instructions.cpp', ROOT/'tb/frontend/early_jump_unit/early_jump_instructions.hh', ROOT/'tb/verilator/verilator-common.core',
                  ROOT/'tb/verilator/tb_macros.cpp', ROOT/'tb/verilator/tb_macros.hh',
                  ROOT/'tb/frontend/pc_gen/pc_gen_model.cpp', ROOT/'tb/frontend/pc_gen/pc_gen_model.hh',
                  ROOT/'tb/frontend/pc_gen/configuration.py', ROOT/'scripts/sim/check-fetch-mem-if.sh'])
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
    return build.resolve()/'fetch-mem-if/model'/('issues-%d-depth-%d-%s' %
            (config['bundle_instructions'], config['metadata_depth'], config['fingerprint'])), config


def write_manifest(directory, config):
    directory.mkdir(parents=True, exist_ok=True)
    lines = ['%s=%s' % (key,value) for key,value in sorted(config.items())]
    for index,path in enumerate(sources()):
        snapshot = 'fetch_mem_source_%d.snapshot' % index
        destination = directory/snapshot
        if not destination.exists() or destination.read_bytes() != path.read_bytes():
            temporary = directory/(snapshot+'.tmp')
            temporary.write_bytes(path.read_bytes()); temporary.replace(destination)
        lines += ['source_file=%s' % path.resolve(), 'snapshot=%s' % snapshot]
    destination = directory/'fetch_mem_build.cfg'
    text = '\n'.join(lines)+'\n'
    if not destination.exists() or destination.read_text() != text:
        temporary = directory/'fetch_mem_build.cfg.tmp'
        temporary.write_text(text); temporary.replace(destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=Path(os.environ.get('BUILD_DIR', ROOT/'build')))
    parser.add_argument('--binary', action='store_true')
    parser.add_argument('--depth', action='store_true')
    parser.add_argument('--model-dir', action='store_true')
    parser.add_argument('--write-manifest', type=Path)
    parser.add_argument('--expect-fingerprint')
    args = parser.parse_args()
    try:
        model,config = model_directory(args.build_dir)
        if args.expect_fingerprint and args.expect_fingerprint != config['fingerprint']:
            raise ValueError('configuration/source changed during build; rebuild before running')
        if args.depth: print(config['metadata_depth'])
        elif args.write_manifest: write_manifest(args.write_manifest, config)
        elif args.binary: print(model/'sim-verilator/Vfetch_mem_tb')
        elif args.model_dir: print(model)
        else: print(json.dumps(config,sort_keys=True))
    except (ValueError,OSError) as error:
        parser.exit(2,'fetch_mem build/configuration failure: %s\n' % error)


if __name__ == '__main__':
    main()
