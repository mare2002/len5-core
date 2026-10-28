# Standalone fetch_mem_if verification

## Current model contract — 2026-10-28

The C++ suite explicitly selects ordered cancel-on-flush, completion depth two.
The separate native SV target selects the source N and native completion depth
(currently 8 and 8), retaining canceled reservations until ordered stale responses
drain. The completion model reserves capacity through buffered completion and
uses independent transaction records; answer-spill storage is accounted separately.

FM-T34 now checks clean and faulting allocation/response on the same edge with
exact independently saved metadata; its association is no longer marked unknown.
The environment requires an accepted allocation, declared latency zero, matching
transaction identity and payload. Unsolicited/out-of-order/duplicate responses and
violations of a declared positive latency remain errors. Random memory traffic
continues using positive latency. Native drain checks also include zero latency.
These directed checks do not establish randomized native drain-mode coverage.

See the [cross-module change and scenario report](../MODEL_UPDATE_2026-10-28.md)
for validation receipts and problem dispositions. Production RTL is unchanged;
R12 is excluded. Current source selects N=8. Older audit-era configurations,
counts and alternative-policy results below are historical and are superseded
by this dated contract where they conflict. Build launchers exclude repository
`build/` from FuseSoC discovery even with a custom BUILD_DIR, preventing archived
core copies from overriding the live verification sources.


Native C++17/Verilator black-box verification of the real `fetch_mem_if`, including
its actual `completion_fifo`, `spill_cell_flush` and control dependencies.
The [specification](VERIFICATION.md) contains FM01–FM20, FM-T01–FM-T44,
FV01–FV22 and FQ01–FQ13. The model never reads internal DUT state or uses observed
outputs to initialize, synchronize or repair expected queues.

## Build and commands

Initialize the repository environment (initialize Conda first if necessary):

```sh
source private/init.sh
make fetch-mem-if-build
make check-fetch-mem-if-run
make check-fetch-mem-if-framework
make check-fetch-mem-if-random-framework
make check-fetch-mem-if-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-fetch-mem-if-mutations JOBS=2
```

`make check-fetch-mem-if` runs both `check-fetch-mem-if-cancel` and
`check-fetch-mem-if-drain` sequentially, including under `make -j`.

`make check-fetch-mem-if-cancel` builds once and runs all seven C++ groups concurrently:
directed, framework, random-framework, one random run, regression, mutations and
reused suite-orchestration tests. It prints `All tests passed` only if every group
succeeds; otherwise `Test failed` and nonzero status. Independent groups finish
after another fails. `TEST_JOBS` controls concurrent groups; `JOBS` controls seed
workers/mutation builds. Mutation compilation itself uses four compiler jobs per
worker, so choose JOBS according to available memory/CPUs.

| Target | Purpose |
| --- | --- |
| `fetch-mem-if-build` | Compile only the source-selected DUT and native harness. |
| `check-fetch-mem-if` | Aggregate cancel-on-flush C++ suite and native drain-on-flush SV checks. |
| `check-fetch-mem-if-cancel` | Complete parallel C++ verification suite; default regression 100×10000, required matrix enabled. |
| `check-fetch-mem-if-run` | All forty-four directed scenarios, or `SCENARIO=FM-Txx`. |
| `check-fetch-mem-if-framework` | Pure units, both profiles, native failure paths, log/replay/FST/configuration guards. |
| `check-fetch-mem-if-random` | One seeded weighted/guided random run. |
| `check-fetch-mem-if-random-framework` | Synthetic confidence, mathematical width coverage fixtures, public-journal reconstruction, random replay/failures/coverage-incomplete detection. |
| `check-fetch-mem-if-regression` | Parallel independent native processes and merged coverage/obligations/reports. |
| `check-fetch-mem-if-mutations` | Disposable RTL copies with original-before/after and source integrity checks. |
| `check-fetch-mem-if-drain` | Separate directed SV checks for native-memory drain-on-flush at the source-selected width and `FETCH_MEMIF_FIFO_DEPTH`. |

