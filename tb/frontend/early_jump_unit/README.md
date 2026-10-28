# Standalone early_jump_unit and RAS verification

## Current model contract — 2026-10-28

R09: a nonempty RAS corrects RET only when the saved prediction is not a
taken BTB hit matching the independently known RAS top. Suppression preserves
metadata and does not suppress the accepted RET pop. EJ-T14 checks every active
lane and hit/taken/equality combination, stalls, and subsequent stack witnesses.

R11/EQ07 is approved D: qualified surviving confirmation updates abstract C before
restoring P; offered speculative work on that flush edge is canceled. Both model
profiles retain this rule. `RAS_ORDER=updated` is the sole supported ordering;
`previous` and `unknown` now fail configuration validation (exit 2). EJ-T20 and
the old-state-restoration mutation retain independent recovery checks. Exception
history survival EQ08 remains unresolved.

See the [cross-module change and scenario report](../MODEL_UPDATE_2026-10-28.md)
for validation receipts and problem dispositions. Production RTL is unchanged;
R12 is excluded. Current source selects N=8. Older audit-era configurations,
counts and alternative-policy results below are historical and are superseded
by this dated contract where they conflict. Build launchers exclude repository
`build/` from FuseSoC discovery even with a custom BUILD_DIR, preventing archived
core copies from overriding the live verification sources.


Native C++17/Verilator verification of `early_jump_unit` **with its actual instantiated
`ras`**. The independent [specification](VERIFICATION.md) defines the boundary and
requirement provenance. Production sources, configuration and pc_gen verification
are unchanged by this implementation. This is a standalone module test, not a
frontend/processor integration test.

## Commands

Initialize your Conda shell if necessary, then:

```sh
source private/init.sh
make check-early-jump JOBS=2 TEST_JOBS=4 LOG_LEVEL=LOG_LOW
```

The aggregate builds the selected DUT once, runs all verification groups in
parallel, retains each group's log, and prints `All tests passed` only when every
group succeeds. Otherwise it prints `Test failed` and returns nonzero. Independent
groups finish even if another fails. Mutation compilation takes much longer than
native simulation; `TEST_JOBS` controls concurrent groups, `JOBS` controls parallel
regression seeds/mutation builds. Each mutation's C++ compilation uses four jobs,
so reduce JOBS on machines with limited CPU/memory.

| Target | Action |
| --- | --- |
| `early-jump-build` | Source-fingerprinted FuseSoC/Verilator build only. |
| `check-early-jump` | Directed, framework units, random confidence/replay/coverage validation, random run, 100-seed regression, mutations and orchestration self-tests. |
| `check-early-jump-run` | Directed EJ-T01–EJ-T34, or one `SCENARIO`. |
| `check-early-jump-framework` | Independent encoder/model/environment units; directed profiles, ten monitor injections, logger, FST/replay, alternative hypotheses and stale/replay guards. |
| `check-early-jump-random` | One seed, default 10000 cycles, all three campaigns. |
| `check-early-jump-random-framework` | Synthetic confidence checks, four mathematical width fixtures, random replay, coverage reconstruction, held response and causal timing checks, injections and incomplete-coverage detection. |
| `check-early-jump-regression` | Parallel isolated seeded processes with combined coverage/report. |
| `check-early-jump-mutations` | Compile disposable EJU/RAS mutations and verify detection plus original before/after. |

```sh
make check-early-jump-run SCENARIO=EJ-T09 SEED=7 LOG_LEVEL=LOG_HIGH DUMP_WAVES=true
make check-early-jump-run EARLY_JUMP_CONTRACT=established
make check-early-jump-random SEED=17 CYCLES=10000 CAMPAIGN=architectural
make check-early-jump-framework
make check-early-jump-random-framework
make check-early-jump-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-early-jump-mutations JOBS=2
```

