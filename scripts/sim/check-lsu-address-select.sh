#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
test_build_dir=${BUILD_DIR:-"$repo_root/build/lsu-address-select"}
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv
  rtl/packages/expipe_pkg.sv rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv
  rtl/common/rr_arbiter_multi.sv rtl/common/sign_extender.sv rtl/common/byte_selector.sv
  rtl/expipe/load-store-unit/load_buffer.sv rtl/expipe/load-store-unit/store_buffer.sv
  tb/expipe/load-store-unit/lsu_address_select_tb.sv
)
for depth in ${ADDRESS_DEPTHS:-1 2 4 8}; do
  for rr in 0 1; do
    case_dir="$test_build_dir/depth-$depth-rr-$rr"
    mkdir -p "$case_dir"
    args=(--timing --assert --top-module lsu_address_select_tb +incdir+rtl/packages
      -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
      -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-PROCASSINIT
      "-GDEPTH=$depth" "-GADDR_RR=$rr" "${sources[@]}")
    if ! timeout -k 5s 180s "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" --Mdir "$case_dir" \
        -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" "${args[@]}" > "$case_dir/build.log" 2>&1; then
      tail -60 "$case_dir/build.log"; exit 1
    fi
    if ! timeout -k 5s 30s "$case_dir/Vlsu_address_select_tb" > "$case_dir/run.log" 2>&1; then
      cat "$case_dir/run.log"; exit 1
    fi
    sed -n '/^PASS /p' "$case_dir/run.log"
  done
done
