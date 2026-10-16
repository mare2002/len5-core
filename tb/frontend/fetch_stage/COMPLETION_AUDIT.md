# Frontend execution/completion policy audit — 2026-10-16

This entry supersedes the earlier exit-policy conclusions below; it does not
supersede the original architectural findings or claim completed coverage.
Production sources on entry select **N=4**, SHA256
`3811d38c7ebb78ad94473fddb9c62a39d497bd6594bab8c7d8a6848337bbd97a`.
The task's N=2 description and the historical N2 audit are not the active source.
No configuration selection or RTL change was made.

## Result-policy root cause and defaults

The actual saved report exists at
`build/fetch-stage/core/ordinary-30hf8h8k/summary.json`. It executed47 native IDs,
68 variants,42,517 cycles and1,699,257 comparisons with **zero field mismatches,
zero environment errors and zero framework errors**. All ordinary IDs/variants
passed except **FE-T15**, variant2, program`interacting`, which missed
`gshare-public-threshold-up`. Its67 other native variants passed. FE-T54's24
composite validators passed separately. No excluded characterization scenario
accidentally entered ordinary scope.

FE15 made116,883 comparisons,114 actual training updates, and reached its program
marker after3045 cycles within its6000-cycle budget. It had a down-threshold
witness but no public upward-threshold witness. This was **not a timeout or an RTL
comparison failure**. The core aggregator returned3 whenever any child exited
nonzero, discarding the difference between an incomplete result and a hard failure.
Native reporting also printed TEST FAILED when all comparison errors were zero.

Default latency1–64, repetitions32 and6000-cycle budget were consistent across
Make/Python/C++; the problem was not a hidden conflicting latency default.
The previously documented1–8/repetitions8 recipe was N2 evidence, not a guarantee
for the present N4 training history. Six short causal FE15 profile experiments
(4,894 cycles total) also missed an upward witness; reducing all execution delays
would not resolve this goal honestly. The short default8-repetition candidate was
therefore **discarded**. Final defaults retain the broad1–64 latency and original
32 repetitions/6000-cycle budget. Missing FE15 coverage remains unexpected and
prominent, rather than being reclassified as a planned exclusion.

FE34/47 keep their explicit fixed64 causal fixtures; FE37 keeps its seeded older64/
younger1 fixture; FE38 retains seven distribution variants. Explicit latency
options now override default34/37/47 fixtures. Reports distinguish requested and
active settings. Directed event/memory streams restart per episode so full-catalog,
single-case and parallel invocations have the same relative causal stimulus.
Random episodes retain continuous independent streams. Marker termination is
reported separately from a bounded stop. No missing training or RAS probe is
fabricated, canceled-as-complete, or removed from a gate.

## Status, aggregation and confidence changes

`results.py` is the frontend-specific structured policy shared by run/catalog/core/
suite/regression. PASS and WARN_INCOMPLETE/WARN_PROVISIONAL return0 by default.
STRICT_COMPLETION=true returns3 for selected incomplete/provisional obligations.
Known comparison failures return1; invalid environment/configuration or framework
failures return2. Precedence is2 then1 then3 then0. A clean bounded cycle stop is
incomplete; an unexpected native crash/watchdog, malformed/missing report, empty
suite or zero useful comparisons is a framework error. The native process watchdog
is120 wall-clock seconds, separate from the cycle limit.

Native reports keep canonical per-variant classifications and typed result counts;
aggregation no longer searches serialized JSON strings for status. Reports retain
scenario, variant, program/digest, requirement, cycle/budget, active latency,
termination, exact missing witnesses, local accepted-event counters and evidence.
Deferred requirements have named remaining obligations rather than generic blank
warnings. FE41's matching same-edge EQ07 hypothesis is WARN_PROVISIONAL, without
approving its ordering. Known field mismatches remain hard even if their legacy
confidence/provenance count is labeled provisional under I context.

Core validates its predeclared47-ID native scope and all required variants before
merging executed FE54. It retains exclusions41/43/48/49/50/51 explicitly. Full
catalog requires all54 IDs and every applicable variant, and replaces only the
FE54 delegation placeholder. Native errors/aborts, missing variants and absent
receipts cannot be overwritten by composite success. Parallel workers use distinct
directories; independent groups continue after warnings or failures. Suite results
come from structured receipts. Explicit matrix coverage requirements remain
reported; strict mode gates missing selected coverage, with no deleted goals.

FE54 validates all24 actual executions, matching binary/manifest/configuration,
independent unit logs, current report files and exact expected failure classes.
An invalid-feedback test must detect FAIL_ENVIRONMENT, not an unrelated framework
error. Empty tests detect FAIL_FRAMEWORK. Its timeout/missing-training/unknown
fixtures deliberately request strict native mode and detect WARN_INCOMPLETE/exit3.
Injected field failures require actual injected discrepancies, including raised
cause0. Repeated first failures and public/FST journals match. No stale receipt or
native placeholder can supply a synthetic confidence PASS.

The composed full report preserves`report.native.json`; native delegation checks
and external confidence checks are counted once with explicit component totals.
Expected-negative injected mismatches are kept separate from ordinary DUT errors.
A successful process never sets incomplete scenarios to PASS or asserts full
contract sign-off. Strict mode on a known incomplete scenario rejects completion;
GNU Make reports `Error 3` and itself returns2, while native/Python/report exit is3.

## Focused validation and remaining coverage

Final command receipts, counts, evidence paths and hashes are recorded below and
in`build/fetch-stage/result-policy-audit/FINAL_RESULT_POLICY_AUDIT.json`.
No million-cycle regression, mutation campaign or full aggregate was executed.
The original pure PC/EJU/FM model algorithms and all golden frontend transitions
remain unchanged.

37 synthetic Python tests cover pass/warnings/strict/hard-failure precedence,
expected and unexpected incompleteness, variants and comparison conservation,
empty/crashed/watchdog/malformed results, stale configuration/FE54 receipts,
missing validators, a negative that did not detect its injection, exact negative
failure classes, missing training witness and actual catalog composition. These
fixtures are explicitly synthetic; they are not claimed as24 real RTL validators.
Pure C++ validation passes70,579 new assertions plus PC341/EJU16,931/FM8,310.

A small ad-hoc expected-framework-negative command initially omitted its injection
flag. The validator rejected the resulting clean incomplete run, as required.
`focused-1jl81krl/diagnosis.json` preserves that invalid test-fixture evidence;
`focused-sleuh3zh/summary.json` records the corrected injection (15 comparisons,
FAIL_FRAMEWORK/exit2) and byte-identical FE34 replay. Neither is an RTL defect.

