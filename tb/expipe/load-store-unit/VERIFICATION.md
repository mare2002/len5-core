# LSU redesign

## Architecture and invariants

`ISSUE_WIDTH` describes the ordered global bundle; `LSU_ISSUE_WIDTH` limits the
mixed memory stream. `LDBUFF_ISSUE_WIDTH` and `STBUFF_ISSUE_WIDTH` independently
limit the loads and stores allocated per cycle. Each must be positive and no
larger than `LSU_ISSUE_WIDTH`; both default to one. All loads and stores decode to one `EU_LSU` identifier. `ldst_width_t`
identifies the operation: `L_BYTE`, `L_BYTE_U`, `L_HALFWORD`, `L_HALFWORD_U`,
`L_WORD`, `L_WORD_U`, `L_DOUBLEWORD`, or `S_BYTE`, `S_HALFWORD`, `S_WORD`,
`S_DOUBLEWORD`. Stores have no sign-extension variants.

The LSU has one ordinary multi-issue valid/ready dispatch interface and separate
load/store CDB result channels. `exec_stage.gen_route` uses the same candidate compaction for
LSU and other EUs; `gen_payload` routes the common `eu_ctl_t` control alongside operands, immediate,
and ROB tag. LSU and branch units extract their operation internally. The
payload mux populates rs3/FRM only for FPU and PC/prediction metadata only for
the branch unit; those fields remain zero in all other routes. There is no separate memory-order route,
load/store routing flag, or per-class readiness interpretation at that boundary.
The issue stage offers an instruction before its own ready, after every older
lane has actually accepted. ROB allocation, IQ removal, register-status updates,
and same-bundle dependencies remain tied to accepted grants.

Inside the LSU, candidate operation types determine LQ/SQ ranks and prefix
readiness independently of offered valids or grants. FIFO mode advertises shared
FIFO capacity; its output uses the same queue allocation calculation as bypass.
One-hot channel ranks route the ordered stream into LQ/SQ allocations. The SQ
exports boundaries after each accepted store prefix, and each load selects its
boundary using the rank of preceding stores. A load cannot cross a blocked older
store.

Dispatch destinations and completion sources have separate enums:
`issue_eu_t` uses `EU_LSU` for both memory operation kinds, while `cdb_source_t`
has separate `CDB_STORE_BUFFER` and `CDB_LOAD_BUFFER` entries. CDB arrays use the
seven-entry `CDB_SOURCE_COUNT`, independent of configured dispatch padding.
Store completion retains the global maximum-priority input; loads and other
units use the existing round-robin group. Both queues independently hold their
result under backpressure, and the global CDB still transfers at most one result
per cycle. The LSU has no local completion mux or completion-ownership state.

The LQ is a reservation station. `prio_enc_multi` chooses distinct currently
empty slots. Independent address, memory, and result selection permits ready
loads to pass unresolved loads. Each selection remains stable under downstream
backpressure. CDB wakeup applies both to resident operands and new allocations,
including the allocation FIFO push edge. Results and faults remain resident
until their CDB handshake.

`check_build` requires positive power-of-two `LDBUFF_DEPTH` and `STBUFF_DEPTH`.
Depth one remains supported. SQ pointers wrap by natural overflow of their index
width; depth-one indices are held at zero despite their minimum one-bit signals.

Both buffers retain the original state/data/operation organisation. `lb_state_t`
and `sb_state_t` are held in separate `curr_state`/`next_state` arrays;
`lb_data_t` and `sb_data_t` contain the retained instruction metadata. The
operand ROB tags and values are separate `rs1_rob_idx`/`rs1_value` and, for stores,
`rs2_rob_idx`/`rs2_value` fields. Readiness is encoded by `curr_state`, without
stored operand-ready bits. Incoming operands retain the existing `op_data_t`
interface and allocation-edge CDB bypass.
The `p_state_prog` blocks describe state progression and select per-entry `lb_op_t`
or `sb_op_t` commands. `p_data_update` applies those commands, and separate
state and data registers capture the results. The SQ's `p_fifo_ctl` independently
updates circular pointers and occupancy. No additional pipeline registers or
changes to the external LSU interface are introduced.

The operation types are enums with `LOAD_OP_*` and `STORE_OP_*` commands,
executed by `case` statements in the data-update blocks. The combined
`STORE_OP_SAVE_ADDR_RS2` command captures an address and wakes rs2 together.
Older-store boundary tracking and non-cancelable write ownership are independent
of the data command, so a load can capture a memory response while clearing its
older-store flag. Incoming operands receive CDB bypass before the initial state is chosen.
Data-update priorities preserve the pre-refactor behaviour: captures precede
allocation, and flush has final priority for state and ownership cleanup. An
already-issued store still captures its response during flush and drains without
broadcasting a stale completion. Queue observation indices and transaction
identity are preserved; the scoreboard and Spike monitor use the flat fields.

The directed matrix checks both concurrent-operation examples explicitly. The
store scenario aligns a pending rs2 CDB wakeup with its address response and
checks both captured values before ROB permission. The load scenario releases a
held store completion and a disjoint load response on the same edge, checking
that both the captured load value and the cleared older-store flag survive.
Handshake and operand-readiness assertions confirm that each test exercises both actions;
the expected addresses and data come from the independent testbench model.

