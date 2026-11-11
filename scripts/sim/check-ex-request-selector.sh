#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/ex-request-selector"}
cd "$repo_root"
mkdir -p "$test_build_dir"

CCACHE_DIR=${CCACHE_DIR:-/tmp/len5-eu-cache} "${VERILATOR:-verilator}" \
  --binary --timing --assert --output-split 10000 --output-groups 100 -j "${JOBS:-4}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0" \
  --Mdir "$test_build_dir" --top-module ex_request_selector_tb \
  -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
  -Wno-BLKSEQ -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET \
  rtl/common/prio_enc.sv rtl/common/prio_enc_multi.sv \
  rtl/common/rr_arbiter_multi.sv \
  tb/expipe/ex_request_selector_tb.sv

"$test_build_dir/Vex_request_selector_tb"
