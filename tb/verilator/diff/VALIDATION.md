# Validation results

[Build and run instructions](README.md) · [Signal map and limitations](ARCHITECTURE.md)

Validation on the supplied tree used Spike v1.1.0, Verilator 5.040 and GCC 16.

## Explicit debug targets (2026-10-11)

The Makefile follows the layout of `feat-multiple-issues`. The original targets
run ordinary simulations; their `-debug` counterparts enable the checker.
`VERIFICATION` is no longer used. Normal models are under `build/normal`, debug
models under `build/debug`. Bash handles build locks, caching and progress output;
FuseSoC owns model compilation and execution.

| Check | Actual result |
| --- | --- |
| `make verilator-build verilator-build-debug JOBS=4 -j2` | Both models built; start/completion messages only |
| Repeated model builds | Passed silently, without recompilation |
| Ordinary `verilator-sim` with `DUMP_TRACE=true`, waves off | Passed; common trace link points into `build/normal/sim-verilator/logs/` |
| `make run-benchmarks` with `crc32` and `aha-mont64`, `-j4` | SUCCESS, 2/2 |
| Equivalent `make run-benchmarks-debug`, waves off | SUCCESS, 2/2; isolated reports; 25,904 and 10,102 checkpoints |
| `verilator-opt-debug DEBUG_ARGS=--diff-fault=register DUMP_WAVES=true` | Expected failure propagated through FuseSoC and Make; original/annotated FST and GTKWave save file present |
| Invalid FuseSoC build option in a separate build directory | Failed; diagnostics and build-log path printed; no completion message |
| Shell syntax and `git diff --check` | Passed |

Benchmark tests reused the existing SPIKE_CHECK firmware in an isolated
`build/target-validation` suite tree. Normal and debug console logs and summaries
are separate; checked reports live in `build/target-validation-debug/run/`.
No full benchmark sweep was run. Sections below retain historical commands and
results; use the current [guide](README.md) for target names and options.

## FuseSoC build/run flow (2026-10-11)

RTL and checker compilation/linking and simulation now run through FuseSoC's
`sim` and `sim-diff` targets. The Python model compiler and quiet-build wrapper
were removed. Python compiles cached Spike libraries and generates the checker
layout header from the XML produced by Edalize's XML target.

| Run | Actual result |
| --- | --- |
| Ordinary `crc32` through `make verilator-opt VERIFICATION=false` | FuseSoC build and run passed; program exit 0x00 |
| Checked `crc32` through FuseSoC | Passed: 29,432 commits, 25,904 checkpoints, no discrepancies |
| Parallel checked `crc32` and `aha-mont64` through `make run-benchmarks ... -j4` | SUCCESS, 2/2; separate report directories; aha-mont64 had 11,916 commits and 10,102 checkpoints |
| Register observation fault through `VERIFICATION_ARGS=--diff-fault=register`, waves enabled | Confirmed result mismatch; checker status 1; FuseSoC and Make returned failure; original and annotated FSTs and GTKWave save file generated |
| Repeated ordinary and checked `verilator-build` | Both returned success with no terminal output or model rebuild |

Artifacts are under `build/fusesoc-validation/`. The parallel run used an isolated
benchmark output tree containing the existing SPIKE_CHECK firmware images, so
older suite failures did not enter its summary. No full benchmark sweep was run.

## FS/fcsr implementation (2026-10-09)

Both the ordinary and `VERIFICATION=true` Verilator builds passed using the cached
Spike v1.1.0 libraries. No vendored Spike source was changed or downloaded.
The old startup/CSR-operand limitations described in the historical sections below
are fixed by this change.

| Run | Actual result |
| --- | --- |
| Existing `load_store`, default hard-float startup, ordinary simulation | Program exit 0x00 |
| Same image, `VERIFICATION=true`, waves off | Passed: 2,716 commits, 1,013 checkpoints, no discrepancies |
| Existing Embench `crc32`, `CDEFS=-DSPIKE_CHECK`, ordinary simulation | Benchmark result check passed, exit 0x00 |
| Same benchmark through `make run ... VERIFICATION=true`, waves off | Passed: 29,432 commits, 25,904 checkpoints, no discrepancies |
| `make run-benchmarks PARALLEL_TESTS=crc32 VERIFICATION=true DUMP_WAVES=false CDEFS=-DSPIKE_CHECK` | SUCCESS, 1/1 benchmarks, summary generated |
| Temporary CSR probe, waves on | Passed: 99 commits, 97 checkpoints; FS/SD and fcsr/frm/fflags read/write/set/clear, retained state across Off/Dirty |
| Register-observation fault in the CSR probe | Simulator status 1 / Make status 2; instruction 1, PC 0x10180, commit result expected 0x1800, actual 0x1801, cycle 19 / FST tick 39 |
| Five temporary FS-Off probes: FP CSR read/write, FP move/load/store | Each passed independently in RTL and Spike: illegal-instruction cause 2, correct mepc and mtval, handler exit 0x00 |
| Temporary FP arithmetic probe with operands loaded from memory | Passed independently in RTL and Spike: dynamic RTZ/RUP, static rounding override, NX/DZ/NV accumulation, f0 source, flags preserved by an exact operation |
| FS Initial/Clean writes | RTL maps both to Dirty and passes readback checks; checker status 2 with explicit unsupported explanation |
| F/D instruction or trap-entry boundary with verification enabled | Explicit status 2; full F/D/trap synchronization is still unsupported |

