#!/usr/bin/env bash
set -euo pipefail
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"
test_build_dir=${BUILD_DIR:-"$repo_root/build/lsu-redesign"}
sources=(
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter_multi.sv rtl/common/rs_alloc_fifo.sv
  rtl/common/sign_extender.sv rtl/common/byte_selector.sv rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
  rtl/expipe/load-store-unit/address_adder.sv rtl/expipe/load-store-unit/load_buffer.sv
  rtl/expipe/load-store-unit/store_buffer.sv rtl/expipe/load-store-unit/load_store_unit.sv
  tb/expipe/load-store-unit/lsu_redesign_tb.sv
)
# IW:LSU_WIDTH:LQ:SQ:FIFO:FWD:ALIGNED_READ:SPILL:DRAIN[:LB_WIDTH:SB_WIDTH]
matrix=${LSU_CASES:-"1:1:1:1:0:1:0:1:1 2:2:2:2:0:1:0:0:1 4:4:4:4:0:1:0:1:1 8:8:8:8:0:1:0:0:1 4:4:4:8:0:1:0:0:1 4:4:4:4:1:1:0:0:1 8:4:4:8:1:1:0:1:1 8:4:4:8:0:1:0:1:1 2:2:4:2:0:0:0:1:1 4:4:4:4:0:1:1:0:1 2:2:2:2:0:1:0:1:0 2:2:2:64:0:1:0:1:1 4:4:4:4:0:1:0:1:1:4:1 4:4:4:4:0:1:0:0:1:1:4 8:8:8:8:0:1:0:1:1:2:2 8:8:8:8:1:1:0:0:1:4:2 8:8:8:8:0:1:0:1:1:2:4 8:8:8:8:1:1:0:1:1:1:1"}
for rr in 0 1; do
  for spec in $matrix; do
    IFS=: read -r iw width ld sd fifo fwd aligned spill drain lb_width sb_width <<< "$spec"
    lb_width=${lb_width:-$width}
    sb_width=${sb_width:-$width}
    case_dir="$test_build_dir/${spec//:/-}-rr$rr"
    mkdir -p "$case_dir"
    args=(--timing --assert --top-module lsu_redesign_tb +incdir+rtl/packages
      -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD
      -Wno-BLKSEQ -Wno-SYNCASYNCNET -Wno-PROCASSINIT
      "-GIW=$iw" "-GLSU_WIDTH=$width" "-GLB_WIDTH=$lb_width" "-GSB_WIDTH=$sb_width"
      "-GLD=$ld" "-GSD=$sd" "-GFIFO=$fifo" "-GFWD=$fwd"
      "-GALIGNED_READ=$aligned" "-GSPILL=$spill" "-GDRAIN=$drain" "-GADDR_RR=$rr" "${sources[@]}")
    if ! timeout -k 5s 90s "${VERILATOR:-verilator}" --lint-only "${args[@]}" > "$case_dir/lint.log" 2>&1; then
      tail -60 "$case_dir/lint.log"; exit 1
    fi
    if ! timeout -k 5s 180s "${VERILATOR:-verilator}" --binary -j "${JOBS:-4}" --Mdir "$case_dir" \
        -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" "${args[@]}" > "$case_dir/build.log" 2>&1; then
      tail -60 "$case_dir/build.log"; exit 1
    fi
    for seed in ${LSU_SEEDS:-1 23 101}; do
      if ! timeout -k 5s 30s "$case_dir/Vlsu_redesign_tb" "+SEED=$seed" > "$case_dir/run-$seed.log" 2>&1; then
        cat "$case_dir/run-$seed.log"; exit 1
      fi
      if ! rg -q '^PASS ' "$case_dir/run-$seed.log"; then
        cat "$case_dir/run-$seed.log"; exit 1
      fi
      sed -n '/^PASS /p' "$case_dir/run-$seed.log"
    done
  done
done
