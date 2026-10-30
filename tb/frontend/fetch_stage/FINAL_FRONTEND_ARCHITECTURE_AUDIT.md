# Final frontend architecture audit

Historical audit: current R03/R05/R06/R07/R09/R10/R11 dispositions and model
contracts are updated in the [2026-10-28 verification report](../MODEL_UPDATE_2026-10-28.md).
Keep the dated observations below as historical evidence; they are not a new
validation of the current sources. R01/R02 and remaining proof limits persist.

2026-10-16. This review distinguishes verification of the approved implementation
from evaluation of a different predictor architecture. Production RTL and source
configuration remain unchanged. Source-selected **N=4**, HLEN=4, BTB_BITS=4,
XLEN=64; the integrated PHT initialization is WT=2. All dynamic DUT observations
are production `fetch_stage` public ports. History, indexes, counter values, RAS
contents and resource occupancies below are **independent model quantities**, not
private RTL observations.

## A. Gshare architecture and source evidence

### A1. Established algorithm

| Evidence | Active source and locations | Finding |
|---|---|---|
| D current implementation target; source confirmation | [gshare.sv](../../../rtl/frontend/gshare.sv):43–56,64–114 | GHR changes only on qualified resolution, reset or predictor flush. No speculative fetch/history update. Both lookup and write use current GHR. |
| D algorithm; I sampling | [bpu.sv](../../../rtl/frontend/bpu.sv):39–82 | `curr_hist_i` is a PC prefix, despite its name. `res_hist_i` is resolution PC bits, not a saved history. Update index is **pre-edge** H XOR resolution word-PC index. |
| D actual metadata format | [fetch_pkg.sv](../../../rtl/packages/fetch_pkg.sv):49–71 | Prediction has PC/hit/target/taken only; resolution has PC/mispredict/taken/target only. Neither carries a lookup history/index. |
| I actual producer scheduling | [branch_rs.sv](../../../rtl/expipe/exec-units/branch_rs.sv):125–141,280–305; [branch_unit.sv](../../../rtl/expipe/exec-units/branch_unit.sv):109–172,184–211; [branch_cu.sv](../../../rtl/expipe/exec-units/branch_cu.sv):53–121 | Multiple branches can be pending, execution is ordered, results are registered, correct feedback is e+1 and misprediction training/recovery e+2. Ordering does not equate prediction and resolution histories. |
| D reset/update policy; I integration | [fetch_stage.sv](../../../rtl/frontend/fetch_stage.sv):141–166; [datapath.sv](../../../rtl/len5_datapath.sv):97–132 | Integrated INIT=WT. Ordinary branch frontend flush preserves predictor state; exception predictor flush resets BTB/GHR/PHT and wins over update. |
| Independent implementation verification | [fetch_stage_components.cpp](fetch_stage_components.cpp):33–68; [fetch_stage_composition.cpp](fetch_stage_composition.cpp):165–183,255–280 | Current predictor oracle uses current H for both reads and updates. Request-time H/index/counter/version are frozen for provenance, never used to replace its update index. |

For G=2^HLEN, w=PC/4:

```text
Policy A (production / exact oracle):
    read = H_at_accepted_request XOR (w mod G)
    write = H_before_resolution_update XOR (w mod G)
    H_next = ((H_before_resolution_update << 1) | actual_taken) mod G
Policy B (architecture experiment only):
    read = H_at_accepted_request XOR (w mod G)
    write = saved_read_index
    H_next = same non-speculative resolution-driven update
```

All lanes read the same old H. An accepted request on a training edge saves old
H/counters; the next interval sees the new state. An unaccepted offer can change
predictions before grant. These details are distinct from speculative GHR, which
LEN5 does not implement. JAL, JALR and returns contribute taken outcomes because
qualified feedback is not restricted to conditional branches. Squashed predictions
have no history effect without illegal later feedback. Ordered branch execution
suppresses younger normal feedback following older misprediction. The actual
mispredicting branch's outcome still updates history; no speculative checkpoint
needs restoring. EQ08 RAS contamination remains a separate issue.

