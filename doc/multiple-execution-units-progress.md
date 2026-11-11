# Multiple execution units: recovery checkpoint

Work remains on `feat-multiple-issues`; all earlier uncommitted changes are preserved.

- **A:** Multi-output arbitration, shared arithmetic RS, forwarding, and ALU
  instances were already implemented. The earlier session reported passing
  focused arbiter and integer/FPU RS tests; those suites were not repeated here.
- **B: complete for the focused one-/two-unit scope.** Parallel and serial
  multiplier instances, per-lane held serial contexts, divider instances, and
  handshake-gated divider metadata were already implemented. This session
  completed their physical-wrapper verification without further RTL changes.
- **C: complete for the focused one-/two-unit scope.** Physical FPnew wrapper
  tests passed with fixed-priority and round-robin scheduling. Existing RTL
  required no changes; the existing testbench and runner were extended.
- **D: bounded integration complete.** Seven representative full-core
  configurations passed Spike, with the existing D-enabled FLW boxing defect
  excluded and recorded below. Broader regressions can proceed with that known
  failure tracked; this is not an unrestricted architectural sign-off.

## Verification completed in milestone B

All builds used `-j1`, with a lint/elaboration check before each wrapper build.

| Check | Result |
| --- | --- |
| Parallel multiplier, pipeline depth 1, units 1/2, fixed/RR | 4 passed |
| Serial multiplier, units 1/2, fixed/RR | 4 passed |
| Divider, units 1/2, fixed/RR | 4 passed |
| Parallel multiplier, pipeline depth 2, units 2, fixed/RR | 2 passed |
| Divider metadata: queued word/full/illegal operations, stalls, flush | Passed |

The wrapper scoreboard checks exactly-once dispatch/completion/writeback,
simultaneous dispatch, simultaneous parallel-multiplier completions,
out-of-order divider completion, stable active serial contexts, CDB stalls,
and flush followed by immediate ROB-tag reuse with different expected results.

`scripts/sim/check-exec-units-multi.sh` now builds one configuration at a time.
Its default is the 12 one-/two-unit multiplier/divider cases above. Use
`EXEC_KINDS=1 UNIT_COUNTS=2 EXEC_VARIANT=2` for the two additional pipeline cases.
Each lint/build is limited to 120 seconds and each simulation to 15 seconds;
timeout termination covers child compiler processes. Logs are under
`build/exec-units-multi/` and `build/div-metadata/`.

The original 44-case concurrent model is preserved as
`exec_units_multi_matrix_tb`, selected only with `EXEC_UNITS_FULL_MATRIX=true`.
Do not use it for resource-limited verification. Counts 3/4/8 and full LEN5
regressions were not run in this recovery session. Earlier full lint and ALU
targets stopped on vendored-source diagnostics; integration must revisit them.

## Verification completed in milestone C

The final `bash scripts/sim/check-fpu-units-multi.sh` run passed all four
configurations below, one configuration at a time with `-j1`. These use the
D-enabled, four-stage FPU configuration and exercise both single- and
double-precision operations.

| Physical FPUs | Arbitration | Peak dispatch/completion | Stall checks | Independent progress | Result |
| --- | --- | --- | --- | --- | --- |
| 1 | Fixed priority | 1 / 1 | 190 | Not applicable | Passed |
| 1 | Round robin | 1 / 1 | 190 | Not applicable | Passed |
| 2 | Fixed priority | 2 / 2 | 19 | Observed | Passed |
| 2 | Round robin | 2 / 2 | 19 | Observed | Passed |

The extended existing testbench checks:

- Exactly-once dispatch, completion, and single-CDB writeback with correct ROB
  tags, result values, exception metadata, and all five `fflags` bits.
- Two simultaneous local results forwarding into different operands, alongside
  CDB forwarding for the third operand, for both an existing and a newly
  inserted FMA instruction.
- Stable request control, operands, ROB tags, and resolved rounding modes under
  backpressure, including changes to the dynamic rounding CSR while stalled.
- Static/dynamic rounding, an explicit older-divide/younger-add out-of-order
  completion sequence, and buffering all 16 results while CDB access is blocked.
- Flush with accepted requests in multiple physical FPUs and completed results
  awaiting CDB access, followed immediately by reuse of flushed ROB tags with
  different operations/results and a check for late results.