The `check-fetch-mem-if-cancel` C++ suite explicitly selects cancel-on-flush mode. The
`check-fetch-mem-if-drain` target checks retained full-queue credits, stale returns
under issue backpressure, repeated/returning-response flush collisions, exact
new-epoch metadata/payload/faults, current-answer consumption on an early flush,
and reset with buffered/outstanding work. It requires drain-on-flush, depth at
least four, request SKIP=1 and answer SKIP=0; incompatible source configurations
fail explicitly. It is a directed protocol subset, without randomized drain-mode
coverage or complete frontend early-jump integration sign-off.

Focused examples:

```sh
make check-fetch-mem-if-run SCENARIO=FM-T16 LOG_LEVEL=LOG_HIGH DUMP_WAVES=true
make check-fetch-mem-if-run SCENARIO=FM-T23
make check-fetch-mem-if-run FETCH_MEM_CONTRACT=established
make check-fetch-mem-if-random SEED=17 CYCLES=4096 CAMPAIGN=architectural
make check-fetch-mem-if-random SEED=18 CYCLES=10000 CAMPAIGN=stress GUIDED=false
make check-fetch-mem-if-random SEED=7 CYCLES=10000 \
  WEIGHTS=request=80,response=90,grant=75,ready=65,error=40,flush=3,reset=1
```

Options follow pc_gen/EJU: SEED/SEEDS/CYCLES/MAX_CYCLES/SCENARIO/CAMPAIGN,
JOBS/TEST_JOBS, LOG_LEVEL, DUMP_WAVES, FETCH_MEM_CONTRACT, GUIDED, WEIGHTS,
JOURNAL, REQUIRE_MATRIX, BUILD_DIR, FUSESOC and VERILATOR. Campaign is
`all|architectural|stress|characterization`; journal is `auto|full|failures`.
Use named LOG_NONE/LOW/MEDIUM/HIGH/FULL/DEBUG levels. The aggregate always runs
all directed cases. Shortened seed/cycle settings are shortened validation,
not the default million-cycle regression. No firmware, Spike, Cocotb or new
runtime dependency is needed. Do not run repository `make check` for this task;
that unrelated target formats production RTL.

## Configuration and build integrity

The sole N selector is production `rtl/packages/len5_config_pkg.sv`.
N=1/2/4/8 is supported by source-derived loops, masks, adapter dimensions and
coverage denominators; only the active value is compiled. No width sweep or
source editing is performed by these targets. Mathematical all-N units are not
claimed as four RTL executions.

Current supported transport profile: XLEN=ALEN=64, ILEN=32, cause width5,
metadata depth 2, request SKIP=1 and answer SKIP=0. `configuration.py` directly
reuses pc_gen's literal/width parser, reads both switches and the actual production
`MAX_MEM_OUTSTANDING_REQUESTS` default, then binds the adapter depth to that value.
Unsupported depth/switch combinations fail clearly under FQ08. They are not
silently treated as the current timing profile. There is no BOOT_PC parameter.

Build roots are:

`build/fetch-mem-if/model/issues-<N>-depth-<D>-<SHA256>/`

The fingerprint includes all production package/module/cell/counter sources,
compiled harness headers/sources, adapter/core/waivers, reused helpers/encoders,
logger, configuration parser and shell helper. Sources changing during a build
are rejected. Source snapshots and `fetch_mem_build.cfg` remain beside the binary;
native startup compares those snapshots and independently parsed constants against
elaborated public static outputs. Stale/missing metadata or incompatible replay
returns exit2. Keep snapshots and original source available when copying a binary.
Per-model locks serialize setup, and FuseSoC exports dependencies into isolated
builds to avoid the source-path alias found by the earlier EJU audit.

## Protocol and independent model

There are separate public handshakes:

- Request accepted: `instr_valid_o && instr_ready_i`.
- Response accepted: `instr_valid_i && instr_ready_o`.
- Output bundle consumed: `issue_valid_o && issue_ready_i`.

