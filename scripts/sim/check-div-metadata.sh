#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/div-metadata"}
cd "$repo_root"
mkdir -p "$test_build_dir"
"${VERILATOR:-verilator}" --binary --timing --assert -j "${JOBS:-1}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir" \
  --top-module div_metadata_tb +incdir+rtl/packages -Wno-fatal \
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv \
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv \
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv \
  rtl/vendor/pulp-common-cells/src/lzc.sv \
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv \
  rtl/expipe/exec-units/serdiv.sv rtl/expipe/exec-units/div.sv tb/expipe/div_metadata_tb.sv \
  > "$test_build_dir/build.log" 2>&1 || { tail -n 25 "$test_build_dir/build.log"; exit 1; }
"$test_build_dir/Vdiv_metadata_tb"
