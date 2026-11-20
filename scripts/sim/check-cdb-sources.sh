#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/cdb-sources"}
cd "$repo_root"
mkdir -p "$test_build_dir"
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
  rtl/common/prio_enc.sv
  rtl/expipe/cdb/cdb_arbiter.sv rtl/expipe/cdb/cdb.sv tb/expipe/cdb_sources_tb.sv
)
args=(--timing --assert --top-module cdb_sources_tb +incdir+rtl/packages
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
  -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-SYNCASYNCNET
  -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT -Werror-SELRANGE)
if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" --lint-only "${args[@]}" "${sources[@]}" > "$test_build_dir/lint.log" 2>&1; then
  tail -n 25 "$test_build_dir/lint.log"
  exit 1
fi
if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" --Mdir "$test_build_dir" "${args[@]}" "${sources[@]}" > "$test_build_dir/build.log" 2>&1; then
  tail -n 25 "$test_build_dir/build.log"
  exit 1
fi
if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$test_build_dir/Vcdb_sources_tb" > "$test_build_dir/run.log" 2>&1; then
  tail -n 25 "$test_build_dir/run.log"
  exit 1
fi
sed -n '/^PASS /p' "$test_build_dir/run.log"