The model matches Policy A deliberately. Zero mismatches establishes compliance
with that target, not the superiority of resolution-indexed training. The original
authors' motivation cannot be established from the available source/comments.
The current user's earlier algorithm approval establishes the implementation
contract; it does not prove that counter attribution is optimal.

### A2. Real two-in-flight counterexample: GH01

Persistent executable program (`make check-fetch-stage-run SCENARIO=GH01`):

```asm
0x000: jal x0,0x040       # actual taken seeds H=1
0x040: bne x0,x0,0x044   # A: actual NT, correct effective prediction
0x044: bne x0,x0,0x048   # B: actual NT, correct effective prediction
        # immutable NOP padding
0x09c: bne x0,x0,0x0a0   # later index-3 public probe
0x0a0: jal x0,Done
```

The memory environment delays grants at the two phase boundaries until the
preceding real update. It neither injects feedback nor modifies the program.
Both A and B are dispatched, issued and survive; neither causes a recovery.
The seed JAL uses normal EJU correction, execution and training. Default GH01 has
a once-sampled fixed16 readiness fixture, independent of ordinary random latency.

| Cycle | Public consuming event / independently attributed state |
|---:|---|
| 3 | Seed request accepted; H=0, lookup0/counter2. |
| 10 | Seed JAL dispatched, effective prediction repaired by EJU. |
| 27 / 28 | Seed executes / trains: counter0 2→3, H0→1. |
| 29 | Request3 containing A/B accepted: both sample H=1. A PC0x40 reads index1/counter2; B PC0x44 reads index0/counter3. |
| 36 | Public bundle dispatch allocates A ID2 and B ID3. Both saved raw directions are1 with hit0, hence effective NT. No EJU rewrite on these branches. |
| 53 / 54 | A executes / trains index1 2→1; H1→2. B is already dispatched and remains live. |
| 55 / 56 | B executes / trains **index3** 2→1 using H=2. Original lookup index0 stays3. H2→4. |
| 58 / 70 | Probe request / matched public dispatch at PC0x9c: H4 XOR word7 = index3; `.taken=0`. |
| 101 total | Program marker retired, remaining speculative work explicitly canceled; 2702 comparisons, zero mismatches. |

Thus prediction and update indexes **demonstrably differ**, despite ordered
resolution. Policy B would decrement B's saved index0 from3→2 and leave index3
at2; the same later probe would have raw taken1. Policy A leaves index0 at3 and
sets index3 to1; the real output has raw taken0. Hit0 is reported honestly: this
probe witnesses raw direction, not a qualified taken redirect. Counter magnitudes
are inferred from reset and accepted training; only their direction projections
are publicly observed.

`history_audit.py` reconstructs H/PHT snapshots from public reset/training pins,
checks actual accepted-request timing and dispatch identities, then compares A/B
on the **same fixed feedback trace**. It does not simulate a closed-loop Policy B
frontend or claim an accuracy/speedup measurement. GH01 has6 attributed updates,
3 distinct lookup/update indexes and3 qualified older-update overlaps. The first
is the A/B pair above. FE-T13/15 provide additional nontrivial histories.

### A3. Recommendation and a reviewable alternative

**Recommendation: Option 1 — retain approved Policy A for the current LEN5
verification baseline and the next issue-stage work.** It is a valid simplified,
resolution-context predictor with recoverable prediction errors, not an ISA
correctness defect. Make its different-counter attribution explicit, as GH01
now does. There is no measured closed-loop performance evidence in this audit
that justifies changing production hardware now.

This is not a claim that A is preferable for accuracy. A learns contexts of the
resolved branch stream while fetch may consult older contexts. B trains the
counter that actually supplied each dynamic prediction, usually the clearer
choice if that attribution is the design goal. Both still have finite-table
aliasing; B does not fix non-speculative history lag, nor guarantee better
accuracy for every interference pattern. The minimal follow-up before selecting
B is a closed-loop A/B program/benchmark comparison with identical workloads and
backend policies, measuring direction/target errors and recovery cost separately.