With the active request bypass, fetch-side acceptance coincides with memory
acceptance. A partial bundle sends the aligned **lane0** PC to memory; its saved
valid mask identifies the actual starting lane. Current BPU metadata can change
before grant, but the accepting-edge snapshot is frozen for each outstanding ID.
Multiple NT/T/miss records and targets are transported without interpretation.

The pure C++ model owns an outstanding-request queue and a separate answer queue.
It predicts channel readiness/validity from the documented named timing contract,
not DUT outputs. R associates with the oldest prior request; K appends a new
request; D consumes the old buffered head. Same-edge K/R/D can represent three
different transaction identities. The two-entry answer buffer has registered
outputs and no full-state ready lookahead. These spill timing assumptions remain I,
including the reset-release interval; they are not promoted to architectural D.

The memory environment separately tracks physical requests, payloads, latency,
held responses and cancellation. Architectural traffic is ordered, positive
latency and capacity-limited to two outstanding requests. The original emulator's
full-memory grant is conservative; stress additionally allows explicitly tagged
capacity-preserving simultaneous full-q response/request turnover. Responses are
never generated for nonexistent architectural requests, swapped, duplicated,
changed while held, or revived after cancellation.

Expected state advances using independently predicted handshakes. Actual handshakes
are separately monitored for exercised coverage. A divergence in physical channel
controls stops the dependent episode after preserving diagnostics; it does not
repair the model or fabricate physical responses. Data mismatches preserve exact
known comparisons. The environment and oracle have no DUT handle/Outputs argument.

Every accepted request has an explicit lifecycle represented by its independent ID
in the outstanding/answer queues and cumulative acceptance/response/delivery/
cancellation counters. At completion:

`accepted = delivered + canceled + pending`

A delivered response cannot also be canceled. Early flush consumes its old answer
before younger cancellation; resets cancel once rather than once per held reset
sample. Counters retain originating campaign identity. Pending requests produce
incomplete/nonzero results, even if no output mismatch occurred. Full public
journals allow an independent Python checker to reconstruct actual queues,
metadata, lane errors and handshake coverage without reading C++ expected values.

## Exceptions, cancellation and unresolved protocols

The real interface has **per-lane flags and 5-bit causes**. Supplied instruction
access faults (code1), misalignment (code0 with raised1), mixed fault/clean lanes,
masked faults and error/clean transitions are checked exactly where meaningful.
A fault response completes one request and is buffered with its saved PC/mask/
predictions. Instruction bits on a faulting lane and unused cause fields are
checked only under the separate raw-transport I policy. The physical memory
scheduler owns fault assignment; the DUT does not detect access permissions or
instruction legality.

“Fault address” at this boundary means the correct **saved lane prediction PC**.
There is no fault-address or mtval output. Page/unknown/raw cause values can be
transport stress; no active instruction translation/page-fault detector is claimed.

Architectural flush atomically cancels the environment's physical pending work as
well as DUT queue obligations. Early flush can transfer the current correction
bundle before clearing younger requests/answers. Branch/exception recovery withdraws
downstream readiness. A new-epoch clean response must not inherit any canceled
prediction, data or fault status.

The following remain explicit characterization, never default definitive failures:

| Question | Implemented observation policy |
| --- | --- |
| FQ02 grant-on-flush | Raw overlap recorded; no invented retained request identity. Reset before normal traffic resumes. |
| FQ03 zero-latency completion | FM-T34 now checks accepted allocation plus its own response with exact association; native drain directed test also checks it. |
| FQ04 late noncancelable response | Old physical data/fault can be offered after cancellation; observation records any downstream valid/error. No fictitious stale-response filter is assumed. |

Both profiles preserve all FQ01–FQ13 in reports. `integrated` checks raw-record
preservation as explicit I for otherwise unused fields. `established` leaves those
unused/faulting-word fields don't-care while retaining relevant flags/causes,
metadata and exact supplied clean data. Both use the same explicit current spill
and memory timing assumptions; `established` is not an assertion that all timing
questions are approved. Unknown associations cannot be repaired from outputs.
A coordinated reset restores independent knowledge between malformed episodes.