The ordinary scope can execute successfully with warnings; full specification
completion remains false. FE15 upward-threshold coverage is still missing.
FE43/48/49/50/51 remain deferred/incomplete, FE41 ordering remains provisional,
EQ08 and the delayed exception window are unfixed, and inherited FEQ/EQ/FQ
questions and complete per-operation/FEV closure remain unresolved. No full-core,
CSR/mtval, retirement or predictor-independent completeness is claimed.

## Canonical executed results (final source)

| Command | IDs / variants | PASS | Incomplete / provisional | Hard failures | Cycles | Comparisons | Test exit / Make exit |
|---|---:|---:|---:|---:|---:|---:|---:|
| `make check-fetch-stage-core JOBS=2` | 48 /69 | 47 | 1 /0 | 0 | 43,449 | 1,728,549 | 0 /0 |
| `make check-fetch-stage-run` | 54 /75 | 47 | 6 /1 | 0 | 57,459 | 2,139,487 | 0 /0 |
| `make check-fetch-stage-run SCENARIO=FE-T54` | 1 /1 | 1 | 0 /0 | 0 | 847 | 30,489 | 0 /0 |
| strict FE-T48,500-cycle budget | 1 /1 | 0 | 1 /0 | 0 | 504 | 19,681 | 3 /2 |
| strict FE-T01 | 1 /1 | 1 | 0 /0 | 0 | 549 | 39,563 | 0 /0 |

Every ordinary DUT comparison above has zero mismatches. Environment/framework
failures are zero. FE54 contains11 intentionally injected mismatches, all detected
with the expected FAIL_MISMATCH classification; these are successful negative
validators, not ordinary DUT failures. Its24 executions contribute847 cycles and
30,489 comparisons to the composed totals. Full-catalog FE54 also retains its
native delegation checks in the actual comparison total, without counting the ID
twice. Pure C++ units execute96,161 assertions; the separate Python policy suite
executes37 tests. No exhaustive FEV closure is claimed.

| Canonical evidence | File |
|---|---|
| `make check-fetch-stage-core JOBS=2` | [build/fetch-stage/core/ordinary-xmigswzl/summary.json](../../../build/fetch-stage/core/ordinary-xmigswzl/summary.json) |
| `make check-fetch-stage-run` | [build/fetch-stage/run/all-ebsxv72_/summary.json](../../../build/fetch-stage/run/all-ebsxv72_/summary.json) |
| `make check-fetch-stage-run SCENARIO=FE-T54` | [build/fetch-stage/confidence/FE-T54-whtf92il/execution-summary.json](../../../build/fetch-stage/confidence/FE-T54-whtf92il/execution-summary.json) |
| strict FE-T48,500-cycle budget | [build/fetch-stage/run/FE-T48-km5lhu0r/summary.json](../../../build/fetch-stage/run/FE-T48-km5lhu0r/summary.json) |
| strict FE-T01 | [build/fetch-stage/run/FE-T01-lxpakix8/summary.json](../../../build/fetch-stage/run/FE-T01-lxpakix8/summary.json) |

Warning details:

| ID | Classification | Missing/unresolved requirement |
|---|---|---|
| FE-T15 | Unexpected incomplete coverage | FE05/FE08/FEV08 public upward-threshold witness.116,883 comparisons and114 updates passed; down threshold witnessed. The independently indexed1→2 update at cycle257,H5,index3,PC0x18 is not by itself a public before/after witness. |
| FE-T41 | Provisional interface-stress result | EQ07 same-edge confirmation/restoration approval; compared current hypothesis matches, no ordering decision inferred. |
| FE-T43 | Deferred incomplete | Full exception-recovery/cold-predictor/intended-history obligations. |
| FE-T48 | Deferred incomplete | EQ08 delayed older data-fault backend context. |
| FE-T49 | Deferred incomplete | Complete delayed-redirect/intervening-dispatch surviving-stream obligations. |
| FE-T50 | Deferred incomplete | Full faulting JAL/RET characterization; exact retained fault transport still checked. |
| FE-T51 | Deferred incomplete | FQ02/03/04 alternative memory protocols; ordinary active-contract checks still execute. |

Core has one missing required witness and no deferred cases. Full catalog has
six named missing obligations, including five deferred ones, plus one provisional
EQ07 result. None becomes PASS merely because the process returns0. The ordinary
scope remains incomplete in coverage, while all its executed checks succeed.

The final ordinary native runs accepted10,468 memory requests:6,577 delivered and
3,891 legitimately canceled;14,909 dynamic instructions:7,159 retired in the
synthetic abstraction and7,750 canceled;2,659 training pulses,763 confirmations
and374 recoveries. Full native catalog:14,317 requests=8,634 delivered+5,683 canceled;
15,723 dynamic=7,875 retired+7,848 canceled;2,760 updates,828 confirmations,376
recoveries. Controlled-stop cancellation is not a missing required witness being
completed. Original obligation files and unobserved RAS/training records remain.

Additional focused validation:

* Two seeds×64 cycles:128 native cycles,3,496 comparisons,zero mismatches. One seed
  and three channel-matrix rows remained incomplete; default process returned0
  with warnings. This is a regression-orchestrator smoke, not matrix closure.
* FE34 recorded-command replay matches the parallel core-worker journal byte for
  byte, including its default fixed64 fixture. Explicit override provenance and
  source fingerprint are replayed; no expected state is repaired.
* A genuine injected framework failure gives FAIL_FRAMEWORK/exit2 with15 checks;
  invalid feedback gives FAIL_ENVIRONMENT, and every public field injection gives
  FAIL_MISMATCH/exit1. FE54 checks their exact classifications.
* Two explicitly synthetic concurrent group processes demonstrate that a mismatch
  stays exit1 while an independent warning group still completes. This does not
  execute the full aggregate.

Final source extra evidence:
[`acceptance-extra-8ztfgovq/summary.json`](../../../build/fetch-stage/result-policy-audit/acceptance-extra-8ztfgovq/summary.json).
The earlier extra replay/injection paths above are preserved development evidence.

Development receipts, including superseded report-schema validations and expected
negatives, are inventoried in FINAL_RESULT_POLICY_AUDIT.json: **417,375 staged
native cycles** before documentation finalization. Repeated core/catalog runs
validated successive classification/counting fixes; their cycles are not extra
distinct functional coverage. The final command rows alone are canonical. The
original failure, rejected short FE15 candidates and invalid ad-hoc negative remain
separately labeled. No million-cycle campaign, full mutation sweep or full suite
was run.

## Files, source integrity and reproduction