Configuration options follow pc_gen: `SEED`, `SEEDS`, `CYCLES`, `MAX_CYCLES`,
`SCENARIO`, `CAMPAIGN=all|architectural|stress|characterization`, `JOBS`, `TEST_JOBS`,
`LOG_LEVEL`, `DUMP_WAVES`, `BUILD_DIR`, `FUSESOC`, `VERILATOR`,
`EARLY_JUMP_CONTRACT=len5_minimal|established`, `GUIDED=true|false`,
`JOURNAL=auto|full|failures`, `REQUIRE_MATRIX=true|false`, `INJECT_FAILURE`.
The aggregate always runs all directed scenarios. Its default is 100 seeds ×
10000 cycles with required combination coverage. Individual regression coverage
is enforced when `REQUIRE_MATRIX=true`; feature gaps are reported separately.

Instruction weights: `ordinary`, `call`, `jump`, `return`, `branch` are relative
weights. `confirm`, `restore`, `stall`, `reset` are percentages (0–100).
A default normalized configuration is stored in every random report. For example:

```sh
make check-early-jump-random SEED=17 CYCLES=4096 \
  WEIGHTS=ordinary=50,call=20,jump=10,return=20,branch=15,confirm=40,restore=12,stall=35,reset=2
```

Named assumption overrides remain `RAS_EXCEPTION=restore|unknown`,
`RAS_BOUNDARIES=recent|unknown`, and `EARLY_LIFECYCLE=held|unknown`.
`RAS_ORDER=updated` names the approved EQ07 rule; previous/unknown order settings
are rejected. They cannot disable an approved comparison. These options do not
change configuration or the approved recognition/RET suppression policies.

## Configuration and build integrity

`rtl/packages/len5_config_pkg.sv` is the sole issue-width/RAS-depth source.
Supported issue widths are 1, 2, 4, 8; the current RAS contract supports depth 4.
The framework does not edit that source, sweep configurations, or accept a second
width selector. The wrapper exposes elaborated static constants; startup compares
them to independently parsed production-source metadata before constructing the
model. Unsupported values, stale sources, missing metadata or elaboration
mismatch are build/configuration failures (exit 2).

`configuration.py` imports pc_gen's existing literal/configuration parser and
adds RAS_DEPTH. It fingerprints packages, the real EJU/RAS/priority encoder,
compiled C++/headers, wrappers/core/waivers, shared logger/helper dependencies and
build helper. Builds live in:

`build/early-jump/model/issues-<N>-ras-<depth>-<SHA256>/`

Changing a compiled source selects a new build root. A per-root lock prevents
concurrent setup; source changes during compilation are rejected. Exact source
snapshots and metadata remain beside the executable and are audited at startup.
Keep them with copied binaries. Use the supported build helper before native
execution; bare FuseSoC setup does not create the audit metadata.

No BOOT_PC parameter exists on this DUT. Bundle PCs are explicit randomized input
metadata; every lane uses the selected bundle width. N=1 uses the RTL's genuine
single-lane elaboration, without zero-width wrapper vectors. Four pure model and
coverage fixtures check width arithmetic; only the currently selected N is built.

## Reuse and independent model

The implementation adapts pc_gen's driver phases, per-field scoreboard/provenance,
bounded history, seeded split streams, coverage, Python regression/suite/mutation
orchestration and source fingerprinting. It directly reuses unchanged
`tb/verilator/tb_macros.hh/.cpp`, `verilator-common`, pc_gen's `Field`, `Campaign`,
hex/JSON helpers and production-constant parser. Linking `pc_gen_model.cpp`
provides these utilities; **the EJU oracle never instantiates pc_gen's PC model**.
No working pc_gen files are refactored or changed.

New module-specific components:

| Files | Responsibility |
| --- | --- |
| `early_jump_instructions.*` | Independent actual 32-bit instruction encoder/decoder and branch/JAL/JALR execution-context calculation. |
| `early_jump_model.*` | Public-interface output contract and separate abstract predictive/confirmed histories. |
| `early_jump_environment.*` | Saved request/response metadata, held transactions, accepted instruction IDs, delayed ordered confirmations and recovery epochs. |
| `early_jump_driver.*`, `early_jump_tb.sv` | Public-port snapshots, static configuration audit, input readback, asynchronous reset and clock phases. |
| `early_jump_scoreboard.*` | Exact qualified output comparisons, causal diagnostics, confidence, coverage and JSON. |
| `early_jump_directed.*`, `early_jump_random.*` | EJ-T01–34 and weighted/guided encoded bundle episodes. |
| `*_unit.cpp`, `validate*.py` | Independent model/environment and synthetic confidence/coverage checks. |
| `regress.py`, `suite*.py`, `mutate.py` | Adapted isolated regression, parallel suite and disposable mutation audit. |
| `configuration.py`, `.core`, `.vlt`, build helper | Configuration-aware selected-source build. |

