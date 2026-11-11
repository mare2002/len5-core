#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/ex-request-selector"}
cd "$repo_root"

sources=(rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv
  rtl/common/rr_arbiter_multi.sv tb/expipe/ex_request_selector_tb.sv)
common_args=(--timing --assert --top-module ex_request_selector_single_tb
  -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
  -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET)

for inputs in ${INPUT_COUNTS:-11}; do
  for outputs in ${OUTPUT_COUNTS:-1 2}; do
    case_dir="$test_build_dir/n$inputs-outputs$outputs"
    mkdir -p "$case_dir"
    args=("${common_args[@]}" "-GN=$inputs" "-GNUM_OUTPUTS=$outputs" "${sources[@]}")
    if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" --lint-only "${args[@]}" > "$case_dir/lint.log" 2>&1; then
      tail -n 12 "$case_dir/lint.log"
      exit 1
    fi
    if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}"         --binary -j 1 --output-split 10000 --output-groups 100         -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0"         --Mdir "$case_dir" "${args[@]}" > "$case_dir/build.log" 2>&1; then
      tail -n 12 "$case_dir/build.log"
      exit 1
    fi
    if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/Vex_request_selector_single_tb" > "$case_dir/run.log" 2>&1; then
      tail -n 12 "$case_dir/run.log"
      exit 1
    fi
    sed -n '/^PASS /p' "$case_dir/run.log"
  done
done
