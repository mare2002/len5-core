#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/load-store-order"}
cd "$repo_root"
mkdir -p "$test_build_dir"

"${VERILATOR:-verilator}" --binary --timing --assert -j "${JOBS:-4}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir" --top-module load_store_order_tb \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
  rtl/misc/packages-waivers.vlt rtl/misc/common-waivers.vlt rtl/misc/expipe-waivers.vlt \
  rtl/packages/util_pkg.sv rtl/packages/len5_config_pkg.sv rtl/packages/len5_pkg.sv \
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv \
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv \
  rtl/common/modn_counter.sv rtl/common/sign_extender.sv rtl/common/byte_selector.sv \
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv \
  rtl/expipe/load-store-unit/address_adder.sv rtl/expipe/load-store-unit/load_buffer.sv \
  rtl/expipe/load-store-unit/store_buffer.sv rtl/expipe/load-store-unit/l0_cache.sv \
  rtl/expipe/load-store-unit/load_store_unit.sv \
  tb/expipe/load-store-unit/load_store_order_tb.sv

"$test_build_dir/Vload_store_order_tb"