The SQ stores entries in place, using a head, tail, and occupancy count. Its
explicit states distinguish both operands pending, only rs1 pending, only rs2
pending, address request/wait, ROB permission, memory request/wait, completion,
and empty. `STORE_S_ADDR_READY_RS2_PENDING` holds a calculated address while
store data is still missing. Address issue is allowed from `RS2_PENDING`, so
waiting for data cannot delay address calculation. The FSM encodes address
progress instead of separate `addr_sent`/`addr_ready` flags; forwarding status is
exported from those phases.

`STORE_S_ADDR_WAIT_RS2_PENDING` distinguishes an outstanding address calculation
whose store data has not arrived. A CDB wakeup moves it to `ADDR_WAIT`, preserving
that wakeup even if the address response arrives later. An address fault enters
`STORE_S_COMPLETED` even when rs2 is missing. A younger load may forward
speculatively from that entry while the store reports its exception to the ROB.
These states fit in the existing four-bit state register. Transition assertions
check operand wakeup before moving from pending states to ready states.

Only the FIFO head may request a write. `WAIT_ROB` may issue on the cycle
permission becomes available, and `MEM_REQ` explicitly records a request held
under backpressure; this avoids adding a registered request-stage cycle.
`MEM_WAIT` and `COMPLETED` entries remain occupied and available to forward.
Exactly one write may be outstanding; the next write waits for the previous
completion handshake. A memory response cannot release a live entry. Address
faults complete without sending a memory request. Write-response faults preserve
the original ROB identity and full faulting address through CDB stalls. Flush
retains an accepted write until it drains, suppressing its obsolete ROB result.

Memory write authorization is restricted to the ROB head. The decoder also marks
loads and stores memory-critical: the ROB clearance frontier cannot pass them
until successful completion. This prevents younger out-of-order retirement from
corrupting precise memory-response faults. There is still one CDB and one commit
interface. The exception redirect also reasserts the existing pipeline flush
when the trap PC is loaded: fetch bundles refilled during the intervening CSR
save cycles must not precede the handler. The earlier exception flush remains.

The existing memory tag width is preserved. Stores use their ROB index when the
memory interface can represent the complete index; otherwise the retained SQ
physical slot is the transaction tag. Responses must match the full expected tag.
Loads always use their physical LQ slot. No ROB-index age comparison is used.

## Store age and forwarding

Each load saves the physical SQ tail in `saved_tail_idx`, including accepted
stores in earlier lanes of the same issue bundle. Its `older_stores_remain` flag
captures whether any older stores remain after a simultaneous head removal.
Eligible valid stores lie in the circular interval `[sq_head, saved_tail_idx)`.
Equal indices with the flag set mean a full older-store prefix. A clear flag
means an empty prefix, regardless of subsequent SQ pointer movement.

On head removal, the flag clears when the next physical head reaches the saved
boundary. It stays clear until the load entry is allocated again, so younger
stores cannot become dependencies after wrapping through that index. No wrap
bit or per-load decrementing count is used. Relative age,
`(physical_index - sq_head) & (STBUFF_DEPTH - 1)`, is used only to prioritize the
youngest overlapping eligible store. SQ occupancy still uses its existing count.
Depth-one queues use physical index zero and distinguish full from empty with
the flag.

A load waits for every older store address to be known and fault-free. Among
byte-range overlaps, the greatest relative age (youngest older store) wins. It
may forward only when its ready data completely covers the load. A younger
partial overlap hides every older full-width match. Otherwise the load waits
until the overlap drains, then retries memory or forwarding. Multiple-store byte
merging is intentionally absent. Loads disjoint from all older resolved
addresses may read memory while their data remains unresolved.

Forwarded values are right-justified before the existing sign extender, as are
memory responses. Aligned-doubleword mode shifts memory responses only;
forwarded values are never shifted twice. Address-adder misalignment exceptions
and full faulting addresses are preserved. MMIO addresses selected by `MMAP_MASK`
cannot forward. The supported native MMIO map permits output stores and faults
reads. There is no second forwarding buffer or retired-store cache.

A younger store cannot overwrite an older load's value: the head is younger
exactly when that load's `older_stores_remain` flag is clear. Such a store waits for an
unknown older load address, or an overlapping older load still acquiring data.

## Flush ownership

All speculative allocations, operands, address work, and live results are
invalidated on the existing global flush. There is no selective surviving-load
suffix protocol in this core. Address-adder and allocation-FIFO work flushes
with the queues.

With `LOAD_BUFFER_DRAIN_ON_FLUSH=1`, outstanding loads become KILLED. Their slots
remain unavailable until the original responses drain, including requests
accepted on a flush edge. A same-edge response releases its slot immediately.
Repeated flushes cannot release a pending tag. With drain disabled, the memory
backend must cancel outstanding loads; `tb_config_pkg` enforces the backend
contract.

An accepted store write cannot be canceled. Flush removes the speculative SQ
suffix and retains the issued head, including a same-edge response. Since flush
cancels its ROB ownership, that retained entry drains without broadcasting into
a recycled ROB tag; it is removed after response processing. Live, unflushed
stores are removed only on completion acceptance. Both AXI and TC_SRAM preserve
store responses across pipeline flush; AXI reset discard behavior is unchanged.