Temporary probes and a small standalone C++ Spike driver were used for directed
validation; they are not an automatically run or installed test suite. Artifacts
are under `build/fs-validation/`; regular benchmark evidence is under
`build/embench/run/crc32/logs/diff/report.json` and `build/embench/logs/sim/crc32.log`.
Both program exit bytes and checker reports were inspected: the existing ordinary
simulator returns process status zero even on program failure or timeout, so that
status alone was not used as evidence of success.

The CSR probe produced original and annotated FSTs. `fst2vcd` parsed the annotated
fault waveform successfully; expected/actual values and the failure signal were
checked against `report.json`. The generated GTKWave marker is at tick 39,
matching the recorded event. No GTKWave GUI was required.

The FP probe initially using `fmv.d.x` exposed a separate existing FP move problem:
that instruction is decoded as `FPU_L2D`, and its observed result did not preserve
the input bits. That mapping is unchanged. The rounding/flag probe uses `fld` to
isolate the FS/fcsr behavior; its pass is not a claim that all F/D instructions work.

Reproduce the existing-program checks from the repository root after sourcing
`private/init.sh` (initialize Conda in noninteractive shells first):

```sh
make app PROJECT=load_store
make verilator-sim VERIFICATION=true DUMP_WAVES=false DUMP_TRACE=true MAX_CYCLES=20000
make -BC sw benchmark SUITE=embench BENCHMARK=crc32 CDEFS=-DSPIKE_CHECK \
    BUILD_DIR="$PWD/build/embench/run/crc32" LINKER="$PWD/sw/linker/len5-sim.ld"
make run BENCHMARK=crc32 VERIFICATION=true DUMP_WAVES=false CDEFS=-DSPIKE_CHECK
```

`SPIKE_CHECK` is the existing benchmark option that omits timing-dependent counter
reads. It does not disable FS startup or change the benchmark's correctness check.
Without it, counter reads remain unsupported. Ordinary runs of both images were
also checked with `VERIFICATION=false`. No full benchmark sweep was performed.

## Historical cache cleanup and program flow


The separate `tests/diff` test programs/runners have been removed at the user's
request. `make check` has its original application/RTL checks again; it no longer
generates or runs the added verification suite. Existing application/benchmark
entry points and the `VERIFICATION`/`DUMP_WAVES` switches remain available.

* Existing Spike archives were moved to `build/spike-build` with their sizes and
  nanosecond modification timestamps unchanged. The new default build reused
  them, reported the libraries up to date, and rebuilt only the RTL executable.
* `make clean-keep-spike` was exercised in temporary build directories. Cache
  contents and timestamps survived; firmware, RTL outputs and hidden stamps
  were removed. Custom nested caches were retained, external symlink targets
  survived, and a missing build directory was handled without creating it.
* A previously compiled supported integer image was used for one-off runtime
  validation, outside the repository's removed test directory. Verification
  passed with waves off/on (94 commits each), preserving the Spike archive
  timestamps. `DUMP_TRACE=true` wrote `logs/sim-trace.log` in both the simulation
  and optimized targets. This image is not part of a retained test suite.
* The existing `sw/applications/load_store` program was built through `make app
  PROJECT=load_store` and passed ordinary `verilator-sim`, exiting with 0x00.
  Its commit trace was generated and the existing common-directory link worked.
  With verification enabled, default FP/CSR startup still returned unsupported,
  and Make propagated the failure. This was before the FS/fcsr changes above.

## Historical results before test-suite removal

The results below were recorded before removing the separate verification suite.
Their test-runner commands are historical, not current usage instructions.

The existing-target integration was validated with the local RISC-V GCC 15.2.0:

* `make check VERIFICATION=true`: **10 dependency-build tests, 9 Make integration
  tests, 27 tracker/FST tests and 26 actual LEN5/Spike cases passed**. The 13
  existing integration scenarios each run with waves enabled and disabled;
  their JSON results match exactly, including faults and unsupported exits.