Standalone success does not verify memory fault detection, mtval generation,
actual trap/CSR/retirement behavior, or the EJU audit's full-core exception-recovery
window. No full-core test is instantiated here.

## Scenarios, randomization and coverage

All FM-T01–FM-T44 are implemented in `fetch_mem_directed.cpp`, following the
specification's catalog: reset/idle, grant stalls, every start lane and prediction
pair, multiple outstanding snapshots, same-edge K/R/D, FIFO wrap, full answer
stall/release, delayed metadata, lane faults/cause0, fault/clean transitions,
held errors, all recovery types, early-head delivery, epoch reuse, encoded/raw
payloads, address boundaries, stopped-clock probes, and FQ02/03/04/malformed cases.
Characterization completion means known checks passed and unknown behavior was
recorded; it does not approve the characterized protocol.

`fetch-mem-if-v1` uses separate splitmix64-seeded mt19937_64 streams for event,
payload and latency choices. Percent weights govern request creation, response
availability, grant/consumer readiness, errors, flush and reset. Multi-cycle grant,
response-gap and consumer-stall bursts and latencies up to forty cycles create
causal histories. Accepted templates remain immutable while newer predictions
change. Real instruction words reuse EJU's independent generator, including JAL,
JALR, branches, arithmetic, memory/system/FP families, near misses and raw bits;
the memory oracle never treats them as EJU operations.

Architectural, stress and characterization rotate in 512-cycle windows in `all`.
Recovery/reset closes old obligations at boundaries; sequence/stall bins do not
bridge unrelated windows. Final 128 cycles are a fair drain with no new requests;
any already-held candidate is accepted before draining, not silently withdrawn.
Very short runs can end with incomplete evidence. Guidance selects bounded legal
queue-preparation episodes using coverage deficits, including full buffers,
all eight K/R/D rows, early-flush cancellation and underrepresented starting lanes.
Guidance can boost a low/zero-weight feasible goal; weights are probabilities,
not hard exclusions. `GUIDED=false` provides an unassisted comparison.

FV01–FV22 instrumentation records sampled offers/stalls, actual handshakes, latency,
queue boundary classes, prediction pairs/masks, starts, matched per-lane metadata,
fault lane/cause, error sequences, flush/fault overlap, epoch transitions, raw stale
response observations, reset occupancy, instruction classes, address categories
and completed/canceled/pending obligations. Required matrix closure covers eight
normal K/R/D rows per selected campaign. Feature goals and unresolved/temporal
scope remain separate; complete matrix coverage is not exhaustive verification.
There are no nonexistent-lane goals or architectural stale/zero-latency goals.
Pre-edge observations are committed to handshake coverage only after the consuming
edge occurs; a control-mismatch abort cannot credit an unclocked transaction.
Independent public-journal reconstruction verifies all matrix rows and the
occupancy/K/R, error/flush/outstanding, and hit-mask/latency/matched-metadata crosses.
Latency in the metadata cross is memory response latency, separate from delivery
age. Matched-word bins require an observed word equal to its known expectation.

## Reuse, source organization and confidence

Unchanged components reused directly: shared TbLogger/macros and core, pc_gen
Field/Campaign/hex/JSON helpers and literal parser, EJU instruction encoders, and
EJU orchestration self-tests. Driver/scoreboard/CLI, deterministic streams,
configuration manifests, shell isolation, Python validators, regression/suite and
mutation orchestration adapt existing pc_gen/EJU patterns. Their behavioral models
are not instantiated or changed.

New module files are the public adapter/core/waivers, `fetch_mem_model.*`,
`fetch_mem_environment.*`, `fetch_mem_driver.*`, `fetch_mem_scoreboard.*`,
`fetch_mem_directed.*`, `fetch_mem_random.*`, native CLI/configuration auditor,
pure units/confidence fixtures and module-specific Python/build helpers.