| Property | A: current H at resolution | B: saved lookup index |
|---|---|---|
| Attribution | Can update a different counter | Updates original queried counter |
| Unresolved branches | No per-branch PHT metadata | Requires HLEN bits per in-flight instruction/branch |
| GHR | Non-speculative, ordered actual outcomes | Can retain the same policy; speculative GHR is unnecessary |
| Recovery | Current reset/flush priorities | Same priorities; discard canceled index metadata with its instruction |
| Timing | XOR on update path | Registered index on update path; added lookup-index routing/storage |
| Tables / tags | Existing PHT/BTB | Same tables/tags; no associative lookup required |
| Cost | Current small implementation | Wider transported records; no ROB/CDB index needed for execution-time training |
| Accuracy evidence | Verified implementation, no optimality proof | Fixed-trace counter differences only; performance not established |

If B is approved later, the minimal concrete proposal is:

1. Expose HLEN-bit lookup indexes from `gshare` to `bpu`; add a `pht_index` to
   `fetch_pkg::prediction_t` (49–55) using the configured history width. Capture
   it on the same request acceptance as hit/direction/target, including BTB misses.
2. Preserve it through fetch_mem metadata/answer records, EJU, mixer and final
   output spill. EJU must preserve this **raw lookup provenance** when rewriting
   effective hit/taken/target. PC generation itself needs no algorithm change.
3. Add the field to `expipe_pkg::iq_entry_t` (266–274), `issue_stage::issue_reg_t`
   (120–136), IQ-to-issue assignments (208–211,325–326), and issue-to-execution
   wiring (`issue_stage`:545–546, `backend`, `exec_stage`, `branch_unit`).
4. Store it in `branch_rs::bu_data_t` (80–96); select by the existing ordered
   execution cursor, and capture it alongside `branch_unit.res_q` (184–211).
   Extend `fetch_pkg::resolution_t` (57–63) with the saved index and return it
   through the existing registered resolution bus to BPU/gshare.
5. Train `res.pht_index` directly; retain actual-outcome GHR updates and current
   reset/flush priority. Squash invalidates the record; no testbench PC→index
   association table can substitute for this missing hardware metadata.

At HLEN4/N4, a rough storage increment is184 bits:32 metadata FIFO +32 answer
spill +32 output spill +64 IQ +4 issue register +16 branch RS +4 resolution
register. This is an estimate excluding synthesis padding/control and optional
cells, not an area result. Full history is unnecessary if only attribution is
needed: a saved HLEN-bit index is sufficient and equally wide. Any speculative
GHR proposal needs separate checkpoint/rollback design and is outside this change.
N=1/2/4/8 transport scales with N; derive widths from HLEN and separately respect
existing `HLEN > log2(N)` declarations. No original RTL or isolated experimental
RTL implementation was changed in this audit.

## B. FE-T15 diagnosis and closure

### B1. Why cycle257 did not close the previous test

Historical evidence:
`build/fetch-stage/core/ordinary-xmigswzl/FE-T15/`, preserved analysis in
`build/fetch-stage/final-architecture-audit/historical-fe15.json`.

The reported update is real in that bounded trace: ID91/PC0x18 at257,
H5 XOR word6 = index3, counter1→2, then H=11. PC0x20 would read index3 under H11.
However:

* PC0x20 is an immutable JAL, not a conditional probe. On an applicable cold/NT
  prediction EJU could overwrite its prediction, hiding the raw direction.
* Accepted bundles at base0x20 at cycles258/264/273/283/292/306 start at logical
  **PC0x24**. Lane0/PC0x20 is excluded. Fetching its physical word is not a valid
  prediction witness.
* No retained index3 conditional prediction with counter1 appears in that run.
  The earlier index3 conditional samples (requests131/137/145) read2. The later
  request398/index3 read2 belongs to ordinary PC0x34, excluded by the branch
  witness monitor. The next retained conditional at432 already reads2.

The failure was missing both a suitable pre-observation and a retained
post-observation, not a comparison mismatch or a reason to increase the budget.
The candidate arithmetic was sound, but the actual program/mask made it unusable.

### B2. New immutable program and stronger monitor

