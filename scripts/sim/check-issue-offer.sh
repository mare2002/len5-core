#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/issue-offer"}
cd "$repo_root"
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
  rtl/expipe/issue-unit/issue_decoder.sv rtl/expipe/issue-unit/issue_decode.sv
  rtl/expipe/issue-unit/issue_queue.sv rtl/expipe/issue-unit/issue_dependencies.sv
  rtl/expipe/issue-unit/issue_cu.sv rtl/expipe/issue-unit/issue_stage.sv
  tb/expipe/issue_offer_tb.sv
)
args=(--timing --assert --top-module issue_offer_tb +incdir+rtl/packages
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
  -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-SYNCASYNCNET
  -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT -Werror-SELRANGE)
for width in ${ISSUE_WIDTHS:-1 2 4 8}; do
  for spill in ${DECODE_SPILLS:-0 1}; do
    case_dir="$test_build_dir/w$width-s$spill"
    mkdir -p "$case_dir"
    config=(-GISSUE_WIDTH="$width" -GDECODE_SPILL="$spill")
    if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" --lint-only "${args[@]}" "${config[@]}" "${sources[@]}" > "$case_dir/lint.log" 2>&1; then
      tail -n 25 "$case_dir/lint.log"
      exit 1
    fi
    if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" --Mdir "$case_dir" "${args[@]}" "${config[@]}" "${sources[@]}" > "$case_dir/build.log" 2>&1; then
      tail -n 25 "$case_dir/build.log"
      exit 1
    fi
    if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/Vissue_offer_tb" > "$case_dir/run.log" 2>&1; then
      tail -n 25 "$case_dir/run.log"
      exit 1
    fi
    sed -n '/^PASS /p' "$case_dir/run.log"
  done
done
