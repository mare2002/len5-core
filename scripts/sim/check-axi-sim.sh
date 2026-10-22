#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
axi_build_dir=${AXI_BUILD_DIR:-"$PWD/build/axi-sim/adapter"}
axi_config=${AXI_CONFIG:-rtl/packages/len5_config_pkg.sv}
axi_tb_config=${AXI_TB_CONFIG:-tb/packages/tb_config_pkg.sv}
mkdir -p "$axi_build_dir"
"${VERILATOR:-verilator}" --binary --timing --timescale 1ps/1ps --assert -j "${JOBS:-4}" \
  -MAKEFLAGS "OBJCACHE= CXX=${CXX:-/usr/bin/g++} OPT_FAST=-O2 OPT_GLOBAL=-O2" --Mdir "$axi_build_dir" --top-module axi_sim_adapter_tb \
  -GNATIVE="${AXI_NATIVE:-0}" -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
  tb/memory/axi_sim/waivers.vlt rtl/misc/packages-waivers.vlt rtl/misc/common-waivers.vlt \
  +incdir+rtl/vendor/pulp-axi/include +incdir+rtl/vendor/pulp-axi/src \
  +incdir+rtl/vendor/pulp-common-cells/include +incdir+tb/memory \
  rtl/packages/util_pkg.sv "$axi_config" rtl/packages/len5_pkg.sv rtl/packages/fetch_pkg.sv "$axi_tb_config" \
  tb/memory/tc_sram/memory_backend_pkg.sv rtl/vendor/pulp-axi/src/axi_pkg.sv \
  rtl/vendor/pulp-axi/src/axi_intf.sv tb/memory/axi_sim/axi_memory_pkg.sv \
  rtl/common/modn_counter.sv rtl/common/modn_counter_updown.sv rtl/common/completion_fifo.sv rtl/vendor/pulp-common-cells/src/fifo_v3.sv \
  rtl/common/spill_cell_flush_cu.sv rtl/common/spill_cell_flush.sv rtl/frontend/fetch_mem_if.sv \
  tb/memory/tc_sram/memory_access_check.sv tb/memory/axi_sim/axi_sim_adapter.sv \
  tb/memory/axi_sim/axi_sim_storage.sv tb/memory/axi_sim/axi_variable_slave.sv \
  tb/memory/axi_sim/axi_sim_adapter_tb.sv tb/memory/axi_sim/axi_sim_model.sv \
  > "$axi_build_dir/build.log" 2>&1 || { tail -70 "$axi_build_dir/build.log"; exit 1; }
python3 - "$axi_build_dir" "$axi_tb_config" <<'PY'
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location("memory_map", "scripts/gen-memory-map.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
config = module.settings(Path(sys.argv[2]))
i = bytes(((b * 37) ^ ((b // 4) * 13) ^ 0x5a) & 255 for b in range(256))
d = bytes(b ^ 0xa5 for b in range(256))
(Path(sys.argv[1]) / "firmware.hex").write_text(
    f"@{config['IMEM_BASE_ADDR']:x}\n" + i.hex(" ") + f"\n@{config['DMEM_BASE_ADDR']:x}\n" + d.hex(" ") + "\n")
PY
for ((seed=1;seed<=${SEEDS:-10};seed++)); do
  "$axi_build_dir/Vaxi_sim_adapter_tb" +seed="$seed" +cycles="${CYCLES:-10000}" \
    +firmware="$axi_build_dir/firmware.hex" > "$axi_build_dir/seed-$seed.log" 2>&1 || {
      tail -60 "$axi_build_dir/seed-$seed.log"; exit 1;
    }
  tail -5 "$axi_build_dir/seed-$seed.log"
done
python3 - "$axi_build_dir" "${SEEDS:-10}" <<'PY'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1]); runs = []
for seed in range(1, int(sys.argv[2]) + 1):
    match = re.search(r"PASS AXI native=(\d+) N=(\d+) seed=(\d+) cycles=(\d+) max_fetch=(\d+) reordered=(\d+) AW=(\d+) W=(\d+) B=(\d+)",
                      (root / f"seed-{seed}.log").read_text())
    assert match, f"Missing pass record for seed {seed}"
    runs.append(dict(zip(("native", "width", "seed", "cycles", "max_fetch", "reordered", "aw", "w", "b"), map(int, match.groups()))))
(root / "report.json").write_text(json.dumps({"status": "passed", "runs": runs}, indent=2) + "\n")
PY
