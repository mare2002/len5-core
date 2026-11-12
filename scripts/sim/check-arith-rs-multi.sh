#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/arith-rs-multi"}
cd "$repo_root"

sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter.sv
  rtl/common/rr_arbiter_multi.sv
  rtl/common/rs_alloc_fifo.sv
  rtl/expipe/exec-units/arith_rs.sv rtl/expipe/exec-units/arith_rs_fpu.sv
  tb/expipe/arith_rs_multi_tb.sv
)
common_args=(--timing --assert --top-module arith_rs_single_tb +incdir+rtl/packages
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
  -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-SYNCASYNCNET)

# Larger unit counts are explicit; every configuration gets its own serial build.
for units in ${UNIT_COUNTS:-1 2}; do
  for rr in ${ARBITRATION_MODES:-0 1}; do
    for fpu in ${FPU_MODES:-0 1}; do
      case_dir="$test_build_dir/n$units-rr$rr-fpu$fpu"
      mkdir -p "$case_dir"
      args=("${common_args[@]}" "-GNUM_UNITS=$units" "-GRR=$rr" "-GFPU=$fpu" "${sources[@]}")
      if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" --lint-only "${args[@]}" > "$case_dir/lint.log" 2>&1; then
        tail -n 12 "$case_dir/lint.log"
        exit 1
      fi
      if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}"           --binary -j 1 --output-split 10000 --output-groups 100           -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0"           --Mdir "$case_dir" "${args[@]}" > "$case_dir/build.log" 2>&1; then
        tail -n 12 "$case_dir/build.log"
        exit 1
      fi
      if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/Varith_rs_single_tb" > "$case_dir/run.log" 2>&1; then
        tail -n 12 "$case_dir/run.log"
        exit 1
      fi
      sed -n '/^PASS /p' "$case_dir/run.log"
    done
  done
done
