#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_build_dir=${BUILD_DIR:-"$repo_root/build/load-store-order"}
test_top=${LOAD_STORE_TOP:-load_store_order_tb}
cd "$repo_root"
mkdir -p "$test_build_dir"
config_output=$(bash scripts/sim/config-args.sh rtl verilator)
config_args=()
if [[ -n $config_output ]]; then mapfile -t config_args <<< "$config_output"; fi

"${VERILATOR:-verilator}" --binary --timing --assert -j "${JOBS:-4}" \
  "${config_args[@]}" +incdir+tb/packages +incdir+rtl/packages +incdir+tb/memory \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir" --top-module "$test_top" \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
  rtl/misc/packages-waivers.vlt rtl/misc/common-waivers.vlt rtl/misc/expipe-waivers.vlt \
  rtl/packages/util_pkg.sv "${LOAD_STORE_CONFIG:-rtl/packages/len5_config_pkg.sv}" rtl/packages/len5_pkg.sv \
  rtl/packages/instr_pkg.sv rtl/packages/csr_pkg.sv rtl/packages/fetch_pkg.sv \
  rtl/packages/expipe_pkg.sv rtl/packages/memory_pkg.sv \
  rtl/common/modn_counter.sv rtl/common/sign_extender.sv rtl/common/byte_selector.sv \
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv \
  rtl/expipe/load-store-unit/address_adder.sv rtl/expipe/load-store-unit/load_buffer.sv \
  rtl/expipe/load-store-unit/store_buffer.sv rtl/expipe/load-store-unit/l0_cache.sv \
  rtl/expipe/load-store-unit/load_store_unit.sv \
  "tb/expipe/load-store-unit/$test_top.sv"

"$test_build_dir/V$test_top"