JAL immediate bits are independently assembled and sign-extended. Fixed known
instruction words supplement encoder/decoder round trips. **JAL x1** is the only
call/push; other JAL destinations (including x5) do not push. Only exact
`0x00008067` is a return/pop; all other JALR forms have no early RAS effect. The
ordinary generator includes register/immediate/word arithmetic, loads/stores,
LUI/AUIPC, FENCE, CSR, multiply/divide and FADD.S/D with randomized registers and
operands. It is a decoder/generator for these classes, not a full execution/CSR/FP
simulator. Characterization includes raw unsupported words and near misses.

For N instructions, the environment calculates the bundle interval mathematically.
The start lane comes from the requested PC; the first eligible **hit AND taken**
prediction ends the validity interval inclusively. A valid not-taken hit leaves
later lanes reachable. A miss with taken=1 stays distinct from hit/not-taken.
Only the oldest eligible recognized JAL/canonical RET supplies the correction and
at most one speculative RAS operation; younger words remain excluded. Saved raw
metadata for all lanes is retained, even when an earlier prediction cuts the mask.
These selection/qualification contracts retain their documented I provenance.

RAS history is an abstract sequence of independent return addresses and origin
IDs, not copied RTL arrays/pointers. Predictive operations require the declared
accepted-response contract; confirmed operations are separate qualified BU pulses.
A branch misprediction restores predictive history from confirmed history.
Same-edge confirm/restore ordering, overflow, exception recovery and held-offer
lifetime are named assumptions. The `established` profile marks state/fields
unknown where those unresolved transitions require it; an independently justified
reset/restoration/known suffix can establish knowledge. DUT observations never
initialize, repair or synchronize either history.

Temporal return probes/draining returns expose past push/pop/restore errors.
A supplemental D no-RAS-effect invariant compares a later independently expected
top (or empty status) with an earlier **matched** independent witness after ordinary
or excluded instructions. Unverified/divergent prior context cannot create a
secondary definitive diagnosis. Exact model comparisons remain active regardless.

## Phases, campaigns and coverage

The driver drives all inputs with clock low, evaluates/samples pre-edge, calculates
model/environment transitions, advances the rising edge, evaluates/samples post,
and samples the falling phase. Separate snapshots prevent edge races. Stopped-clock
probes demonstrate combinational timing and async reset without consuming events.
Verilator ticks are simulation timestamps, not a physical setup/hold measurement.

Architectural traffic registers independent memory requests/delays, preserves saved
lane PCs/words/predictions/masks while stalled, accepts instruction IDs once,
orders mature nonfaulting confirmations, and cancels younger histories on recovery.
Branch operand outcomes respect x0 and are decoded independently. Correctly
predicted calls/returns can confirm; a mature misprediction supplies a recovery ID.
Architectural fetch addresses are randomized legal stimulus at this standalone
boundary: this environment is not a PC-generator/processor execution simulator.
The current architectural scheduler confirms before recovery, excluding F+confirm
from its denominator. Those pin overlaps are covered in interface stress.

Stress covers raw simultaneous scalar confirmations/recovery and frontend operations,
conflicting targets and long stable holds without claiming backend reachability.
Characterization additionally allows both confirm bits, raw words/addresses, holey
masks, held-metadata changes and arbitrary feedback. Unknown fields are observed,
not automatically passed. An early flush output does not restore RAS; external F
and generated memory flush are separate events.

Unlike changing the BPU prediction for pc_gen's current stalled request, an EJU
**buffered response** carries saved prediction metadata. Changes to that response
while stalled are malformed characterization, not normal architectural traffic.

Separate campaign coverage contains sampled instruction-class × lane × four-state
prediction crosses, observed hit/taken/jump masks × selected lane, lane/start masks,
matched corrections, accepted RAS operations, predictive/confirmed depth/divergence,
restoration and later-return witnesses, confirmation/stall overlaps, stalls/lengths,
consecutive events, reset/release, signed immediates and address boundary classes.
No internal depth is observed: depth bins label independent expected history, and
later return witnesses provide the externally checked evidence. A complete depth
bin alone does not prove all hidden entries.

