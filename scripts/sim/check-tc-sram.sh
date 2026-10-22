#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
test_build_dir=${TC_SRAM_BUILD_DIR:-"$PWD/build/tc-sram"}
mkdir -p "$test_build_dir"
"${VERILATOR:-verilator}" --binary --timing --assert -j "${JOBS:-4}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++}" --Mdir "$test_build_dir" --top-module tc_sram_adapter_tb \
  -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
  tb/memory/tc_sram/waivers.vlt rtl/misc/packages-waivers.vlt \
  rtl/packages/util_pkg.sv "${TC_SRAM_CONFIG:-rtl/packages/len5_config_pkg.sv}" rtl/packages/len5_pkg.sv rtl/packages/fetch_pkg.sv \
  "${TC_SRAM_TB_CONFIG:-tb/packages/tb_config_pkg.sv}" \
  rtl/common/modn_counter.sv rtl/common/modn_counter_updown.sv rtl/common/completion_fifo.sv \
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv rtl/frontend/fetch_mem_if.sv \
  tb/memory/tc_sram/memory_backend_pkg.sv tb/memory/tc_sram/memory_access_check.sv \
  tb/memory/tc_sram/memory_response_buffer.sv tb/memory/tc_sram/tc_sram_adapter.sv \
  rtl/vendor/tech_cells_generic/tc_sram.sv +incdir+tb/memory tb/memory/tc_sram_storage.sv \
  tb/memory/tc_sram/tc_sram_adapter_tb.sv > "$test_build_dir/build.log" 2>&1 || { tail -60 "$test_build_dir/build.log"; exit 1; }
python3 - "$test_build_dir" "${TC_SRAM_TB_CONFIG:-tb/packages/tb_config_pkg.sv}" <<'PY_IMAGE'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("memory_map", "scripts/gen-memory-map.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
base = module.settings(Path(sys.argv[2]))["IMEM_BASE_ADDR"]
data = bytes(((index * 37) ^ ((index // 4) * 13) ^ 0x5a) & 255 for index in range(256))
(Path(sys.argv[1]) / "firmware.hex").write_text(f"@{base:x}\n" + data.hex(" ") + "\n")
PY_IMAGE
for ((seed=1;seed<=${SEEDS:-10};seed++)); do
  "$test_build_dir/Vtc_sram_adapter_tb" +seed="$seed" +cycles="${CYCLES:-10000}" +firmware="$test_build_dir/firmware.hex" | tee "$test_build_dir/seed-$seed.log"
done
python3 - "$test_build_dir" "${SEEDS:-10}" <<'PY'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
runs = []
for seed in range(1, int(sys.argv[2]) + 1):
    log = (root / f"seed-{seed}.log").read_text()
    match = re.search(r"PASS seed=(\d+) cycles=(\d+) all_ports=(\d+) collisions=(\d+) flushes=(\d+) mmio=(\d+)", log)
    assert match, f"missing pass record for seed {seed}"
    runs.append(dict(zip(("seed", "cycles", "all_ports", "collisions", "flushes", "mmio"), map(int, match.groups()))))
(root / "report.json").write_text(json.dumps({"status": "passed", "runs": runs}, indent=2) + "\n")
PY
