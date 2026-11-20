#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/lsu-rob-precision"}
cd "$repo_root"
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/common/modn_counter.sv rtl/common/modn_counter_special.sv
  rtl/expipe/issue-unit/issue_decoder.sv rtl/expipe/commit-unit/rob.sv
  tb/expipe/load-store-unit/lsu_rob_precision_tb.sv
)
args=(--timing --assert --top-module lsu_rob_precision_tb +incdir+rtl/packages
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
  -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-SYNCASYNCNET)
for width in ${ISSUE_WIDTHS:-1 4 8}; do
  case_dir="$test_build_dir/w$width"
  mkdir -p "$case_dir"
  config=(-GISSUE_WIDTH="$width" -GROB_DEPTH="${ROB_DEPTH:-16}")
  if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" --lint-only "${args[@]}" "${config[@]}" "${sources[@]}" > "$case_dir/lint.log" 2>&1; then
    tail -n 20 "$case_dir/lint.log"
    exit 1
  fi
  if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$case_dir" "${args[@]}" "${config[@]}" "${sources[@]}" > "$case_dir/build.log" 2>&1; then
    tail -n 20 "$case_dir/build.log"
    exit 1
  fi
  if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/Vlsu_rob_precision_tb" > "$case_dir/run.log" 2>&1; then
    tail -n 20 "$case_dir/run.log"
    exit 1
  fi
  sed -n '/^PASS /p' "$case_dir/run.log"
done
