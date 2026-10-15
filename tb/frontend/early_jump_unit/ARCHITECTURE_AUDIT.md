# Early-jump/RAS independent verification and recovery audit

Review: 2026-10-14, branch `feat-verification`. Scope: the active EJU/RAS and its
standalone verification, with read-only inspection of surrounding recovery logic.
Sections A–D record the initial source/standalone audit. Section E records the
subsequent user-requested full-core experiments at N=2 and N=4 in disposable copies.
Production RTL/configuration remain unchanged; the original no-integration scope
was expanded explicitly for that follow-up.
Source references below use repository-relative paths and inspected line ranges.
[A/D/I/O/Q](VERIFICATION.md#1-evidence-policy-and-scope) retain their existing meanings.
A source-derived ordering proof is integration evidence **I**, not new user approval D.

**Finding:** EQ08 is now reproduced in full-core simulation at N=2 and N=4
(§E), extending the original source-supported reachability argument.
Execution-confirmed RAS operations can survive an older precise exception that
invalidates their instructions. Ordinary branch misprediction has a different
ordering argument: the current ordered branch execution cursor and confirmation
controller prevent the proposed younger-before-older confirmation sequence.
Recommend clearing both histories on exception recovery, with an explicit recovery
reason, while retaining P←C on ordinary branch recovery. This is a design proposal,
not an implemented fix or an approved replacement oracle.

The standalone checker is useful and independent, but its passing runs do not
prove exception-safe history. Its default explicitly assumes the current exception
restore policy; the architectural generator has no retirement/precise-exception
model. Three verification bugs were fixed during this review, detailed in C.

## A. EQ01–EQ12 decisions and evidence

| ID | Active RTL / integration observation | Intended or proposed behavior and classification | Closure / remaining uncertainty | Verification action | Possible RTL action (none performed) |
| --- | --- | --- | --- | --- | --- |
| EQ01 | `gen_valid_instr` includes lanes from request start through first eligible hit&&taken; EJU chooses oldest input-valid recognized jump and truncates younger lanes. | Coherent response interval and oldest recognized selection I; restricted recognition D. NT branches leave later lanes eligible. | Strong source support for coherent masks; arbitrary holey/contradictory masks and generic-JALR cutoff are not approved. | Existing T05/T09–T13, mask units and random crosses check this exactly under I. | None justified for coherent masks. Specify unsupported masks before changing behavior. |
| EQ02 | RAS validity resets asynchronously; EJU cancels pending correction but has a RESET release interval. Speculative controls are not gated by that EJU control state. | Empty P/C and canceled pending work are supported reset assumptions I; exact immediate-release behavior Q. | Normal answer/output spills prevent a live accepted bundle during their release interval. This does not specify arbitrary standalone release inputs. | T01/T02/T30 plus asynchronous samples; retain Q for immediate live release. | No required change established; do not add a golden release bubble. |
| EQ03 | Opcode-qualified JAL x1 push; other JAL no push; only exact `0x00008067` pop; backend decoder matches. | **D: approved x1-only subset**, including negative no-RAS-effect rules. | Recognition closed. Generic-JALR lane cutoff remains Q. No x5/coroutine defect. | T03/T06/T07/T31, fixed words, temporal no-op witnesses and forbidden-x5 mutation. | None. |
| EQ04 | JAL correction tests its selected lane's hit&&taken only; RET with nonempty P corrects even if prediction already matches. | **D: taken-hit JAL may suppress correction even with wrong target.** Remaining RET redundancy is I/Q. | JAL target-validation question closed by user. No requirement to add a comparator. | T08 already tests all four hit/taken pairs and correct/wrong targets at every lane; T14 retains push. Added pure D-policy fixtures and report provenance. | None for JAL; RET optimization would require a separate decision. |
| EQ05 | Correction is offered while spill not ready; memory flush waits for spill acceptance. Stable response fields supply operands throughout. pc_gen may load the same target repeatedly. | Hold offer until accept/cancel; one P operation per accepted bundle, I. | Integration supports stable holds; no dedicated correction ack. Repeated target requests depend on actual memory cancellation, outside this DUT. Malformed withdrawal remains Q. | T21–T24, held-response validation and return witnesses; preserve I. | No demonstrated EJU defect. Review request/cancel integration before changing timing. |
| EQ06 | RAS restore wins over P push/pop; EJU pending work canceled at edge. Output spill ready is low on recovery, but EJU combinational valid can remain high. | Recovery cancels speculative acceptance; flushed outputs ignored by downstream, I. | Normal F&&V&&R is excluded by connected spill. Raw pin overlap is stress, not a proven consumed instruction. | T20/T23/T29; check later cancellation and meaningful outputs, not arbitrary flushed payloads. | None established for normal timing. |
| EQ07 | RAS uses updated C on F. Actual mispredicted call/return confirms in MIS, then F occurs in MIS_LOAD_PC; backend exception flush masks confirmation. | Proposed `C'=step(C,c); P'=C'`, I. | Same-edge update-first is consistent with port semantics but not newly approved; normal integration does not require this overlap. Keep alternatives. | T18–T20; `previous` retains provisional failures, `unknown` retains unknown P. | None without a design decision; retain ordinary confirm-before-F schedule. |
| EQ08 | Every F restores P from C; no reason input and no C rollback/clear except reset. BU confirmation precedes retirement. | Recovery must not retain squashed operations if C is to represent surviving history. Clear-both exception policy is the recommended **proposal I/Q**, not D. | Older load-fault contamination reproduced at N=2/N=4 in E, for both confirmed push and pop. Recovery policy still awaits approval. | T28 characterizes current ports; conservative profile now leaves both histories unknown across exception and later F. New integration tests required for a fix. | Separate exception clear from branch restore in datapath/fetch/EJU/RAS; clear dominates confirmation. |
| EQ09 | Depth4 keeps newest four on overflow; empty pop leaves validity empty; unused data not reset. | Recent-entry/drop-oldest and empty-pop-no-op remain named I policies. | Supported test contract depth4 only; depth1 has `$clog2` zero-width risk, other depths not validated. | T15/T25/T26 drain both histories; unknown-boundary profile retained. | None requested. Do not confuse N=1 with RAS depth1. |
| EQ10 | Selected corrected metadata takes supplied pc_gen feedback. During frontend F, output spill refuses acceptance and clears its stored data. | Exact consumed feedback propagation I; flushed lane payloads don't-care; overriding redirect generation outside EJU. | Branch-F coincidence supported for current BU setting; whole exception redirect/refill window not proven. | T13/T29; no output-derived feedback oracle. Keep canceled versus unknown windows distinct. | No EJU fix established; integration assertions needed. |
| EQ11 | EJU has no exception input. Fetch exceptions bypass it; BU suppresses faulting call/return confirmation on taken target bit1 misalignment. | EJU can speculate before a fault; no invented EJU fault responsibility. Fault qualification/cancellation is producer I. | An EJU-only pass cannot prove actual fault suppression or cleanup. | T34 is fault-prone port characterization, not a branch-unit fault test. Environment rejects faulting confirmations. | Exception reason-specific cleanup proposed under EQ08; producer fault correctness is separate. |
| EQ12 | Branch RS executes only its execution cursor; CU confirms once in UPD_FE/MIS, independent of CDB retirement/frontend ready; backend flush masks it. | Ordered eligible confirmations, once per execution, I. | Proven for inspected current combinational BU path; not general out-of-order confirmation or arbitrary BU latency. Earlier nonbranch faults remain outside this guarantee. | Environment's ordered ledger matches that subset; scalar pulses are not retried held requests. Generator remains an abstract projection, not a full processor history. | None for ordinary ordering; any future BU scheduling/latency change needs re-audit. |

### A1. Valid bits and multiple predictions

Three qualifiers must stay distinct: bundle `instr_valid_i`, per-lane
`valid_instr_i`, and prediction `.hit`. `taken` without hit is not a taken
successor. With B=4N and an aligned request PC, input-valid lanes form the inclusive
interval from `(pc mod B)/4` through the first hit-and-taken lane at or after that
start. A predicted-not-taken branch remains a real branch and leaves younger lanes
speculatively eligible. Multiple raw predictions are legitimate; they do not mean
multiple taken successors are accepted.

Evidence: `rtl/frontend/gen_valid_instr.sv:11–64`;
`bpu.sv:40–82`; `gshare.sv:43–114`. Request masks and prediction records travel
through the request spill, prediction FIFO and answer spill together
(`fetch_mem_if.sv:88–145,159–165`). EJU selects the oldest **recognized**, not the
oldest **uncorrected**, jump (`early_jump_unit.sv:92–151`). A predicted JAL still
truncates younger words and can push. A masked jump does neither. The mixer moves
instruction, prediction and exception metadata together
(`instr_mixer.sv:18–61`), then issue takes `hit & taken`
(`rtl/expipe/issue-unit/issue_stage.sv:206–225`).

Consequently PN-branch→JAL, multiple PN branches, first PT followed by masked JAL,
CALL→RET, RET→CALL and wrong-path speculative lanes are meaningful cases. A mask
that includes a lane after an earlier eligible PT contradicts the request producer;
it belongs to interface stress/characterization. No full hint expansion follows
from any of these selection rules.

### A2. What a BTB hit proves

`rtl/frontend/btb.sv:39–72` stores valid, source-PC tag and target. Index is source
PC bits `[BTB_BITS+OFFSET-1:OFFSET]`; the tag contains the remaining upper bits.
Read logic at 88–122 compares the complete remaining tag for each reconstructed
bundle lane. For aligned PCs in this bare-metal address space, an index collision
with a *different* tag is a miss, not evidence of an aliased valid hit. Direction
aliasing in gshare can change taken prediction but does not change that BTB match.

The target is the last supplied resolution target; no instruction bits are stored
or compared. Dynamic JALR targets can therefore be stale at the same source PC.
For an unchanged direct JAL at an unchanged PC, the decoded target is constant:
an ordinary index collision alone does not explain a wrong-target JAL hit. A
same-PC code replacement/stale instruction stream, bad prior update, or malformed
standalone metadata could explain it; this review did not prove a coherent
self-modifying-code protocol. Exception flush invalidates BPU state
(`datapath.sv:105–106`, `bpu.sv:55–69`, `btb.sv:75–86`).

EQ04 does not depend on proving how a wrong target arose. User approval permits
suppression even in that case. T08's wrong-target samples remain useful interface
verification; do not call them a JAL defect or claim all are reachable from an
immutable correct program/BTB. The model now records the suppression selection as
EJ05/D; exact external valid/metadata comparisons retain their separate EQ01/EQ05
qualification dependencies. This approval does not turn every early-valid mismatch
into a definitive error.

### A3. Stall, release and feedback timing

`early_jump_unit.sv:155–197,202–222` separates correction offer from acceptance.
The answer record stays stable while the output spill is full
(`fetch_mem_if.sv:132–145`, `spill_cell_flush_cu.sv:132–168`). During a stalled
call/return, P does not update, but an independent BU pulse can update C. At normal
release, the selected operation happens once at V&&R. A return's consumed target
is the pre-edge top; post-edge operands can expose the next top.

`pc_gen.sv:82–110` loads the early target at every applicable rising edge and keeps
ordinary valid high absent commit/branch recovery. Repeated correction offers can
therefore cause repeated identical PC loads and, if request capacity permits,
repeated target fetch requests. They do **not** by themselves imply duplicate RAS
pushes. At correction completion, `mem_flush_o` flushes the memory request/answer
path and external memory path (`fetch_stage.sv:185,224–225`, `datapath.sv:197`),
while the accepted instruction goes into the distinct output spill. Correctness
requires those outstanding requests to be canceled before delivery in a new epoch.
The standalone wrapper cannot prove that cancellation; EQ05 remains open at that
integration boundary. Live buffered prediction changes during this stall are
malformed even though pc_gen's current-request BPU may change during a stall.

Frontend F lowers output spill ready immediately and clears it at the edge
(`fetch_stage.sv:262–273`, `spill_cell_flush_cu.sv:126–168`). EJU outputs are not
combinationally gated by F. This explains why flush-edge sideband assertions can
be harmless without requiring their exact target. Normal branch F and pc_gen
recovery coincide in the inspected schedule below. Exception F precedes the later
commit target load; do not extend this one-edge nonconsumption argument into a
proof of every intervening request/refill window.

Both RAS valid histories asynchronously clear (`ras.sv:63–69,110–117`); EJU resets
its correction state (`early_jump_unit.sv:193–197`). Reset release moves EJU out
of RESET at the first rising edge, while ordinary answer spills start empty.
`FETCH_ANS_SPILL_SKIP`/output-spill assumptions matter to integrated startup.
Immediate standalone V/R after release is still Q; no extra reset delay was added.

## B. EQ08: recovery history and design proposal

### B1. Confirmation is not retirement

The full path is:

1. Returned bundle → EJU selected x1 call/RET → predictive update at spill acceptance.
2. Mixer/output spill → issue queue FIFO. Queue pops its head only
   (`issue_queue.sv:74–82,118–149`). Issue allocates execution/ROB work together
   (`issue_cu.sv:83,207–234`) and stores instruction/PC in ROB
   (`issue_stage.sv:548–559`).
3. Branch reservation station waits for operands at its execution cursor.
4. BU computes actual target, direction, link and misprediction
   (`branch_unit.sv:109–172`). Call/return confirmation depends on valid execution,
   supported BU type and no target-alignment fault, not on ROB retirement
   (`branch_unit.sv:127–135`).
5. A resolution register captures the operation/link; next-cycle UPD_FE or MIS
   enables the confirmation output (`branch_unit.sv:200–228,278–281`,
   `branch_cu.sv:89–114`). No EJU ready participates.
6. Separately, branch completion is sent through the reservation station/CDB to
   ROB (`branch_rs.sv:285–295`, `rob.sv:194–205`). Commit and recovery can occur later.
7. Commit exception asserts both backend flush and frontend exception flush
   (`commit_cu.sv:429–435`). Backend routes the former to the branch unit and ROB;
   datapath ORs frontend exception/misprediction flush into EJU's single F
   (`backend.sv:425–433,492,514–515,590`, `exec_stage.sv:154–177`,
   `datapath.sv:105,128–130`). RAS copies C into P and leaves C intact.

There is no ROB identity, instruction age, exception reason, commit pulse or undo
information at the RAS boundary. Canceling an instruction ledger entry cannot undo
an operation already applied to C. A confirmed return is particularly important:
rollback may need to restore an address that was removed, not merely discard a
new top entry. Overflow can also have discarded an older address.

### B2. Scenario A — reachable older precise exception

A concrete instruction-age construction (values initialized earlier):

```text
D: divu x10, x11, x12       # x11=0x8000000000000001, x12=1: long operation
A: ld   x1, 0(x10)         # waits for D; resulting address has low bits 001
B: jal  x1, target_B       # independent of x10/x1 values, correctly predicted
```

Choose enough free ROB/load/branch entries and ready instruction delivery. D's
serial divider has a large shift/count for these operands
(`serdiv.sv:118–124,155–203`), permitting A and B to issue while D runs. Load
allocation accepts an unready base, waits for its CDB value, then requests the
address calculation (`load_buffer.sv:224–264`). Thus A does not block *issue* of B.
JAL's source is PC/immediate, not the unresolved value of x1
(`issue_decoder.sv:334–345`). B can execute and confirm first.

The address adder raises a doubleword misalignment exception from bits[2:0]
(`address_adder.sv:52–68`). The load stores that exception and sends it through
CDB (`load_buffer.sv:380–384,433–437`); ROB stores it, and the commit decoder gives
an exception priority over opcode (`commit_decoder.sv:45–48`). This uses an
implemented address-computation fault, not an assumed late memory-access fault.

**Why B remains unretired in this example:** ROB is *not* wholly in-order.
It has one lookahead slot (`rob.sv:139–167,250–261`). While D is head and A is the
lookahead, A is unready and the lookahead cannot skip to B. After D commits, A is
head. A and B both write x1, so the explicit WAW check blocks B's out-of-order
commit (`rob.sv:153–163`). Once A's fault is ready, the head wins and exception
recovery clears younger work. This argument does not incorrectly assume that
all loads are memory-critical or all JALs are order-critical.

Illustrative edge-relative timeline; gaps depend on fetch/CDB/commit scheduling:

| Interval before edge | Signals / event | C/P consequence at that edge |
| --- | --- | --- |
| Earlier | B's fetched call accepted, V=R=1 | P pushes B.pc+4. |
| t | B executes: rs_bu_valid=1, BU_CALL, no fault; controller IDLE/UPD_FE | Register captures call/link; no retirement needed. |
| t+1 | UPD_FE, `fe_call_confirm_o=1`, frontend F=0 | C pushes B.pc+4. |
| t+2 … u | A still waits for D / address calculation; B held in ROB by conditions above | C retains B. |
| u | A completes with E_LD_ADDR_MISALIGNED and reaches commit | Exception selected. |
| v (later commit interval) | COMMIT_EXCEPT: `except_flush=1`, `ex_mis_flush=1`; EJU F=1; BU confirmation masked | B is squashed; current RAS restores P from C **including B**. |
| Later | Trap/recovery path offers a canonical return before another overriding history change | EJU can predict B.pc+4 although B is not in surviving instruction history. |

This is **demonstrably reachable by the inspected logic** under the stated legal
resource/latency conditions, not merely an arbitrary EJU pin combination. It is a
static reachability argument; no full-core execution trace is claimed. The subsequent full-core experiments in §E instantiate this schedule and observe
retirement/flush; this paragraph records the original static argument.

A younger confirmed **return** can likewise remove surviving history. Use a
long-latency D, an older delayed faulting load A writing a register other than x1,
and a younger canonical RET B whose actual x1 target differs from the supplied
prediction. BU confirms B's pop (alignment is valid) and starts normal branch
recovery. Its ROB result is marked E_MISPREDICTION, which independently prohibits
out-of-order commit (`rob.sv:161`). A's older exception subsequently wins; B is
squashed, but the removed C entry is not restored. The intermediate branch recovery
does not make B retired or make its confirmed pop safe against A. Initialize C
with a distinct older link to observe the missing entry.

The existing standalone witness is reproducible with
`make check-early-jump-run SCENARIO=EJ-T28 LOG_LEVEL=LOG_HIGH`. In this audit's
full directed journal, cycle5424 applies exception F after C contains `0x808`;
cycle5425's RET gives expected/actual offset `0x0000000000000808` under the
**provisional** restore contract. Another branch F at5426 exposes the same address
at5427. This proves the port-level survival mechanism, not ROB reachability. The
assembly/ordering argument supplies the latter; full-core waveforms are now supplied separately in §E. There is no new definitive standalone failure
because exception-clear behavior has not yet been approved/implemented.

An older issue-known illegal instruction/fetch exception is a different case:
issue enters exception/stall handling and prevents ordinary younger issue
(`issue_cu.sv:161–175`). Do not use that simpler sequence as proof that B could
execute. Delayed execution faults are the necessary counterexample above.

### B3. Scenario B — younger confirmation before older branch recovery

For the **current** BU configuration, the proposed counterexample is prevented:

- FIFO issue gives branch RS ordered allocations.
- Only `curr_state[ex_idx] == BU_S_EX_REQ` drives execution valid. No search for a
  younger ready branch exists (`branch_rs.sv:129–141,297–306,337–345`). If A's
  operands are missing, younger B cannot execute past A.
- The selected BU spill is bypassed (`len5_config_pkg.sv:161`), and branch RS
  result-ready is constantly one (`branch_rs.sv:298`, `spill_cell.sv:40–45`). A's
  execution acceptance and target/misprediction computation occur together.
- Once A mispredicts, the controller freezes its resolution register and disables
  confirmations after the one MIS notification (`branch_cu.sv:55–74,89–114`).
  **The RS can still advance/expose younger executions.** Ordered allocation alone
  is insufficient: it is the freeze plus output gating that prevents those younger
  executions from becoming confirmed RAS updates.

| Interval | Branch CU / issue CU | Confirmation and frontend action |
| --- | --- | --- |
| t | A valid in IDLE/UPD_FE, wrong prediction | Capture A; an older previous correct operation may confirm. |
| t+1 | MIS; `issue_mis_o=1`, register enable=0 | Confirm A once if eligible call/RET; do not capture/confirm younger B. |
| t+2 | MIS_LOAD_PC; issue CU S_FLUSH | Frontend F and pc_gen recovery both active; C already includes A; P←C. |
| Following | STALL until backend flush | No later younger confirmations, even if RS/CDB made progress. |
| A's commit | Backend `ex_mis_flush`; issue resumes | BU/RS cleared; CU masks confirmation. No second mandatory EJU F. |

Issue's registered misprediction transition and F are at
`issue_cu.sv:256–272`; pc_gen ready is one at `pc_gen.sv:109`. Therefore scenario B's
specific *younger B confirms before unresolved older A* is **impossible under this
ordering/gating guarantee**. This is not a proof for a future out-of-order branch
scheduler, changed BU latency, or confirmation at CDB retirement. An earlier EQ08
exception contamination can of course persist across later branch restorations;
that is not fresh contamination caused by younger branch execution bypass.

### B4. Scenarios C/D — traps and coincident recovery

- **Synchronous delayed exceptions:** reachable as above. Already-confirmed wrong
  younger pushes/pops can persist. Exception-boundary confirmation itself is masked
  by BU's backend flush, so the problem is chiefly *prior* confirmations.
- **External interrupts:** `datapath.sv:54–56` declares IRQ pins, but these identifiers
  have no internal routing in that module; issue WFI still has an interrupt TODO
  (`issue_cu.sv:175`). This audit cannot demonstrate a functioning interrupt-entry
  path. The future recovery contract should clear both histories on interrupt
  context entry, but no interrupt reachability/result is claimed.
- **MRET:** do not infer working MRET from named commit states. Issue currently
  tags MRET as ISSUE_TYPE_EXCEPT with `opcode_except=1`
  (`issue_decoder.sv:746–752`), issue stores except_raised
  (`issue_stage.sv:327–328`), and commit decoding prioritizes that flag over MRET
  (`commit_decoder.sv:45–48,159–162`). The named COMMIT_MRET/MRET_LOAD_PC path
  (`commit_cu.sv:409–424`) therefore does not prove correct ordinary MRET execution.
  This is a separate producer-path concern, not an EJU fix; no MRET correctness
  claim or redesign was made. A corrected MRET path should explicitly choose a
  context-switch RAS policy; clearing both is a safe predictor fallback.
- **Nested traps:** a second synchronous fault can again reach exception handling;
  this does not prove architectural nested-trap save/restore correctness. RAS has
  no trap-context stack. Clear-on-each-context-change needs no nesting bookkeeping,
  but loses outer return predictions. Precise CSR/interrupt behavior is out of scope.
- **F+confirmation at one EJU edge:** normal branch scheduling confirms before F;
  exception/backend flush suppresses BU confirmation. It remains a useful
  **standalone interface-stress** case, not a fabricated normal producer transaction.
  The proposed update-C-then-restore ordering is sensible if that confirmation
  belongs to the surviving recovery boundary. An exception must instead discard
  it under the proposed clear-both policy. EJU currently cannot distinguish those
  reasons or ages. EQ07 remains I/Q.

### B5. Recovery architecture comparison

| Option | Recovery semantics / safety | Benefit and cost | Fit to active LEN5 |
| --- | --- | --- | --- |
| A: reason-specific clear | Branch: P←C under existing ordering. Exception/context change: P=C=empty; ignore coincident confirmations/speculation. | Removes contaminated state including destructive pops/overflow; constant small control cost. Loses useful caller history across traps, so later returns miss RAS until retrained. | **Recommended smallest robust fix for the demonstrated gap.** Requires a separate clear reason; cannot implement it using the existing undifferentiated F alone. |
| B: retirement-confirmed history R | Update R only from truly committed supported call/RET; keep speculative frontend P. | R cannot contain squashed operations if retirement is precise/in order for these ops. Retains pre-trap call history, but handler/context policy still needed. | Raw instruction and PC already reach commit (`issue_stage.sv:548–559`, `commit_stage.sv:286–309`), so recognition and PC+4 metadata exist. Must audit actual commit selection and event pulse, not rename C. |
| C: age-aware checkpoint/log | Preserve RAS snapshot or reversible operations with ROB age/epoch; restore the prefix surviving recovery. | Preserves useful older unretired history, supports out-of-order execution. Requires ordering, wrapped ROB identity, logs for pop/overflow-discarded values, checkpoint reclamation and capacity policy. | Disproportionate for depth4 and current ordered branch producer unless performance measurements justify it. |

A retirement-only `P←R` on ordinary branch misprediction is **not** an exact
replacement for `P←C`: surviving older and resolving call/return operations may
have executed but not retired. Options are (1) accept a colder predictor and
explicitly change the recovery contract, (2) maintain C as well and reconcile it
with retirement, or (3) replay age-tagged unretired operations on top of R. Simply
moving confirmation to commit does not preserve the approved branch-restoration
semantics. Also, LEN5's limited out-of-order commit means the exact meaning of a
retirement history must be designed, not assumed.

For checkpoints/logs, copying two depth4 histories is small; *managing which copy
is valid for which branch/ROB epoch* is the complexity. Pops require undo data;
full pushes require the discarded oldest value. A pointer checkpoint alone is
insufficient after overwriting entries. Checkpoints must distinguish the state
before a squashed instruction from state after a surviving resolving call/return.

### B6. Concrete proposal and limits

Proposed priority, pending explicit approval:

```text
async reset                       -> P=C=empty; cancel pending correction
exception/context-clear edge      -> P=C=empty; ignore C+/C- and speculative op
ordinary branch-recovery edge     -> apply eligible C update; P=updated C
otherwise                         -> independent eligible C and accepted P operations
```

The ordinary same-edge ordering remains the EQ07 proposal, even though real current
producers separate the edges. Clear priority must be unambiguous at the RAS itself,
not rely solely on a producer suppressing confirmations.

Proposed wiring changes (not implemented):

1. Preserve `be_fe_except_flush` separately from `be_fe_mis_flush` when entering
   fetch; pass an explicit reason/clear qualifier to EJU/RAS. Keep ordinary frontend
   FIFO cancellation as the existing OR. Prefer a clear signal coincident with
   exception flush, not the later trap-PC-valid signal.
2. Clear both RAS valid histories on that synchronous exception/context-clear edge;
   data bits can remain don't-care. Branch-only recovery continues copying C.
3. Cancel EJU pending correction for either reason. Preserve memory-only early flush
   as a separate event that does not clear either RAS.
4. Retain BU backend-flush confirmation suppression. Define exception dominance
   for simultaneous branch recovery, and define MRET/context entry policy explicitly.
5. Keep the current ordered confirmation guarantee. If branch scheduling changes,
   Option A alone no longer proves safe normal branch recovery; add age recovery
   or change predictor policy deliberately.

This fixes **prediction-history recovery**, not an architectural software stack.
A stale RAS target is a prediction: branch execution still calculates RET from
actual x1, compares target/direction, and recovers (`branch_unit.sv:143–172`).
Under working ordinary recovery/precise exception handling it causes wrong-path
fetch and performance loss, not an inherently uncorrectable execution result.
It can create extra speculative accesses; this standalone audit makes no security
noninterference claim. Any independent backend/flush bug would require separate
verification and cannot be excluded by EJU tests.

Required future tests after a proposed fix:

- Standalone: distinct branch-restore versus exception-clear pins, prior confirmed
  push **and pop**, known P/C divergence, overflow, clear+confirmation, clear+held
  correction, branch+exception overlap, later return witnesses, reset and ordinary
  operation regressions. Mutate “exception restores C”, “clear only P”, and “apply
  confirmation after clear”; each must be detected.
- Integration: execute the D/A/B timelines with ROB identities and retirement
  traces; prove B never retires, C update occurs before A's exception, and the new
  clear reason reaches EJU on the correct edge. Include the destructive-pop case.
- Integration: older stalled branch A plus younger ready B; observe ex_idx
  blocking and confirmation gating, not just allocation order. Stall CDB and
  frontend independently; check one confirmation per operation and no late squashed
  confirmation after resume.
- Integration: held early correction with multiple memory grants; cancellation of
  every old request, exactly one accepted instruction/RAS action, feedback consumed
  only by surviving lanes. Exercise delayed trap target load and refills.
- Trap producer work: test real interrupt/MRET/nested-trap paths only once their
  producer semantics are implemented/verified. Do not substitute trap-shaped EJU
  input values for those tests.

## C. Verification implementation audit

### C1. Inspected implementation and independence

Reviewed all EJU `.cpp/.hh`, wrapper/core/waiver, configuration parser/auditor,
validators, regression, mutation and suite scripts, build helper and Make targets.
Relevant pc_gen model/Field helpers, driver phases, confidence check, README/spec,
coverage/regression patterns and shared `tb_macros` supply the reused foundation.
No pc_gen behavior was changed. Key findings by component:

| Component / functions | Audit result |
| --- | --- |
| `early_jump_instructions.cpp`: `decode`, `jal`, `jalr`, `branch`, `ordinary`, `outcome` | Raw opcode/architectural immediate assembly, exact canonical RET; no RTL union or DUT dependency. Modular uint64 arithmetic avoids signed overflow. Fixed words supplement round trips; added sign extrema/upper-immediate fixtures. |
| `early_jump_model.cpp`: `select`, `outputs`, `plan`, `History::apply/top` | Owns independent P/C sequences with origin IDs and dependencies. No Verilator object/Outputs input, physical pointer, array read or observed-state repair. Uses supplied prediction PCs and independently decoded immediates. |
| `early_jump_environment.cpp`: `request`, `validate`, `consume`, `pending` | Saved request metadata, interval mask, maturity, ordered confirmation, cancellation and once-only acceptance. `consume` takes the *model's planned* retained lanes, not DUT mask. This shared semantic selection is intentional but means an oracle-selection bug needs independent tests/mutations to catch it. |
| `early_jump_driver.cpp`: `drive/read_inputs/read_outputs`, `step`, `probe` | Public ports/static constants only. Deterministic setup with clock low, planned state before rising edge, separate pre/post/falling snapshots. Feedback derives from independent selection, never actual base/offset. No delta-cycle output-to-oracle loop. |
| `early_jump_scoreboard.cpp`: `sample`, `compare`, `mismatch`, `finish` | Exact all-known output comparisons including every retained lane's four prediction fields. Unknown and don't-care counts separated. Supplemental target-sum/confidence checks do not replace exact comparisons. Zero checks/incomplete suites cannot pass. |
| `early_jump_random.cpp`: `generated`, `architectural`, `stress`, `run` | Three seeded streams; whole encoded bundles; masks computed from first eligible PT; stable held responses; ordered confirmation and later recovery. Guidance reads coverage deficits, not actual targets for golden values. |
| `configuration.py`, `early_jump_configuration.cpp`, adapter/core/helper | Source fingerprint + snapshots + elaborated constants; only real EJU/RAS/prio_enc compiled. Static source audit is separate from behavioral expectation. Public trace depth1; no dynamic internal oracle observation. |
| `validate.py`, `validate_random.py`, `*_unit.cpp` | Real expected-negative statuses, journal/FST replay, synthetic confidence, independent width fixtures, coverage reconstruction. Recovery-label typo found and fixed. |
| `regress.py`, `suite.py`, `suite_unit.py`, `mutate.py` | Isolated processes/artifacts and exit propagation; actual mutation compile and run required. Reporting limitations below; mutation metadata must be read with audit summary. |

The abstract model is behaviorally independent of DUT observation, though some I
rules intentionally match the proposed current interface policy. Independence does
not make those policies architecturally approved. Most exact temporal RAS errors
retain reset/acceptance/boundary assumptions and are classified provisional.

The scoreboard's D no-effect witness stores an independently **expected** top after
it matched a public return observation. A mismatch clears diagnostic confidence;
exact known values continue to be checked. A later matching independent witness
can establish confidence in the visible top, not silently synchronize the stack.
`JAL_architectural_target_sum` becomes provisional when the selected base/early
context is unverified, preserving the pc_gen confidence lesson. Three synthetic
fixtures exercise prior mismatch, matched context and unrelated exact arithmetic
with unknown P.

### C2. Instruction, lane and temporal coverage

The ordinary generator emits ADD/word operations, immediate arithmetic, loads,
stores, LUI/AUIPC, FENCE, mscratch CSR operations, M operations and FADD.S/D. It
randomizes registers and operands, including x1/x5 fields. It is **not a complete
ISA legality/execution decoder**: FP enable/privilege, CSR side effects, memory
faults and all FP/system opcodes are not modeled. Architectural labels describe
local coherent port histories, not proof every complete program is executable.
Raw unsupported words and near misses remain characterization. x5 exclusion is D.

T08 checks hit/taken 00/01/10/11 with correct/wrong targets at every lane. T09/T10
check PN/PT before later jumps and multiple raw predictions; T11/T12 check oldest
JAL/CALL/RET competition; T05 skips prefix lanes; T13 checks retained metadata.
Random generation produces those combinations and the scoreboard checks relevant
fields. Inactive lane output payloads are intentionally unqualified; their effect
on selected masks/targets and subsequent RAS history is checked where known.

T15/T19/T25/T27 drain distinguishable links and separately witness C through F.
T21/T22 verify stalled P with concurrent C changes; T07 places 4096 ordinary
bundles between witnesses; T31 excludes broader hints. A return samples old top
before the pop and recomputes post-edge expectations. Confirmed updates are
independent of frontend ready. Mutations demonstrate delayed state corruption is
observable, not merely counted as attempted input traffic.

### C3. Concrete fixes and retained gaps

1. **Fixed conservative EQ08 knowledge leak.** Before this audit,
   `exception=unknown` cleared P knowledge but preserved known C. A later ordinary
   F copied that C into P as known, despite exception-surviving C being the very
   unresolved question. The new pure assertion failed on the old model
   (`review-dy6i2s5z/model-before.log`, exit1). Both histories now become unknown on
   that unresolved exception transition. A later F cannot repair them. Independent
   JAL arithmetic stays known; reset or a justified known suffix can establish
   knowledge without DUT input. `len5_minimal` transition behavior is unchanged.
   This is uncertainty preservation, not weakening a definitive stack requirement.
2. **Fixed unknown-occupancy boundary leak.** With `boundaries=unknown`, a push
   after loss of history certainty previously supplied a known top even though
   the unknown old occupancy could already be full. An unspecified overflow policy
   might retain the old top rather than the new entry. The new pure assertion
   failed before the fix (`review-dy6i2s5z/boundary-before.log`, exit1). Such a push
   now preserves uncertainty, including through a later restoration. Under the
   explicit `recent` policy, a known suffix can still establish knowledge. This
   changes only conservative unknown-boundary expectations, not known in-capacity
   pushes, default history semantics or independent JAL checks.
3. **Fixed dead random validation assertion.** It tested reason `mispredict`, but
   the generator emits `misprediction`. It now checks the correct reason, counts
   sampled architectural recoveries and requires a positive count. The focused
   validation observed 33 recoveries and 47 confirmations. Causal verification
   still lives in `Environment::validate`; this independent assertion supplements it.
4. **Updated approved EQ04 provenance.** Selection's taken-JAL suppression is D,
   contract/spec reports mark EQ04 partially resolved, and pure policy checks test
   wrong as well as correct target. External lifecycle/selection remains I. No
   transition was changed to match a DUT result; T08 already exercised the policy.
5. **Temporal coverage is less complete than the original plan.** There is no
   outstanding obligation ledger mapping each accepted push/pop/confirm/restore to
   a later distinguishing return or explicit cancellation. EV13 counts witnesses;
   `restored_` remains true until reset/another flush, so a distant later return can
   count even after intervening operations. Full feature coverage is not proof every
   recovered entry was observed. Directed drains provide stronger bounded evidence.
   Future coverage work should tag obligations by epoch/origin and report pending,
   fulfilled and canceled counts; no such completeness claim is made here.
6. **Regression summary omissions:** `regress.py` creates reset maps without filling
   them, and reads `report['assumptions']` although native key is `assumption_checks`.
   Native EV15 and assumption maps are intact; use them plus explicit contract
   metadata. These summary fields cannot support reset-coverage/assumption claims.
   `REQUIRE_MATRIX` enforces only the offered-op/confirmation/F matrix, not all
   feature goals or temporal obligations. These reporting gaps were documented,
   not expanded into a broader refactor in this audit.
7. **Causal environment limits:** confirmations validate earlier unresolved control
   order, duplicates, faults, IDs and maturity. Recovery validates source/outcome,
   but does not independently enforce older-unresolved ordering or a recovered-once
   flag; the actual generator's oldest `pending()`/one pending recovery enforces
   that subset. A future independent environment-negative fixture should cover raw
   younger/duplicate recovery requests before broadening that scheduler. Legacy
   directed RET records may use feedback as fallback execution context when no
   context is supplied; randomized control records set `execution_known` and use
   independently calculated operands/outcomes. No fallback reads DUT outputs.
8. **Architectural campaign scope:** fetch PCs are independent aligned inputs, not
   a simulated pc_gen trace; no ROB, retirement, older nonbranch exception or real
   memory cancellation is modeled. Random exception F occurs in stress/characterization,
   not as a causally proven precise-exception architectural episode. Random reset
   and 256-cycle campaign boundaries often truncate long histories; T07/T15/T25
   cover specific longer witnesses. These limits explain why millions of passing
   cycles did not close EQ08.
9. **Coverage strengths and limits:** counters use read-back pre-edge inputs;
   matched outcomes are gated on comparisons. Expected depth bins are model state,
   not observed DUT occupancy. Mask crosses count raw inactive records too, while
   matched selected-lane bins are separate. Journal reconstruction checks many
   counters but derives class/selection labels from the journal's model annotations,
   not a second independent decoder; decoder units/mutations supply independent
   checks. Trace replay compares full journals, not just aggregate hashes.

No checker or generator was rewritten; no failing definitive comparison was
suppressed. Follow-up coverage/environment improvements above are explicit gaps,
not evidence that the sampled passing comparisons were fake.

### C4. Mutation evidence

Inspected the actual mutation definitions, build/run statuses, first discrepancies
and original-before/after digests in the existing artifact summaries. All fourteen
compiled and were detected; no survivor is hidden as a build failure. N=1's reverse
lane priority mutation is explicitly excluded as equivalent, not credited as killed.
No alternate configuration was executed by this audit.

| Existing mutant / scenario | What the evidence establishes |
| --- | --- |
| missed-jal / T03; false-positive-call / T07 | Detection/qualification differences found; provisional interface context retained. |
| wrong-immediate-sign / T04 | 105 confirmed EJ03 arithmetic comparisons plus operand discrepancies. |
| wrong-lane-selection / T11; wrong-jal-base / T03 | Exact lane/base checks fail; unverified context does not invent definitive priority diagnosis. |
| predicted-call-not-pushed / T14; push-while-stalled / T21 | Later return/hold witnesses expose wrong predictive history. |
| wrong-confirmed-link / T16; missing-restoration / T19 | Hidden confirmed/recovery error exposed by later return. |
| old-confirmation-restoration / T20 | 96 provisional discrepancies, not approval of EQ07 ordering. |
| wrong-return-target / T15; wrong-metadata-target / T13 | Target/retained sideband comparisons active. |
| silent-ordinary-push / T07; forbidden-x5-push / T03 | 1 and 2 confirmed EJ08/D no-effect violations, respectively, plus provisional exact checks. |

Monitor injections named predictive/confirmed/restore/return all corrupt the
observed return offset; they validate scoreboard failure paths, not four different
physical state faults. Disposable RTL mutations provide the distinct state-fault
evidence. Mutation run manifests intentionally retain original configuration/source
snapshots while the mutation summary records changed disposable source; therefore
interpret mutant reports together with their mutation summary, not as ordinary
production-binary provenance.

Coverage of mutation *types* is bounded: no exception-clear architecture exists
here to mutate, and the current suite is not exhaustive for reset validity,
full/empty corner faults, confirmation-on-ready gating or every masked-lane defect.
This review changed no default transition or scoreboard comparison rule; only
conservative exception/boundary uncertainty, policy provenance, fixtures and validation.
Existing mutations were inspected, not needlessly rebuilt. A recovery RTL redesign
requires fresh targeted mutations and full regressions.

## D. Validation and evidence

The currently selected N=4, depth4 build was compiled automatically from
`rtl/packages/len5_config_pkg.sv`, verified against elaborated wrapper constants.
The resolved prior configuration discrepancy was not investigated. Historical
three-million-cycle artifacts remain labeled with their own configuration; their
counts are not presented as new runs or as a configuration sweep.

Commands executed for this audit (logs preserved):

```sh
source /home/markospremic/miniconda3/etc/profile.d/conda.sh
source private/init.sh
make check-early-jump-framework LOG_LEVEL=LOG_LOW
make check-early-jump-random-framework LOG_LEVEL=LOG_LOW
```

Before each model fix, the newly added pure test was also compiled with
`/usr/bin/g++ -std=c++17 -O2 -Wall -Wextra -Werror` using instructions/model/environment,
unit and unchanged pc_gen helper sources. The checks failed on EQ08 C knowledge
and on unknown-occupancy push knowledge as expected; both binaries and logs remain
in `build/early-jump/review-dy6i2s5z/`.

| New validation | Result |
| --- | --- |
| Pure encoder/model/environment | 16,931 checks pass; includes independent fixed words, approved EQ04 target independence and EQ08/EQ09 unknown-history regressions. |
| Directed len5_minimal | EJ-T01–34, 5526 cycles, 16,624 checked records, 198,106 field comparisons, zero mismatches. |
| Directed established | EJ-T01–34, 195,570 field comparisons, zero mismatches; unresolved state remains explicit. |
| Native framework | 21 cases pass, three build/replay guards pass; exact journal replay with FST and LEN5 logger checks pass. Deliberate exits 1/2/3 verified. |
| Alternative EQ07 previous | 102 provisional, zero confirmed discrepancies, native exit1; expected-negative validator passes. |
| Random framework | 15 cases pass; 11 normal runs ×4096 cycles =45,056 cycles and 852,478 comparisons, zero normal mismatches. Includes seeds17,18,max uint64, profiles, campaigns, guided/unguided/weights and replay variants; these are not 11 distinct seeds. |
| Random confidence/reconstruction | Three synthetic checks and four pure width fixtures pass; 1097 bins reconstructed, 47 architectural confirmations and 33 recoveries checked. |
| Injected random failure | Two 4096-cycle failure/replay runs each exit1 with one injected mismatch; first discrepancy and replay histories match. These are excluded from normal zero-error totals. |
| Random incomplete-coverage case | One-cycle regression returns incomplete/nonzero with zero DUT mismatches, as intended. |

The conservative comparison count decreased because uncertain boundary outcomes
are no longer labeled known; default-profile checks remain unchanged. Unknown
state cannot suppress independently known JAL arithmetic or input qualification.

New evidence:

- `build/early-jump/review-dy6i2s5z/`: initial protected-source hash baseline,
  both before-fix failing pure units, final command logs and `summary.json`.
- `build/early-jump/validation/framework-i5stodhv/summary.json`: directed/framework,
  per-case logs/reports, FST and alternative-hypothesis evidence.
- `build/early-jump/validation/random-cd3_9qnt/summary.json`: random/confidence,
  full journal reconstruction, FST and deterministic failure replay.
- New random replay journal SHA256:
  `224efec638454184d24cd68a02a175fb16c47ca00cbe5664441136ef1f6316d0`.

Focused seed17/all/4096 coverage is deliberately **not claimed complete**:
architectural 11/12 matrix rows and 140/203 features; stress 18/18 and 217/240;
characterization 18/18 and 218/240. Established profile has additional unknowns and
11/12 architectural rows with 142/203 features in its corresponding short run;
established stress and characterization have 201/240 and 208/240 features, respectively.
Full individual gaps are in each native coverage JSON. No short smoke result replaced the historical full
regression's evidence or silently waived a required full-campaign gate.

Historical evidence independently read, not rerun:

- Guided: `suite/all-mn_7z_sf/regression/all-len5_minimal-szv3fajo/summary.json`.
- Established: `regression/all-established-v75pdp1i/summary.json`.
- Unguided: `regression/all-len5_minimal-12b6j04c/summary.json`.
- Twelve mutations: `suite/all-mn_7z_sf/mutations/audit-uap3llrq/summary.json`;
  two policy mutations: `mutation/audit-l0jgo8lo/summary.json`.

All paths in that list are beneath `build/early-jump/`. The three historical
100×10000 runs total 3,000,000 cycles, 52,286,987 comparisons and zero baseline
mismatches, with their declared 12/18/18 rows and feature goals complete. Fourteen
mutations compiled/detected, none survived, originals before/after identical.
These are meaningful bounded checks under named contracts, not EQ08 sign-off.

No full regression or mutation rebuild was necessary for this focused audit.
Re-run full selected-configuration regressions, replay/confidence tests and
recovery-specific mutations after any future reason-specific RTL recovery change
or substantive generator/scoreboard change. Preserve the present EQ07 alternative
evidence and remaining EQ questions in that work.

Files changed by this audit: this report, `VERIFICATION.md`, `README.md`,
`early_jump_model.cpp`, `early_jump_unit.cpp`, `early_jump_directed.cpp`, and
`validate_random.py`. Preexisting EJU implementation/Make/helper changes were
preserved. Production RTL, production configuration and pc_gen verification files
were not modified; all 282 protected files match the audit's own initial SHA256
baseline, checked separately
from historical implementation baselines. No full frontend/processor correctness
claim follows from these results.

## E. Full-core execution follow-up

This section supersedes the earlier **not yet dynamically reproduced** limitation.
It does not promote the proposed recovery design to an approved D requirement.
The current live configuration remains N=4. The user explicitly requested both
N=2 and N=4; each was compiled in a disposable source copy with only that copy's
`LEN5_MULTIPLE_ISSUES` literal selected. Actual trace constants and standalone
source/elaboration guards verify each width. No production configuration was edited.

### E1. Experimental boundary and result

**EQ08 is reproduced, for both a squashed confirmed call and a squashed confirmed
return, in both configurations.** These are actual instruction executions through
fetch, issue, execution units, ROB and commit, with the real EJU and RAS. No
branch-confirmation, exception, flush, register or RAS signal was forced.

New `recovery/recovery_tb.sv` instantiates the existing `tb_bare`, hence production
`datapath` plus the existing memory emulator. A read-only hierarchical monitor
captures instruction-stage PCs, branch execution and confirmation, commit/exception
signals, every ROB slot's PC/validity, EJU acceptance and P/C validity/data.
This is diagnostic integration instrumentation, **not** a modification of the
standalone black-box oracle. `recovery_tb.cpp` reuses the LEN5 logger and native
clock pattern. Three small assembly programs and `exercise.py` independently check
necessary witness conditions against program symbols and the observed trace.

The analysis requires a real code-4 load exception at the older PC, an earlier
younger confirmation, the younger instruction still present in ROB at exception
flush, its removal on the next edge, and no earlier ROB pop of that instruction.
It also verifies the older call's architectural link write. Therefore neither
an arbitrary standalone F nor an already-retired younger operation can satisfy
the witness. Raw invalid RAS storage is never interpreted as a live history.

Each firmware runs 300 clock cycles including ten reset cycles. The final six
cases total **1,800 captured full-core cycles**; earlier bring-up/replay captures
are separate. The standalone comparisons below are separate metrics.

### E2. Confirmed-push witness: cycle-by-cycle evidence

The minimal tested call episode, after mtvec setup and an older call, is:

```text
100c: jal  x1,1040           # older call; surviving link = 1010
1040: addi x11,x0,1
1044: slli x11,x11,63
1048: addi x11,x11,1
104c: addi x12,x0,1
1050: divu x10,x11,x12       # long dependency, value 8000000000000001
1054: ld   x1,0(x10)         # older fault, doubleword misalignment
1058: jal  x1,1180           # younger call, link = 105c
1180: wfi                   # parks younger issue; not the exception source
1200: ret                   # mtvec handler probe, not MRET
1010: jal  x0,1010           # actual return destination
```

`mtvec=0x1200` is written by real CSR instructions before the episode. There is
no artificial delay between DIVU/LD/JAL and no testbench-stalled execution unit.
NOP-filled layout gaps keep speculative instruction reads well formed.

Cycle numbers below are **pre-edge samples**. Registered effects become visible
in the next row. N=2/N=4 have the same call/fault timeline through cycle107.
All addresses below are hexadecimal; C/P lists are oldest to newest.

| Cycle | Observed stage / signals | Observed RAS/ROB implication |
| ---: | --- | --- |
| 13 (N=4) | Older call accepted by EJU, predictive push | P becomes `[1010]`. |
| 17 (N=4) | Younger call at1058 accepted, predictive push | P becomes `[1010,105c]` before either call retires. |
| 24 | BU executes older call100c | Real call execution. |
| 25 →26 | `call_confirm=1`, resolved PC100c, link1010 | C becomes `[1010]`. |
| 26 /27 | Older call pops ROB / asserts integer register-file commit enable | The first C entry belongs to an older committed call. |
| 28 /29 /30 | DIVU1050 / LD1054 / JAL1058 issue | Real program order, distinct ROB entries. |
| 31 | BU valid at1058, target1180, misprediction=0 | Younger JAL executes correctly before the load completes. |
| 32 →33 | `call_confirm=1`, PC1058, link105c; ROB head1050 not ready | C becomes `[1010,105c]`; younger call is **not retired**. |
| 100 | ROB presents1054 with ready result and exception | Faulting load moves to commit. |
| 101 | Commit PC1054, exception=1, code4; exception/frontend and backend flush=1; C+/C-=0 | Younger1058 is still valid in ROB. C/P both `[1010,105c]`. |
| 102 | Younger1058 is absent from all valid ROB slots | Squash occurred, but C and P remain `[1010,105c]`. |
| 107 | Accepted handler RET1200; EJU early target105c | The squashed call's link is actually used for prediction. |
| 112 (N=2) /116 (N=4) | BU executes RET1200, actual target1010, misprediction=1 | Actual x1 target disagrees with stale RAS prediction. |
| 113 /117 | RET confirmation pulse | C pops the stale top. |
| 114 /118 | Normal frontend branch flush, corrected target1010 | Confirmation preceded restoration by one edge. |

This satisfies all four requested EQ08 steps and exposes an observable prediction
consequence. It is a **demonstrated predictor-recovery-history defect**, not merely
a model mismatch. It is not evidence that RAS state is architectural register state
or that this stale target alone causes an uncorrectable instruction result.

### E3. Confirmed-pop witness and empty-RAS control

`exception_return.S` uses the same older committed call but writes x1=1180 before
the divide. Its DIVU/LD/RET PCs are1058/105c/1060; the older LD writes x6 rather
than x1. The canonical RET's actual target1180 differs from RAS link1010, so its
misprediction also prevents early out-of-order ROB retirement.

| Cycle, both widths | Actual event | Consequence |
| ---: | --- | --- |
| 27 | Older call's architectural link write | C contains legitimate link1010. |
| 33 | BU executes RET1060, actual1180, wrong predicted target | Qualified return execution, not a target-alignment fault. |
| 34 →35 | `ret_confirm=1` then C becomes empty | Surviving old link1010 has been removed by younger B. |
| 35 | Ordinary branch flush, no simultaneous confirmation | P restores already-updated empty C. |
| 102 →103 | Older LD105c commits exception4, flush squashes resident RET1060 | Both histories remain empty: the squashed pop is not undone. |

The analyzer checks that RET1060 never previously popped from ROB. This proves
why merely deleting newly pushed addresses would not repair EQ08: a pop loses
older data, and overflow can likewise discard older history.

`empty_return.S` is a separate control, with **no prior call**. A real canonical
RET1008 is accepted with empty P and `early_jump_valid=0` (cycle14 for N=2,
cycle13 for N=4). BU resolves target1100 at20, restoration is empty at22, target1100
issues at28 and its ADDI commits at32. Neither call confirmation nor exception
flush occurs. Thus physically invalid/empty RAS correctly disables its early
return prediction and the normal branch mechanism works in this control.
This does not treat a C++ model's **unknown** history as a hardware empty flag.

### E4. Exception clearing: effect, trade-offs and recommendation

The clearing proposal would remove stale105c in E2, and avoid claiming that the
empty C in E3 is an exact surviving call history. It also deliberately removes
**legitimate committed1010** in E2. It is conservative predictor invalidation,
not exact rollback. This performance cost is real: useful nesting history is
lost across trap entry, and later returns may use BTB prediction or await execution.

Only validity needs clearing; invalid address bits remain don't-care. EJU gates
RET correction with RAS validity (`early_jump_unit.sv:144–151`); the full-core
empty-return control demonstrates the fallback. BU computes RET from x1+immediate
and checks direction/target independently (`branch_unit.sv:142–172`). E2 also
shows correction of an actual stale prediction. Therefore loss of valid predictor
entries **should affect prediction performance, not ISA correctness**, conditional
on correct general branch/exception recovery. It does not justify claiming that
all recovery machinery is correct; see the separate E5 observation.

The current single F has insufficient information to choose exception clearing
versus normal restoration. Exception clear must dominate simultaneous speculative
operations and confirmation. Clear **both** P and C: clearing only P allows a later
branch flush to resurrect polluted C. Preserve normal P←C because current ordered
BU confirmation includes surviving unretired operations. The full-core RET traces
show the confirmation-before-restoration schedule.

Alternatives remain:

- **Clear on every recovery:** simplest interface, safe cold predictor if defined
  deliberately, but unnecessarily loses normal-branch history and changes the
  established P←C requirement. Prefer distinguishing recovery reason.
- **Retirement-aware history:** preserves older committed entries. Use an actual
  precise, ordered RAS retirement stream; do not equate BU confirmation or every
  limited out-of-order ROB pop with such a stream. Normal branch recovery still
  needs surviving unretired operations, or an explicitly colder recovery policy.
- **Checkpoint/operation log:** exact surviving prefix requires ROB age/epoch and
  retention/undo of popped or overflow-discarded entries. Branch checkpoints alone
  do not automatically identify the state preceding an arbitrary older nonbranch
  exception. Snapshot validity/reclamation and finite-capacity behavior add control
  complexity much greater than the four-entry storage itself.

Recommendation remains **reason-specific clear-both for exception/context recovery,
P←C for ordinary branch recovery**, pending approval and a separate RTL task.
Propagate existing `be_fe_except_flush` separately through fetch/EJU to RAS, cancel
pending corrections, retain backend confirmation suppression, and define context
entry/MRET policy. No such wiring or RTL change was made here. Interrupts, MRET and
nested-trap semantics remain outside these three programs.

### E5. Separate recovery-window observation

The call trace exposes additional behavior that must not be hidden by the EQ08
success: after exception flush101 and before/around the trap RET reaching execution,
NOPs from other fetch PCs enter issue and assert commit register-file enable.
For N=4, PCs1220–123c appear at commit cycles111–118; for N=2, PCs11f0–11fc appear
at111–114. The trace distinguishes qualified enables from stale inactive PC buses.

These NOPs came from the instruction stream buffered/fetched around exception
entry, not an intended sequential path before the handler's first RET1200. Source
logic explains a recovery window: COMMIT_EXCEPT flushes at101, while
EXCEPT_LOAD_PC redirects/resumes later (`commit_cu.sv:429–465`); pc_gen has no
exception-flush input and suppresses ordinary fetch only while redirect-valid is
asserted (`pc_gen.sv:82–110`). A flush alone does not hold all new requests until
trap redirection. Initial zero-filled firmware gaps caused secondary illegal
instruction traps; final fixtures use explicit NOP padding and retain both traces.

This is a **separate observed recovery-window concern** requiring a dedicated
request-epoch/commit-stream investigation. The final programs do not demonstrate
a harmful wrong-path register write (NOP destination is x0), and no full ISA
checker ran. Do not attribute it to RAS, claim that clearing RAS fixes it, or use
successful RET target resolution as proof of full precise-exception correctness.

### E6. EQ07: meaning of the 102 discrepancies

The focused T20 `order=previous` run still produces **102 provisional field
comparisons**, zero confirmed mismatches, at both widths. It does not represent
102 independent architectural failures. Exact breakdown:

| Compared field | Differences |
| --- | ---: |
| Return offset | 6 |
| Early valid | 22 |
| Memory flush | 20 |
| Retained lane0 hit / taken / target | 18 each |

The first discrepancy is cycle72: the alternative expects808, RTL returns908.
Cycle70 confirmed808; cycle71 offers F and a new confirmed push908. The alternative
copies **old** C into P; RTL copies **updated** C. Subsequent returns expose the
different depth/top, leading to repeated pre/post-edge and qualification/metadata
comparisons. The current source explicitly says to include confirmations in the
recovery cycle (`ras.sv:63–69,88–117`). This is evidence of implementation intent,
not independent approval of all simultaneous-request lifecycle semantics.

The new full-core traces provide a different, integrated timing result: confirmed
RET at34, frontend recovery at35; the handler RET similarly confirms one cycle
before its recovery. Exception flush suppresses confirmation at101/102. No F+C
coincidence occurs in any of the six final traces. This agrees with the source
ordering argument in B3 and `branch_cu.sv:89–121`; both old-C/new-C hypotheses agree
when no update is present at the restore edge.

**Conclusion:** these 102 differences demonstrate that the alternative model's
same-edge assumption disagrees with intentionally implemented update-first RTL.
They do not establish an EQ07 architectural defect under the actual observed
producer schedule. Keep the alternative as provisional interface characterization;
retain I/Q for a future genuinely coincident surviving confirmation and recovery.
No default behavior, evidence category or golden transition was changed.

### E7. Selected-width verification and mutation results

The standalone oracle, generator and scoreboard behavior were not modified in this
follow-up. Both width configurations use the previous audit's uncertainty fixes.
The only existing verification implementation change is dependency export in
`mutate.py`; the new full-core capture/analysis is separate under `recovery/`.

| Focused validation | N=2 disposable configuration | N=4 |
| --- | ---: | ---: |
| Independent encoder/model/environment assertions | 16,931 pass | 16,931 pass |
| Directed scenarios | all34 pass | all34 pass |
| `len5_minimal` field comparisons / mismatches | 139,377 /0 | 198,106 /0 |
| `established` field comparisons / mismatches | 136,961 /0 | 195,570 /0 |
| Framework cases + configuration guards | 21 +3 pass | 21 +3 pass |
| Random validation cases / confidence fixtures | 15 /3 pass | 15 /3 pass |
| Normal random cycles / comparisons / mismatches | 45,056 /787,974 /0 | 45,056 /852,478 /0 |
| Reconstructed sampled coverage bins | 511 | 1097 |
| Architectural confirmations / recoveries checked | 41 /33 | 47 /33 |
| Alternative EQ07 `previous` | 102 provisional, 0 confirmed | 102 provisional, 0 confirmed |
| Real compiled RTL mutations detected | 14 /14; none survived | 14 /14; none survived |

Normal random counts are eleven 4096-cycle configurations per width, including
replays, campaigns, weights, profiles and seeds17,18,max-uint64—not eleven unique
seeds. Injected failures are separate and return nonzero with matching replay
history/first discrepancy. The two widths total **90,112 normal random cycles and
1,640,452 comparisons**, not a new million-cycle campaign. No full regression
was necessary because the standalone checker/generator semantics did not change.

Short-run default seed17/all coverage is intentionally incomplete:

| Width / campaign | Required matrix rows | Feature goals |
| --- | ---: | ---: |
| N=2 architectural | 10/12 | 86/112 |
| N=2 interface stress | 18/18 | 116/131 |
| N=2 characterization | 18/18 | 119/131 |
| N=4 architectural | 11/12 | 140/203 |
| N=4 interface stress | 18/18 | 217/240 |
| N=4 characterization | 18/18 | 218/240 |

Required matrix closure is not claimed for these short checks. The earlier full
regression remains historical evidence, and the temporal coverage gaps in C3 remain.

All fourteen mutation types listed in C4 were re-executed at both widths, **28
successful build/run detections**. Originals pass before/after with identical
counts/digests. N=4 took169s and N=2 took117s while other builds ran. Detection
classifications remain important: old-confirmation-restoration is provisional;
missed-target arithmetic and approved no-effect violations retain their respective
confirmed checks. No compile failure is counted as a killed mutant.

Two infrastructure bring-up problems were exposed and corrected, with logs retained:

1. Private source libraries under `build/` were initially discoverable by the
   repository FuseSoC scan. The audit output now contains `FUSESOC_IGNORE`; direct
   builds from each private source root still work. An initial width-literal rewrite
   retained the old literal suffix and produced a width warning; the runner now
   replaces the entire RHS with `32'dN`. The initial failed mutation attempt
   `mutation/audit-sh2deo_i` is **not credited** as mutation detection.
2. At the deeper N=2 mutation build path, Verilator's relative source/include search
   found another checkout's N=4 package. The source/elaboration guard rejected the
   binary before comparisons (`.../mutation/audit-qe9h5q_8/missed-jal/console.log`),
   rather than silently passing a wrong-width run. `mutate.py` now uses FuseSoC's
   dependency export instead of `--no-export`, keeping the build's sources local.
   All14 N=2 mutations then compiled, passed the static guard and were detected.
   The full-core runner also uses dependency export. This is a distinct demonstrated
   build-path alias, not a reopening of the user's earlier configuration selection.

The initial full-core build also hit a host ccache write restriction; the new core
uses the existing standalone convention `OBJCACHE=` and `/usr/bin/g++`. No tool
installation, permission change or production source edit was needed.

### E8. Reproduction commands, artifacts and remaining limits

```sh
source private/init.sh
python3 tb/frontend/early_jump_unit/recovery/run.py --width 2
python3 tb/frontend/early_jump_unit/recovery/run.py --width 4

# Live source-selected N=4 standalone checks used in this audit:
make check-early-jump-framework LOG_LEVEL=LOG_LOW
make check-early-jump-random-framework LOG_LEVEL=LOG_LOW
make check-early-jump-mutations JOBS=2 LOG_LEVEL=LOG_LOW

# Same standalone checks were run inside the disposable N=2 source root:
make -C <N2_SOURCE> check-early-jump-framework check-early-jump-random-framework LOG_LEVEL=LOG_LOW
make -C <N2_SOURCE> check-early-jump-mutations JOBS=2 LOG_LEVEL=LOG_LOW
```

See `recovery/README.md` for simulator/analysis status interpretation: a successful
reproducer reports **reproduced**, not “RTL correct.” Full-core internal traces
are diagnostic evidence; no internal value enters the standalone golden model.
Each final capture has CSV at every cycle and FST, exact assembly/ELF/disassembly,
program symbols, width checks, ROB squash checks and explicit verdicts. Reusing a
binary creates a new experiment directory instead of overwriting earlier evidence.

Standalone evidence beneath `build/early-jump/`:

- N=4 framework: `validation/framework-lrj1hl6b/summary.json`.
- N=4 random: `validation/random-uao5qncn/summary.json`.
- N=4 mutations: `mutation/audit-2e6bwidl/summary.json`.
- N=2 source root: `recovery/n2-5zvgqujy/source/`; within its `build/early-jump/`:
  `validation/framework-7d4vcrhs/summary.json`,
  `validation/random-hci2v8pq/summary.json`, and
  `mutation/audit-z5dmanmw/summary.json`.

The recovery artifact index `build/early-jump/recovery/summary.json` names the
final full-core experiments, exact result files and protected-source hash checks.
Final captures completed on 2026-10-15:

- N=2: `build/early-jump/recovery/n2-vxo584tj/experiments/cases-vdvm191m/`.
- N=4: `build/early-jump/recovery/n4-zlyagelb/experiments/cases-hxfcbpi5/`.

The six full-core cases total 1,800 cycles and 66 successful evidence checks.
Successful evidence checks establish reproduction of the call/pop defect and
operation of the empty-RAS control; they do not indicate that EQ08 passes.
Earlier zero-padding/longer-program experiments and failed builds remain available
but are not conflated with the final minimal-program evidence.

Remaining limits: no ISA-wide differential checker, real interrupt entry, MRET,
nested traps, exception-clear implementation, recovery-epoch repair, or hardware
performance comparison was tested. EQ07's simultaneous interface contract remains
I/Q despite actual separated-edge evidence. The E5 fetch/recovery window requires
separate integration investigation; a RAS clear alone cannot address it. The
proposal should receive approval before any RTL task, then get fresh full-core
call/pop/empty controls, recovery-window tests and targeted mutation coverage.

Changes in this follow-up: `ARCHITECTURE_AUDIT.md`, documentation links in README
and VERIFICATION, the isolated `recovery/` harness/programs/scripts/README, and
EJU `mutate.py` dependency export. Existing pc_gen and standalone EJU behavior were
preserved. Production RTL and its configuration were not modified.
