# Validation results

[Build and run instructions](README.md) · [Signal map and limitations](ARCHITECTURE.md)

Validation on the supplied tree used Spike v1.1.0, Verilator 5.040 and GCC 16.

The vendored-dependency integration was validated again with the local RISC-V
GCC 15.2.0 toolchain loaded through `private/init.sh`:

* Pinned Spike libraries built successfully from `sw/vendor/riscv-isa-sim` into
  `build/diff/spike-build`, without changing upstream sources or installing a CLI.
* `make verilator-build DIFF=1` automatically ensured the reference libraries and
  rebuilt the actual RTL checker with their new local paths.
* A repeated identical build completed in approximately 0.32 seconds, reported
  both libraries and simulator up to date, and changed no archive or executable
  modification timestamps. This run required no network access.
* `make diff-test` passed all **10 dependency-build tests, 27 tracker tests and
  13 actual LEN5/Spike integration cases**. Expected injected failures and
  unsupported cases remain distinct from matching programs.
* The new dependency tests cover initial build, unchanged reuse, missing archives,
  backdated header edits, changed compiler flags/configuration, missing commit
  logging, failed-build recovery, wrong pins and missing-source rejection.

This dependency change adds no FP or privileged-state verification coverage.

* `make diff-unit`: **27 passed**, including multi-event timestamps, repeated
  PCs, ROB reuse after commit/flush, wrong-path execution, out-of-order and
  incomplete checkpoints, WAW corruption, delayed memory writes/responses,
  authorization/order faults, timeout, CSR state and FST hierarchy/alias checks.
* `make diff-test`: **13 real LEN5/Spike runs passed their expected outcomes**:
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