Verification fixes were confined to the testbench: allow combinational ready
to settle after flush deassertion; require an explicit out-of-order sequence;
fill the RS sufficiently to cause backpressure; place the fast special-case
divide in the first dispatched pair in either arbitration mode. No functional
RTL defect was demonstrated. Branch/LSU/ROB/commit logic and the CDB interface
and arbitration were not changed.

The runner defaults to counts `1 2` and both arbiters. Existing `UNIT_COUNTS`,
`ARBITERS`, `PRECISIONS`, and `PIPE_DEPTHS` overrides remain explicit options;
larger counts and other precision/pipeline configurations were not run during milestone C.
Each configuration has a 60-second lint limit, 180-second build limit, and
15-second simulation limit, with termination of child compiler processes.
Logs are under `build/fpu-units-multi/n{count}-rr{mode}-d1-p4/`.

Focused Verible lint and shell syntax checks passed. Verilator elaboration
passed with latch, combinational-loop, multiple-driver, and implicit-signal
warnings treated as errors, using the existing vendor waivers. Full integration
and regressions were deliberately not started during milestone C.

## Milestone D: final integration

### Architecture and review

`ALU_NUM_UNITS`, `MULT_NUM_UNITS`, `DIV_NUM_UNITS`, and `FPU_NUM_UNITS` are
positive physical-instance counts for enabled categories, defaulting to one.
Disabled optional categories may use zero. The counts are propagated through
both configuration structs, defaults, `build_config`, validation, TB parameters,
FuseSoC targets, and simulation argument handling. They are independent of
`ISSUE_WIDTH`, `MULT_EU_N`, `DIV_EU_N`, `FP_EU_N`, and `MAX_EU_N`; these last
fields retain their category/identifier meanings. Core metadata confirmed,
for example, three ALUs with issue width two and seven CDB source slots.

Each category retains one RS and one CDB output. Execution requests hold their
assigned indices under stalls. Accepted completions match live entries by ROB
tag, including same-cycle dispatch/completion, and each operand independently
selects accepted local forwarding or CDB data. Completed entries remain buffered
until CDB acceptance; allocation still excludes entries released in that cycle.
The multi-output RR selector finishes eligible saved-round requests before
starting a new round and advances progress on accepted grants. No age-based
policy was introduced, and legacy `rr_arbiter.sv` is unchanged.

Serial multipliers retain an independent held context per physical instance.
Multi-FPU configurations use the existing registered request spill cells because
FPnew readiness depends on the presented operation. The selector's readiness
contract is now documented. Branch, LSU, issue/exec-stage routing, CDB, ROB, and
architectural commit implementations were not modified by this task.

Two review fixes were made:

- Separate flush-dependent spill-cell `ready_o` from the state-only valid/select
  block. The previous grouping introduced an artificial frontend recovery loop
  diagnosed by full-core elaboration. Substituting the original control module
  removed the diagnostic; the split preserves the original output truth tables.
- Restore the legacy illegal-RS-state checks as Verilator-compatible assertions
  in the integer and FPU RSs, also covering the shared serial RS implementation.

### Executed full-core configurations

All runs used the existing `tb_bare`/Spike checker, Verilator 5.040, `-j1`,
TC_SRAM, boot PC `0x10000`, and the short mixed assembly workload in
`tb/expipe/multiple_exec_integration.S`. "Default" below refers to default
physical-unit/pipeline settings; memory backend and boot address were selected
for the existing checker's supported scope. Each run checked integer and FP
arithmetic, dependent/independent operations, memory, branches, CSR rounding and
flags, and successful program exit, without waveform/trace dumps.

| Case | ALU/MULT/DIV/FPU | Issue width | Selection / pipeline variation | Spike commits | Result |
| --- | --- | --- | --- | --- | --- |
| default | 1/1/1/1 | 1 | RR; parallel MULT depth 1, FPU depth 4 | 116 | Passed |
| alu-mult | 2/2/1/1 | 4 | Fixed ALU/MULT | 116 | Passed |
| alu-div | 2/1/2/1 | 2 | RR | 116 | Passed |
| alu-fpu | 2/1/1/2 | 4 | Fixed ALU/FPU | 116 | Passed |
| all-two | 2/2/2/2 | 4 | RR; serial MULT, FPU depth 2 | 116 | Passed |
| three-alu | 3/2/1/1 | 2 | Fixed ALU/MULT; parallel MULT depth 2 | 116 | Passed |
| fp32-only | 2/1/1/2 | 2 | RR; F-only, FPU depth 2 | 109 | Passed |

