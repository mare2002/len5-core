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
