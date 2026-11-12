#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/fpu-units-multi"}
cd "$repo_root"

# Reuse the vendored manifests' ordered HDL lists, without FuseSoC setup.
mapfile -t vendor_sources < <(awk '$1 == "-" && $2 ~ /\.(sv|v)$/ { print "rtl/vendor/" $2 }' \
  rtl/vendor/common_cells.core rtl/vendor/fpu_div_sqrt_mvp.core rtl/vendor/cvfpu.core)
sources=(
rtl/misc/fpu-waivers.vlt rtl/vendor/misc/cvfpu-waivers.vlt
          rtl/vendor/misc/pulp-common-cells-waivers.vlt
          rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
          rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
          "${vendor_sources[@]}"
          rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter.sv
          rtl/common/rr_arbiter_multi.sv
          rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv
          rtl/common/rs_alloc_fifo.sv
          rtl/expipe/exec-units/arith_rs_fpu.sv rtl/expipe/exec-units/fpu_wrapper.sv
          rtl/expipe/exec-units/fpu_unit.sv tb/expipe/fpu_units_multi_tb.sv
)
common_args=(--timing --assert --top-module fpu_units_multi_tb
  +incdir+rtl/packages +incdir+rtl/vendor/pulp-common-cells/include
  -Wall -Wno-fatal -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT)

# One configuration per build, including explicitly requested larger counts.
for precision in ${PRECISIONS:-1}; do
  for pipeline in ${PIPE_DEPTHS:-4}; do
    for count in ${UNIT_COUNTS:-1 2}; do
      for rr in ${ARBITERS:-0 1}; do
        case_dir="$test_build_dir/n$count-rr$rr-d$precision-p$pipeline"
        mkdir -p "$case_dir"
        args=("${common_args[@]}" -GNUM_UNITS="$count" -GRR="$rr"
          -GDOUBLE_PRECISION="$precision" -GPIPE_DEPTH="$pipeline" "${sources[@]}")
        if ! timeout -k 5s "${LINT_TIMEOUT:-60}s" "${VERILATOR:-verilator}" \
            --lint-only "${args[@]}" > "$case_dir/lint.log" 2>&1; then
          echo "FAIL FPU lint: $case_dir/lint.log" >&2
          tail -n 20 "$case_dir/lint.log"
          exit 1
        fi
        if ! timeout -k 5s "${BUILD_TIMEOUT:-180}s" "${VERILATOR:-verilator}" \
            --binary -j 1 -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0" \
            --Mdir "$case_dir" "${args[@]}" > "$case_dir/build.log" 2>&1; then
          echo "FAIL FPU build or timeout: $case_dir/build.log" >&2
          tail -n 20 "$case_dir/build.log"
          exit 1
        fi
        if ! timeout -k 5s "${RUN_TIMEOUT:-15}s" "$case_dir/Vfpu_units_multi_tb" \
            > "$case_dir/run.log" 2>&1; then
          echo "FAIL FPU simulation or timeout: $case_dir/run.log" >&2
          tail -n 15 "$case_dir/run.log"
          exit 1
        fi
        sed -n '/^PASS /p' "$case_dir/run.log"
      done
    done
  done
done