Confidence validation includes independent queue fixtures for all mathematical N,
cause-zero errors, simultaneous old/new association, full/empty timing, early-head
flush accounting, unknown association/reset, and rejected orphan/duplicate/
out-of-order/zero-latency/overcapacity/held-payload histories. Separate synthetic
scoreboard cases preserve provisional unverified-context diagnostics and definitive
independent checks with unrelated unknown state. Monitor injections test control,
word, saved PC/target/mask, flags and causes; they are not RTL mutation coverage.

Disposable mutation tests change actual module/common-cell source copies. Targets
include current-versus-saved metadata, mask association, pop-on-offer, dropped/
delayed errors, cause0 corruption, wrong saved fault PC, lane swaps, lost responses,
missing answer/metadata flush, flush-ready, request address and read-only violations.
Each must compile, execute meaningful checks and fail with a recorded requirement.
Compile failures and equivalent N=1 lane swaps are not killed mutants. Original
before/after runs and production hashes are checked. Mutant manifests retain
production source audits plus explicit compiled-variant hashes in their evidence;
read mutant reports together with the mutation summary.

## Reports and replay

Runs use unique directories under `build/fetch-mem-if/{run,validation,regression,
mutation,suite}/`. A native run stores console.log and logs/report.json,
coverage.json, samples.jsonl, characterization.jsonl and optional waves.fst.
Normal random journals are bounded failure histories; use JOURNAL=full for
independent reconstruction/replay. Detailed discrepancy storage is bounded while
total counts retain every mismatch.

TbLogger formatting/colors/verbosity, context timestamps, explicit cycle/phase,
REQ/RSP/SCB, zero-padded 64-bit addresses and module summary strings are retained:

`TEST SUCCEEDED > errors: <failed checked records>/<checked records>`

`TEST FAILED > errors: <failed checked records>/<checked records>`

Each completed scenario/group prints `Test successfully passed` or `Test failed`.
At LOG_NONE successful log messages are gated as in the existing logger; errors
and configuration remain visible. Reports distinguish sampled records, checked
transactions, field comparisons and lifecycle counters.

Native status0 means selected known checks passed and obligations closed;1 is a
confirmed/provisional/injected mismatch;2 is environment/configuration/framework
failure;3 is empty/incomplete/timeout. Validators pass intentional failures only
when the expected nonzero status and diagnostics are verified. Coverage-incomplete
regressions fail separately from DUT mismatch.

Copy the exact `replay_command` from report.json, replacing NEW_REPLAY_DIRECTORY.
After building, a manual example is:

```sh
binary=$(python3 tb/frontend/fetch_mem_if/configuration.py --binary)
"$binary" --random --seed=17 --cycles=4096 --max_cycles=4096 \
  --campaign=all --contract=integrated --guided=true --journal=full \
  --log_level=LOG_HIGH --dump_waves=true --run_dir=build/fetch-mem-if/replay/new-run
```

Recorded commands include N/depth compatibility guards and exact weights/policy.
A mismatch log includes FM/FQ provenance, scenario/seed/configuration, cycle/tick/
phase, transaction IDs/epochs, active events, expected/actual fields and recent
stimuli. Public-control failures stop the physical episode rather than causing
invalid dependent responses. Repeating the same run must preserve full journal
SHA256 and the first injected failure, irrespective of waves/log level.

## Validation record

Validation on 2026-10-15 used the source-selected **N=4**, bundle 16 bytes,
metadata depth 2, request bypass and registered answer profile. Only this RTL
configuration was compiled. Pure model/coverage fixtures exercised N=1/2/4/8.

The final aggregate command was:

```sh
make check-fetch-mem-if JOBS=4 TEST_JOBS=3 SEEDS=100 CYCLES=10000 \
  REQUIRE_MATRIX=true LOG_LEVEL=LOG_LOW
```

Evidence root: `build/fetch-mem-if/suite/all-x6lpnaum/`. The machine-readable
artifact index is `build/fetch-mem-if/validation-summary.json`; full console output
is `build/fetch-mem-if/final-validation.log`.

