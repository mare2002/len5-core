# Validation results

[Build and run instructions](README.md) · [Signal map and limitations](ARCHITECTURE.md)

Validation on the supplied tree used Spike v1.1.0, Verilator 5.040 and GCC 16.

## Cache cleanup and current program flow

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
  and Make propagated the failure; that coverage limitation is unchanged.

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
