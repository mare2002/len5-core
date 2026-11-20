#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
test_build_dir=${BUILD_DIR:-"$repo_root/build/lsu-issue-route"}
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter_multi.sv
  rtl/common/rs_alloc_fifo.sv rtl/common/sign_extender.sv rtl/common/byte_selector.sv
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
  rtl/expipe/load-store-unit/address_adder.sv rtl/expipe/load-store-unit/load_buffer.sv
  rtl/expipe/load-store-unit/store_buffer.sv rtl/expipe/load-store-unit/load_store_unit.sv
  tb/expipe/load-store-unit/lsu_issue_route_tb.sv
)
# Common LSU width:load width:store width, including non-power-of-two issue widths.
matrix=${ROUTE_CASES:-"1:1:1 2:2:1 2:1:2 3:3:2 3:2:3 4:4:1 4:1:4 4:2:2 4:2:1 4:3:2 4:2:3 4:1:1 8:8:1 8:1:8 8:4:2 8:2:4 8:1:1"}
for spec in $matrix; do
  IFS=: read -r width lb_width sb_width <<< "$spec"
  for fifo in 0 1; do
    case_dir="$test_build_dir/${spec//:/-}-fifo$fifo"
    mkdir -p "$case_dir"
    args=(--timing --assert --top-module lsu_issue_route_tb +incdir+rtl/packages
      -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
      -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-PROCASSINIT
      "-GLSU_WIDTH=$width" "-GLB_WIDTH=$lb_width" "-GSB_WIDTH=$sb_width" "-GFIFO=$fifo" "${sources[@]}")
    if ! timeout -k 5s 180s "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" --Mdir "$case_dir" \
        -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" "${args[@]}" > "$case_dir/build.log" 2>&1; then
      tail -60 "$case_dir/build.log"; exit 1
    fi
    if ! timeout -k 5s 30s "$case_dir/Vlsu_issue_route_tb" > "$case_dir/run.log" 2>&1; then
      cat "$case_dir/run.log"; exit 1
    fi
    sed -n '/^PASS /p' "$case_dir/run.log"
  done
done
