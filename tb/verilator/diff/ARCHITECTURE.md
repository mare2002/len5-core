# Pipeline observation and verification coverage

[Build and run instructions](README.md).

## Files and outputs

* `compile_model.py`, `layout.py`, `signals.vlt`: reuse FuseSoC's simulation
  manifest in an isolated build, expose selected modules read-only, derive
  packed offsets, enum values and configuration from elaborated XML. Missing
  signals/types or changed widths fail explicitly. VPI's wide-vector buffer is
  sized from the generated schema, including the packed ROB array.
* `spike_adapter.cpp`: direct `processor_t`, `state_t`, `simif_t` integration.
  `sim_t` is intentionally unnecessary: LEN5 starts directly at its configured
  boot PC without Spike's HTIF boot ROM, CLINT or device tree. The independent
  sparse memory loads exactly the same byte-wide HEX as LEN5. Initial selected
  CSRs are synchronized once from reset state; subsequent speculative RTL state
  is never fed into Spike. Execution hooks supply register/CSR/store logs;
  zero-placeholder load log data is reconstructed from reference memory.
* `checker.cpp`: architectural reference stream, dynamic instruction queue,
  active ROB/LSQ associations, outstanding memory transactions, deferred commit
  checks and actual register-file checkpoints. Reference records contain order,
  PC/encoding/length, next PC, decoded sources/destination and pre-execution
  operands, result, raw memory access, XPR snapshot, selected CSR snapshots and
  CSR changes, privilege and trap cause/tval when a boundary is reached.
* `monitor.cpp`: the inspected RTL-to-checker mapping and edge sampling.
* `annotate.cpp`: streaming FST reader/writer merge, JSON field legend and GTKWave
  save file, using Verilator's bundled GTKWave library.

Original output remains `logs/waves.fst` and, when requested,
`logs/sim-trace.log`. The checker output directory contains `report.json`,
`events.bin`, `annotated.fst`, `annotated.gtkw` and `fields.json`. `events.bin`
is a local C++ event spool, not a portable/versioned interchange format.

The annotated FST copies the original hierarchy, aliases, widths, time scale and
time zero, then adds `verification.<stage>.laneN`. Lanes represent simultaneous
**comparison events**, not hardware issue slots; several fields of one
instruction also get separate lanes. Read `event_valid`, `field`,
`expected_value`, `actual_value`, `architectural_order`, `instruction_id` and the
ROB/LSQ indices together. Named `expected_result`, `actual_address`, etc. are
provided as well. `register_index` identifies an XPR or CSR at checkpoints.
An unavailable tag/order is all ones.

Execution discrepancies are tentative until commit or an irreversible store
write. Final annotation distinguishes `mismatch`, `confirmed` and `squashed`.
`event_time` preserves the original Verilator timestamp; `confirmation_time`
records when architectural relevance became known. The overall failure flag and
GTKWave's primary marker are placed retrospectively at the earliest confirmed
event, including an earlier bad CDB result. Deferred next-PC comparisons occur
when both commits are known; the individual commit events remain at their own
original times. A two-pass event scan and streaming FST copy avoid loading the
whole waveform into RAM. Disk space for both original and annotated FSTs is
required; only live instruction/reference windows and discrepancies stay in RAM.

## Verified pipeline semantics and coverage

The current configuration has an eight-instruction **fetch bundle**, one IQ
pop/dispatch, one accepted CDB result and one selected commit notification per
cycle. The checker API supports repeated dispatch/execution/commit calls at the
same timestamp and tests them; the monitor binds the actual scalar interfaces.
A future superscalar backend needs corresponding monitor lane bindings.

| Stage | Observed boundary and verified fields | Limits |
| --- | --- | --- |
| Fetch | `issue_stage.fetch_valid_i && fetch_ready_o`, per-lane `fetch_valid_instr_i`; compacted `new_instr` PC/encoding | Creates records only on IQ acceptance, not on held instruction-memory responses. |
| Decode/dispatch | `comm_valid_o && comm_ready_i`, `ex_rob_idx_o`, `comm_data_o`, `ireg_data_out`; FIFO identity, PC, encoding, used source indices, rd and write enable | Separate decode control bits/immediates are not independently checked; execution effects are. Register-source CSR operand is checked here because CSR instructions skip RS execution. |
| RS/CDB | Each station's `cdb_valid_o && cdb_ready_i`; selected `data[cdb_idx/head_idx]`, CDB tag/result/exception | RS entries retain operand **values and producer ROB tags**, not architectural source indices/rd. Architectural indices come from dispatch; no independent CDB rd-index signal exists. Only used operands/results are compared. |
| Branch | Accepted branch resolution (`rs_bu_valid`, `bu_rs_ready`, `cu_res_reg_en`), resolved target/taken/link, misprediction and ROB tag | Conditional-branch CDB data is link PC, not the architectural successor; next PC is checked at resolution and deferred commit. |
| Load | Actual LB `push`/`tail_idx`; address-adder answer; retained completion fields; external request/response tag | Address, size, byte mask, raw data, sign/zero-extended CDB result and base operand. Tag-associated response tombstones survive flush/reuse; forwarded loads need no external request. |
| Store | SB allocation/address/data; transition into `STORE_S_MEM_REQ`; external tag/address/mask/data and response | Authorization, overlapping-store visibility order, no unknown/duplicate/unauthorized external write. Identity survives active-ROB removal. |
| Commit | `csr_comm_insn_o != COMM_CSR_INSTR_TYPE_NONE`, **old** `comm_reg_data`, `int_rf_valid_o`, `rd_idx_o`, `rd_value_o` | PC, encoding, integer rd/write/result and exception indication. Trap transitions are explicitly unsupported. |
| Checkpoint | **Post-edge** `int_rf.rf_data[1:31]` plus implicit x0 and the five selected CSR registers | All 32 integer registers and selected CSRs, only at a complete architectural prefix with no younger unmatched visible commit. No duplicate shadow register file. |