All341 protected production/configuration/prior-framework source hashes match
`protected-before.json`. No production RTL, RTL configuration, existing PC/EJU/FM
implementation or oracle changed. Only root`makefile` and frontend-specific test
code/documentation changed. Final compiled-source fingerprint:
`c2e4497e54b0c52c1653f574340641e31a27eba61bcee4e9334d8aa9bc1da0ee`. All final reports/receipts agree with it. Markdown
updates do not participate in the compiled fingerprint.

Files changed:

* `makefile`
* `tb/frontend/fetch_stage/COMPLETION_AUDIT.md`
* `tb/frontend/fetch_stage/README.md`
* `tb/frontend/fetch_stage/VERIFICATION.md`
* `tb/frontend/fetch_stage/catalog.py`
* `tb/frontend/fetch_stage/confidence.py`
* `tb/frontend/fetch_stage/core.py`
* `tb/frontend/fetch_stage/fetch_stage_driver.cpp`
* `tb/frontend/fetch_stage/fetch_stage_driver.hh`
* `tb/frontend/fetch_stage/fetch_stage_tb.cpp`
* `tb/frontend/fetch_stage/regress.py`
* `tb/frontend/fetch_stage/run.py`
* `tb/frontend/fetch_stage/suite.py`
* `tb/frontend/fetch_stage/validate.py`
* `tb/frontend/fetch_stage/results.py`
* `tb/frontend/fetch_stage/results_unit.py`

```sh
source private/init.sh
make check-fetch-stage-core JOBS=2
make check-fetch-stage-run
make check-fetch-stage-run SCENARIO=FE-T54
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T48 DIRECTED_CYCLES=500
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T01
python3 tb/frontend/fetch_stage/results_unit.py
```

The strict incomplete recipe returns3 (GNU Make exits2). Exact waveform/journal
and replay commands are in each native report. `make check-fetch-stage` remains
available with the same warning policy but was deliberately not executed because
it launches the substantial regression and mutation groups.

---

# Focused frontend completion audit — 2026-10-15

The real frontend compiles and passes the focused supported-contract tests at
**N=1,2,4,8** with HLEN=4. No production parameterization failure was reproduced
for these four configurations. The source-selected working-tree value on entry
was **N=2**, not the earlier implementation record's N=4. Its pre-existing user
edit has been preserved byte for byte.

**Ordinary supported scope passes; full specification remains incomplete.**
This audit did not run the million-cycle regression, the full aggregate, a mutation
campaign, or a full-core test. Historical regression and mutation results remain
historical. The result is bounded verification evidence, not processor correctness.

Machine-readable evidence and all protected source hashes:
[`FINAL_COMPLETION_AUDIT.json`](../../../build/fetch-stage/completion-audit/FINAL_COMPLETION_AUDIT.json).

## A. Configuration and real multi-N execution

`widths_smoke.py` exports complete private `rtl/` and `tb/` libraries, writes a
private FuseSoC library configuration, and changes exactly the production
`LEN5_MULTIPLE_ISSUES` literal in each copy. It does not pass a fake N parameter
to the wrapper. Production packages, frontend modules and dependencies are
compiled consistently from that library. The wrapper's existing elaborated
configuration ports are checked against the source parser before simulation.

Each source tree and build root is distinct and content addressed. The existing
`configuration.py`/`run.py` build lock, source manifests, exported dependencies,
startup stale-source guard and static checks are reused. A parent `FUSESOC_IGNORE`
prevents private cores from entering the main library scan. Repeating the final
smoke reused the four previously built, unchanged private snapshots; there was
no further RTL compilation. Default build commands still select only live-source
N. `N_VALUES` is exclusively an explicit disposable-audit selector.

Final evidence:
[`evidence-tm14sgsn/summary.json`](../../../build/fetch-stage/widths-smoke/evidence-tm14sgsn/summary.json).
Each row contains the actual binary, source directory, commands and native reports.

| N | Real elaboration / static assertions | Reset/sequential | Every start lane / JAL | Conditional and JAL training | Calls, stale-BTB returns, recovery | Cause0 / access fault | Random smoke | Total cycles | Comparisons / mismatches |
|---|---|---|---|---|---|---|---|---:|---:|
| 1 | PASS | PASS,67 cycles | PASS,1 lane | PASS | PASS | PASS | 3×1500 PASS | 7,198 | 173,944 / 0 |
| 2 | PASS | PASS,44 cycles | PASS,2 lanes | PASS | PASS | PASS | 3×1500 PASS | 6,714 | 177,933 / 0 |
| 4 | PASS | PASS,40 cycles | PASS,4 lanes | PASS | PASS | PASS | 3×1500 PASS | 6,555 | 179,283 / 0 |
| 8 | PASS | PASS,31 cycles | PASS,8 lanes | PASS | PASS | PASS | 3×1500 PASS | 6,723 | 188,028 / 0 |

Total: **27,190 cycles,719,188 comparisons,zero mismatches**. The random portion
is **12 seed/configuration runs,18,000 cycles**: seeds1–3 at each N, respectively
uniform, triangular-early and bimodal sampled execution latency1–8. These are
three distinct seed values per configuration, not twelve distinct seed numbers.
Memory latency, grant stalls, backend readiness and program repetition remain
randomized. No all-cross closure was required from short smoke.

The fixed directed set is reset/short-sequential, FE-T02,06,07,17,18,19,09,28,30,33,34.
Training budgets are2000 cycles with8 repetitions; tests terminate on their actual
marker/witnesses. FE-T02/17 run every lane. Reset/sequential has a250-cycle budget.
FE-T34 uses an explicitly reported fixed64-cycle diagnostic fixture so several
wrong-path returns can precede the older branch resolution. N=1 excludes no
ordinary control-flow requirement; it has one real lane, not fictional missing
multi-lane bins. Actual first-pass initialization succeeded at all widths, so no
configuration was advanced past a failed reset.

### Source-level parameterization findings