Assertions check distinct/free allocations, circular-prefix occupancy, load
boundaries bounded by resident stores, full-tag response ownership, ordered dispatch,
and at most one issued store.

## Reproducible verification

Run `make check-issue-offer` for the issue handshake regression. It uses the
production issue stage, decoder, IQ, dependency logic, and control logic at
widths 1, 2, 4, and 8 with decode spilling on and off. It checks blocked-lane
offers, actual acceptance of older lanes, ROB backpressure, same-bundle operand
tags, direct results, CSR serialization, and flush. Mock ROB and execution
capacity make offer-versus-acceptance independently observable.

Run `make check-lsu`. Its build and simulation logs are under
`build/lsu-redesign/`, with existing ordering logs in `build/load-store-order/`.

The self-checking `lsu_redesign_tb` uses an independent byte-addressed reference,
program-ordered expected values, delayed/reordered read responses, and writes
visible only after write responses. It checks full LQ/SQ/FIFO backpressure,
arbitrary LQ slot reuse, circular SQ wrap, same-cycle removal/allocation,
interleaved same-bundle ages, all access widths/extensions, unresolved operands,
youngest/partial overlaps, SENT/COMPLETED forwarding, MMIO exclusion, CDB and
memory stalls, faults, repeated flush, response/flush collisions, and ROB reuse.
Its randomized phase issues 100 bundles for each seed after the directed tests.

An independent scoreboard uses monotonically increasing store sequence numbers
and captures the accepted store sequence at each load allocation. Each cycle it
checks SQ indices/occupancy and each live load's saved boundary and remaining
older-store flag. This model does not use circular pointer comparisons to decide
whether a dependency remains. Directed tests cover equal-index full prefixes,
last-older-store removal, simultaneous removal/response and removal/allocation,
and a delayed load response while younger stores drain through more than two SQ
wraps without reviving dependencies. Existing flush and reuse tests also run
under the boundary scoreboard.

Default matrix (three seeds: 1, 23, 101):

| Global/LSU width | LQ/SQ depth | Additional configuration |
|---|---|---|
| 1/1 | 1/1 | depth-one pointers/counts |
| 2/2 | 2/2 | registered address adder |
| 4/4 | 4/4 | bypassed address adder |
| 8/8 | 8/8 | registered address adder |
| 4/4 | 4/8 | unequal power-of-two buffer depths and circular wrap |
| 4/4 | 4/4 | allocation FIFO |
| 8/4 | 4/8 | narrower LSU plus allocation FIFO |
| 8/4 | 4/8 | narrower LSU with allocation bypass |
| 2/2 | 4/2 | forwarding disabled |
| 4/4 | 4/4 | aligned-doubleword read transport |
| 2/2 | 2/2 | cancel-on-flush load backend |
| 2/2 | 2/64 | full ROB-index memory store tags |

`lsu_rob_precision_tb` uses the actual instruction decoder and tests all integer
and FP memory decodes, pending and faulting memory instructions blocking younger
retirement, successful release, head-only write permission, stalled fault
results, out-of-order retirement holes, full ROB wrap and tag reuse. Its default
widths are 1, 4, 8 at ROB depth 16.

The existing ordering and LOAD_S_KILLED regressions remain enabled; the latter
includes 10,000 randomized cycles. Old retired-L0-cache checks now require
exactly one memory read after SQ removal, matching the new architecture.

Full-core checks use the pinned Spike checker:

```sh
python3 scripts/sim/check-multiple-exec-integration.py \
  --simulate --cases lsu-wide,lsu-fifo,lsu-depth-one \
  --fusesoc /home/markospremic/miniconda3/envs/core-len5/bin/fusesoc
```

Those configurations also run `lsu_precise_faults.S`, which checks access and
alignment trap causes/addresses, preservation of younger register/memory state,
and recovery with `mret`. The Spike observer consumes actual multi-lane queue
allocations, forwarding capture, response ownership, and precise write events;
its operand/CDB/register/store fault injection paths remain available.

## Recorded results

The completed run passed:

- `make check-lsu`: 33 configuration/seed runs, three decoder-backed ROB
  precision runs, the existing ordering test, and LOAD_S_KILLED with 10,000
  randomized cycles. See `build/lsu-redesign-acceptance.log`.
- Full-core elaboration/lint and Spike differential execution for `lsu-wide`,
  `lsu-fifo`, and `lsu-depth-one`: 116 checked commits per configuration,
  zero discrepancies. All three also passed the four precise trap/recovery
  cases with a four-byte-aligned handler. See
  `build/lsu-redesign-complete-integration.log` and each configuration's
  `run/logs/diff/report.json` and `precise-faults/console.log`.
- `make check-multiple-exec check-rs-alloc-fifo check-branch-rs-alloc`: 61
  reported checks including configuration rejections and execution/allocator
  regressions. See `build/lsu-redesign-exec-regression.log`.
- `make check-alu` using pinned Verilator 5.040 and `CCACHE_DISABLE=1`:
  750,148 checks, zero errors. See `build/lsu-redesign-alu-pinned.log`.
- AXI variable-slave and native-memory adapter tests, each at fetch width eight,
  seed one, 10,000 random cycles plus directed flush/reset/MMIO/fault cases.
  Builds and logs are in `build/lsu-redesign/axi-adapter/` and `axi-native/`.
