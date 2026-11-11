#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/div-metadata"}
cd "$repo_root"
mkdir -p "$test_build_dir"
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
  rtl/expipe/exec-units/serdiv.sv rtl/expipe/exec-units/div.sv tb/expipe/div_metadata_tb.sv
)
args=(--timing --assert --top-module div_metadata_tb +incdir+rtl/packages -Wno-fatal
  -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT)
if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}"     --lint-only "${args[@]}" "${sources[@]}" > "$test_build_dir/lint.log" 2>&1; then
  tail -n 12 "$test_build_dir/lint.log"
  exit 1
fi
if ! timeout -k 5s "${BUILD_TIMEOUT:-120}s" "${VERILATOR:-verilator}"     --binary -j 1 -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir"     "${args[@]}" "${sources[@]}" > "$test_build_dir/build.log" 2>&1; then
  tail -n 12 "$test_build_dir/build.log"
  exit 1
fi
if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$test_build_dir/Vdiv_metadata_tb" > "$test_build_dir/run.log" 2>&1; then
  tail -n 12 "$test_build_dir/run.log"
  exit 1
fi
sed -n '/^PASS /p' "$test_build_dir/run.log"