| Area / source locations | Finding |
|---|---|
| `rtl/packages/len5_config_pkg.sv:37,100,103`; `len5_pkg.sv:21–29`; `fetch_pkg.sv:68–89` | Source N and derived bundle width propagate through package types. XLEN64, ILEN32, HLEN4, BTB_BITS4, RAS4, metadata2 remain unchanged. |
| `pc_gen.sv:44–67` | N=1 has a separate progression generate branch. Multi-lane part-select is excluded at N=1; ordinary progression is independently modeled as next aligned bundle boundary. |
| `bpu.sv:47,74–80`; `btb.sv:85–108`; `gshare.sv:22,43–113` | Single-lane cases avoid negative lane slices. N=8 leaves a positive one-bit PC prefix at HLEN4. BTB source-tag comparison and replacement remain exact, not false hits from different tags. |
| `gen_valid_instr.sv:11–65`; `early_jump_unit.sv:49,91–140`; `instr_mixer.sv:18–63` | Single-lane generate branches and minimum-one-bit EJU locator exist. Validity cutoff excludes pre-start/younger lanes; complete tuples are shifted. |
| `fetch_mem_if.sv:72–170`; `fifo_nohs.sv:51–146`; `spill_cell_flush.sv`; `spill_cell_flush_cu.sv` | One metadata record per accepted bundle; selected depth2 is independent of N. Ordered positive-latency capacity2 and coordinated cancellation prevent overwrite. No N-dependent FIFO occupancy width. |
| `ras.sv:41–173` | State depth and priority encoding depend on RAS_DEPTH, not N. Only selected depth4 is supported by the oracle. |
| `fetch_stage_tb.sv:10–70`; driver `drive/read_inputs/outputs` | Public arrays are unpacked and source sized, including N=1. Masks fit8 bits and C++ arrays have8 slots; loops use active N. No private signal was added. |
| `Config::validate`, `Composition::plan`, `Program::read`, backend dispatch, configuration parser | Bundle bytes, lane bounds, PCs, capacities and metadata snapshots derive from configuration. Existing pure PC/EJU/FM models are still linked directly. |

**Unsupported combinations:** production gshare's `curr_hist_i` range and BPU PC
slice require **HLEN>log2(N)**; its history shift also needs HLEN>=2. The existing
configuration guard rejects violations. All four tested N values satisfy this
with HLEN4. No HLEN sweep or alternative RAS/depth/timing configuration is claimed.
A future design supporting shorter histories needs its own generate/slicing
contract; it is not an oracle workaround. No production fix is needed for the
four selected N/HLEN4 combinations demonstrated here.

The effective BOOT_PC is the elaborated fetch-stage parameter0. No alternate
BOOT build was executed in this audit. FE-T19's targeted layout is established
for this boot alignment; arbitrary boot relocation may need another interference
layout and must retain an unmet witness rather than pass automatically.

## B. Verilator optimization investigation

Installed Verilator5.040 was tested with default optimization, Verilator `-O0`
and `-fno-dfg`. C++ compilation remained the same; `-O0` here is a Verilator graph
option. The O0 diagnostic build needed an additional UNOPTFLAT warning waiver
for its coarser dependency graph; width diagnostics were not disabled.

Original reproduction: immutable alternating program, seed1,N=4,500-cycle capture.
An independent public-port-only replayer removes the backend, golden model,
scoreboard, random generation and grant-feedback settling loop. It feeds exactly
the saved public inputs and consuming-edge sequence into the real production
frontend. RTL hashes are identical across the three builds.

* Default first differs at cycle245,post-edge, `issue_taken_o[0]`=0 versus1.
* The JAL atPC0x20 has the correct word,PC,hit and target0x28. Only its taken bit
  is wrong at the first meaningful sample.
* O0 and no-DFG agree on all compared meaningful public fields throughout.
* Four extra `eval()` calls at every phase change no result under any policy.

The new FE-T19 program reduces this to **cycle54,post-edge,165 public phase
samples**. It is a coherent immutable program/training history, not injected PHT
contents. Its JAL at0x180 targets0x100; default again forwards hit1,target0x100,
**taken0** where O0/no-DFG forward taken1. The checked pre-edge correction has
public memory-flush1. The minimal retained prefix includes reset and all causal
training. No claim of globally minimal RTL or instruction count is made.

Evidence:

* [`dfg-xw9j1vje/summary.json`](../../../build/fetch-stage/completion-audit/optimization/dfg-xw9j1vje/summary.json): original public replay, three policies, extra-evaluation control.
* [`FE19-reduced/summary.json`](../../../build/fetch-stage/completion-audit/optimization/dfg-xw9j1vje/FE19-reduced/summary.json): smaller witness.
* `FE19-reduced/minimal-inputs.txt`, `*-minimal.txt`: standalone165-sample vectors/results.
* `default/source/tb/frontend/fetch_stage/reproduce_dfg.cpp`: standalone replayer; no oracle or backend.
* `minimal-evidence.json`: equal production RTL digests and original prefix hash.

### Mechanism and confidence

The static generated C++ provides a concrete explanation. In default
`Vfetch_stage_tb___024root__DepSet_h9b60af80__0.cpp:1251–1280`, a mixer temporary
copies the partially rewritten EJU prediction **before** lines1281–1307 apply the
selected prediction's taken-bit rewrite. The mixer consumes the earlier copy.
SV `early_jump_unit.sv:264–271` completes that rewrite in its `always_comb gen_out`;
`instr_mixer.sv:34–58` must consume the settled tuple. Hit and target were already
rewritten, matching the observed isolated taken-bit error. A raw taken1 masks
this ordering problem; hit/not-taken JAL correction exposes it.

This supports a **Verilator DFG code-generation/dependency-order defect** for this
legal pattern, rather than golden-model repair, backend scheduling, insufficient
host `eval()` calls or a demonstrated hardware defect. No second HDL simulator
or upstream tool diagnosis was obtained. `-fno-dfg` remains necessary for this
installed tool and witnessed N=4 sequence and remains in the normal core.

The same500-cycle seed1 alternating-program captures were replayed at N=1,2,8;
default/O0/no-DFG did not differ in their meaningful public samples. This is bounded
non-reproduction, not proof those widths are immune. Corresponding experiment
summaries are `dfg-iz9r1p5q` (N1),`dfg-y64_8g44` (N2),`dfg-dc0ffmdf` (N8).

## C. Verification completion and focused fixes

### FE-T19 — reached through actual legal training

The immutable `jal-nt` program installs the JAL's BTB source tag, then executes
real operand-derived not-taken branches in other BTB rows. Their resolution-time
history indexes lower the JAL's direction counter without deleting/replacing its
BTB row. Refetch therefore requires EJU correction under approved EQ04.

N=4 consuming-edge trace, from the final short matrix:

| Cycle | Event / independently derived history effect |
|---:|---|
| 14 | JAL0x8 update: H0,index2,counter2→3,taken. |
| 23 | JAL0x180 installs target0x100: H1,index1,2→3; H becomes3. |
| 32 | NT branch0x104: H3,index2,3→2; H becomes6. |
| 33 | NT branch0x108: H6,index4,2→1; H becomes12. |
| 34 | NT branch0x110: H12,index8,2→1; H becomes8. |
| 39 | NT branch0x120: H8,index0,2→1; H becomes0. BTB row0 is retained. |
| 40 | NT branch0x12c: H0,index11,2→1; H remains0. |
| 54 | Same JAL0x180 accepted with modeled hit/NT,target0x100; checked public early flush1 and corrected metadata. |
| following output | Corrected JAL and target-path tuples are compared; execution reaches the program marker. |