- Focused Verible lint for changed LSU/commit-control RTL and new benches,
  shell/Python syntax checks, and `git diff --check`.

The pre-fix full-core trap program reproduced the stale recovery-stream failure.
After the late dual flush, it verifies trap entry, exact exception metadata,
younger-state preservation, and successful return for store/load access faults
and address misalignment. This addresses the R02 recovery window identified by
the frontend audit without changing PC-generator redirect priority or targets.

## Performance and verification limits

Forwarding compares every LQ entry with every SQ entry and multiplexes the
winning store. Comparison/mux area and the load eligibility path grow with
LQ×SQ depth. No synthesis, place-and-route, timing closure, or PPA claim is made.
Address and memory ports remain single-ported. Currently empty slots supply
allocation capacity, so a full queue has a one-cycle allocation bubble when an
entry is released. ROB-head store authorization and waiting for precise write
completion intentionally limit store throughput.

Focused and full-core simulation do not constitute formal proof or full ISA
compliance. Application/benchmark sweeps and the historical frontend R02
reproducer matrix were not rerun. The aggregate `make check` was not used because
it formats the complete tree and its lint step fails on the existing vendor
violations below; relevant subchecks were run directly. Repository-wide Verible lint reports pre-existing style violations
in vendored `rtl/vendor/tech_cells_generic/tc_sram.sv`; changed LSU RTL and new
SystemVerilog benches are checked separately. The standalone TC_SRAM regression
has a fetch-response assertion at `tc_sram_adapter_tb.sv:545`, reproducible with
the original configuration and both installed Verilator versions; that runner
contains no LSU/ROB/decoder RTL. These failures are not waived or weakened.

## Earlier shared-router verification (before the unified EU)

The LSU ingress now uses the existing execution router and existing typed valid
ports. The readiness contract above is covered by `make check-issue-offer` and
`make check-lsu`, including an extra bypass configuration with issue width 8,
LSU width 4, LQ depth 3, and SQ depth 5. The issue-offer target is a prerequisite
of `check-lsu`.

The final `make check-lsu` passes all eight issue-offer configurations, 36 LSU
configuration/seed runs, three ROB precision configurations, the existing
ordering test, and LOAD_S_KILLED with 10,000 randomized cycles. Its log is
`build/lsu-routing-final-lsu.log`.

The `lsu-depth-one`, `lsu-wide`, and `lsu-fifo` full-core configurations each
pass 116 Spike-compared commits and all four precise load/store access/alignment
trap scenarios. See `build/lsu-routing-core-sim.log`. The existing `fifo-mixed`
configuration also passes 116 Spike-compared commits with all execution FIFOs
enabled, unequal execution-unit widths, and global issue width 4 versus LSU
width 1; see `build/lsu-routing-fifo-mixed-sim.log`.

The follow-up also passed 58 execution-unit/configuration checks, the 84-case
allocation-FIFO regression, and both branch-allocation FIFO modes. Nine other
full-core configurations elaborate successfully: default, fifo-mixed, alu-mult,
alu-div, alu-fpu, all-two, three-alu, fp32-only, and disabled-zero. Focused Verible
lint and `git diff --check` are clean. Repository-wide `make lint` still reports
only the ten existing style findings in vendored `tc_sram.sv`; no waiver was
added. Synthesis and static timing analysis were not run, so the candidate-rank
logic and existing older-acceptance chain still require implementation timing
measurement.

## Earlier unified-completion implementation: recorded results

This earlier run used `EU_LSU` and explicit `L_*`/`S_*` operations,
with a common dispatch interface and the subsequently removed common result port. The preceding
shared-router section records the earlier design's checks, not its current
interface contract.

The completed unified-EU run passed:

- `make check-lsu`: eight issue-offer configurations, 36 LSU configuration/seed
  runs, ROB precision at issue widths 1/4/8, the legacy ordering test, and
  LOAD_S_KILLED with 10,000 randomized cycles. Log:
  `build/lsu-unified-regression.log`.
- The final 36-run LSU matrix, including the new completion-owner flush test in
  every configuration: `build/lsu-unified-final-matrix.log`. The tests verify
  late store completion behind a stalled load, stable shared completion data,
  flush/reuse with both sources completed, and forwarding from COMPLETED stores
  while their shared CDB result is stalled. Depths include 1, 3, 5, 8, and 64;
  issue widths include 1, 2, 4, and 8; FIFO, forwarding, aligned reads, spill, and
  load-drain settings retain their existing matrix coverage.
- Updated decoder-backed precision tests verify every integer load/store
  operation and both floating-point widths, as well as memory exception
  barriers and ROB handshakes: `build/lsu-unified-rob.log`.
- The 84-configuration allocation-FIFO regression and all eight issue-offer
  configurations: `build/lsu-unified-ingress.log`.
- 58 execution/configuration regressions plus both branch-allocation modes:
  `build/lsu-unified-exec.log`.
- Spike comparisons with 116 commits each for `lsu-depth-one`, `lsu-wide`,
  `lsu-fifo`, `fifo-mixed`, and `lsu-narrow`. The four `lsu-*` configurations also
  pass all four precise load/store access/alignment trap scenarios. Logs:
  `build/lsu-unified-core.log` and `build/lsu-unified-extra-core.log`.
  `lsu-narrow` uses issue width 8, LSU width 4, LQ depth 3, SQ depth 5, and eight
  configured EU slots, covering the unused-row tie-offs.