Each campaign has 18 semantic offered-operation × confirmation × flush rows.
Architectural excludes its six same-edge confirmation/recovery rows, requiring
12; stress and characterization require 18. Producer-illegal double confirms are
recorded separately. Coverage reflects actual pre-edge samples; matched outcomes
are counted only after comparisons. Four pure N fixtures and journal reconstruction
validate counters. Sparse observed crosses are not an enormous Cartesian sign-off
claim. Coverage goals exclude nonexistent lanes and architectural ordinary taken-hit
metadata (unproven stale-BPU producer behavior); stress keeps those bins.

Guidance increases underrepresented class/lane/prediction and stress matrix choices,
using deterministic coverage of sampled inputs, never DUT outputs for golden state.
Three splitmix64-seeded mt19937_64 streams separate events, payloads and latency.
All campaigns rotate in 256-cycle windows with reset between categories; one-campaign
runs are available. Same seed/config/policy/options deterministically replay.

## Reports and debugging

Native runs are isolated under `build/early-jump/run/`; regression, validation,
mutation and suite roots use private temporary directories. Each native run has:

- `console.log`: existing LEN5 TbLogger formatting, colors, CONFIG, REQ/RSP/SCB,
  timestamps, `TEST SUCCEEDED > errors: <errors>/<transactions>` or `TEST FAILED`.
- `logs/report.json`: configuration/fingerprint, profiles, seeds, executed cycles,
  sampled records/transactions/field comparisons, confidence/error classes,
  assumptions, unresolved EQs, bounded discrepancy details and replay command.
- `logs/coverage.json`: per-campaign observed/matched bins, required rows, exclusions
  and feature goals. Aggregated `summary.json` lists remaining gaps.
- `logs/samples.jsonl`: full directed journal by default; random full journal on
  request, otherwise bounded history only on mismatch.
- `logs/characterization.jsonl`: counted observations with representative input,
  expected-known status and actual output snapshots.
- `logs/waves.fst`: optional public-boundary waveform, depth 1.

Addresses are zero-padded 64-bit hexadecimal. Failure reports include scenario,
requirement/classification/assumptions, seed, cycle/timestamp/phase, active inputs,
selected lane, prior independent P/C origin history, expected/actual output and
recent eight samples. Detailed discrepancy records are bounded at 256; total
counters retain all failures. Ordinary random logs remain concise.

Exit 0 means successful meaningful checks under the reported contracts; 1 means
confirmed/provisional/injected comparison mismatch; 2 means environment/framework/
configuration failure; 3 means empty/incomplete/timeout. Regression required coverage
failure returns 1 with `status=incomplete` and zero DUT mismatches. A validator can
pass a deliberate negative case because it expected and verified a nonzero exit.
That does not make a real DUT mismatch pass.

For replay, copy `replay_command` from report.json, choose a new run directory,
and retain its complete policy/weights/configuration guards:

```sh
binary=$(python3 tb/frontend/early_jump_unit/configuration.py --binary)
"$binary" --random --seed=17 --cycles=10000 --max_cycles=10000 \
  --campaign=all --contract=len5_minimal --guided=true --journal=full \
  --log_level=LOG_HIGH --dump_waves=true --run_dir=build/early-jump/replay/new-run
```

Recorded replay commands additionally enforce `--expect_issues` and
`--expect_ras_depth`. These are compatibility guards, not selectors. Replaying a
source/configuration change requires the compatible build; stale binaries fail.
The stimulus digest covers pre-edge public inputs and causal execution context;
the validator also compares complete sampled-journal SHA256 and first-fault history.

## Validation evidence and remaining scope

Validated with source-selected **N=2, RAS_DEPTH=4**: all 34 directed scenarios,
16,832 independent checks, 21 framework cases, 15 random validation cases and
three confidence fixtures pass. Three 100-seed regressions total 3,000,000 cycles
and 52,286,987 comparisons with zero baseline mismatches. All declared campaign
coverage goals are exercised. Fourteen distinct disposable mutations were detected
(twelve in the aggregate audit plus two focused policy mutations), with no survivors.
The aggregate target passed 7/7 groups; subsequent focused unit/mutation checks
also passed. Historical alternative EQ07 `previous` runs recorded provisional failures.