The case passed at all four N values. The raw selected JAL prediction remains
**model inferred**, because EJU rewrites it before the public output. Accepted
training, source-tag preservation and the public correction/effective output are
the temporal evidence; this is not a newly exposed raw-BPU port. FEQ13's JAL/NT
reachability subquestion is answered; FEQ10 observability and other rare states
are not erased.

### FE-T54 — executed composite confidence

`confidence.py` reuses the original pure units, native validator, journal
reconstruction and obligation auditor. `run.py` routes selected FE-T54 to this
composite; `catalog.py` merges its real result into full directed results. Directly
invoking the raw native placeholder still requests external validation rather
than manufacturing a PASS. Every other incomplete catalog result survives the
merge. A Python composition unit verifies that native failures/aborts and deferred
FE-T48 survive successful confidence validation.

Final FE-T54 evidence is
[`core-ledger-final/.../FE-T54/summary.json`](../../../build/fetch-stage/completion-audit/core-ledger-final/ordinary-0t6c69g5/FE-T54/summary.json).
It records **24 actual native validator executions**, including:

* Positive baseline, repeat and public-only FST replay; byte-identical journals.
* Request, output-valid, early-flush, word, PC, target, taken, mask, fault flag and
  raised cause0 injections; repeated first failure is identical. Expected exit1
  requires actual injected field discrepancies.
* Real independent backend negative fixtures, invalid feedback, bad latency,
  width/configuration assertions, incompatible replay fingerprint and stale source.
* Empty zero-comparison run, timeout and a deliberately missing warm-JAL witness:
  all exit3, never PASS.
* EQ07 unknown-dependent state exits3; independent unit fixtures retain exact
  JAL arithmetic and raised cause0 after P/C become unknown. No numerical repair.

Independent units passed **70,579 new assertions**, plus unchanged PC341,
EJU16,931 and FM8,310. The count includes a ledger-negative test proving that a
second recovery cannot serve as a witness for an unobserved first restoration.
The confidence subprocesses took1,045 cycles and29,163 comparisons; their expected
injected failures are separate from ordinary DUT mismatches.

### RAS operations and subsequent public probes

`fetch_stage_ras_witness.hh` is an obligation/provenance ledger over the **reused
EJU state**, not a second stack transition implementation. Records contain
request/lane identity, eventual dynamic ID, PC, frontend epoch, P/C operation,
address, event/cancellation cycles and subsequent public probe cycles. Dynamic
ID0 means no backend instruction was allocated, e.g. A canceled before D; it is
not an observed DUT identity or known architectural zero.

Operations are created at modeled acceptance/confirmation. Witness credit occurs
only after the corresponding consuming edge and matched public return tuple.
A push must be exposed by its return; a pop must be exposed by a later successor
probe. A restore tracks every retained entry. A subsequent recovery cancels an
unobserved/partially observed old restoration; it cannot repair its coverage.
Reset/controlled stop records unwitnessed cancellation, not completion. Confirmed
history is witnessed only when its entries become predictive and publicly used.

Corrected FE-T34 uses three nested calls, a cold always-taken conditional branch,
wrong-path returns while that branch is delayed64 cycles, then a recovery directly
to the surviving unwind. No second recovery intervenes before the probes:

| N | Recovery cycle | Restored entries | Matched public return cycles |
|---|---:|---:|---|
| 1 | 103 | 3 | 108,117,129 |
| 2 | 100 | 3 | 106,110,115 |
| 4 | 100 | 3 | 106,111,116 |
| 8 | 100 | 3 | 108,112,117 |

The links are0x288,0x208,0x4; x1 is preserved/restored with actual integer
instructions. Earlier loop-based development runs failed the stricter ledger gate
or could have credited probes after another restore; those are superseded.

The final N2 ordinary run records644 RAS operations:142 publicly witnessed,
224 canceled by recovery without a witness,273 unwitnessed at controlled stop,
2 unwitnessed at the populated-history reset and3 unknown exception transitions.
Witnessed operations include111 P pushes,14 P pops,4 C pushes,8 C pops and5
restores. **This is not142/644 coverage closure:** many operations have no required
future probe, and cancellation is not proof of state correctness.

### Other directed gaps

| ID | Strengthening and final N2 result |
|---|---|
| FE-T15 | Public unchanged prediction tuples before/after model-indexed counter thresholds; two down and one up witnesses.362 cycles,8,941 comparisons. Index/history relation remains inferred; direction bits are public checked outputs. |
| FE-T31 | Seed-selected shuffled caller order encoded immutably, three static call sites and one shared RET. RET moved to BTB row4 so unrelated continuation controls do not constantly replace its row. Seven changing-return-target witnesses;500 cycles,12,016 comparisons. |
| FE-T32 | Below/at/above depth4, every real return target and final marker required. Five nesting variants completed full unwind, including overflow and eventual empty-stack fallback.336 cycles,7,766 comparisons. |
| FE-T33 | Wrong-path call, recovery, later distinguishing empty return. Per-operation records separate accepted speculative work, canceled work and witnessed restore. |
| FE-T34 | Single restoration and three-entry public drain, as above.200 cycles,4,748 comparisons. |
| FE-T40 | Native split confirmation/training schedule plus a real pure-backend repeated-redirect rejection. Found/fixed acceptance of repeated redirect without training after acknowledgment. One update/recovery remains;47 cycles,1,097 comparisons. The actual always-ready port is never forced unready. |
| FE-T44 | Schedule distinct commit0x700 and branch0x100 only while an independently pending early correction exists. At cycle15, E+B+early compete; later request and delivered target prove E priority.27 cycles,581 comparisons. Artificial overlap remains interface stress. |
| FE-T47 | Reset predicate requires trained predictor, nonempty P/C, q=2,answers=2,output=2 and a pending control obligation simultaneously. Fixed64 fixture reaches reset at cycle85, then restarts cold and reaches marker;305 cycles,10,619 comparisons. Occupancies/P/C are inferred, not internal probes. |

## D. Scope, coverage and validation accounting

The ordinary scope is declared in `core.py` **before judging results**. It also
includes explicitly labeled supported pin-level stress (FE-T20/44); these cases
are not relabeled as architectural execution histories. It excludes
FE-T41 (unapproved same-edge EQ07 alternatives),43,48,49,50,51 (deferred exception
or alternative-memory contracts). FE-T54 is executed as a composite. It does not
relax normal training, exact transport, source independence or required markers.