- Nine additional core configurations elaborate successfully:
  `build/lsu-unified-elaboration.log`.
- Focused Verible checks on all changed SystemVerilog and `git diff --check`:
  clean. Full `make lint` has only the same ten vendored `tc_sram.sv` style
  findings: `build/lsu-unified-repository-lint.log`.

No synthesis or static timing analysis was run. Candidate-rank/prefix readiness
and the local completion mux need implementation timing measurement. In that earlier design, loads
shared the LSU's global priority completion slot. The separate-channel change
below restores load round-robin service and store-only maximum priority.

## Direct controls and separate completion-source indexing

The current interface passes routed `eu_ctl_t` directly into the LSU and branch
unit. The branch RS extracts `.bu` when constructing its allocation payload;
the LSU extracts `.lsu`. `exec_stage` has no `branch_ctl`/`rs_lsu_type` adapter.
Its `payload_mux` fills rs3/FRM only for `EU_FPU` and PC/prediction fields only
for `EU_BRANCH_UNIT`, preserving default zero values elsewhere.

Dispatch arrays retain `issue_eu_t`/`EU_*`, including one `EU_LSU`. Completion
arrays use `cdb_source_t`/`CDB_*` and independent `CDB_SOURCE_COUNT`. Separate
`CDB_STORE_BUFFER` and `CDB_LOAD_BUFFER` ports restore the existing global store
priority and load round-robin behavior without changing the arbiter algorithm.
The former local LSU completion mux and ownership registers are removed.

Verification passed:

- `make check-lsu`: eight issue-offer configurations, 36 LSU configuration/seed
  runs, ROB precision at widths 1/4/8, ordering, and 10,000-cycle LOAD_S_KILLED.
  Log: `build/lsu-cdb-split-final-regression.log`. A missing `decoded_ctl`
  declaration from the earlier testbench cleanup was restored during this run.
- `scripts/sim/check-cdb-sources.sh`: all seven completion-source identities,
  payloads, store priority, load round-robin fairness, backpressure, and flush
  with dispatch-array counts 6 and 8. Log: `build/cdb-sources/run.log`.
- Branch allocation with FIFO off/on and focused independent-channel stability
  assertions at depth 1, width 4 bypass, and width 4 FIFO:
  `build/lsu-cdb-split-branch.log` and `build/lsu-cdb-split-assertions.log`.
- Five full-core Spike runs with 116 commits each: depth-one, wide, FIFO,
  mixed-FIFO, and narrow/extra-dispatch-slots. All four LSU configurations also
  pass all four precise load/store trap scenarios. Nine other core
  configurations elaborate. Logs: `build/lsu-cdb-split-core.log`,
  `build/lsu-cdb-split-extra-core.log`, `build/lsu-cdb-split-elaboration.log`.
- Focused Verible and `git diff --check` are clean. Full repository lint retains
  only the ten existing vendor `tc_sram.sv` style findings. Synthesis and static
  timing were not run.

## Explicit store-FSM refactor

Only `store_buffer.sv` changes in production RTL. The reviewed execution/issue
logic, load buffer, interfaces, configuration, memory adapter, and Spike observer
are unchanged. The existing LSU wakeup test now explicitly checks that the
store address is ready while rs2 remains pending.

Verification passed:

- The pre-refactor baseline directed/random LSU test at width 4, seed 1.
- `make check-lsu`: eight issue-offer configurations, 36 LSU configuration/seed
  runs, ROB precision at widths 1/4/8, ordering, and 10,000-cycle LOAD_S_KILLED.
  Log: `build/store-fsm-regression.log`.
- A cycle-comparison miter checks all 24 store-buffer output ports against the
  pre-refactor implementation on every cycle across the same 36-case matrix.
  This includes forwarding metadata, request/completion handshakes, occupancy,
  head movement, and removal. Log: `build/store-fsm-equivalence/matrix.log`.
- An additional direct-interface cycle comparison checks address backpressure
  with a simultaneous rs2 wakeup, immediate address/write responses, memory and
  CDB stalls, an address-ready/data-pending store, flush of an outstanding write,
  circular wrap, and allocation-edge wakeup of both sources. Log:
  `build/store-fsm-equivalence/channels/run.log`.
- Spike and precise-trap checks use `build/store-fsm-core.log` and
  `build/store-fsm-extra-core.log`; the cases cover depth-one, width 8, FIFO,
  mixed-FIFO, and narrow/non-power-of-two queues.

The comparison is simulation-based rather than a formal equivalence proof.
Synthesis and static timing analysis were not run; the registered cycle behavior
is preserved in the exercised cases, while physical timing remains unmeasured.


## State/data/operation organisation refactor

Production changes are confined to `load_buffer.sv` and `store_buffer.sv`. The
module parameters, port declarations, state encodings, queue policy, and memory/
CDB timing are preserved. State registers are separated from instruction data;
per-entry enum commands select data updates without adding pipeline stages.
The existing testbench and Spike monitor retain their `data` field/index paths.

Verification evidence:

