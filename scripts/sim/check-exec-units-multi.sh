#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/exec-units-multi"}
cd "$repo_root"

sources=(
rtl/misc/packages-waivers.vlt rtl/misc/common-waivers.vlt rtl/misc/expipe-waivers.vlt
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter.sv
  rtl/common/rr_arbiter_multi.sv
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
  rtl/expipe/exec-units/arith_rs.sv rtl/expipe/exec-units/arith_rs_serial.sv
  rtl/expipe/exec-units/alu.sv rtl/expipe/exec-units/alu_unit.sv
  rtl/expipe/exec-units/mult.sv rtl/expipe/exec-units/sermult.sv rtl/expipe/exec-units/mult_unit.sv
  rtl/expipe/exec-units/serdiv.sv rtl/expipe/exec-units/div.sv rtl/expipe/exec-units/div_unit.sv
  tb/expipe/exec_units_multi_tb.sv
)
common_args=(--timing --assert -Irtl/packages -Wall
  -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM
  -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET)

run_case() {
  local case_name=$1
  local top=$2
  shift 2
  local case_dir="$test_build_dir/$case_name"
  mkdir -p "$case_dir"
  local args=("${common_args[@]}" --top-module "$top" "$@" "${sources[@]}")
  if ! timeout -k 5s "${BUILD_TIMEOUT:-120}s" "${VERILATOR:-verilator}" \
      --lint-only "${args[@]}" > "$case_dir/lint.log" 2>&1; then
    echo "FAIL $case_name: lint failed or timed out; see $case_dir/lint.log" >&2
    tail -n 25 "$case_dir/lint.log"
    return 1
  fi
  if ! timeout -k 5s "${BUILD_TIMEOUT:-120}s" "${VERILATOR:-verilator}" \
      --binary -j 1 -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" \
      --Mdir "$case_dir" "${args[@]}" > "$case_dir/build.log" 2>&1; then
    echo "FAIL $case_name: build failed or timed out; see $case_dir/build.log" >&2
    tail -n 25 "$case_dir/build.log"
    return 1
  fi
  if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/V$top" \
      > "$case_dir/run.log" 2>&1; then
    echo "FAIL $case_name: simulation failed or timed out; see $case_dir/run.log" >&2
    tail -n 15 "$case_dir/run.log"
    return 1
  fi
  sed -n '/^PASS /p' "$case_dir/run.log"
}

if [[ ${EXEC_UNITS_FULL_MATRIX:-false} == true ]]; then
  run_case full-matrix exec_units_multi_matrix_tb
else
  # Small, sequential multiplier/divider checks; no simultaneous model matrix.
  for kind in ${EXEC_KINDS:-1 2 3}; do
    for units in ${UNIT_COUNTS:-1 2}; do
      for rr in ${ARBITRATION_MODES:-0 1}; do
        variant=${EXEC_VARIANT:-1}
        run_case "kind-$kind-units-$units-rr-$rr-variant-$variant" exec_units_multi_tb \
          "-GKIND=$kind" "-GNUM_UNITS=$units" "-GROUND_ROBIN=$rr" "-GVARIANT=$variant"
      done
    done
  done
fi
