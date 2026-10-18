# Frontend RTL verification findings

Consolidated review: 2026-10-16. This document collects the problems, risks and
remaining questions recorded by the `pc_gen`, `early_jump_unit`, `fetch_mem_if`
and complete `fetch_stage` verification efforts. It distinguishes current RTL
defects from historical defects, proposed architectural improvements, unsupported
protocols, simulator problems and incomplete verification.

This was a documentation review with read-only checks of the relevant active RTL.
No new simulation was run and no RTL, configuration or existing verification
implementation was changed. The source currently selects **N=4, HLEN=4 and
BTB_BITS=4**. The pre-existing local modification of
`rtl/packages/len5_config_pkg.sv` was preserved. Results below belong to the
specific historical builds identified in their source documents; they are not
new validation of every current working-tree setting.

## 1. Findings at a glance

| Finding | Current classification | Affected area | Disposition |
|---|---|---|---|
| **R01: Confirmed RAS retains operations squashed by an older exception** | **Demonstrated current predictor-recovery defect**; full-core push and pop witnesses at N=2 and N=4 | RAS, EJU and exception recovery | EQ08 / FEQ05. No fix implemented; exception-specific clear-both is a proposal. |
| **R02: Instructions from an unexpected stream reach commit around exception recovery** | **Demonstrated recovery-window observation; functional severity and full cause unresolved** | Commit/issue/frontend recovery coordination | FQ12 / FEQ07. Requires a dedicated surviving-instruction/retirement investigation. |
| **R03: MRET is classified as an exception before reaching normal MRET commit decoding** | Source-level producer-path concern; no dynamic MRET proof | Issue decoder, commit decoder and trap return | Investigate before claiming working MRET. Separate from RAS recovery. |
| **R04: External interrupt path remains unfinished** | Source-observed implementation limitation | Datapath interrupt routing, WFI/issue control | No verified interrupt-entry or nested-trap contract. |
| **R05: Correct fetch-fault `mtval` generation is not established** | Integration question, not a demonstrated wrong CSR value | Issue result construction and commit/CSR path | FQ10 / FEQ06. Exact frontend fault transport does not settle it. |
| **R06: Late responses cannot be distinguished after cancellation** | Demonstrated conditional hazard under an unsupported noncancelable-memory protocol | Fetch memory interface | FQ04 / FEQ08. Active memory contract cancels pending responses atomically. |
| **R07: Grant-on-flush, zero-latency response and excess-outstanding behavior** | Unsupported/undecided protocol combinations with association risks | Fetch memory metadata FIFO | FQ02/03/08. Not active-contract RTL failures. |
| **R08: Gshare may train a different counter from the one used for prediction** | Demonstrated property of the approved implementation; architecture/accuracy tradeoff | BPU/gshare | Policy A retained; saved-index Policy B needs a separate design decision. |
| **R09: RET correction can be redundant or override a correct BTB with stale RAS** | Demonstrated recoverable prediction-quality behavior; optimization/policy question | EJU/RAS/BPU | EQ04 residual / FEQ03 / RAS-O. Backend recovery remains necessary. |
| **R10: Held early corrections may cause repeated target fetch offers** | Source-supported integration/lifecycle concern; no demonstrated duplicate accepted RAS operation | EJU, PC generation, memory cancellation | EQ05 / Q3. Current cancellation contract and focused tests cover supported operation. |
| **R11: Same-edge RAS confirmation/recovery ordering remains provisional** | Alternative-model disagreement, not a demonstrated integrated defect | RAS/branch producer | EQ07. Normal confirmation-before-flush schedule is supported. |
| **R12: Some parameter combinations are not supported** | Source-level parameterization restrictions; selected four widths passed focused RTL tests | Gshare, RAS depth, FIFO/spill configuration | Do not generalize N=1/2/4/8 success to arbitrary HLEN/depth settings. |
| **H01: Raw target low bits persisted during ordinary PC progression** | Historical confirmed RTL defect, **documented as fixed** | PC generator | Old T19 failures must not be counted as current failures. |
| **T01: Verilator DFG produces wrong corrected JAL metadata** | Reproduced simulator optimization discrepancy with a supported code-generation explanation | Simulation of EJU-to-mixer path | Keep `-fno-dfg`; not established as a hardware defect. |

There is **no documented outstanding definitive standalone PC mismatch** after
the alignment correction, and **no observed active-contract fetch_mem_if RTL
defect** in its recorded validation. Those statements do not close the system
recovery issues or all specification questions.

Evidence labels retain their original meanings: **A** architectural requirement,
**D** approved/documented design requirement, **I** inferred integration contract,
**O** RTL observation and **Q** unresolved specification. A reproduced observation
does not by itself approve a replacement architecture. Repeated comparison errors
and mutation detections are not counts of independent production defects.

## 2. R01 — Exception-contaminated confirmed RAS (EQ08)

### Cause and reachability

Predictive history P changes when the frontend accepts recognized calls/returns.
Confirmed history C changes when the branch unit confirms execution. Confirmation
is **not retirement**. A younger call/return can therefore update C while an older
nonbranch instruction is waiting to produce an exception. When that exception
eventually squashes the younger instruction, the RAS has no age, retirement or
recovery-reason information with which to undo its confirmed operation.

