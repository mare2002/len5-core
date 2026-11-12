#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/rs-alloc-fifo
sources=(rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv
  rtl/vendor/pulp-common-cells/src/lzc.sv
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv
  rtl/common/rs_alloc_fifo.sv tb/expipe/rs_alloc_fifo_tb.sv)
verilator --binary -MAKEFLAGS "OBJCACHE= CXX=/usr/bin/g++" --timing --assert -j 4 --top-module rs_alloc_fifo_tb \
  +incdir+rtl/packages -Wno-fatal -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT -Werror-SELRANGE --Mdir build/rs-alloc-fifo "${sources[@]}" \
  > build/rs-alloc-fifo/build.log 2>&1
build/rs-alloc-fifo/Vrs_alloc_fifo_tb
