#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/arith-rs-multi"}
cd "$repo_root"
mkdir -p "$test_build_dir"

"${VERILATOR:-verilator}" --binary --timing --assert -j "${JOBS:-4}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir" \
  --top-module arith_rs_multi_tb +incdir+rtl/packages \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
  -Wno-DECLFILENAME -Wno-BLKSEQ -Wno-PROCASSINIT -Wno-SYNCASYNCNET \
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv \
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv rtl/packages/expipe_pkg.sv \
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv rtl/common/rr_arbiter.sv \
  rtl/common/rr_arbiter_multi.sv \
  rtl/expipe/exec-units/arith_rs.sv rtl/expipe/exec-units/arith_rs_fpu.sv \
  tb/expipe/arith_rs_multi_tb.sv > "$test_build_dir/build.log" 2>&1 || {
    cat "$test_build_dir/build.log"
    exit 1
  }

"$test_build_dir/Varith_rs_multi_tb"