Final source-selected N2 result:
[`ordinary-0t6c69g5/summary.json`](../../../build/fetch-stage/completion-audit/core-ledger-final/ordinary-0t6c69g5/summary.json).
**47 native IDs /62 variants + FE-T54 passed;11,508 cycles,323,790 comparisons,
zero DUT mismatches.** This is an explicit ordinary subset, not54/54 sign-off.

| Actual accepted/checked event | Count |
|---|---:|
| Physical requests / public delivered bundles | 3,055 /2,118 |
| Legitimately canceled physical transactions | 937 |
| BPU update pulses / call-RET confirmations | 773 /233 |
| Normal backend recoveries | 150 |
| Dynamic instructions / retired abstraction / canceled | 3,345 /2,818 /527 |
| Later public saved-training witnesses within the update window | 335 |
| EJU-overwritten inferred training within the update window | 73 |

Learning now records the BTB row's next overwrite/deletion cycle. A saved
prediction witnesses an update only if its request sampled within that update's
valid window; a same-edge overwrite still samples old state.181 superseded updates
remain unwitnessed,183 are canceled at controlled stop and one at populated reset.
335 public and73 inferred associations complete the773 accepted update records.
These are source-PC/BTB reuse witnesses, not proof of every individual hidden PHT
or GHR transition. Threshold-specific public direction checks are separate.

The audit also found that the old mid-run reset dropped pre-reset learning records.
Those records now retain reset-window IDs and explicit cancellation, and the
independent auditor requires one training record per accepted update. All45
architectural controller scenarios pass request/backend/training conservation;
FE-T20/44 raw-port stress remains separately classified.

Generated program intent is not credited as dispatch or training. Request and
backend conservation are checked. Pending physical/backend work at controlled
stop is explicitly canceled; the running frontend is not claimed to drain
naturally. Required finite ordinary programs now need their semantic marker,
preventing activity-only PASS at a budget expiration. Learning/RAS operations
canceled before their witnesses remain explicitly unwitnessed.

No percentage closure of FEV01–22 is claimed. Raw overwritten predictor state,
internal occupancy, complete producer timing and some temporal crosses remain
inferred/uncovered. Predictor-agnostic path checking is still incomplete. Current
BTB/gshare **algorithm** is now an approved implementation target D by the user's
instruction; it is not an ISA guarantee. Sampling, composition and producer timing
retain their I dependencies, so exact-I naming and conservative mismatch
classification remain appropriate.

### All execution groups retained

| Evidence group | Purpose / disposition |
|---|---|
| `widths-smoke/evidence-i78r92os` | First four real builds and focused directed tests; no random seeds. |
| `widths-smoke/evidence-xjd8kpkt` | Initial stricter FE-T34 at N2/N4: incomplete ledger gate, zero RTL mismatches. Superseded. |
| `completion-audit/gaps-first` | FE15/31/34/40/44/47 diagnosis. Initial caller stale-BTB gate and short-latency reset setup incomplete; fixed causally. FE47 fixed64 follow-up passed. |
| `widths-smoke/evidence-t4eai7bt` | First full short matrix,26,969 cycles/713,319 comparisons. Superseded restoration ledger evidence. |
| `core/ordinary-9qqx3v77` | Preliminary ordinary scope and24 validators. Superseded FE34 causal witness. |
| `widths-smoke/evidence-9xwrezv6` | Four final-source real elaborations plus corrected single-recovery FE34. |
| `widths-smoke/evidence-yr83akts` | Earlier final matrix before stricter per-update bookkeeping; identical functional stimulus/check counts. |
| `completion-audit/core-final/ordinary-z0gt6er4` | Ordinary validation before per-update overwrite/reset bookkeeping was tightened. |
| `completion-audit/core-ledger-final/ordinary-0t6c69g5` | Canonical ordinary N2 result, independent units and24 confidence subprocesses. |
| `completion-audit/optimization-native` | Four500-cycle FE12 captures, not current full FE12 completion claims. |
| `completion-audit/optimization/dfg-*` | Public replay default/O0/no-DFG and extra-evaluation controls at all N; N4 smaller FE19 replay. Differential experiments, not architectural PASS counts. |
| `completion-audit/catalog-nfsmhug5` | Four Python result-composition unit cases reusing the actual confidence receipt; no DUT simulation or invented validator execution. |

`widths-smoke/evidence-4wvm_vf3` records the update-window follow-up.
`widths-smoke/evidence-tm14sgsn` is the final matrix after training reset-window
preservation; its60 stimulus digests and comparison counts equal the earlier
matrix (`bookkeeping-equivalence.json`). The common bookkeeping fixes justified
these short follow-ups; they introduced no new golden transition.
Only the final groups support current completion claims. Counts from repeated
runs are not added to unique coverage. No regression/mutation campaign was run.
Historical twelve provisional mutation detections have **not** been revalidated
against the new ledger; no fresh mutation coverage is claimed.

### Deferred questions and limitations

FE-T43/48/49/50/51 retain incomplete/characterization declarations. EQ08's prior
full-core defect, delayed exception redirect, delayed data-fault/retirement context,
faulting RET/JAL policy, mtval/CSR correctness and FQ02/03/04 remain deferred.
EQ07 alternatives remain provisional; normal separated confirmation/recovery is
tested. FEQ01's algorithm approval and FEQ13's JAL/NT reachability are partial
closures only; other FEQ/EQ/FQ questions remain. No x5/coroutine expansion or RTL
recovery redesign was introduced. The full specification aggregate was not rerun
and must continue to report incompleteness while its deferred obligations remain.

## E. Changes, integrity and reproduction

Changed existing frontend-specific framework files:
`fetch_stage_driver.{hh,cpp}`, `fetch_stage_components.{hh,cpp}`,
`fetch_stage_program.cpp`, `fetch_stage_tb.cpp`, `fetch_stage_tb.core`,
`fetch_stage_unit.cpp`, `validate.py`, `run.py`, `suite.py`, README/specification and root makefile.
New files: `fetch_stage_ras_witness.hh`, `widths_smoke.py`, `optimization_audit.py`,
`confidence.py`, `catalog.py`, `core.py`, and this report. The production wrapper,
composed oracle algorithms and all prior PC/EJU/FM implementations remain intact.

341 protected production/prior-framework files match the entry SHA256 baseline.
Production configuration SHA256 is
`108925fbdd08e18aa92dbdacfd479904ffa7691a6c10d5cdac5b4ff6f80430f8`.
`git diff` still shows the user's pre-existing4→2 configuration edit; it is not
an audit edit. All width changes occurred exclusively in disposable copies.

All current compiled C++/SV/core/waiver and orchestration files equal the final
N2 source snapshot. No source changed after the final native runs. Default live-tree
commands fingerprint their own source/configuration and cannot silently reuse an
older binary. Every executed private binary audited its unchanged source snapshot.