`threshold-interacting` prepends four actual PC+4 conditional branches at
0x0/0x40/0x84/0xc8, with outcomes NT/T/NT/NT. Memory grant barriers wait for the
preceding qualified feedback, allowing controlled reads of index0 across
2→1→2→1. The existing interacting-branch body follows at0x200 (same low PC-index
relationships); it was not replaced by random stimulus or a fake predictor write.
All outcomes come from encoded x0 comparisons. The program remains immutable.

Every saved lane now carries an independent PHT write-generation number. A public
threshold witness requires matched accepted conditional metadata, no EJU rewrite,
exact pre/post counter values, and adjacent write generations of the **same entry**.
The pre-request can coincide with the update edge (old state), while the post-read
must be later. An intervening write cannot masquerade as this transition.
Credit occurs only after matched consuming-edge checks. Both raw-direction
crossings and **BTB-hit pre/post crossings** are mandatory FE-T15 gates.

Actual stronger witnesses in the interacting body:

| Event | Request / dispatch / update cycle | PC | H | PHT entry / counter | Public metadata |
|---|---|---|---:|---|---|
| Down pre |375 /384|0x218|13|11 /2, generation0|hit1/taken1|
| Down update |416|0x218|13|11:2→1, generation1|Actual NT feedback; BTB deletion applies|
| Down post |948 /957|0x218|13|11 /1, generation1|hit1/taken0 after later valid BTB installation|
| Up pre |872 /875|0x238|14|0 /1, generation5|hit1/taken0|
| Up update |945|0x238|14|0:1→2, generation6|Actual taken feedback; H becomes13|
| Up post |1026 /1035|0x22c|11|0 /2, generation6|hit1/taken1|

There are intervening **other-entry** updates and H changes; the post probe's PC
compensates for H. There is no intervening write to the attributed entry. Thus
this also meets the stronger valid-BTB condition, rather than relying solely on
raw direction on a miss. Default FE-T15 completes in3330 cycles,125160 comparisons,
118 actual updates, zero mismatches. Strict FE-T15 returns0. No witness requirement
was removed; the original opposing-outcome collision/interference gates remain.

## C. Synthetic backend resource audit and corrections

### C1. Production capacities and lifetimes

| Resource / event | Active production evidence | Synthetic abstraction now enforced |
|---|---|---|
| IQ16 instructions | `len5_config_pkg.sv`:131; `issue_queue.sv`:74–123,153–164 | Whole contiguous-low valid-mask admission. Reserve V slots, not always N. No partial acceptance, no same-edge full-release lookahead. |
| Scalar issue | `issue_cu.sv`:83–100,207–253 | At most1 instruction/edge; only previously dispatched work. Allocate ROB and destination RS together. |
| ROB32 instructions | `len5_config_pkg.sv`:164; `rob.sv`:97–100,139–166,267–273 | Allocate at scalar issue, retain through completion and publication, release at retirement/squash. IQ+ROB envelope can reach48, not incorrectly32 including unissued IQ work. |
| ALU RS8 / BU RS4 | `len5_config_pkg.sv`:139,160; `arith_rs.sv`:134–144,397–420; `branch_rs.sv`:125–141,280–305 | Both bounded, held until result publication, not freed merely by result computation. |
| Execution | `alu_unit.sv`:63–112; branch unit/cursor above | Up to1 initiation per unit/edge; ALU and branch are independent paths. One-cycle modeled service after legal start. Ordered branch cursor and mispredict freeze retained. |
| CDB result publication | `backend.sv`:487–506; `expipe/cdb/cdb.sv`:20–39,57–87 | At most1 publication/edge. Multiple unit completions can coexist. Oldest-ready fair arbitration is a conservative abstraction, not the physical round-robin/priority network. |
| Retirement | `rob.sv`:139–166,174–196; commit consumer | At most1/edge, synthetic in-order. Real optional safe lookahead retirement is not reproduced. Completed-but-unretired entries retain capacity. |