The inspected implementation is in `rtl/expipe/{issue-unit,exec-units,
load-store-unit,commit-unit,register-file}`. `rob.fifo_pop` transfers an entry
into the commit pipeline; it is **not** the architectural commit boundary.
The modified ROB selects the ready head or eligible `work_idx`, with the
current WAW check against the head. Completion only supplies a ROB result.
Actual commit writes the architectural integer RF and cannot be rolled back by
the existing flush path. The checker therefore treats that event as irrevocable
and detects a wrong-path commit even if a later flush would clear its ROB slot.

At commit, `committed=true` and the active ROB association is removed immediately.
There are no ROB generations. Committed records remain for adjacent-order
next-PC checks, snapshots and store completion; squashed records are excluded
from every active association. Age comes from dynamic/reference order, never
from numerical ROB indices. Register comparison waits until the contiguous
committed prefix reaches the newest observed commit. Thus I0,I2,I3,I1 can compare
against Spike after I3; a visible I5 with missing I4 prevents that checkpoint.
This also catches an older write incorrectly overwriting a younger write to the
same architectural register.

Store authorization is deliberately distinct from normal commit. In this RTL,
ROB `mem_clear`/`sb_mem_clear_o` permits the store buffer to enter MEM_REQ **before
its CDB result and commit notification**. Older memory-critical instructions
must be resolved without exception/misprediction. The checker observes that
transition and independently rejects clearance past an unresolved older
branch/jump/load/CSR or unsupported instruction. This is the design's intended
point at which a store is no longer squashable. Squashing an externally written
store is an immediate failure. The bare emulator's irreversible write occurs
on **negedge `data_store_valid_i && data_store_we_i`**, irrespective of ready;
the monitor samples exactly that boundary. Load requests are captured on
posedge valid, also irrespective of ready, including a coincident flush.

Frontend recovery and backend squash are separate. `issue_stage.iq_flush`
invalidates un-dispatched IQ/issue-register records; `commit_stage.cu_mis_flush`
invalidates remaining dispatched records. Misprediction resolution releases
younger expected-stream associations early, allowing refetch even when the
predicted and resolved next PC coincide. Wrong-path fetches never consume Spike
orders. Repeated PCs match the next architectural order, not a search by PC.
The 10,000-cycle recovery timer clears only on a matched accepted fetch, never
on a flush alone. A separate commit-progress timer detects stalls/deadlock.

## Boundaries and remaining work

* The observed LB uses dependency waits/forwarding and has no replay or
  memory-order-violation recovery interface. This version handles its actual
  flush/reissue behavior, including delayed responses; adding a replaying LSU
  requires an explicit replay observation and invalidation of superseded
  tentative comparisons. Other memory systems, caches and external bus
  protocols need their own write-acceptance/transaction bindings.
* FP registers, fflags/rounding and privilege/trap transitions are not verified.
  The current RTL hardwires `mstatus.fs=0`, whereas Spike requires FP state
  enablement; an agreed architectural reset/privilege contract and FP operand,
  commit and checkpoint bindings are needed before claiming F/D support.
* Interrupts are not driven by this testbench. Counter/time CSRs, other
  nondeterministic sources and MMIO reads are rejected. RAM is modeled below
  `0x20000000`; only output stores at serial `0x20000000` and exit `0x20000100`
  are accepted above it. Neither model receives speculative inputs from the
  other. Fences/atomics, modified instruction bytes and non-32-bit instructions
  are explicitly rejected. Trap cause/tval are reported but execution does not
  continue through trap entry.
* The final committed instruction has no observed committed successor at normal
  exit. Its deferred next-PC check remains pending and is counted in the report;
  it is not declared checked. Active speculative instructions at exit are also
  counted. Incomplete architectural prefixes and unfinished committed stores
  cause a nonzero result.
* Spike/Verilator internals are intentionally pinned. To support another
  version, update and test the adapter/schema generator against actual headers;
  do not remove the version checks blindly. Journal I/O and read-only VPI have
  overhead in enabled runs; large-trace throughput has not been benchmarked.