- The pre-refactor `make check-lsu` passed. Saved sources and hashes are in
  `build/lsu-organisation-before/`; the log is
  `build/lsu-organisation-baseline.log`.
- The post-refactor `make check-lsu` passed with the two new concurrent-operation
  scenarios in every matrix configuration. This also runs issue-offer checks,
  ROB precision at widths 1/4/8, the ordering regression, and the 10,000-cycle
  killed-load regression. Log: `build/lsu-organisation-regression.log`.
- Both buffers were compared against those saved sources on every rising clock edge:
  every output port, every entry's state, and every retained metadata field.
  All 36 matrix runs passed: 12 configurations and seeds 1, 23, and 101, including
  widths 1/2/4/8, non-power-of-two queues, SQ depth 64, FIFO/bypass, forwarding
  disabled, aligned reads, both address-spill settings, and both load-drain modes.
  References, instrumented modules, runner, and logs are in
  `build/lsu-organisation-equivalence/`; matrix log: `matrix.log`.
- The two added concurrent-operation scenarios were also rerun against the saved
  references in depth-one/bypass and width-four/FIFO configurations. Both passed;
  log: `build/lsu-organisation-equivalence/concurrent.log`.
- Additional direct-interface comparisons passed for both buffers. The store
  test covers held address/memory requests and CDB results, immediate address and write
  responses, allocation wakeup, outstanding-write flush, and circular wrap.
  The load test covers immediate address and read responses, allocation wakeup,
  held address/CDB channels, outstanding-read flush, response-plus-flush, recycled
  physical/ROB tags, and load-access faults. Logs: `channels/run.log` and
  `load-channels/run.log` under the equivalence directory.
- Focused Verible lint and `git diff --check` passed. Parsed module-header tokens
  match the saved parameters/ports exactly. The final buffer code tokens also
  match the implementations used by the cycle-comparison tests.
- Full-core lint/elaboration and Spike differential checks passed for `lsu-wide`
  and `lsu-narrow`, with 116 committed instructions each. Both configurations also
  passed all four precise load/store access-fault and alignment-trap cases.
  This exercises the existing XML/VPI monitor against the separated data types
  without changing the monitor. Log: `build/lsu-organisation-core.log`.

These are simulation comparisons, not a formal equivalence proof. Synthesis,
place and route, and static timing analysis were not run; physical PPA and timing
have not been measured.


### Enum command conversion

The subsequent enum-only conversion passed `make check-lsu` and all 36
cycle-comparison runs against the saved action-record implementation. Logs:
`build/lsu-enum-regression.log` and `build/lsu-enum-equivalence/matrix.log`; saved
sources: `build/lsu-enum-before/`. Direct load/store channel comparisons also
passed, including resident `STORE_OP_SAVE_RS12`, simultaneous address/rs2 capture,
immediate responses, and flush/tag-reuse races. Their logs are under
`build/lsu-enum-equivalence/{load_buffer_channels_tb,store_buffer_channels_tb}/`.
Wide/narrow full-core lint and elaboration passed (`build/lsu-enum-core.log`),
as did focused Verible lint and whitespace checks. Interfaces and all code tokens
of the compared implementations match the final buffers. Full-core Spike
simulation, synthesis, and static timing were not rerun for this enum-only edit.


### Power-of-two buffer depths

`check_build` now accepts only positive power-of-two load/store buffer depths;
depth one remains valid. The configuration regression accepts defaults and
depth-one buffers, and rejects 0, 3, and 6 independently for each buffer. Log:
`build/lsu-power2-config.log`. The affected matrix and narrow-core fixtures now
use valid, unequal power-of-two depths instead of non-power-of-two depths.

`make check-lsu` passed (`build/lsu-power2-regression.log`). All 36 matrix
comparisons against the previous generic-wrap implementation passed, plus
width-eight/depth-one and width-eight/depth-two comparisons. Logs:
`build/lsu-power2-equivalence/{matrix,narrow-queues}.log`. Wide, narrow, and
depth-one full-core lint/elaboration passed (`build/lsu-power2-core.log`), as did
focused Verible lint and Python/shell syntax checks. The only changes within the
buffer modules are SQ pointer wrapping and the LQ's circular store-age formula.
Full-core simulation, synthesis, and static timing were not rerun for this change.


### Flat operands and state-local commands

Stored operands now use separate producer ROB indices and values; readiness is
encoded only in the existing four-bit SQ state register and the LQ state. The two
additional SQ states distinguish pending rs2 during address wait and address-fault
completion. All non-default `lb_op`/`sb_op` commands are selected inside their
`case (curr_state[i])` branches, including allocation and removal. The redundant
clear command and readiness-gated global wakeup selection are removed. SQ head
and tail increments use native index-width overflow; depth-one indices remain zero.
The Spike monitor uses flat operand fields and state-based readiness at address
response. Only the two buffer RTL modules and their affected verification files
changed.

Verification:

- `make check-lsu` passed, including a new unresolved-rs2 address-fault test with
  CDB backpressure and a late operand wakeup. Log: `build/lsu-flat-regression.log`.