Optional direct ROB result paths and EU operand bypass are not copied. Supported
ordinary instructions use the bounded synthetic ALU path and dependencies wait
for publication. This is conservative, not a cycle-accurate backend or ISA-complete
FU model. FP/MUL/DIV/load/store service is not fabricated by the integer engine.

The old implementation had no separate publication stage, released branch capacity
at computation, allowed unlimited ordinary completions in a cycle, and reserved
ROB for unissued IQ entries. These were environment-model defects/limitations,
not production frontend RTL defects. They are corrected without changing the
composed PC/EJU/RAS/memory algorithms or predictor update policy.

### C2. Latency and consuming-edge accounting

The existing §9 contract explicitly defines `earliest = dispatch + L`.
**L remains a once-sampled abstract minimum scheduling/readiness delay, not FU
service time.** Reinterpreting it as service latency would change that approved
generation policy. Reported stages are now separate:

```text
dispatch -> scalar issue -> operand/publication readiness
         -> start >= max(dispatch+L, issue+1, dependency_publication+1)
         -> result capture after one service cycle
         -> at most one shared publication on a later edge
         -> retirement on a subsequent eligible edge
```

Time spent waiting in IQ is not claimed as FU execution. This abstraction permits
additional scheduler delay even when operands are ready; it models no assertion
that a real ALU takes64 service cycles. All seven distributions and once-only
sampling survive unchanged. Branch feedback remains capture+1/capture+2 and can
precede branch retirement, just as production. CDB contention delays operand
forwarding/reclamation, not the already captured branch result's control pulse.

Admission metrics freeze the pre-edge capacity decision and credit only a matched
consuming edge. High-watermarks sample actual edge states, not the transient state
between software dispatch insertion and same-edge issue removal. Ready-low capacity
cycles, actually stalled valid offers and random/external valid-offer stalls are
reported separately. Resource stalls cannot be overridden by random readiness.
Resource/conservation violations and duplicate scheduler edges are hard framework
errors. Invalid later instruction lanes are rejected before any ID/version/RNG
allocation. Skipping a scheduled feedback pulse is also rejected.

### C3. Focused BP catalog

These auxiliary IDs are explicitly selected, not extra entries silently added to
the FE-T01–54 full catalog. Every BP case requires its semantic marker, plus its
specific resource witnesses. A forced final reset only cancels younger speculative
residuals; it does not satisfy normal program completion.

| ID | Setup and required checked behavior |
|---|---|
| BP01 | Sustained sequential input, fixed64 readiness, external readiness100%; IQ full, actual valid-offer stall, later accepted resumption, marker. |
| BP02 | Explicit interface-stress retirement-ready0 until cycle200, fast fixed2 readiness; ROB32 with completed/unretired entries, resumed retirement and marker. A separate old-branch64/younger-ALU1 pure fixture proves delayed-head lifetime directly. |
| BP03 |64 actual NT conditional branches, fixed64; branch RS4, scalar issue blocked, ordered resolution, marker. |
| BP04 | Long fixed64 readiness; every witnessed result starts legally and captures after service, marker. |
| BP05 |48-instruction pressure program, fixed256 readiness, budget2500; enough causal pressure even at N1. IQ full, valid-offer stalls and resumption, whole-bundle admission, marker. This special fixture does not lower ordinary/random latency bounds. |
| BP06 | Real older branch misprediction after wrong-path return activity, fixed64; younger cancellation, resource reclamation, three restored return probes and correct marker. |
| BP07 | BP01 plus independent75% random readiness; both random and resource stalls witnessed. |
| BP08 | Finite sequential fixed2 program; marker naturally retires, scalar publication/retirement and allocation/release conservation checked. |

An early BP05/N1 trial reached only a transient IQ high-watermark, without a held
valid offer, and correctly remained WARN_INCOMPLETE. It was not called a functional
RTL failure. The final shorter program/longer readiness fixture produces real
consumed-edge saturation/stalls at all four widths. The diagnostic accounting was
also corrected to exclude the software-only intermediate occupancy.

