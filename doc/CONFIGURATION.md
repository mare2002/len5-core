# LEN5 configuration migration

The production entry point is `rtl/len5_datapath.sv`, module `len5_datapath`, with typed `Len5Cfg`. This checkout had no `len5_core.sv`. The simulation instance is `i_len5_datapath`; the FuseSoC dependency identity `polito:len5:datapath` stays stable.

`len5_config_pkg::len5_user_cfg_t` contains selectable settings. The SV constant function `build_config()` returns the complete packed `len5_cfg` (alias of `len5_cfg_t`), including derived widths and counts. `DEFAULT_LEN5_USER_CFG` preserves every original package value; `DEFAULT_LEN5_CFG` is built from it once. `tb_config_pkg::tb_user_cfg_t`, `build_config()` and the resolved `tb_cfg_t` do the same for TB memory configuration. The TB builder takes the resolved CPU instruction beat width; it does not derive that width again. Runtime counters, firmware filenames, queues and PRNG state remain runtime state. `SRAM_SIM_INIT` is an explicit string parameter because strings cannot be packed; its default is `DefaultSramSimInit`.

The architecture follows [CVA6's typed top-level configuration](https://github.com/pulp-platform/cva6/blob/master/core/cva6.sv), [packed configuration definitions](https://github.com/pulp-platform/cva6/blob/master/core/include/config_pkg.sv), and [constant configuration building](https://github.com/pulp-platform/cva6/blob/master/core/include/build_config_pkg.sv). Scalar build-tool adapters assemble packed values once at elaboration. Implementation modules receive those values explicitly. Shared type-expression headers centralize record layouts; they do not select configuration through defines.

## Complete old-to-new mapping

Every RTL row below maps `len5_config_pkg::NAME` to `Len5Cfg.NAME`; values are the original defaults. Every TB row maps `tb_config_pkg::NAME` to `TbCfg.NAME`, except the separately forwarded string.

| RTL parameter | Default |
|---|---|
| `BOOT_VM_MODE` | `BARE` |
| `BOOT_PC` | `64'h180` |
| `LEN5_MULTIPLE_ISSUES` | `32'd8` |
| `LEN5_M_EN` | `1'b1` |
| `LEN5_DIV_EN` | `1'b1` |
| `LEN5_F_EN` | `1'b1` |
| `LEN5_D_EN` | `1'b1` |
| `LEN5_C_EN` | `1'b0` |
| `LEN5_A_EN` | `1'b0` |
| `LEN5_STORE_LOAD_FWD_EN` | `1'b1` |
| `MAX_EU_N` | `32'd7` |
| `ONLY_DOUBLEWORD_MEM_ACCESSES` | `1'b0` |
| `LEN5_CSR_HPMCOUNTERS_EN` | `1'b1` |
| `MMAP_MASK` | `64'hffffffffe0000000` |
| `BPU_HLEN` | `32'd4` |
| `BPU_BTB_BITS` | `32'd4` |
| `RAS_DEPTH` | `32'd4` |
| `FETCH_MEMIF_FIFO_DEPTH` | `32'd8` |
| `FETCH_MEM_DRAIN_ON_FLUSH` | `1'b1` |
| `LOAD_BUFFER_DRAIN_ON_FLUSH` | `1'b1` |
| `FETCH_REQ_SPILL_SKIP` | `1'b1` |
| `FETCH_ANS_SPILL_SKIP` | `1'b0` |
| `IQ_DEPTH` | `32'd16` |
| `LDBUFF_DEPTH` | `32'd8` |
| `STBUFF_DEPTH` | `32'd16` |
| `LSU_SPILL_SKIP` | `1'b1` |
| `ALU_RS_DEPTH` | `32'd8` |
| `ALU_SPILL_SKIP` | `1'b1` |
| `ALU_RR_ARBITER` | `1'b1` |
| `MULT_RS_DEPTH` | `32'd4` |
| `LEN5_MULT_SERIAL` | `1'b0` |
| `MULT_PIPE_DEPTH` | `32'd1` |
| `MULT_RR_ARBITER` | `1'b1` |
| `DIV_RS_DEPTH` | `32'd4` |
| `DIV_RR_ARBITER` | `1'b1` |
| `FPU_RS_DEPTH` | `32'd8` |
| `FPU_RR_ARBITER` | `1'b1` |
| `FPU_PIPE_DEPTH` | `32'd4` |
| `FPU_SPILL_SKIP` | `1'b1` |
| `BU_RS_DEPTH` | `32'd4` |
| `BU_SPILL_SKIP` | `1'b1` |
| `ROB_DEPTH` | `32'd32` |
| `COMMIT_SPILL_SKIP` | `1'b1` |

| TB parameter | Default |
|---|---|
| `MEMORY_BACKEND` | `MEM_BACKEND_AXI_SIM` |
| `AXI_CLOCK_HALF_PERIOD_PS` | `1000` |
| `IMEM_BASE_ADDR` | `64'h0001_0000` |
| `IMEM_SIZE_BYTES` | `256 * 1024` |
| `IMEM_LATENCY` | `10` |
| `DMEM_BASE_ADDR` | `64'h0005_0000` |
| `DMEM_SIZE_BYTES` | `768 * 1024` |
| `DMEM_LATENCY` | `1` |
| `SRAM_SIM_INIT` | `"none"` |
| `SERIAL_ADDR` | `64'h2000_0000` |
| `EXIT_ADDR` | `64'h2000_0100` |

`fetch_pkg::INIT_C2B` additionally becomes `Len5Cfg.BPU_INIT_C2B` (default 2, WT). `fetch_pkg::HLEN` and `BTB_BITS` become `Len5Cfg.BPU_HLEN` and `BPU_BTB_BITS`.

## Dependency graph

- Issue width -> issue bits, fetch line width, bundle ports/records, predictor banking, instruction-memory and AXI beat width.
- D extension -> floating-point register/data width and FPU formats; M/DIV/F/D -> decode/generate switches and enabled execution-unit count.
- ROB depth -> ROB index type, CDB/operand records, reservation stations, register-status counters (`clog2(ROB_DEPTH+3)`) and verification reorder buffers.
- Load/store depths -> individual index widths and shared maximum tag width -> address-adder records, memory response records, AXI IDs/ownership capacity. Suspended VM LSQ record dependencies were also moved out of global package typedefs.
- Fetch FIFO depth -> completion queue capacity and AXI outstanding/count widths.
- TB region sizes plus instruction beat width -> native SRAM address widths; data/instruction latency -> response reservations and count widths.

Derived quantities are fields in the resolved configuration, filled only by the SV builder. There are no scalar build-tool overrides for derived fields. Implementation modules directly reuse `Len5Cfg.ROB_IDX_LEN`, `Len5Cfg.BUFF_IDX_LEN`, `Len5Cfg.FLEN`, etc. Localparams remain for types and genuinely instance-specific dimensions, such as `$clog2(DEPTH)` when a generic FIFO depth is independently parameterized. Config-dependent records reside in `len5_typedef.svh`, `len5_memory_typedef.svh` and `tb_typedef.svh`; architectural instruction types, exception codes, CSR encodings and fixed EU identifiers remain in packages. Generic utility parameters remain explicit module parameters.

## RTL module parameters

CPU configuration travels through `.Len5Cfg(Len5Cfg)` throughout `rtl/`. Queue depths, predictor dimensions, arbitration choices, pipeline depths, spill controls and boot addresses are localparams derived from that value; callers cannot override them separately. For example, `load_store_unit` uses `LB_DEPTH = Len5Cfg.LDBUFF_DEPTH` and `SB_DEPTH = Len5Cfg.STBUFF_DEPTH`, and passes the same configuration to both buffers. Wrappers that only forwarded scalar settings no longer duplicate those settings.

The shared integer `arith_rs` also takes a typed `expipe_pkg::issue_eu_t EU` parameter. Its ALU, multiplier and divider instances select their corresponding depth and arbitration fields from `Len5Cfg`. Integer and FPU control widths come from the fixed architectural definitions in `expipe_pkg`.

Parameters describing distinct instance roles or reusable algorithms remain explicit: `arith_rs.EU`, `address_adder.IS_STORE`, `serdiv.WIDTH/STABLE_HANDSHAKE`, the multiplier/divider register controls, and the unused generic `op_only_*` depth/control-width parameters. These have no CPU configuration fields. `rtl/common/` and `rtl/vendor/` retain their existing interfaces and contents. Standalone TB adapters construct their cancellation/drain profiles in the selected configuration before passing it to RTL; ALU TB `SKIP_REG` selects `ALU_SPILL_SKIP` there.

The module-interface follow-up scanned all 51 active RTL modules and verified that all 188 common/vendor files stayed byte-identical. Normalized comparisons preserve the ports and control/datapath expressions in all 33 changed active RTL modules. Default and four-issue/F32 firmware traces match their saved baselines byte-for-byte. The serial-multiplier profile also passes full RTL elaboration with MULT_RS_DEPTH=8, priority arbitration, ROB64 and load16/store32 buffers; serial firmware execution was not checked.

PC directed/framework checks and the 100-seed regression passed (6,948,463 comparisons, zero mismatches), as did the frontend directed/framework/random-framework suites, native drain test, both load/store suites, default ALU test, and three seeds each of SRAM and variable/native AXI protocols. PC mutations detected 8/8 faults; the two affected frontend mutations detected 2/2. Spike differential verification passed 14,122 commits with no discrepancies. Commands, configuration receipts, mappings and logs are under `build/rtl-cfg-ports/`, with the summary in `results.json`. Large C++ models used unoptimized compilation to limit build resource use; RTL assertions and diagnostics were retained.

An additional `make check-alu ALU_SPILL_SKIP=0` run exposed a pre-existing registered-output test discrepancy. With the same seed, the original and refactored sources both produce identical mismatch records and 19 errors in 8,835 transactions. The existing C++ harness returns zero even when it prints `TEST FAILED`; this profile is therefore recorded as failing. Evidence is in `build/rtl-cfg-ports/alu-registered-comparison/summary.json`. The ten pinned-vendor lint diagnostics and five documented incomplete frontend scenarios remain. No synthesis/PPA, Questa, exhaustive configuration, or suspended-VM sign-off is claimed.

## Overrides

Make preserves the original uppercase names and exports only explicitly selected variables. Build caches, source manifests, standalone oracles, firmware maps and mutation builds include the selected configuration. Memory-backend snapshot preparation now writes `config.mk` instead of rewriting packages.

The normal and differential Make build recipes invoke FuseSoC directly. Directories, process-lock files, configuration-selection records and successful-build stamps have separate Make rules. The normal `.verilator.lock` and differential `.verilator-diff.lock` stamps are updated only after a successful build; unchanged sources and selections reuse them. Configuration arguments, tool settings and changes to the source list invalidate the selection record. A target-specific `flock` shell holds the process lock for the complete build recipe; merely creating the lock file as a prerequisite would not hold that lock during compilation. Separate build directories should be used for concurrent, different configurations.

`scripts/sim/config-args.sh` owns scalar override validation and rendering. Make uses its output in `FUSESOC_CONFIG_ARGS` for normal CPU/TB builds and `RTL_CONFIG_ARGS` for RTL-only targets. Standalone verification and firmware tools call the same helper directly. Its arguments are the domain (`rtl|tb|all`), output format (`fusesoc|verilator`), and an optional comma-separated exclusion list. The helper never runs a build. Defaults and derived hardware fields remain exclusively in SystemVerilog.

```sh
make verilator-build LEN5_MULTIPLE_ISSUES=2 ROB_DEPTH=16 LDBUFF_DEPTH=4 STBUFF_DEPTH=8
make verilator-build MEMORY_BACKEND=TC_SRAM IMEM_LATENCY=3 DMEM_LATENCY=2
make app BUILD_DIR="$PWD/build/relocated" IMEM_BASE_ADDR=0x400000 DMEM_BASE_ADDR=0x600000
make verilator-sim BUILD_DIR="$PWD/build/relocated" IMEM_BASE_ADDR=0x400000 DMEM_BASE_ADDR=0x600000
```

Select matching drain bits when using legacy memory:

```sh
make verilator-build MEMORY_BACKEND=LEGACY FETCH_MEM_DRAIN_ON_FLUSH=0 LOAD_BUFFER_DRAIN_ON_FLUSH=0
```

FuseSoC accepts scalar integer parameters. All 64-bit fields use `_HI`/`_LO` transport to prevent Edalize string quoting and Verilog unsized-literal truncation. Make still accepts the original single variable. Example:

```sh
fusesoc run --target sim --tool verilator --setup --build polito:len5:len5   --LEN5_MULTIPLE_ISSUES=4 --ROB_DEPTH=64 --MEMORY_BACKEND=1   --BOOT_PC_HI=1 --BOOT_PC_LO=384
BOOT_PC=0x100000180 bash scripts/sim/config-args.sh rtl fusesoc
```

Programmatic SV callers copy `DEFAULT_LEN5_USER_CFG`, change selectable members in a constant function, and call `build_config(UserCfg)` once. Pass that resolved value as `.Len5Cfg(SelectedCfg)` to the hierarchy. Build the TB configuration analogously and pass `.TbCfg(SelectedTbCfg)`. Do not edit derived fields by hand. The TB's default boot address remains IMEM base plus 0x180; standalone frontend benches retain their explicit boot-zero, two-entry cancellation profile. The production fetch default remains eight entries with draining.

## Validation and limits

Detailed command logs and configuration receipts are under `build/config-migration/`. The original inventory, including every source usage, is `build/config-migration/inventory.json`. No diagnostic waivers were added. Existing waiver hierarchy paths were renamed with the datapath.

The installed Verilator 5.040 is used because the differential checker requires its XML API. System Verilator 5.046 reports pre-existing implicit-static and vendor import warnings. Repository Verible lint retains ten diagnostics in the unmodified pinned `tech_cells_generic/tc_sram.sv`; migrated active sources have no additional lint diagnostics.

The five pre-existing incomplete fetch-stage scenarios FE-T43/48/49/50/51 remain incomplete, with no assertions or coverage removed. C/A and VM remain unsupported as before. The suspended `rtl-vm` tree has migrated configuration references but is not a verified VM implementation. Feature-off forwarding still exposes existing unused-interface diagnostics under strict whole-core warning settings. Exhaustive combinations of all independent depths, latencies and feature switches are not claimed.

## Verification results

| Check | Result |
|---|---|
| Selected-configuration validation | `make checkbuild`, using SV `check_build()` functions |
| PC directed T01–T22 and both framework suites | Passed |
| PC regression, 100 seeds × 10,000 cycles, JOBS=4, REQUIRE_MATRIX=true | 6,948,463 checks, zero mismatches; required combination matrices complete |
| EJU, fetch-memory and composed frontend directed/framework/random-framework | Passed, preserving the documented five incomplete frontend cases |
| ALU | 890,891 transactions, zero errors |
| SRAM and AXI variable/native protocol suites | Ten seeds × 10,000 random cycles each, passed |
| SRAM geometry/negative configuration checks | 35 passed |
| SRAM/AXI firmware-loader tests | 63 / 36 passed, including malformed-image rejection |
| Load/store ordering and killed-response tests | Passed |
| Memory backend selection | All nine acceptance/rejection cases passed |
| PC/EJU mutations with issue width 2 and ROB depth 16 | PC 8/8 and focused EJU 1/1 compiled and detected |
| Default full-core hello_world | Completed; trace byte-identical to original source snapshot |
| Default Spike differential run | Status 0; 14,122 commits |
| AXI clock half-period override 1000 → 2000 ps | hello_world completed at timestamp 118,644,000 |
| Four-issue, ROB64, load16/store32, F32, RAS8, fetch16 configuration | hello_world completed |

Default execution completed at simulation timestamp 59,322,000; the four-issue configuration completed at 56,938,000. The original and migrated default traces contain identical cycle and retirement records, not merely identical instruction counts. `[CFG]` receipts in each run log read configuration members from the instantiated datapath/backend/frontend.

An additional integer-only two-issue SRAM profile timed out at a CSR write, both with default spill settings and with `*_SPILL_SKIP=0`. The default-spill version was reproduced against the original source with an identical trace (through PC 0x101c4), establishing that this stall predates the migration. Those combinations are not signed off; the trial log is `build/config-migration/compact-spill-stall.log`. No diagnostics were disabled to pass this trial. The installed firmware library provides only the double-float ABI; the integer-only core trial therefore uses the integer-only instructions exercised by the ordinary hello_world image rather than claiming a soft-float library build.

Representative verification commands (use the repository tool environment with Verilator 5.040):

```sh
make checkbuild
make checkbuild LEN5_MULTIPLE_ISSUES=4 ROB_DEPTH=64 LEN5_D_EN=0
make checkbuild MEMORY_BACKEND=LEGACY FETCH_MEM_DRAIN_ON_FLUSH=0 LOAD_BUFFER_DRAIN_ON_FLUSH=0
make check-pc-gen-run check-pc-gen-framework check-pc-gen-random-framework
make check-pc-gen-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-early-jump-run check-early-jump-framework check-early-jump-random-framework
make check-fetch-mem-if-run check-fetch-mem-if-framework check-fetch-mem-if-random-framework
make check-fetch-stage-run check-fetch-stage-framework check-fetch-stage-random-framework
make check-alu
bash scripts/sim/check-tc-sram.sh
bash scripts/sim/check-axi-sim.sh
AXI_NATIVE=1 bash scripts/sim/check-axi-sim.sh
python3 scripts/sim/check-tc-sram-config.py
python3 scripts/sim/check-tc-sram-loader.py
LOADER_BACKEND=AXI_SIM python3 scripts/sim/check-tc-sram-loader.py
bash scripts/sim/check-load-store.sh
LOAD_STORE_TOP=load_store_killed_tb bash scripts/sim/check-load-store.sh
make verilator-sim-debug FIRMWARE=/absolute/path/to/main.hex
make lint
```

The complete changed-file inventory is [CONFIGURATION_FILES.txt](CONFIGURATION_FILES.txt). Machine-readable validation results are in `build/config-migration/results.json`. ModelSim/Questa execution, synthesis/PPA, exhaustive feature combinations, the remaining EJU mutations, and full VM verification were not performed.

## Follow-up: build once in SystemVerilog

The additional Python configuration parser has been removed. Scalar transport lives in the readable `scripts/sim/config-args.sh` helper, shared by Make and the existing verification/firmware tools. It contains no configuration defaults or hardware derivations. Source expressions and configuration construction are evaluated by SystemVerilog.

The existing verification configuration modules and firmware map generator read JSON exported by `tb/config/len5_config_probe.sv`. This small, cached Verilator executable uses the same canonical SV defaults and builders as the processor; its only role is exporting elaborated metadata. Python neither parses SV configuration definitions nor evaluates their expressions. Existing independent verification oracles still calculate expected behavior independently.

The firmware memory-map generator now requires Verilator to elaborate this cached probe, even when invoked before the full CPU simulator build. Its existing overlap, alignment, overflow and malformed-configuration rejection checks are retained.

Follow-up validation before the direct-FuseSoC change: default and four-issue/F32 hello_world completed with byte-identical traces to their pre-follow-up versions; the 2000 ps AXI half-period profile also completed at timestamp 118,644,000. Spike differential verification passed 14,122 commits; PC regression passed 100 seeds/1,000,000 cycles with 6,948,463 checks and zero mismatches. Standalone frontend directed/framework checks, ALU, SRAM/AXI protocols, and both load/store suites passed. All 35 memory-geometry cases, 63 SRAM loader cases, 36 AXI loader cases, and nine backend-selection cases passed. The existing ten pinned-vendor lint diagnostics remain; no new waivers were added. Those receipts are in `build/config-migration/build-once-results.json`.

## Configuration validation during the build

The two additional Python test scripts have been removed. `len5_config_pkg::check_build(Len5Cfg)` validates CPU dimensions, supported features, and consistency of the derived fields. `tb_config_pkg::check_build(Len5Cfg, TbCfg, SRAM_SIM_INIT)` also validates memory geometry, MMIO addresses, initialization, and the CPU/memory flush protocol. Native memories cannot cancel accepted requests and therefore require both drain switches; legacy memory requires both switches disabled. Independently overridden adapter dimensions retain their existing local checks.

The functions use explicit `if (...) $fatal(...)` checks: Verilator 5.040 cannot evaluate immediate `assert` statements in a constant function. The datapath and system TB call the validators in constant generate conditions, so invalid settings fail elaboration even without `--assert`, before C++ compilation or simulation. The separate `make checkbuild` target uses the same functions in a small FuseSoC `lint-only` target, without building the CPU simulator. Derived-value calculations inside these validators are consistency checks and do not produce hardware.

For example, `make checkbuild LOAD_BUFFER_DRAIN_ON_FLUSH=0` fails with a message naming that switch and explaining the native-memory requirement. No separate test program is needed to validate the currently selected configuration. Build-argument syntax checks and firmware output generation remain in the existing transport and firmware tools; SV validation cannot inspect a generated linker file or a malformed argument rejected before elaboration.

Direct-build validation accepted eight valid profiles and rejected twenty invalid profiles. Corrupted derived CPU/TB fields were rejected on Verilator 5.040 and 5.046 without `--assert`. Default hello_world and a four-issue/F32 rebuild in the same directory produced traces identical to their saved baselines; Spike passed 14,122 commits. PC directed/framework checks and the 100-seed regression passed with 6,948,463 checks and zero mismatches. All nine backend-selection cases passed. An incompatible normal `make verilator-build` failed before producing any C++ objects. The same ten existing vendor lint diagnostics remain. Receipts are in `build/config-migration/direct-build-results.json`.

The build-rule update passed build-stamp reuse and invalidation checks, failed-build recovery, missing-binary rebuilding, and parallel build-lock checks. Normal and differential targets retain separate stamps even if their custom roots coincide. The default and four-issue core traces remained identical to their baselines; Spike passed 14,122 commits. PC directed/framework checks and the 100-seed regression passed again with 6,948,463 checks and zero mismatches. Standalone frontend directed checks, SRAM and AXI protocol runs (three seeds each), and load/store ordering passed. Those receipts are in `build/config-make-owned/results.json`. Restoring the standalone argument helper preserves those Make rules and the probe; compatibility receipts are in `build/config-args-restored/`.

## Resolved field mapping

| Former derived definition | Resolved field |
|---|---|
| `len5_pkg::LEN5_MULTIPLE_ISSUES_BITS` | `Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS` |
| `len5_pkg::LWIDTH`, `FLEN` | `Len5Cfg.LWIDTH`, `Len5Cfg.FLEN` |
| `len5_pkg::LDBUFF_TAG_W`, `STBUFF_TAG_W`, `BUFF_IDX_LEN` | Same member names in `Len5Cfg` |
| `expipe_pkg::ROB_IDX_LEN`, `COMMIT_UNIT_DEPTH`, `IQ_IDX_LEN`, `REGSTAT_CNT_W` | Same member names in `Len5Cfg` |
| `expipe_pkg::MULT_EU_N`, `DIV_EU_N`, `FP_EU_N`, `EU_N` | Same member names in `Len5Cfg` |
| `axi_memory_pkg::InstrDataWidth`, `TagCount`, `CountWidth` | `Len5Cfg.IMEM_DATA_WIDTH`, `TAG_COUNT`, `AXI_COUNT_WIDTH` |
| `memory_backend_pkg::IMEM_DATA_WIDTH`, `IMEM_WORD_BYTES`, `IMEM_ADDR_WIDTH`, `DMEM_ADDR_WIDTH`, `SRAM_RESPONSE_DEPTH`, `SRAM_COUNT_WIDTH` | Same member names in `TbCfg` |

Example of direct SV use:

```systemverilog
function automatic len5_config_pkg::len5_user_cfg_t selected_user_config();
  len5_config_pkg::len5_user_cfg_t cfg = len5_config_pkg::DEFAULT_LEN5_USER_CFG;
  cfg.ROB_DEPTH = 64;
  return cfg;
endfunction
localparam len5_config_pkg::len5_cfg SelectedCfg =
    len5_config_pkg::build_config(selected_user_config());
// Pass .Len5Cfg(SelectedCfg); consumers use SelectedCfg.ROB_IDX_LEN (6).
```