The current shared frontend flush restores P from C. It does not remove the
squashed operation from C. A push can retain a nonexistent return address; a pop
can remove an older return address that should survive. Overflow can also destroy
older history, so deleting only newly pushed entries would not solve the problem.

Active source: [ras.sv](../../rtl/frontend/ras.sv), lines 63–117;
[branch_unit.sv](../../rtl/expipe/exec-units/branch_unit.sv), lines 109–172,
198–229 and 278–281; [datapath.sv](../../rtl/datapath.sv), lines 97–132.
The single EJU/RAS flush combines exception and branch recovery, although the BPU
receives a separate exception-flush qualifier.

### Actual full-core push witness

The existing experiment executes real instructions through production fetch,
issue, execution, ROB and commit. A diagnostic monitor observes internal state;
it does not feed that state into the standalone black-box oracle. No confirmation
or exception is forced. Addresses below are hexadecimal; cycle numbers are
pre-edge samples, with registered effects visible in the next sample.

| Cycle | Observed execution | Consequence |
|---:|---|---|
| 25 → 26 | Older call at `0x100c` confirms link `0x1010` | C becomes `[0x1010]`. |
| 26 / 27 | Older call leaves ROB / writes the committed integer register file | The older link is legitimate surviving history. |
| 28–30 | `DIVU 0x1050`, dependent `LD 0x1054`, younger `JAL x1 0x1058` issue | The older load waits while the independent younger call can execute. |
| 31 | Younger call executes to `0x1180` with no misprediction | This is a real eligible call. |
| 32 → 33 | Younger call confirms link `0x105c`; older ROB work remains blocked | C becomes `[0x1010,0x105c]`; younger call has not retired. |
| 101 | Older LD commits a doubleword-misalignment exception, code 4; frontend/backend flush assert | The younger call is still resident in ROB; P restores contaminated C. |
| 102 | Younger call is gone from valid ROB entries | C and P still contain `[0x1010,0x105c]`. |
| 107 | Handler canonical RET at `0x1200` is accepted | EJU predicts the squashed link `0x105c`. |
| 112 (N=2) / 116 (N=4) | RET executes using actual x1=`0x1010` | Backend detects the wrong target and recovers. |

The destructive-pop experiment independently demonstrates the other direction:
RET `0x1060` confirms at cycle 34, removing legitimate link `0x1010`. The older
LD `0x105c` causes exception recovery at cycle 102; the squashed pop is not undone.
Both push and pop experiments reproduced at **N=2 and N=4**.

This is a demonstrated **predictor-history recovery defect**, with an observed
incorrect return prediction. It is not proof of an uncorrectable ISA execution
error: the branch unit independently computes the actual return target and the
push witness shows subsequent correction. General precise recovery must still be
verified independently, especially given R02.

An older issue-known fetch/illegal-instruction exception is not an equivalent
reproducer: issue blocks younger normal work in that case. The experiment uses
a real delayed execution-side load fault. Ordered branch execution also prevents
the analogous proposed younger-confirmation-before-older-branch scenario under
the inspected normal branch producer. That ordering does not protect against an
older nonbranch exception.

### Proposed remedy, not implemented

The audit recommends a distinct exception/context-clear signal: clear **both** P
and C on exception recovery, while retaining P←C for ordinary branch recovery.
Clear must dominate speculative operations and confirmations and cancel pending
EJU corrections. Clearing only P would allow contaminated C to reappear later.

This deliberately discards legitimate committed call history too. Empty RAS
disables its early RET prediction, leaving BTB/backend resolution as fallback;
the expected cost is prediction performance, conditional on correct recovery.
Retirement-aware history or an age-aware reversible log/checkpoints can preserve
more history, but need additional metadata and correct handling of pops,
overflow and surviving unretired operations. Simply moving all confirmation to
commit does not preserve the existing ordinary branch-restoration contract.