`BackendStats` and each case's `backend_resources` report offered/accepted bundles,
admitted/issued/started/completed/published/retired/canceled instructions, all resource
high-watermarks, capacity/RS/ROB block cycles, random stalls and CDB contention.
The per-instruction obligation ledger retains issue/start/completion/publication/
retirement timestamps and prediction provenance. Case resource counters describe
the final backend reset window; all windows remain in the instruction/learning
obligation ledgers. Do not treat final-window resource counters in FE47 as
whole-run totals. BP/GH measurements here use one live backend window. Invariant checks enforce both
capacity and admitted=retired+canceled+pending conservation. Rates can be computed
from these counts and the reported consuming-cycle budget; they are not FU timing
measurements of the real processor.

## D. Validation and retained evidence

Authoritative final evidence paths/counts and hashes are recorded in
`build/fetch-stage/final-architecture-audit/FINAL_EVIDENCE.json` and the latest
[completion-audit entry](COMPLETION_AUDIT.md). Earlier `first`, `sensitive-first`,
`stable`, `final`, and width `evidence-vzylo7cw` groups are development evidence,
not additional unique coverage or final-source claims.

Executed pure validation:70650 frontend C++ assertions,341 PC,16931 EJU,8310 FM,
37 result-policy tests and7 independent history-attribution tests. New negatives
cover all resource overflows, illegal bundle admission, duplicate edges/IDs,
latency/start/publication/retirement violations, exact issue/CDB/retirement bandwidth,
missing feedback consumption, wrong-history/index/ID association and read-old versus
post-update counter substitution. Bandwidth negatives check the intended error,
not an unrelated premature-lifecycle rejection. Earlier standalone behavior is
unchanged. The public-journal auditor's update count now accumulates across reset
windows instead of returning the emptied final-window set; duplicate prevention
remains per window.

GH01 and FE-T13/15 histories are independently cross-checked against public pins
and dispatch records. Policy B remains fixed-trace comparison only. FE-T15 replay
must reproduce samples and training traces byte-for-byte. Budget-limited FE-T15
still warns by default and returns3 under strict completion; a completed strict
FE-T15 returns0. FE-T54 retains all24 expected-positive/negative native validators.

No million-cycle regression, full aggregate, new RTL mutation campaign, experimental
RTL rewrite, original configuration change or private-state DUT probe was run.
The Verilator `-fno-dfg` workaround remains. Exact transport/approved algorithm
mismatches still fail, invalid environments/framework conditions still fail, and
missing selected obligations still warn or reject strict completion.

### D1. Final-source results

| Selected command/group | Cycles | Comparisons | Outcome |
|---|---:|---:|---|
| Default core, JOBS=2 |44913|1791021|48/48 IDs,69 cases PASS;0 ordinary mismatches/missing witnesses|
| Focused16 IDs /22 cases |14081|666528|GH01, FE15, BP01–08, FE13/34/37/38/40/47 all PASS|
| Strict FE15 |3330|125160|PASS, exit0;118 updates, public hit thresholds complete|
| Isolated BP05 N1 /N2 /N4 /N8 |792 /794 /796 /800|26861 /34736 /43535 /60665|All compile and simulate; all required saturation/stall/resume/marker witnesses PASS|
| Budget-limited FE15, default /strict |104 /104|2372 /2372|Both honestly incomplete; exit0 /3,7 missing witnesses each|
| FE15 replay |3330|125160|PASS; public/training journals byte-identical|

These groups overlap and do not represent additive unique coverage. The evidence
index additionally records217841 actual simulated cycles across285 native reports
with cycle metrics, including repeated development attempts and expected negatives.
Startup rejection receipts are retained separately. No million-cycle campaign
was run. FE54 includes
24 actual validators,830 cycles/29772 comparisons and11 deliberate detected
injections. Those expected negatives are kept separate from ordinary failures.
The core's native portion is44083 cycles/1761249 comparisons; the remaining830
cycles/29772 comparisons are FE54. Native core records10986 requests (6992
provided downstream,3994 canceled),15848 dynamic instructions (7223 retired,
8625 canceled),2696 updates,763 confirmations and377 recoveries. Request/backend
obligation conservation holds; canceled/unobserved individual training/RAS probes
are not credited as public witnesses.