* No-wave cases verify absence of the raw/annotated FSTs, GTKWave save file,
  field legend and event journal, including removal of seeded stale artifacts.
  Wave cases independently validate FST values and first-error markers.
* The same regression runs two real integer fixtures concurrently through
  `make run-benchmarks VERIFICATION=true`, with waves off, on, then off again.
  Both fixtures pass, retain separate working directories and generate the
  existing benchmark CSV summary. An injected CDB fault through
  `make verilator-opt` returns a failing Make status and a matching JSON report.
* `make verilator-sim` passed `memory_branch` in ordinary mode with waves off/on.
  `make verilator-sim VERIFICATION=true` passed the same firmware with waves
  off/on, each checking 94 commits. Relative firmware paths are resolved before
  changing the simulator's working directory.
* A default-toolchain `crc32` run through `make run-benchmarks VERIFICATION=true
  DUMP_WAVES=false PARALLEL_TESTS=crc32` compiled and launched successfully, then
  returned **unsupported** at startup. Its floating-point/CSR startup remains
  outside checker coverage. Make propagated that result as a failure and kept
  `build/embench/run/crc32/logs/diff/report.json`; no waveform was generated.
* The GTKWave launch command was checked with Make's dry run; no GUI was opened.

Earlier dependency and pipeline validation results follow. Their former
`diff-*` entry points have been replaced by the existing targets with
`VERIFICATION=true`; these historical measurements predate the optional-wave
integration above.

The vendored-dependency integration was validated again with the local RISC-V
GCC 15.2.0 toolchain loaded through `private/init.sh`:

* Pinned Spike libraries built successfully from `sw/vendor/riscv-isa-sim` into
  `build/diff/spike-build`, without changing upstream sources or installing a CLI.
* The verification RTL build automatically ensured the reference libraries and
  rebuilt the actual RTL checker with their new local paths.
* A repeated identical build completed in approximately 0.32 seconds, reported
  both libraries and simulator up to date, and changed no archive or executable
  modification timestamps. This run required no network access.
* The verification suite passed all **10 dependency-build tests, 27 tracker tests and
  13 actual LEN5/Spike integration cases**. Expected injected failures and
  unsupported cases remain distinct from matching programs.
* The new dependency tests cover initial build, unchanged reuse, missing archives,
  backdated header edits, changed compiler flags/configuration, missing commit
  logging, failed-build recovery, wrong pins and missing-source rejection.

This dependency change adds no FP or privileged-state verification coverage.

* Tracker/FST unit tests: **27 passed**, including multi-event timestamps, repeated
  PCs, ROB reuse after commit/flush, wrong-path execution, out-of-order and
  incomplete checkpoints, WAW corruption, delayed memory writes/responses,
  authorization/order faults, timeout, CSR state and FST hierarchy/alias checks.
* Earlier hardware integration: **13 real LEN5/Spike runs passed their expected outcomes**:
  four matching programs, four injected failures, four explicit unsupported
  boundaries and one known RTL CSR failure. `memory_branch` produced 94 commits,
  88 checkpoints, six out-of-order commits and three frontend recoveries, with
  zero discrepancies. Tests independently convert annotated FSTs with `fst2vcd`
  and check original RTL, expected/actual values, mismatch timestamps and the
  exact GTKWave primary marker. GUI launch was not required/tested.
* An ordinary FuseSoC model built without Spike and ran `memory_branch`.
  Its 186-line existing execution trace matched the checker-built simulator
  with checking disabled byte for byte; both generated normal FSTs.
* Existing `scripts/sim/check-load-store.sh`: **passed**, including ordering,
  forwarding, delayed tags, queue reuse and flush.
* Existing `make check-alu`: **blocked by 13 existing Verilator WIDTHEXPAND
  warnings**, concerning the 4-bit ALU control versus 6-bit operation enums.
  No RTL was changed to suppress these. The aggregate `make check` includes
  RTL formatting and was not run as a substitute for these targeted checks.

The checker also found a reproducible existing CSR bug. In
`issue_decoder.sv:706`, CSRRW/CSRRS/CSRRC select `rs2_sel` but leave `rs1_sel`
at NONE; `issue_stage.sv:550` uses `rs1_value` for the CSR operand.
`csr_register_bug.S` writes 256 to mscratch but LEN5 supplies 0. The regression
requires a nonzero failure at PC `0x10184`, field `rs1_value`, expected 256,
actual 0. The existing `hello_world` startup similarly fails `csrw mtvec,a0`
at `0x101bc` (expected 65537, actual 0). This is reported at the operand's
original dispatch timestamp and confirmed at commit. Processor RTL remains
unchanged; fix that separately before expecting these application startups to
pass differential verification.