- All 36 matrix comparisons against `build/lsu-flat-before/` passed, plus
  width-eight/depth-one and width-eight/depth-two cases. The comparison checks
  every output and every retained metadata field, mapping the two new SQ phases
  to the former address-wait/completed phases plus their stored rs2-ready bit.
  It also checks state-derived readiness against the independent old ready bits.
  Logs: `build/lsu-flat-equivalence/{matrix,narrow-queues}.log`.
- Direct store and load channel comparisons passed, including rs2 wakeup before
  a delayed address response, immediate responses, channel stalls, circular wrap,
  outstanding-write flush, killed-load responses, tag reuse, and load faults. Logs:
  `build/lsu-flat-equivalence/{store_buffer_channels_tb,load_buffer_channels_tb}/run.log`.
- Wide, narrow, and depth-one full-core Spike checks passed with 116 committed
  instructions each; all four precise access/alignment-trap checks passed in each
  configuration. Log: `build/lsu-flat-core.log`. This includes runtime XML/VPI
  observation of the flat data layout and state-based store readiness.
- Focused Verible lint and whitespace checks passed. Structural checks confirm
  no stored `op_data_t` operands, no `advance` function, and state-local selection
  of every non-default operation.

These are simulation comparisons, not formal equivalence. Synthesis and static
timing were not run; physical PPA and timing remain unmeasured.

### Saved SQ tail boundaries

Per-load decrementing older-store counts are replaced by the physical exclusive
tail boundary and sticky `older_stores_remain` flag described above. The SQ
exports its existing physical tail to the allocation logic. State encodings,
operation enums, state/data update blocks, external LSU ports, CDB channels, and
memory/ROB protocols are preserved.

Verification:

- `make check-lsu` passed: 36 LSU matrix runs, eight issue-offer configurations,
  three ROB precision configurations, ordering checks, and the killed-load
  regression with 10,000 randomized cycles. Log:
  `build/lsu-boundary-regression.log`.
- All 36 matrix comparisons against `build/lsu-boundary-before/` passed, plus
  width-eight/depth-one and width-eight/depth-two comparisons. The reference uses
  the unchanged previous counter implementation. Every external output, queue
  state, common LQ metadata field, and SQ metadata field is checked each cycle;
  each new boundary/flag pair is also checked against the reference older-store
  count. Logs: `build/lsu-boundary-equivalence/{matrix,narrow-queues}.log`.
- Wide, narrow, and depth-one full-core lint/elaboration and Spike simulation
  passed with 116 committed instructions each. All four precise access/alignment
  trap checks passed in each configuration. Log:
  `build/lsu-boundary-integration.log`.
- Focused Verible lint and whitespace checks passed. Log:
  `build/lsu-boundary-verible.log`.

These are simulation comparisons, not formal equivalence. Synthesis and static
timing were not run; physical PPA and timing remain unmeasured. The boundary
comparisons replace per-load decrementers, while relative-age arithmetic remains
for youngest-overlap priority.


### Configurable load address arbitration and head-relative store priority

`LDBUFF_RR_ARBITER` defaults to zero (fixed lowest-physical-index priority via
`prio_enc`). Setting it to one selects the existing `rr_arbiter_multi` with one
output. Only load address arbitration changes; allocation, memory selection,
result selection, interfaces, and dependency tracking remain unchanged. The flag
is propagated through the existing core/testbench elaboration overrides.

The SQ splits address-ready entries into `first_candidates` (physical index at
or above `head_idx`) and `second_candidates` (below `head_idx`). Two lowest-index
priority encoders feed a mux that prefers the first valid range. This selects
the oldest ready store across circular wraparound without preventing a younger
store from calculating its address when older base operands are unavailable.
Store data can remain pending during address calculation. Depth one bypasses the
encoders with index zero.

Address selection follows the live candidates; neither buffer holds an
unaccepted address request, and LQ round-robin mode has no held-candidate
snapshot. Both buffers always accept address responses, so the connected adders
do not introduce normal execution backpressure. The round-robin arbiter updates
acceptance bookkeeping only for accepted requests and clears its state on flush.
Memory-request and completion holding are unchanged. SQ write issue remains
restricted to its authorized head.

Focused verification:

- `bash scripts/sim/check-lsu-address-select.sh` passes for depths 1, 2, 4, and 8,
  with both LQ policies. It checks every nonempty SQ readiness subset at every
  head position, live reselection before acceptance, all four initial operand-ready
  combinations, immediate/delayed address response with simultaneous rs2 wakeup
  including faults, low-slot load reuse that distinguishes the policies, newly
  woken loads changing address selection before acceptance, and flush.
- The focused test fails against the pre-edit selector at SQ head 1: entry 0
  wins even though ready entry 1 is older. Evidence is in
  `build/lsu-address-selection/baseline.log`; passing directed results are in
  `build/lsu-no-address-hold/regression.log`.
- The current live-selection checks fail against the pre-removal buffers as
  expected: an old SQ retains younger slot 1 when older slot 0 becomes ready;
  an old LQ retains slot 1 when newly woken slot 0 should be selected. Negative
  evidence: `build/lsu-no-address-hold/{baseline,baseline-load}.log`.
- Before address-hold removal, full-core IW8/LQ8/SQ8 runs with buffered commit
  input passed in both policies:
  116 Spike-checked commits with no discrepancies and all four precise
  load/store access/alignment trap checks per policy. See
  `build/lsu-address-selection/core.log`.