Default and all-two were rerun after the final review changes. Additional checks:

- Default, three instances of every category with issue width one, and disabled
  optional categories with zero instances elaborated. All four enabled-zero
  configurations were rejected by `check_build` with the intended diagnostic.
- Physical three-ALU directed test passed, including simultaneous dispatch.
- FP32-only, two-FPU, RR, depth-two directed test passed: simultaneous dispatch/
  completion, forwarding, all flags, out-of-order results, stalled rounding-mode
  changes, independent progress, and flush/tag reuse.
- All 24 existing fixed/RR selector tests passed, including sustained fairness,
  partial acceptance, stale-mask removal, and one/non-power-of-two input counts.
- Existing load/store ordering, forwarding, delayed-tag, queue-reuse, and flush
  regression passed following the shared spill-control change.
- Focused production Verible lint, Python syntax, and whitespace checks passed.
  RTL-only `len5_top` elaboration with `SYNTHESIS` defined and the all-two
  configuration passed. Latches, combinational loops, multiple drivers, invalid
  selections, and implicit nets were treated as errors in integration checks.
  Mapped synthesis, STA/PPA, and formal verification were not performed.

### Reproduction and diagnostics

Run the bounded integration target with the existing FuseSoC environment:

```sh
make check-multiple-exec-integration FUSESOC=/path/to/fusesoc
# Optional subset; the runner also accepts explicit tool paths.
make check-multiple-exec-integration FUSESOC=/path/to/fusesoc INTEGRATION_CASES=default,all-two
```

The runner builds one case at a time, uses a 300-second compilation limit and
30-second simulation limit, and retains per-case setup/lint/build logs and
`run/logs/diff/report.json` under `build/multiple-exec-integration/`. The final
collected results and elaborated parameter values are in `final-summary.json`.
The separate
configuration checker now defaults to three representative elaborations plus
four invalid-count checks, with timeouts; its original larger selection remains
available explicitly with `--cases all`.

The ordinary Spike bootstrap wanted a large rebuild after compiler identity
changed. Its pinned source fingerprint, archive size/timestamp signatures, and
commit-log configuration matched the recorded cached build, so the integration
runner verified and reused those archives without rebuilding third-party code.

Unresolved findings are separate from the multi-unit implementation:

1. **Existing LSU FLW boxing defect with D enabled.** The first default run
   failed at PC `0x100d8`, instruction `flw f9,8(s0)`: expected
   `0xffffffff42a60000`, actual `0x0000000042a60000`. The LSU is unchanged and
   explicitly outside this task's modification scope. Evidence is saved as
   `default/flw-boxing-failure.json`; it was reproduced on the final RTL in the
   separate `default/flw-repro/` run. D-enabled successful workloads use FSD/FLD;
   the F-only workload uses FSW/FLW. Compile the assembly with
   `-DLEN5_REPRO_FLW_BOXING` and D enabled to reproduce the excluded failure.
2. **Unchanged vendor/tool diagnostics.** ALU-target lint passes with 5.040 and
   fails with six `IMPORTSTAR` warnings in unchanged MVP vendor files under
   5.046. Standalone Verible reproduces ten style diagnostics in unchanged
   `tech_cells_generic/tc_sram.sv`. No third-party RTL was modified. Logs and
   classification are in `vendor-diagnostics.json` and adjacent log files.
3. Full-core counts 4/8, other pipeline depths/RS depths, other memory backends,
   broader random/firmware campaigns, traps/interrupts, and PPA/formal sign-off
   remain untested here. Existing zero-stage parallel multiplication remains
   unsupported. The standalone selector/RS evidence from milestone A is broader
   than this bounded physical/full-core matrix.

Files changed during D: `rtl/common/spill_cell_flush_cu.sv`,
`rtl/common/ex_request_selector.sv`, `rtl/expipe/exec-units/arith_rs.sv`,
`rtl/expipe/exec-units/arith_rs_fpu.sv`, `scripts/sim/check-multiple-exec-config.py`,
new `scripts/sim/check-multiple-exec-integration.py`, new
`tb/expipe/multiple_exec_integration.S`, `makefile`, and this checkpoint.
