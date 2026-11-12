# RS allocation FIFO checkpoint

## State

Implementation is uncommitted. Preserve the entire working tree. No commit,
reset, checkout or cleanup was performed. See `rs-allocation-fifo.md` for the
architecture and configuration contract. The initial tree was clean.

Implemented: shared `rs_alloc_fifo`, elaboration bypass, registered multi-push /
multi-pop ring queue, arbitrary positive depths, conservative beginning-of-cycle
capacity, independent per-operand CDB wakeup and boundary forwarding, flush/reset
priority, occupancy/valid-slot/accounting assertions, per-unit allocation limits,
configuration overrides and validation. Arithmetic, FPU, branch and legacy
operand-only RS instances use it. Branch insertion now accepts an ordered prefix;
its execution and completion order remain unchanged. LSU insertion uses a shared
queue to preserve load/store ordering and dependency snapshots.

Important limitation: the LSU still has exactly one physical insertion channel.
`LSU_ISSUE_WIDTH` is an upper bound; setting it above one does not increase memory
allocation throughput. Higher LSU input channels are zero and higher output
channels cannot transfer. This preserves existing memory issue arbitration. If
full multi-allocation LSU throughput is required, that remains architectural work:
inspect `load_buffer.sv`, `store_buffer.sv`, their cross-buffer snapshot signals,
and `exec_stage.sv`'s `older_memory` restriction before changing it. Do not simply
split the shared queue or remove the restriction. The disconnected legacy
operand-only unit remains scalar and exposes FIFO settings as module parameters.

## Verified results (2026-11-11)

- FIFO scoreboard: 80 configurations × 600 cycles, PASS. Widths 1/2/4/8;
  depths 1/2/3/4/7; disabled/enabled; narrow/full allocation limits;
  one/two/three operands; full, empty, simultaneous transfers, sparse validity,
  non-prefix downstream ready, CDB capture/forwarding, reset while occupied,
  flush, tag reuse and final drain. `build/rs-alloc-fifo/`.
- Branch RS allocation: FIFO disabled/enabled, PASS. Both cases observed four
  multi-allocation cycles and 29 ordered completions, plus backpressure, CDB
  operands, flush and immediate tag reuse. `build/branch-rs-alloc/`.
- Arithmetic/FPU RS regression: 8/8 PASS (1/2 physical units × round-robin off/on
  × arithmetic/FPU). `build/arith-rs-multi/`.
- Physical ALU/multiplier/divider wrappers: 12/12 PASS (three categories × 1/2
  physical units × arbitration off/on). `build/exec-units-multi/`.
- Real FPU wrappers: 4/4 PASS (1/2 physical units × arbitration off/on).
  `build/fpu-units-multi/`.
- Load/store ordering, forwarding, delayed tags, queue reuse and flush: PASS
  both disabled and enabled, depth 3. `build/load-store-order/` and
  `build/load-store-fifo/`.
- Full-core elaboration: enabled FIFO widths 1/2/4/8 PASS, mixed per-unit widths,
  including widths larger than depth. Critical loop/latch/multiple-driver/
  implicit-net warnings treated as errors. `build/multiple-exec-config-core/`.
- Invalid configuration checks: 18/18 new allocation cases rejected (zero width,
  width above global, enabled zero depth, for six unit prefixes); four existing
  physical-unit-count rejection cases also PASS.
- Spike differential mixed program: default and fifo-mixed PASS, 140 committed
  instructions each. `build/multiple-exec-integration/{default,fifo-mixed}/`.
  Later changes were FIFO assertions and LSU vector padding with inactive lanes;
  the final LSU version independently passed ordering tests and core elaboration.
- PC generator: directed, framework, random framework and 100-seed regression
  PASS. 1,000,000 cycles, 6,948,463 checks, zero mismatches; required combination
  matrix covered. Evidence:
  `build/pc-gen/regression/all-proposed-fvvhkimo/summary.json`.
- Legacy operand-only unit: enabled depth-3 elaboration PASS.
- Shell syntax, Python compilation and `git diff --check`: PASS.

Strict focused RTL lint uses `-Wall` with only testbench/unused-signal waivers.
No synthesis, timing analysis, PPA estimate, exhaustive formal proof or complete
repository `make check` has been run. Depths beyond seven are parameterized but
not simulated. Core differential execution used global widths one and four;
widths two/eight have elaboration and standalone FIFO evidence.

## Tooling and resolved failures

- FuseSoC is `/home/markospremic/miniconda3/envs/core-len5/bin/fusesoc`.
- Existing Spike integration uses `../tool/verilator/5.040/bin/verilator` and
  the pinned archives under `build/spike-build`; other focused runs use system
  Verilator 5.046. Do not rebuild Spike unnecessarily.