| Validation | Result |
| --- | --- |
| FM-T01–FM-T44, integrated | 40 scenarios, 1180 cycles, 76,519 field comparisons; zero mismatches, zero pending obligations. |
| Established profile directed run | 66,059 comparisons; zero mismatches; relevant cause-zero and metadata checks retained. |
| Independent model/environment units | 8310 checks passed, including all four mathematical widths. |
| Native framework | 19 cases and four build/replay guards passed, including nine injected field failures, invalid environment, framework failure, empty/incomplete/timeout and quiet logging. |
| Random framework | 14 cases, including ten successful 4096-cycle runs (40,960 cycles, 2,225,101 comparisons), two reproducible injected failures and two rejected invalid runs; three synthetic confidence cases and four width fixtures passed. |
| Full regression | Seeds 1–100 ×10,000 cycles =1,000,000 cycles; 58,174,622 field comparisons; zero confirmed/provisional mismatches or environment/framework errors. |
| Coverage reconstruction | 24 campaign matrix bins and 159 observed cross bins independently recounted from public journals. |
| Replay/waves | Full journals identical with FST enabled; repeated injected failure has identical first discrepancy and journal SHA256. |
| Existing framework preservation | pc_gen T01 (46 comparisons) and EJU EJ-T01 (114 comparisons) passed; existing verification sources unchanged. |

Regression obligations: **118,642 accepted =66,423 delivered +52,219 canceled**;
**zero pending**. There were 85,680 normal memory responses, 33,843 error-flagged
response accepts (including masked/raw flags), 22,810 relevant fault deliveries and
6644 buffered-fault cancellations. The 1078 ambiguous completions belong to explicit
characterization, not confirmed faults or completed normal transaction identities.

Each of architectural/interface-stress/characterization achieved **8/8 required
K/R/D rows and 39/39 feature goals**, with no declared goal gaps. The default
regression made 11,770 guided choices. At seed 17/4096 cycles, guided execution hit
39/39 goals in every campaign versus 38/39 unguided. Observed FV crosses, reset
occupancy combinations, error histories and temporal counters remain available
separately. The declared marginal goals do not demand every proposed Cartesian
cross, every possible latency/cause/address or exhaustive FV/sign-off coverage.

Mutation results are indexed beside the regression results. All 16 applicable
mutations compiled and were detected; no surviving or unexecuted mutant is counted
as detected. Ten produced at least one definitive transport/readonly mismatch;
six were detected only against explicit provisional timing/request contracts:
`lost-error-response`, `missing-answer-flush`, `ready-on-flush`, `ready-on-full`,
`duplicate-answer`, `wrong-request-address`. These are checker sensitivity results,
not evidence that those inferred contracts have been approved. Original before/
after journals matched and production source hashes remained unchanged.

No active-contract RTL defect was observed. FQ01–FQ13 remain explicit. FQ04
characterization shows that a noncancelable late fault can be presented as valid
without a stale-response discriminator; this does not contradict the selected
coordinated-cancellation contract. FQ02/03 association remains unknown. Spill timing,
reset release, unused raw-field preservation and external flush coordination retain
their I/Q status. Neither profile implements the specification's complete future
set-valued timing oracle. Depth/switch profiles beyond depth 2/req-bypass/registered-
answer are rejected rather than silently modeled. There is no claim about mtval,
memory permission checking, or full-core exception recovery.

Bring-up evidence includes the fixed unused-lane randomization error, semantic-ID
reuse rejection, unverified-context scoreboard classification, and pre-edge-only
coverage credit bug; §23 of the specification records the before-fix artifacts.
Their failing runs are retained and excluded from successful DUT regression totals.
All 313 protected RTL and pre-existing pc_gen/EJU files match their initial hashes.
No production RTL or configuration was modified.

On this machine the final million-cycle regression took 40.4 seconds with four
seed workers while other suite groups ran concurrently. The complete seven-group
suite took 140.2 seconds after the primary build, dominated by 16 disposable mutant
compilations/runs (131.4 seconds). These times are workload measurements, not a
performance guarantee. Normal random logs omit per-cycle formatting; full journals,
verbose logs and FST intentionally add overhead.