```sh
source private/init.sh
# Short isolated matrix; no regression or mutations:
make check-fetch-stage-widths-smoke N_VALUES=1,2,4,8 SMOKE_SEEDS=3 SMOKE_CYCLES=1500
# One width and one real program:
make check-fetch-stage-widths-smoke N_VALUES=4 SCENARIO=FE-T19 SMOKE_SEEDS=0
make check-fetch-stage-widths-smoke N_VALUES=2 SCENARIO=FE-T34 SMOKE_SEEDS=0
# Selected live configuration only; explicit ordinary scope:
DIRECTED_CYCLES=2000 DIRECTED_REPETITIONS=8 EXEC_LATENCY_MAX=8 make check-fetch-stage-core JOBS=2
# Composite confidence, actual execution of expected-negative validators:
make check-fetch-stage-run SCENARIO=FE-T54
# Individual strengthened cases / every lane unless VARIANT is supplied:
make check-fetch-stage-run SCENARIO=FE-T31 DIRECTED_REPETITIONS=8 DIRECTED_CYCLES=2000 EXEC_LATENCY_MAX=8
make check-fetch-stage-run SCENARIO=FE-T47 DIRECTED_CYCLES=2000
```

For the compiler experiment, pass one recorded private source and public journal:

```sh
python3 tb/frontend/fetch_stage/optimization_audit.py \
  --source build/fetch-stage/widths-smoke/n4-no-dfg-<source-key>/source \
  --journal build/fetch-stage/widths-smoke/evidence-yr83akts/n4/FE-T19/logs/samples.jsonl \
  --output build/fetch-stage/compiler-reproduction
```

The exact existing binaries can replay `FE19-reduced/minimal-inputs.txt` without
any oracle/backend. Source manifests and command arrays provide the absolute
paths. The shuffled-caller image is bounded to32 static episodes; arbitrary program
synthesis and longer caller layouts are not claimed.

`DIRECTED_CYCLES`, `DIRECTED_REPETITIONS` and `VARIANT` are included in
native replay commands. Budget expiration never satisfies a missing witness.

## Final backend/history audit — 2026-10-16

This entry supersedes the earlier FE-T15-incomplete and coarse-backend-resource
statements for the final source fingerprint below. Earlier timing/validation
records are retained, not added to unique coverage. See
[FINAL_FRONTEND_ARCHITECTURE_AUDIT.md](FINAL_FRONTEND_ARCHITECTURE_AUDIT.md)
for source citations, the complete gshare policy comparison, cycle traces and
an independently reviewable saved-index interface proposal.

### Findings and changes

* Production/current golden gshare both use **pre-edge resolution-time history**
  for training. They do not preserve a prediction-time training index. GH01
  demonstrates two surviving branches sampled with H1, then younger B trains
  with H2 after older A updates. This is approved Policy A behavior, not a new
  ISA/approved-contract mismatch. Saved-index Policy B is separately simulated
  on the same feedback trace and is not substituted into the oracle.
* Recommendation: retain A for the next issue-stage verification baseline, with
  explicit attribution semantics; evaluate closed-loop accuracy/recovery costs
  before approving B. The audit details prediction/IQ/issue/RS/resolution fields
  that B would need. No speculative GHR or production RTL changes are introduced.
* FE-T15 now requires original collision/interference and raw threshold witnesses
  **plus BTB-hit pre/post up/down witnesses**. A persistent four-branch prelude
  precedes the original interfering body. PHT write generations prevent unrelated
  updates from satisfying a transition. At N4, PC0x238 is publicly hit/NT at
  request872/dispatch875, trains index0 1→2 at945, and PC0x22c is publicly hit/T
  at request1026/dispatch1035 with the same new generation. A separate hit/T→NT
  witness surrounds index11's2→1 update at416. Strict FE-T15 passes.
* The earlier cycle257 index3 crossing lacked a retained counter1 pre-read.
  Base0x20 requests under H11 started at0x24, masking PC0x20. Its physical JAL
  word therefore supplied no public probe. Increasing the budget was not a fix.
* Backend IQ admission uses actual V slots, ROB allocates at scalar issue, ALU
  RS8/BU RS4 persist until publication, ROB32 persists until retirement/squash.
  One shared result publication and one retirement per edge are enforced.
  Independent ALU/BU computation can overlap. Wrong-path resources and feedback
  are canceled by age, with allocation/release conservation.
* Once-sampled L keeps the specified dispatch-relative minimum-readiness meaning.
  It is not silently redefined as FU service latency. Issue, dependency readiness,
  start, one-cycle service capture, publication and retirement are separate.
  Invalid bundles are rejected transactionally before ID/version/RNG allocation;
  missed feedback and duplicate scheduler edges are hard framework failures.
* Admission metrics are credited only after matched consuming edges; high-watermarks
  exclude the software-only intermediate dispatch-before-issue state. Idle
  capacity-ready0 and actual held-valid stalls have separate counts. BP01 removes
  random output stalls; BP07 combines them with resource stalls. BP02 explicitly
  blocks retirement until200; BP05 uses a short fixed256-readiness fixture so even
  N1 has actual stalls. Every BP case requires its semantic marker.
* `history_audit.py` reconstructs H/PHT snapshots from public request/reset/train
  inputs and checks dispatch identity/metadata before policy comparison. Seven
  hand-calculated positive/negative units are mandatory in pure validation.
  Cumulative public-auditor training counts now survive reset; per-window duplicate
  guards are retained. FE-T54 still executes all24 native validators.

### Canonical final execution evidence

| Command / group | IDs / cases | Cycles | Comparisons | Result |
|---|---:|---:|---:|---|
| `make check-fetch-stage-core JOBS=2` |48 IDs /69 cases, including24-validator FE54 composite|44913|1791021|PASS, exit0; no missing selected witnesses|
| Focused GH01, FE15, BP01–08, FE13/34/37/38/40/47 |16 IDs /22 cases|14081|666528|All PASS, exit0|
| `STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T15` |1|3330|125160|PASS, exit0;118 updates|
| Real isolated BP05 N1 |1|792|26861|PASS, build0/run0|
| Real isolated BP05 N2 |1|794|34736|PASS, build0/run0|
| Real isolated BP05 N4 |1|796|43535|PASS, build0/run0|
| Real isolated BP05 N8 |1|800|60665|PASS, build0/run0|
| FE15 explicit100-cycle budget, default |1|104 including reset/stop|2372|WARN_INCOMPLETE, exit0;7 missing witnesses|
| Same bounded fixture, strict |1|104|2372|WARN_INCOMPLETE, exit3|
| FE15 deterministic replay |1|3330|125160|PASS; both public and training journals byte-identical|