Evidence and reproduction:
[EJU audit §B and §E](early_jump_unit/ARCHITECTURE_AUDIT.md#e-full-core-execution-follow-up),
especially §E2–E4; [recovery README](early_jump_unit/recovery/README.md).
After loading the repository tool environment, the existing audit commands are:

```sh
python3 tb/frontend/early_jump_unit/recovery/run.py --width 2
python3 tb/frontend/early_jump_unit/recovery/run.py --width 4
```

These build disposable configuration copies and save assembly, disassembly,
`cycles.csv`, waves and `result.json` under `build/early-jump/recovery/`. For the
exception fixtures, a successful reproducer means **defect reproduced**, not RTL
correctness passed. These commands were not rerun for this consolidation.

## 3. R02 — Exception flush and redirect leave a recovery window

The same full-core captures observed unexpected-stream NOPs entering issue and
asserting qualified commit register-file enables around exception entry:

| Configuration | Exception flush | Unexpected committed PCs | Commit cycles |
|---|---:|---|---|
| N=4 | 101 | `0x1220`–`0x123c` | 111–118 |
| N=2 | 101 | `0x11f0`–`0x11fc` | 111–114 |

The handler's first intended control transfer was RET `0x1200`. The observation
is not merely an inactive PC bus. `COMMIT_EXCEPT` flushes first; trap redirection
and issue resume occur in later states. `pc_gen` has no exception-flush/fetch-hold
input and suppresses ordinary fetch only when a redirect qualifier is active.
A flush by itself therefore does not prevent intervening requests/refills.

Source: [commit_cu.sv](../../rtl/expipe/commit-unit/commit_cu.sv), lines 429–465;
[pc_gen.sv](../../rtl/frontend/pc_gen.sv), lines 82–110;
[datapath.sv](../../rtl/datapath.sv), lines 97–132.

The traces use NOPs writing x0 and did not run a complete ISA checker. They do
**not** demonstrate a harmful wrong-path register update or establish the full
causal mechanism. Treat this as an observed system-recovery concern needing a
request-epoch, IQ/ROB and commit-stream investigation. Clearing RAS would not fix
it. Withholding every post-flush memory grant would conceal rather than resolve it.

Evidence: [EJU audit §E5](early_jump_unit/ARCHITECTURE_AUDIT.md#e5-separate-recovery-window-observation),
[fetch-memory specification §10.3](fetch_mem_if/VERIFICATION.md#103-recovery-window-identified-by-the-eju-audit),
and FEQ07 / FE-T49 in the [frontend specification](fetch_stage/VERIFICATION.md).

## 4. R03–R05 — Trap/exception producer concerns outside standalone frontend proof

| Concern | Actual evidence | What remains unproven / next check |
|---|---|---|
| **MRET decode path** | [issue_decoder.sv](../../rtl/expipe/issue-unit/issue_decoder.sv), lines 744–752, labels MRET `ISSUE_TYPE_EXCEPT`, sets `opcode_except=1` and `E_ENV_CALL_MMODE`. [issue_stage.sv](../../rtl/expipe/issue-unit/issue_stage.sv), lines 327–328, propagates that exception classification. [commit_decoder.sv](../../rtl/expipe/commit-unit/commit_decoder.sv), lines 45–48, prioritizes an exception over the MRET case at line 161. | Source-level reason not to assume the named `COMMIT_MRET` states prove working MRET. Run an actual MRET/CSR-target integration test; no such dynamic result is claimed here. |
| **Interrupt implementation** | [datapath.sv](../../rtl/datapath.sv), lines 53–56, marks interrupt ports TODO; the EJU audit found no internal IRQ routing. Issue WFI handling also has an interrupt TODO. | No functioning interrupt-entry, acknowledgment or nested-trap behavior was established. This is unfinished production capability, not an EJU prediction mismatch. |
| **Fetch-fault `mtval`** | Fetch_mem_if transports saved lane PC plus flag/cause, but no fault-address result. [commit_cu.sv](../../rtl/expipe/commit-unit/commit_cu.sv), lines 443–448, uses instruction result data for fault-address saving; issue result construction is at [issue_stage.sv](../../rtl/expipe/issue-unit/issue_stage.sv), lines 548–558. | Correct frontend PC/error association does not prove that the eventual result/CSR path supplies the faulting fetch address. FQ10 calls for issue/commit verification; no incorrect `mtval` value was dynamically demonstrated. |

PC Q10 tests only supplied trap/MRET/interrupt-shaped addresses. They do not
execute those producer paths. The EJU full-core handler uses **RET, not MRET**.
See [EJU audit §B4](early_jump_unit/ARCHITECTURE_AUDIT.md#b4-scenarios-cd--traps-and-coincident-recovery)
and [fetch-memory specification §9.3](fetch_mem_if/VERIFICATION.md#93-path-to-architectural-exception-outside-the-dut).

## 5. R06–R07 — Memory protocol limitations and conditional hazards

The verified architectural profile requires **ordered responses, positive response
latency, at most two outstanding requests and coordinated physical cancellation
on flush**. Metadata is saved at request acceptance and associated with responses
by FIFO order. There are no transaction IDs, stale-response tags, tombstones or
drain/cancel acknowledgment ports.

| Case | Why it is a problem outside that contract | Correct classification |
|---|---|---|
| **Late clean/fault response after flush** | FIFO metadata was discarded. An old physical response may be offered as valid with missing or new-request metadata; a canceled fault can be attached to a live transaction. Existing FQ04 characterization observes stale-fault validity. | Demonstrated unsupported-protocol hazard. Not a failure of a contract that cancels the physical response. Noncancelable memory needs an explicit adapter/epoch/drain architecture. |
| **Request grant on flush edge** | Request bypass can permit the electrical overlap while the metadata FIFO is being cleared. If that grant denotes new live work, its metadata would be lost. Current memory withdraws grant. | FQ02 unresolved ownership; characterization, not a proven architectural failing sequence. |
| **Empty-queue zero-latency request/response** | The metadata FIFO has no fall-through from the newly accepted record to its old empty head. Response association is not established. | FQ03 alternative protocol; positive latency remains the default. |
| **More outstanding requests than metadata slots** | Fetch_mem_if does not gate acceptance using FIFO full/empty. `fifo_nohs` can overwrite on overflow; its full assertion is disabled under Verilator. | Violates the documented producer capacity guarantee. No claim that arbitrary memory backpressure/capacity is internally enforced. |
| **Out-of-order responses** | No response identity/address is available to reorder the saved records. | Unsupported; FIFO association explicitly requires ordered memory. |
| **Redirect changes an unaccepted request address** | Request bypass and memory-independent PC correction can replace an unaccepted offer. | FQ01 integration contract, not generic irrevocable ready/valid semantics. A stricter memory protocol needs adaptation. |

Source: [fetch_mem_if.sv](../../rtl/frontend/fetch_mem_if.sv), lines 79–144;
[fifo_nohs.sv](../../rtl/common/fifo_nohs.sv), lines 51–146;
[fetch-memory specification §§6, 9.4 and 21](fetch_mem_if/VERIFICATION.md).
Early-jump memory flush may consume the current answer before canceling younger
work; branch/exception recovery withdraws downstream readiness. Treating these
as identical cancellation events would be a model error, not evidence of RTL loss.

No active-contract data/metadata/error association defect is reported by the
[fetch-memory validation record](fetch_mem_if/README.md#validation-record).
Its recorded million-cycle run has zero confirmed/provisional mismatches. This
does not establish safety for the alternative protocols above.

## 6. R08 — Gshare prediction/update counter attribution

Current RTL and its independent model both implement **resolution-indexed Policy A**:

```text
lookup_index = H_at_request XOR word_PC_index
update_index = H_before_resolution_update XOR word_PC_index
H_next       = ((H_before_resolution_update << 1) | actual_taken) mod 2^HLEN
```

GHR is updated by qualified branch resolution, not speculatively by fetch. JAL,
JALR and RET outcomes also participate. No prediction-time history/index is carried
in `prediction_t` or returned in `resolution_t`. Ordered branch resolution does
not prevent an older branch from changing H between a younger branch's lookup
and resolution.

The **real GH01 executable witness** establishes the difference:

| Cycle | Event | Independent attribution and public evidence |
|---:|---|---|
| 28 | Seed JAL trains | H becomes 1. |
| 29 | One accepted request contains A=`0x40` and B=`0x44` | Both sample H=1. B reads entry 0, counter 3. |
| 36 | A ID2 and B ID3 dispatch | Both survive with operand-derived not-taken outcomes. |
| 54 | Older A trains | H changes 1→2. |
| 56 | B trains | Uses H=2, **entry 3**, counter 2→1; original entry 0 remains 3. |
| 58 / 70 | Later probe at `0x9c` requests / dispatches | H=4 selects entry 3; matched public `.taken=0`. BTB miss is reported, not counted as a qualified taken redirect. |

History, indexes and counter magnitudes are independently derived model state;
the public interface witnesses direction, not private PHT contents. Policy B
(saved prediction index) would update entry 0 from 3→2 and leave entry 3 at 2,
giving a different probe direction on the same fixed feedback trace.

This is an important **counter-attribution/accuracy tradeoff**, not an ISA
correctness failure or a mismatch against the approved current predictor design.
The original designers' motivation is not established. The latest audit recommends
retaining Policy A for the baseline until a closed-loop A/B workload comparison
justifies a change. Zero RTL/model mismatches verifies Policy A implementation;
it does not prove that Policy A is the best predictor architecture.

A saved-index design would need HLEN-bit provenance through gshare/BPU prediction
records, fetch-memory buffers, EJU/mixer/output, IQ/issue, branch RS and registered
resolution feedback. EJU must retain that provenance when rewriting effective
predictions. It does **not** require speculative GHR; adding speculative history
would separately require checkpoint/rollback design.

Source: [gshare.sv](../../rtl/frontend/gshare.sv), lines 43–114;
[bpu.sv](../../rtl/frontend/bpu.sv), lines 39–82;
[fetch_pkg.sv](../../rtl/packages/fetch_pkg.sv), lines 49–71.
Evidence/proposal: [final frontend audit §A](fetch_stage/FINAL_FRONTEND_ARCHITECTURE_AUDIT.md#a-gshare-architecture-and-source-evidence).
Existing focused command: `make check-fetch-stage-run SCENARIO=GH01`.

## 7. R09–R11 — EJU/RAS policy and timing questions

### Return correction is not always an improvement

With nonempty P, canonical RET requests EJU correction even when BTB already
predicts the same target. This can cause a redundant memory flush. The source
contains a commented alternative comparison; removing redundant correction would
be a policy/optimization change, not a demonstrated required fix.

Conversely, a coherent FE-T36/RAS-O program demonstrates a **correct BTB target
overridden by stale RAS**: actual x1 is `0x100`, P predicts `0x110`, execution at
216 detects the error, confirmation is at 217, training/redirect/flush at 218,
and the recovery request for `0x100` is accepted at 219. This is recoverable
prediction-quality loss under the current policy. RAS contents are predictions,
not guaranteed copies of architectural x1 or the software call stack.

Source: [early_jump_unit.sv](../../rtl/frontend/early_jump_unit.sv), lines 142–151;
[frontend README return witnesses](fetch_stage/README.md#learning-and-recovery-trace-excerpts),
FE-T36; [EJU audit §A](early_jump_unit/ARCHITECTURE_AUDIT.md#a-eq01eq12-decisions-and-evidence).

### Held correction and repeated fetch offers

EJU can offer correction while the final output spill is stalled. `pc_gen` can
load that same target at several edges, permitting repeated target requests if
memory accepts them. The selected predictive push/pop still happens only on
bundle acceptance. Completion flush must cancel younger memory work; there is
no separate EJU correction acknowledgment. No current supported-history duplicate
accepted push/pop or dispatch defect was demonstrated. EQ05/Q3 lifecycle and
alternative memory cancellation remain explicit integration assumptions.

### EQ07's 102 provisional differences

The `previous` alternative restores P from old C on a coincident confirmation and
flush. RTL includes the same-edge confirmed operation before restoration. At the
first differing sample, cycle 72, the alternative expects `0x808` while RTL returns
`0x908`. The 102 differences include propagated valid/target/flush/metadata checks;
they are **not 102 RTL defects**.

The full-core witnesses instead have confirmation **one edge before** frontend
branch recovery; exception flush suppresses confirmation. Both restoration
hypotheses agree in that supported schedule. Keep truly coincident alternatives
provisional until their surviving-instruction contract is approved.

Evidence: [EJU audit §A3](early_jump_unit/ARCHITECTURE_AUDIT.md#a3-stall-release-and-feedback-timing)
and [§E6](early_jump_unit/ARCHITECTURE_AUDIT.md#e6-eq07-meaning-of-the-102-discrepancies).

## 8. R12 — Configuration restrictions, not a demonstrated failure of N=1/2/4/8

The complete frontend was actually elaborated and simulated in disposable
N=1/2/4/8 configurations with HLEN=4. Reset, basic fetching, JAL/conditional
training, call/return recovery and fault transport passed the recorded focused
tests. The latest BP05 saturation checks also passed all four widths. Mathematical
model support alone was not used as proof of RTL support.

Remaining restrictions:

* Gshare/BPU slices require **HLEN > log2(N)**, and the history shift requires
  **HLEN >= 2**. Configurations violating these conditions are not supported by
  the current declarations. HLEN=4 satisfies all four tested widths.
* RAS depth 4 is the verified stack contract. Depth 1 has a `$clog2(DEPTH)=0`
  index-width risk; arbitrary depths were not validated. RAS depth 1 is different
  from fetch width N=1.
* Metadata depth 2 and the selected request/answer spill settings define the
  tested memory timing/capacity profile. Depth-0 bypass, depth-1 width risks and
  alternate spill settings require separate contracts/builds.
* Package `BOOT_PC` is not automatically the effective module parameter. Tests
  must fingerprint the elaborated value. Confusing these was a configuration
  hazard, not a demonstrated wrong RTL reset address.
* Compressed instructions, arbitrary unsupported widths and a full alternate
  backend/ISA configuration are not verified by these tests.

Evidence: [completion audit §A](fetch_stage/COMPLETION_AUDIT.md#a-configuration-and-real-multi-n-execution)
and [final audit §D](fetch_stage/FINAL_FRONTEND_ARCHITECTURE_AUDIT.md#d-validation-and-retained-evidence).

## 9. H01 — Historical PC alignment defect, now fixed

The earlier approved-contract T19 found a real ordinary-successor defect. With
N=4, a supplied raw target `0x701` was accepted correctly, but the next ordinary
fetch progressed to `0x711` instead of the required aligned bundle successor
`0x710`. The old arithmetic retained the raw target's low bits.

Fifteen directed cases produced 30 field differences; historical mixed regressions
recorded 44,432 differences across four million cycles. Those are repeated
manifestations of **one defect**, not separate bugs. The PC documentation explicitly
states that the user subsequently corrected RTL. The current ordinary adder base
clears instruction-offset bits; the recorded current suite passes T01–T22 and its
million-cycle regression with zero mismatches.

Source: [pc_gen.sv](../../rtl/frontend/pc_gen.sv), lines 44–71;
[PC specification decision/history ledger](pc_gen/VERIFICATION.md#q1q10-decisions-residual-scope-and-evidence);
[PC README current validation](pc_gen/README.md#current-suite-validation).

Different historical hypotheses—ready-gated early correction and always-arithmetic
early-target metadata even when a higher-priority redirect wins—were superseded
by approved contracts. Their provisional differences are **not current defects**.

## 10. T01 — Verilator DFG metadata discrepancy

Verilator 5.040 default optimization disagrees with `-O0` and `-fno-dfg` on the
production EJU-to-mixer prediction rewrite. The smaller retained public-port-only
reproducer first differs at **cycle 54, post-edge**, using a 165-sample causal
prefix: JAL at `0x180` targets `0x100`; default forwards the correct PC, hit and
target but **taken=0**, whereas O0/no-DFG forward taken=1 after EJU correction.

The public replayer removes the reference model, synthetic backend and random
generation. Identical RTL/input histories are used. Four extra `eval()` calls per
phase do not change the result. Generated default C++ copies a partially rewritten
prediction into a mixer temporary before applying its taken-bit rewrite, matching
the isolated public error.

This supports a **simulator DFG dependency/code-generation defect**, not a proven
hardware defect or reason to weaken metadata checking. No independent second
HDL simulator or upstream diagnosis was obtained. Keep the documented `-fno-dfg`
workaround. Short N=1/2/8 captures did not reproduce the difference; that does not
prove immunity.

Evidence and retained standalone vectors:
[completion audit §B](fetch_stage/COMPLETION_AUDIT.md#b-verilator-optimization-investigation),
`build/fetch-stage/completion-audit/optimization/dfg-xw9j1vje/FE19-reduced/`.
The earlier longer witness first differed at cycle 245. These simulator samples
must not be counted as confirmed production RTL errors.

## 11. Complete question-register cross-reference

These tables preserve the outstanding scope without turning every Q into an RTL
bug. Shared issues appear once in the detailed findings above.

### PC generator: Q1–Q10

| IDs | Current disposition |
|---|---|
| Q1 | Reset/BOOT/release contract approved; readiness during reset remains Q. |
| Q2 | Redirect priority approved; losing acknowledgment and reachability are separate residuals. |
| Q3 | Memory-independent early redirect approved; held correction lifetime/cancellation remains I/Q (R10). |
| Q4 | Consumed selected early metadata exact; branch-overridden consumer window remains Q. Unused commit/reset/idle metadata is don't-care. |
| Q5 | Control-cycle valid qualification, idle/shared/reset ready and losing redirect acknowledgments remain I/Q; no confirmed PC-selection failure. |
| Q6/Q7 | Bundle successor and exact supplied-target pass-through approved. Historical alignment defect fixed (H01); executability/fault checks belong to producers. |
| Q8 | Stable consuming inputs and changing stalled predictions approved; physical setup/hold is outside simulation proof. |
| Q9 | Physical cancellation, older survival and integrated ROB/issue timing are outside standalone PC proof (R02/R06/R10). |
| Q10 | Supplied address forwarding checked; actual trap/MRET/interrupt target construction is outside scope (R03–R05). |

Source: [PC specification Q ledger](pc_gen/VERIFICATION.md#q1q10-decisions-residual-scope-and-evidence).
Active residuals are Q1/Q3/Q4/Q5/Q9, not an assertion that all original decisions
are still undecided.

### Early jump and RAS: EQ01–EQ12

| ID | Current disposition |
|---|---|
| EQ01 | Coherent-mask oldest recognized jump selection is supported I. Arbitrary holey masks/generic-JALR cutoff remain unapproved. |
| EQ02 | RAS asynchronous reset and pending-correction cancellation observed; immediate live standalone reset-release behavior remains Q. Normal empty spills constrain integrated startup. |
| EQ03 | Restricted x1-call/canonical-RET recognition approved D; no x5/coroutine defect. |
| EQ04 | Taken-hit JAL suppression approved D even for wrong target. RET redundancy remains I/Q (R09). |
| EQ05 | Held corrections/repeated offers and cancellation lifecycle I/Q (R10). |
| EQ06 | Recovery overrides predictive updates; meaningful consuming-edge qualification matters. Raw flush/valid/ready combinations are not automatically integrated transactions. |
| EQ07 | Same-edge old/new-C alternatives provisional; normal producer separates confirmation and restoration (R11). |
| EQ08 | Confirmed predictor-history contamination reproduced (R01); exception recovery redesign not approved/implemented. |
| EQ09 | Depth-4 newest-entry overflow and empty-pop behavior are named I policies; other depths not validated (R12). |
| EQ10 | Exact consumed feedback checked; canceled-lane values are not architectural results; delayed exception window remains unresolved (R02). |
| EQ11 | No EJU exception input; faults bypass it and BU must suppress faulting confirmation. Complete faulting-jump cleanup/sign-off not established (R05, deferred FE-T50). |
| EQ12 | Current ordered branch execution/confirmation is source-supported I; not retirement, not a guarantee for future scheduling or older nonbranch faults (R01). |

Source: [EJU audit decision table](early_jump_unit/ARCHITECTURE_AUDIT.md#a-eq01eq12-decisions-and-evidence)
and its later §E full-core results.

### Fetch memory interface: FQ01–FQ13

| ID | Current disposition |
|---|---|
| FQ01 | Unaccepted request stability/replacement on redirect requires the connected protocol (R07). |
| FQ02 | Grant-on-flush old/new ownership unresolved (R07). |
| FQ03 | Zero-latency empty-FIFO response association unsupported/unresolved (R07). |
| FQ04 | Noncancelable stale-response filtering absent; conditional stale-fault hazard demonstrated (R06). |
| FQ05 | Exact reset-release readiness/latency is I, not an independently approved universal timing rule. |
| FQ06 | Consumed-head early flush versus canceled branch/exception head must be distinguished; supported profile checked. |
| FQ07 | Unused fields, invalid lanes and unraised causes need explicit raw-preservation/don't-care qualification; no live stale-error failure observed. |
| FQ08 | Other metadata depths/spill settings/capacity guarantees unvalidated (R07/R12). |
| FQ09 | Raw misaligned target detection belongs to memory/producers; N>1 emulator reconstructs aligned lanes. Exact supplied error transport does not verify fault detection. |
| FQ10 | Correct architectural fetch-fault `mtval` unresolved (R05). |
| FQ11 | No established general bus timeout/retry/page-fault producer. Enum code availability is not implemented translation/error detection. |
| FQ12 | Separate full-core recovery-window observation (R02). |
| FQ13 | External fairness/timeout/cancellation guarantees beyond the emulator unestablished; permanent stall is not demonstrated DUT response loss. |

Source: [fetch-memory specification question table](fetch_mem_if/VERIFICATION.md#21-open-specification-questions-and-architectural-risks).

### Complete frontend: FEQ01–FEQ13

| ID | Current disposition |
|---|---|
| FEQ01 | Current BTB/gshare algorithm approved D as implementation target; exact-I sampling dependencies and predictor-agnostic checking limits remain (R08). |
| FEQ02 | Same-edge predictor timing, row deletion without a tag recheck, target-low-bit truncation and predictor-only flush need their stated scope. Current algorithm is not replaced with a generic textbook rule. |
| FEQ03 | Inherited EJU lifetime/reset/feedback and redundant RET questions (R09/R10). |
| FEQ04 | EQ07 alternatives provisional (R11). |
| FEQ05 | EQ08 and reason-specific exception/MRET history policy (R01). |
| FEQ06 | Faulting raw jumps, confirmation qualification and `mtval` scope (R05). |
| FEQ07 | Delayed exception recovery window (R02). |
| FEQ08 | Cancellation/unaccepted-offer/alternative-memory contracts (R06/R07). |
| FEQ09 | Shared/losing redirect acknowledgments and exact producer schedules remain I/Q; PC priority itself is approved. |
| FEQ10 | Raw BPU and EJU offer are hidden at the complete frontend boundary. Corrected metadata cannot alone prove raw BPU correctness; use public temporal witnesses. |
| FEQ11 | Effective BOOT parameter and alternate depth/spill support (R12). |
| FEQ12 | Synthetic integer backend is bounded and conservative, not complete real-backend/ISA/retirement/interrupt verification. |
| FEQ13 | JAL hit/not-taken and good-BTB/stale-RAS reachability demonstrated; other rare combinations remain unproven, not automatically impossible or passed. |

Source: [frontend decision register](fetch_stage/VERIFICATION.md#182-decision-register),
with later updates in [final architecture audit](fetch_stage/FINAL_FRONTEND_ARCHITECTURE_AUDIT.md).

## 12. Behaviors explicitly approved or valid — not RTL defects

* `JAL rd=x1` pushes predictive RAS. Other JAL destinations, including x5, do
  not. Only exact canonical `JALR x0,0(x1)` (`0x00008067`) is an early return.
  General x5/coroutine hints and indirect-call RAS acceleration are outside the
  approved recognition policy.
* For JAL, `hit && taken` suppresses EJU correction without checking target
  equality. Backend execution remains responsible for a wrong target. A wrong
  target on an immutable JAL is not automatically reachable by ordinary training.
* BTB index collisions with different source tags cause replacement/misses,
  **not ordinary false-tag hits**. Gshare interference is a distinct effect.
  BTB deletion can evict the indexed row without a tag recheck; that is part of
  the current approved predictor policy, not proof of an execution error.
* BTB stores word targets and reconstructs low zero bits. PC pass-through of raw
  targets does not impose a different storage contract on BTB.
* Cold integrated gshare counters are weakly taken, but cold BTB is invalid.
  Raw taken=1 without hit is not a qualified taken redirect.
* Instruction-address-misalignment cause **0 with raised=1** is a valid fault.
  Memory faults are per lane. No failure is established merely because an
  exception code is zero or an unraised cause field retains arbitrary bits.
* RAS underflow/overflow are prediction-state policies, not software stack
  correctness. Overflow's loss of old entries can reduce prediction accuracy;
  actual x1-based return semantics still require backend checking.
* A raw valid/target can remain combinationally asserted on a canceling edge when
  the downstream consumer correctly withdraws acceptance. Inactive buses are not
  proof that a canceled instruction executed.

## 13. Verification and tooling problems must not be counted as production bugs

The audits also found framework deficiencies. Their existence matters to the
strength of the evidence, but they do not add production RTL defects:

| Area | Recorded verification problem and current treatment |
|---|---|
| PC framework | Configuration selection, comparison-confidence and coverage/replay accounting were strengthened. Old ready-gated/always-arithmetic model assumptions were superseded by approved decisions. Historical evidence must be read with its contract revision. |
| EJU unknown-state tracking | Conservative exception handling previously kept C known and could restore false knowledge into P; unknown-overflow handling could invent a known top. Both corrected. A dead `mispredict`/`misprediction` random-validator assertion was also fixed. |
| EJU standalone audit limits | Per-operation witness completeness, independent recovery-order validation and some aggregate reset/assumption fields were incomplete. The later integrated frontend added a causal RAS-operation ledger and stronger public drains; that does not retroactively establish exhaustive standalone coverage. |
| EJU mutation isolation | Relative dependency paths once risked compiling the wrong source configuration. Disposable export/source guards were corrected; stale/wrong-width builds are not RTL functional failures. |
| Fetch-memory framework | Inactive-array-slot randomization, canceled-ID reuse, secondary mismatch confidence, orchestration CLI adaptation and acceptance coverage credited before an edge were found and fixed. No golden transport result was changed to hide RTL failure. |
| Memory emulator | `ReadW` returns its last byte-read status, so partially initialized words may have surprising error status. This is an emulator limitation/source observation, not production fetch_mem_if fault detection. The independent environment supplies its own explicit fault map. |
| Frontend backend abstraction | Earlier code reserved ROB for unissued IQ work, lacked a distinct publication stage, released branch capacity at computation and allowed unlimited ordinary completions. Latest audit enforces IQ16/ROB32/ALU-RS8/BU-RS4, scalar issue, one shared publication per edge and proper retention until publication/retirement. |
| Frontend scheduler/confidence | Repeated redirect after acknowledgment, missing negative-validator flags, composite FE-T54 evidence and other orchestration checks were corrected. Deliberate injected failures are expected-negative validation, not discovered RTL faults. |
| Default result policy | Incomplete witnesses once made zero-mismatch suites fail or printed misleading failure summaries. Default warning/strict-completion separation now preserves incomplete status without falsely claiming PASS. This was orchestration, not RTL. |
| FE-T15 witness | Historical cycle-257 update had no valid conditional pre/post probe: candidate PC `0x20` was a JAL and masked out of the relevant accepted bundles. Latest immutable threshold/interference program closes both public BTB-hit crossings; it was a coverage gap, not an RTL mismatch. |

Sources: [PC README](pc_gen/README.md),
[EJU audit §C3](early_jump_unit/ARCHITECTURE_AUDIT.md#c3-concrete-fixes-and-retained-gaps),
[EJU audit §E7](early_jump_unit/ARCHITECTURE_AUDIT.md#e7-selected-width-verification-and-mutation-results),
[fetch-memory implementation/confidence record](fetch_mem_if/VERIFICATION.md#23-standalone-implementation-and-validation-record),
[frontend completion audit](fetch_stage/COMPLETION_AUDIT.md),
[final frontend audit §§B–C](fetch_stage/FINAL_FRONTEND_ARCHITECTURE_AUDIT.md).

Mutation results establish sensitivity to **deliberately altered disposable RTL**.
They do not mean those defects exist in production. In particular, the original
12 frontend mutation detections were classified provisionally under integrated
I dependencies; they are not 12 confirmed architectural bugs.

## 14. Remaining verification limits and priorities

The latest ordinary frontend audit records **48 passed IDs / 69 cases**, zero
ordinary mismatches and no missing selected ordinary witnesses. FE-T15 strict
completion now passes; FE-T19's coherent JAL hit/not-taken history and FE-T54's
24 composite validators are also established. Older sections calling these cases
incomplete are historical and superseded.

Full specification completion still excludes:

| Scenario | Remaining unfinished obligation |
|---|---|
| FE-T43 | Complete exception-recovery, predictor-reset and intended surviving-history obligations. |
| FE-T48 | Delayed older data-fault context needed for integrated EQ08 modeling; cannot substitute a known fetch fault. Existing full-core EQ08 reproduction remains valid separately. |
| FE-T49 | Complete delayed-redirect/intervening-dispatch surviving-stream proof (R02). |
| FE-T50 | Full faulting JAL/RET characterization and cleanup policy. Exact retained fault transport is still checked. |
| FE-T51 | FQ02/03/04 alternative memory protocols without an approved architectural contract. |
| FE-T41 alternatives | Genuinely simultaneous confirmation/restoration remains provisional, separate from normal producer timing. |

Predictor-agnostic checking, all FEV crosses, complete real backend execution,
CSR/`mtval`, interrupt/MRET and precise retirement correctness are not closed.
A successful default process can therefore mean **PASS WITH WARNINGS**, not full
specification sign-off. Strict completion remains available for selected required
obligations. No new full regression or mutation campaign was needed to compile
this report.

Recommended follow-up order:

1. Approve the EQ08 recovery policy and implement/test it as a separate RTL change.
2. Investigate R02 with a precise surviving-instruction/commit trace and a harmless
   distinguishing non-NOP fixture; establish functional impact before claiming it.
3. Verify real issue/commit exception producers, MRET, fetch-fault `mtval` and
   interrupt capability before treating trap-shaped frontend inputs as system proof.
4. Retain the active memory cancellation/capacity contract; design an explicit
   adapter before attaching noncancelable or zero-latency memory.
5. Retain current gshare Policy A for baseline verification; measure a closed-loop
   saved-index alternative before approving predictor/interface changes.
6. Keep the simulator workaround and its reproducer until independently resolved.

## 15. Source documents and review integrity

The consolidation uses the following verification records, with later dated audit
updates taking precedence over historical results in the same document:

* [pc_gen README](pc_gen/README.md) and [VERIFICATION](pc_gen/VERIFICATION.md).
* [early_jump_unit README](early_jump_unit/README.md),
  [VERIFICATION](early_jump_unit/VERIFICATION.md),
  [ARCHITECTURE_AUDIT](early_jump_unit/ARCHITECTURE_AUDIT.md) and
  [full-core recovery README](early_jump_unit/recovery/README.md).
* [fetch_mem_if README](fetch_mem_if/README.md) and
  [VERIFICATION](fetch_mem_if/VERIFICATION.md).
* [fetch_stage README](fetch_stage/README.md),
  [VERIFICATION](fetch_stage/VERIFICATION.md),
  [COMPLETION_AUDIT](fetch_stage/COMPLETION_AUDIT.md) and
  [FINAL_FRONTEND_ARCHITECTURE_AUDIT](fetch_stage/FINAL_FRONTEND_ARCHITECTURE_AUDIT.md).

Only this Markdown file was added. Production RTL/configuration and the four
existing verification directories were preserved. Build-artifact locations in
the cited audits describe their retained historical evidence; this report does
not imply those simulations were rerun or that every artifact is portable to a
different source fingerprint.
