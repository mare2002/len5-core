#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/branch-rs-alloc
verilator --binary --timing --assert -j 4 -MAKEFLAGS "OBJCACHE= CXX=/usr/bin/g++" \
  --top-module branch_rs_alloc_tb +incdir+rtl/packages -Wno-fatal -Werror-UNOPTFLAT -Werror-LATCH -Werror-MULTIDRIVEN -Werror-IMPLICIT -Werror-SELRANGE --Mdir build/branch-rs-alloc \
  rtl/vendor/pulp-common-cells/src/cf_math_pkg.sv \
  rtl/vendor/pulp-common-cells/src/lzc.sv \
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv \
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv \
  rtl/common/modn_counter.sv rtl/common/rs_alloc_fifo.sv rtl/expipe/exec-units/branch_rs.sv \
  tb/expipe/branch_rs_alloc_tb.sv > build/branch-rs-alloc/build.log 2>&1
build/branch-rs-alloc/Vbranch_rs_alloc_tb