- After address-hold removal, the wrapped `make check-lsu` compares the integrated
  LSU against its pre-removal implementation cycle by cycle during all 72 matrix
  simulations and the ordering/killed-load tests. The regression includes 12 existing
  configurations, both policies, and three seeds, eight issue-offer checks,
  eight focused address configurations, three ROB-precision configurations,
  ordering integration, and the 10,000-cycle killed-response regression.
  Aggregate log: `build/lsu-no-address-hold/regression.log`.
  All 93 checks passed, with no integrated output or queue-state/data differences.
- Configuration/elaboration checks pass for the default, depth-one, and both
  new-flag settings; unsupported buffer depths remain rejected. Additional
  round-robin ordering and killed-response tests (10,000 random cycles) pass.
  See `build/lsu-address-selection/{config,order-rr,killed-rr}.log`.

The broader legacy regression uses the previously adapted commit-guard fixtures
that enforce actual ROB-head store grants and finish an authorized noncancelable
write before flushing. The native new address-selection tests need no fixture
adaptation. Full-core checks reuse the existing build-only memory-monitor probe
adaptations. See `build/lsu-address-selection/README.md` for commands and scope.
No new full-core firmware run was made for the hold removal. Synthesis and static
timing were not run; arbitration PPA remains unmeasured.


### One-hot allocation routing and independent buffer issue widths

The former `queue_ready` and `allocate_queues` counter loops are replaced by the
same one-hot rank/masked-OR payload pattern used in `exec_stage`. Candidate
operation types determine ranks independently of valid/ready grants. Readiness
from each physical buffer is zero-extended to the common LSU width; the ordered
prefix reduction stops every younger lane after the first blocked candidate.
Payloads and accepted valids are sliced to the corresponding buffer issue width.
The mixed stream can use both quotas in one cycle, subject to its common width
and program-order prefix. Only the SQ receives rs2.

`LDBUFF_ISSUE_WIDTH` and `STBUFF_ISSUE_WIDTH` are independent user/build fields,
not queue depths. Unlike the depths, their values need not be powers of two.
Both default to one and `check_build` requires each in `1..LSU_ISSUE_WIDTH`.
Core and testbench override parameters use the corresponding package default.
Programmatic configurations and regression cases explicitly set both widths when
they require wider allocation. The allocation FIFO remains at the common
`LSU_ISSUE_WIDTH`, so buffering and bypass use the same output routing rules.

The store buffer owns the allocation-frontier arithmetic and exports:

- `issue_sq_tail_o[k]`: physical tail plus `k` with pointer wrap, for `k`
  from zero through the store-buffer issue width.
- `issue_older_stores_remain_o[k]`: whether resident stores survive a simultaneous
  head removal, or the specified prefix contains an accepted new store.

The LSU selects `k` by counting the stores before each load. An accepted load
can only follow accepted stores, so the exported boundary is independent of
store acceptance. The actual tail still advances by the LZC allocation count.
Depth one fixes all boundaries at zero and excludes the just-removed sole entry
from the resident-store flag.
A shared scalar resident flag avoids a packed-output self-reference in the
pinned full-core Verilator. There is no per-load store counter or new pipeline
stage. The LSU only one-hot selects these exported boundaries and flags.

Verification for this change:

- `bash scripts/sim/check-lsu-issue-route.sh`: 34 native configurations covering
  common issue widths 1/2/3/4/8, unequal local widths including three, FIFO and
  bypass, every mixed load/store bundle pattern, exact quota-limited acceptance,
  payload/ROB routing, per-load boundaries, full queues and flush. The oracle
  tracks the original stream and resident allocations independently of routing.
- `bash scripts/sim/check-lsu-address-select.sh`: all eight depth/policy
  configurations pass with independent checks of every exported store-prefix
  boundary. Includes simultaneous last-store removal/new-store acceptance and
  the depth-one no-allocation case, alongside existing address/forwarding tests.
- 108 redesign matrix simulations pass (18 configurations, both LQ address
  policies, three seeds). The 72 equal-width runs compare every public LSU output
  and all queue state/data cycle by cycle against the pre-change implementation;
  36 asymmetric runs use the independent architectural/dependency scoreboard.
  Twelve additional simulations cover common width eight with depth-one and
  depth-two queues and unequal allocation widths.
- ROB precision (three configurations), issue offers (eight configurations),
  ordering integration, and the 10,000-cycle killed-response regression pass.
  Configuration checks pass 42 cases, including both independent-width extremes
  and rejection of zero/above-common widths.
- Full-core IW8/LQ8/SQ8 runs pass for LB8/SB1 with bypass/priority and LB1/SB8
  with FIFO/round-robin, both with buffered commit input: 116 Spike-checked
  commits and all four precise access/alignment traps per configuration.

Evidence and commands are under `build/lsu-onehot-routing/`. The broader legacy
regression retains the previously adapted commit-guard fixtures, and full-core
checks retain the existing build-only memory-monitor probe adaptations; the new
native routing and boundary tests need no fixture adaptation. The interleaved
bundle test now waits for actual allocations and holds load completions while
checking the same exact boundaries, instead of assuming one FIFO-pop cycle.
Relevant Verible lint and shell/whitespace checks pass. Synthesis and static
timing were not run; the allocation combinational path remains unmeasured.