Final artifacts: core `build/fetch-stage/core/ordinary-_o09v469/summary.json`,
focused `build/fetch-stage/final-architecture-audit/accepted/summary.json`,
widths `build/fetch-stage/widths-smoke/evidence-g_vp0vz6/summary.json`, strict
`build/fetch-stage/run/FE-T15-siq6aj22/summary.json`. Full paths, exact commands,
per-operation metrics, replay digests and development runs are indexed by
`build/fetch-stage/final-architecture-audit/FINAL_EVIDENCE.json`.

All341 protected files match entry. Selected configuration SHA256 remains
`3811d38c7ebb78ad94473fddb9c62a39d497bd6594bab8c7d8a6848337bbd97a`;
final source/build fingerprint is
`2699a477916c13b38521a5f4ab6526b03cda4baa757c0eeeac5daaa49427c180`.
Only frontend-specific model/driver/program/unit, diagnostic snapshot, build-parser,
auxiliary selection, history-auditor and documentation files changed. The root Make,
production wrapper/RTL/config and prior three frameworks were preserved relative
to task entry. The exact entry-relative list is in the evidence index.

## E. Remaining boundaries and reproduction

The ordinary scope can complete; **full specification sign-off remains false**.
FE-T43/48/49/50/51 remain deferred/incomplete. EQ07 same-edge alternatives remain
provisional, EQ08 exception-contaminated confirmed RAS remains a known separate
problem, and the delayed exception redirect/full precise retirement/CSR/mtval
questions remain outside this frontend transport checker. FQ02/03/04 alternative
memory protocols, fully predictor-agnostic path checking and exhaustive FEV crosses
are not closed by this audit. No new production RTL correctness defect is claimed.

```sh
source private/init.sh
make check-fetch-stage-run SCENARIO=GH01
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T15
make check-fetch-stage-run SCENARIO=BP02
make check-fetch-stage-run SCENARIO=BP05
make check-fetch-stage-run SCENARIO=BP06
make check-fetch-stage-run SCENARIO=BP07
make check-fetch-stage-widths-smoke N_VALUES=4,8 SCENARIO=BP05 SMOKE_SEEDS=0
# Optional width-sensitive admission follow-up:
make check-fetch-stage-widths-smoke N_VALUES=1,2 SCENARIO=BP05 SMOKE_SEEDS=0
make check-fetch-stage-core JOBS=2
python3 tb/frontend/fetch_stage/history_audit_unit.py
python3 tb/frontend/fetch_stage/history_audit.py <GH01-or-FE-T15-run-directory>
```

The policy comparison requires a full public journal and ordinary WT-initialized,
resolution-driven histories (GH01/FE13/FE15); it is not an alternative oracle for
unknown exception histories. Use `JOURNAL=full` for an explicitly selected random
history audit. Exact program images, source manifests, normalized latency fixtures
and replay commands accompany each native run. Original protected-file SHA256
values are retained before/after; only disposable copies select another N.


## F. Entry-relative changed files

Existing user/prior-task uncommitted changes were retained. This audit changes:

* Model and adapters: `fetch_stage_components.cpp/.hh`,
  `fetch_stage_composition.cpp/.hh`, `fetch_stage_configuration.cpp`,
  `configuration.py`.
* Execution and scenarios: `fetch_stage_driver.cpp/.hh`, `fetch_stage_program.cpp`,
  `fetch_stage_tb.cpp`, `fetch_stage_unit.cpp`.
* Selection/auditing: `results.py` (auxiliary IDs only), `validate.py`,
  `widths_smoke.py`; new `history_audit.py`, `history_audit_unit.py`.
* Documentation: `README.md`, `VERIFICATION.md`, `COMPLETION_AUDIT.md`, and this
  new report.

No standalone gshare/BPU test directory was found under `tb`; the relevant
independent predictor fixtures live in `fetch_stage_unit.cpp`. The three existing
standalone PC/EJU/FM pure suites were compiled/executed unchanged. Neither the
root Make's pre-existing modifications nor any protected production/prior-suite
file was changed by this audit.