- New test scripts disable compiler caching via `OBJCACHE=` and select
  `/usr/bin/g++`, matching existing regression scripts. An early FIFO build hit
  the read-only home compiler cache; this was resolved.
- Initial FIFO output data and transfer counting shared an `always_comb`, causing
  an apparent ready/data loop in the LSU. These are now separate; critical loop
  checks pass.
- Configuration argument handling now treats `*_USE_FIFO` as one-bit values.
- All explicit standalone testbench configuration aggregates needed the new
  fields. Their parameter adapters were updated; no unrelated datapath logic
  was changed in those files.
- A PC-generator run detected stale provenance because `config-args.sh` changed
  during the run. The rebuilt final full run passed; do not report the stale
  run as an unresolved RTL failure.

## Commands

```sh
make check-rs-alloc-fifo check-branch-rs-alloc
make check-arith-rs-multi check-exec-units-multi check-fpu-units-multi
bash scripts/sim/check-load-store.sh
BUILD_DIR=build/load-store-fifo LSU_USE_FIFO=1 LSU_FIFO_DEPTH=3 bash scripts/sim/check-load-store.sh
python3 scripts/sim/check-multiple-exec-config.py --fusesoc /home/markospremic/miniconda3/envs/core-len5/bin/fusesoc --cases fifo-width-1,fifo-width-2,fifo-width-4,fifo-width-8
python3 scripts/sim/check-multiple-exec-integration.py --simulate --cases default,fifo-mixed --fusesoc /home/markospremic/miniconda3/envs/core-len5/bin/fusesoc
FUSESOC=/home/markospremic/miniconda3/envs/core-len5/bin/fusesoc make check-pc-gen check-pc-gen-framework check-pc-gen-random-framework check-pc-gen-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
```

Do not repeat successful expensive regressions unless an affected path changes.

## Modified/new files

- `doc/rs-allocation-fifo-progress.md`
- `doc/rs-allocation-fifo.md`
- `len5.core`
- `makefile`
- `rtl/common.core`
- `rtl/common/rs_alloc_fifo.sv`
- `rtl/expipe/exec-units/arith_rs.sv`
- `rtl/expipe/exec-units/arith_rs_fpu.sv`
- `rtl/expipe/exec-units/branch_rs.sv`
- `rtl/expipe/exec-units/branch_unit.sv`
- `rtl/expipe/exec-units/exec_stage.sv`
- `rtl/expipe/exec-units/op_only_rs.sv`
- `rtl/expipe/exec-units/op_only_unit.sv`
- `rtl/expipe/load-store-unit/load_store_unit.sv`
- `rtl/packages/len5_config_pkg.sv`
- `scripts/sim/check-arith-rs-multi.sh`
- `scripts/sim/check-branch-rs-alloc.sh`
- `scripts/sim/check-exec-units-multi.sh`
- `scripts/sim/check-fpu-units-multi.sh`
- `scripts/sim/check-load-store.sh`
- `scripts/sim/check-multiple-exec-config.py`
- `scripts/sim/check-multiple-exec-integration.py`
- `scripts/sim/check-rs-alloc-fifo.sh`
- `scripts/sim/config-args.sh`
- `tb/config/len5_config_probe.sv`
- `tb/expipe/alu/alu_tb.sv`
- `tb/expipe/arith_rs_multi_tb.sv`
- `tb/expipe/branch_rs_alloc_tb.sv`
- `tb/expipe/exec_units_multi_tb.sv`
- `tb/expipe/fpu_units_multi_tb.sv`
- `tb/expipe/load-store-unit/load_store_killed_tb.sv`
- `tb/expipe/load-store-unit/load_store_order_tb.sv`
- `tb/expipe/rs_alloc_fifo_tb.sv`
- `tb/frontend/early_jump_unit/early_jump_tb.sv`
- `tb/frontend/early_jump_unit/recovery/recovery_tb.sv`
- `tb/frontend/fetch_mem_if/fetch_mem_drain_tb.sv`
- `tb/frontend/fetch_mem_if/fetch_mem_tb.sv`
- `tb/frontend/fetch_stage/fetch_stage_tb.sv`
- `tb/frontend/pc_gen/pc_gen_tb.sv`
- `tb/len5_tb.sv`
- `tb/memory/axi_sim/axi_sim_adapter_tb.sv`
- `tb/memory/axi_sim/axi_sim_loader_tb.sv`
- `tb/memory/tc_sram/tc_sram_adapter_tb.sv`
- `tb/memory/tc_sram/tc_sram_config_tb.sv`
- `tb/memory/tc_sram/tc_sram_loader_tb.sv`
- `tb/tb_bare.sv`