The implementation validation record is appended to [VERIFICATION.md §25](VERIFICATION.md#25-implementation-and-validation-record).
Only the current source-selected width is compiled/tested. Pure mathematical
fixtures at other widths do not prove their RTL elaboration. Full declared coverage
and detected mutations are useful evidence, not exhaustive verification or approval
of unresolved contracts.

EQ01–EQ12 remain recorded; EQ03 recognition and EQ04 taken-JAL suppression are
D-approved. Generic JALR cutoff and stale-RAS preference retain their separate limits. Matching RET suppression is now approved. In particular EQ05, EQ07 and EQ08 are not closed by passing runs.
Exception-safe retirement checkpoints, producer cancellation, physical memory flush,
ROB/commit/BPU correctness and general x1/x5 RAS hints are outside this standalone
DUT. RAS_DEPTH other than 4, full ISA execution and mutation equivalence analysis
beyond documented exclusions are not implemented.


## Independent recovery audit

See [ARCHITECTURE_AUDIT.md](ARCHITECTURE_AUDIT.md) for the EQ01–EQ12 review,
source-level timing proofs, precise-exception counterexample and recovery options.
BU confirmation is execution confirmation, **not retirement**. A younger confirmed
call/return can be squashed by an older delayed fault; restoring P from the unchanged
C then retains the wrong history. Normal branch recovery has a separate ordered
execution/confirmation guarantee. The recommended exception-specific clear of both
histories is a proposal only; no production RTL was changed.

Approved EQ04 policy: a hit-and-taken JAL may suppress correction regardless of
whether the BTB target matches its decoded target. T08 covers correct and wrong
targets at every lane. The model records this D policy separately from I lane
selection/lifecycle and unresolved RET redundancy.

Audit fixes are deliberately local: the `exception=unknown` profile now invalidates
both histories, so a later branch restoration cannot fabricate knowledge of C.
With an unknown overflow policy, a push into unknown occupancy no longer fabricates
a known top either. The random validator checks the emitted `misprediction` label and requires observed
recovery IDs. T28 tests exception followed by branch recovery and a still-checkable
JAL. Independent fixed JAL words and EQ04 policy tests were added. The default
`len5_minimal` transition rules and seeded generator policy are unchanged. An old
source fingerprint is not a replay of this revised conservative model; preserve
its source/binary evidence when comparing historical results.

New selected-configuration validation: 16,931 pure checks; all 34 directed scenarios
in both profiles (198,106 / 195,570 comparisons); 21 framework cases; 15 random
validation cases; three confidence fixtures and four mathematical width fixtures.
Normal random validation totals 45,056 cycles / 852,478 comparisons with zero
mismatches. Deliberate failures and EQ07 alternative discrepancies remain separate.
Exact journal/FST and first-failure replay pass. These are focused audit runs, not
a repeat of the historical three-million-cycle campaign. Detailed artifacts and
remaining short-run coverage gaps are in the audit report.

Coverage caveats: required matrix closure is offered-operation coverage, not an
obligation proving every hidden RAS update via a later return. Native EV13 return
witnesses and directed drains provide bounded temporal evidence; a per-operation
fulfilled/canceled/pending obligation ledger remains future work. Regression reset
summary fields are currently unpopulated and its legacy `assumptions` list misses
the native `assumption_checks` map: consult native EV15 counters, `contract` and
`assumption_checks`. Architectural traffic validates local instruction/confirmation
causality, not whole-program fetch continuity, actual retirement, trap handling or
physical request cancellation. Full declared coverage does not close those gaps.

Full-core follow-up: EQ08 is now dynamically reproduced for squashed confirmed
pushes and pops at N=2 and N=4 using disposable configurations. See
[the recovery audit](ARCHITECTURE_AUDIT.md#e-full-core-execution-follow-up) and
[reproducer instructions](recovery/README.md). The standalone oracle remains
independent and unchanged. A separate exception redirect-window observation
prevents a claim of complete recovery correctness. Mutation builds now export
dependencies to avoid relative source-path aliases between checkouts.