Groups overlap; their counts must not be summed as unique coverage. There are
zero ordinary DUT mismatches, invalid environments or framework failures in the
canonical positive groups. FE54's24 native validators execute830 cycles/29772
comparisons, including11 deliberate detected injected errors; these are expected
negative evidence, not ordinary RTL failures. Pure units pass70650 frontend,
341 PC,16931 EJU and8310 fetch-memory assertions, plus37 result-policy and7 new
history-attribution tests. No new full random campaign or RTL mutation campaign
was run. Seven latency distributions are exercised in FE38 and pure samplers.

Canonical native core totals (excluding FE54 negatives):10986 requests =6992
delivered +3994 legitimately canceled;15848 dynamic instructions =7223 retired
+8625 canceled;2696 actual BPU updates,763 confirmations,8728 result captures,
377 recoveries. Per-request/backend/training ledgers retain terminal dispositions;
no unresolved memory/backend lifecycle is silently passed. Unwitnessed individual
training/RAS operations remain canceled/unobserved rather than claimed observed.
Full FEV closure is not implied by scenario-gate completion.

Artifacts:

* Core: `build/fetch-stage/core/ordinary-_o09v469/summary.json`.
* Composite: `build/fetch-stage/core/ordinary-_o09v469/FE-T54/summary.json`.
* Focused: `build/fetch-stage/final-architecture-audit/accepted/summary.json`.
* Policy comparison and matched update/request/dispatch histories: each focused
  GH01/FE13/FE15 directory's `history-policy-comparison.json` and training journal.
* Strict Make run: `build/fetch-stage/run/FE-T15-siq6aj22/summary.json`.
* Widths: `build/fetch-stage/widths-smoke/evidence-g_vp0vz6/summary.json`.
* Bounded completion/replay: `final-architecture-audit/accepted/completion-and-replay.json`.
* Consolidated final evidence/hashes/changed-file list:
  `build/fetch-stage/final-architecture-audit/FINAL_EVIDENCE.json`.

Earlier `first`, `sensitive-first`, `stable`, `final` and width
`evidence-vzylo7cw`/`evidence-fxpijriy` groups are preserved development evidence.
The early N1 width case honestly warned because a transient full occupancy did
not coincide with a valid stalled offer. The final saturation setup and metrics
correct that gap. Prior core `ordinary-da_90bh_` and `ordinary-0b223k00` are
superseded by the final-source run; repeated runs earn no additional coverage.

### Resource and history observations

| Case | IQ / ROB / BU RS / ALU RS high | Capacity ready-low cycles | Stalled valid offers | Random stalled offers |
|---|---|---:|---:|---:|
| BP01 |16 /9 /4 /8|700|682|0|
| BP02 |16 /32 /2 /3|316|305|0|
| BP03 |16 /8 /4 /4|256|216|0|
| BP05 N4 |16 /9 /4 /8|699|684|0|
| BP07 |16 /11 /4 /8|685|669|204|

BP02 reaches48 total backend entries (IQ16+ROB32). It records158 ROB-block cycles,
retains completed/unretired entries, then retires the finite marker. Independent
older64/younger1 tests prove that younger completion does not release ROB behind
a delayed older branch. BP03 records224 branch-RS blocked cycles. Multiple FU
results contend for publication without exceeding the single CDB port. BP06 has
37 canceled dynamic instructions,13 naturally retired surviving instructions and
three distinguishing restored returns; stale younger feedback is rejected.

At N1/2/4/8, final BP05 has IQ16 and ALU RS8 at every width; actual stalled valid
offer counts are568/644/684/693 respectively, followed by accepted resumption.
Source/elaboration agreement is checked for every real private build. The live
and isolated N4 BP05 public journals are identical (SHA256
`e6b02c45fd41b0c2f5731930b6fa755c98534bf6ea61d85c3bfdad5fc59b64f4`).
These are capacity tests, not a new all-width training regression.

GH01's first history discrepancy is B ID3, PC0x44: request29 with H1/index0/
counter3, dispatch36, execute55, update56 with H2/index3/counter2→1. A ID2 at
PC0x40 updates54 with NT, changing H1→2 without canceling B. Probe PC0x9c accepts58
and dispatches70 with raw taken0. Policy B would instead decrement saved index0
3→2. This is a real implementation-policy difference, not an actual mismatch.
The final independent audit verifies6/118/114 attributed updates for GH01/FE15/FE13.

FE15 replay SHA256:

* samples: `042f3deb5944aaaa36427af21bc6542ff9eb860006d8d52136c062f51d42ad04`.
* training: `c7615d74353da6bcb26345bc719207f612a3851d0400ce1f4fc90c300e04e63b`.

### Integrity, changes and remaining scope

All341 protected production and prior PC/EJU/FM files match the entry hashes.
Original config SHA256 remains
`3811d38c7ebb78ad94473fddb9c62a39d497bd6594bab8c7d8a6848337bbd97a`.
Final frontend source/build fingerprint:
`2699a477916c13b38521a5f4ab6526b03cda4baa757c0eeeac5daaa49427c180`.
The wrapper and `-fno-dfg` production build option remain unchanged. Width edits
occurred only in disposable source copies. Existing uncommitted user/prior-task
changes, including the result-policy implementation, were preserved.

This task changes only frontend-specific components/driver/program/unit logic,
diagnostic composition snapshots, configuration parsing, auxiliary selection,
public-auditor counting, width-smoke BP profiles and these documents. New files:
`history_audit.py`, `history_audit_unit.py`, and the final architecture audit.
The exact entry-relative file list is in FINAL_EVIDENCE.json; root Make and prior
standalone behavior were not changed by this task.

The ordinary selected scope is complete and passes. **Full specification remains
incomplete**: FE-T43/48/49/50/51, EQ07 alternatives, EQ08, delayed exception
recovery, alternative memory protocols, full precise retirement/CSR/mtval and
exhaustive/predictor-agnostic FEV checks remain deferred or unresolved. Their
statuses were not converted to PASS. No new production RTL defect or architectural
fix is claimed. Default warnings and strict rejection remain tested.


The final evidence index also enumerates217841 actual simulated cycles across285
native reports with cycle metrics, including superseded development attempts and
expected-negative fixtures. Those repetitions are not extra functional coverage.
Configuration/startup rejections are separately preserved by the confidence
receipts. Resource counters in a case describe its final backend reset window;
per-instruction/learning ledgers retain earlier windows (notably FE47). BP/GH
measurements above have one live backend window. All source and protected-file
hashes were rechecked after documentation changes; the build fingerprint is
unchanged because Markdown is not a compiled input.
