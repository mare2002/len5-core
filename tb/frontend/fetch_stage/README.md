# Closed-loop production frontend verification

Native C++17/Verilator verification of the real `fetch_stage` and all its real
submodules. The golden executable compiles the existing `pc_gen_model.cpp`,
`early_jump_model.cpp`, `fetch_mem_model.cpp` and EJU instruction helpers directly.
The [specification](VERIFICATION.md) remains the requirement and evidence ledger.

**Implementation status: working closed-loop infrastructure with explicit
remaining verification gaps.** A successful individual run means its selected
witnesses and known comparisons passed. It is not complete FE01–FE24/FEV01–FEV22
sign-off. By default, incomplete verification scenarios are reported as warnings and do not
cause the test suite to fail. Definitive mismatches, invalid environments and
framework failures still cause nonzero exits. Use `STRICT_COMPLETION=true` to
require all selected verification obligations to be completed. Exit0 with warnings
is successful execution with incomplete verification, never full specification sign-off.


## Final backend/history audit (2026-10-16)

The current source remains **N=4**. See
[FINAL_FRONTEND_ARCHITECTURE_AUDIT.md](FINAL_FRONTEND_ARCHITECTURE_AUDIT.md)
for source evidence, exact cycle traces, resource measurements and the predictor
architecture recommendation. Historical counts below describe earlier binaries.

* FE-T15 now has matched public **BTB-hit** before/after witnesses for upward and
  downward PHT threshold crossings. The original interference body is retained;
  an immutable four-branch prelude supplies controlled history. Strict FE-T15
  passes. A write-generation ledger prevents unrelated later counter changes
  from satisfying a threshold witness.
* GH01 is a101-cycle legal two-in-flight-branch reproducer. B samples H=1/index0;
  after older A updates H, B trains H=2/index3. A later public conditional probe
  witnesses the resulting direction. This verifies current resolution-indexed
  Policy A; saved-index Policy B is a separate fixed-feedback-trace experiment.
* The backend now allocates ROB at scalar issue, bounds IQ16/ROB32/ALU RS8/BU RS4,
  holds RS until publication and ROB until retirement, and limits shared CDB
  publication to one per edge. Independent ALU/BU result capture can overlap.
  Whole-bundle ready uses the actual valid-lane count; random stalls cannot bypass
  capacity. Admission/occupancy metrics are credited at matched consuming edges.
* `EXEC_LATENCY_*` retains its specified once-sampled **dispatch-to-readiness
  minimum**, not FU service time. Separate issue/start/capture/publication/retire
  timestamps make this explicit. Modeled service is one cycle; optional real EU
  bypass and safe ROB lookahead retirement are conservatively omitted.
* BP01–BP08 are explicit auxiliary cases, not silent additions to the54-ID
  catalog. They cover IQ/ROB/branch RS saturation, long readiness, whole-bundle
  admission at real widths, recovery, separate/combined stalls and marker
  retirement. BP02 explicitly stalls the retirement sink until cycle200;
  BP05 uses48 ordinary words and fixed256 readiness to saturate even N1. These
  fixtures do not change ordinary/random uniform1–64 defaults.
* `history_audit.py` independently reconstructs prediction snapshots from public
  request/reset/training pins, checks dynamic dispatch association and compares
  policies. Seven hand-derived positive/negative units run with FE-T54's pure
  validation, while its24 native confidence validators remain mandatory.

```sh
make check-fetch-stage-run SCENARIO=GH01
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T15
make check-fetch-stage-run SCENARIO=BP02
make check-fetch-stage-run SCENARIO=BP05
make check-fetch-stage-run SCENARIO=BP06
make check-fetch-stage-run SCENARIO=BP07
make check-fetch-stage-widths-smoke N_VALUES=1,2,4,8 SCENARIO=BP05 SMOKE_SEEDS=0
make check-fetch-stage-core JOBS=2
python3 tb/frontend/fetch_stage/history_audit_unit.py
python3 tb/frontend/fetch_stage/history_audit.py <GH01-or-FE-T15-run-directory>
```

The recommendation is to retain the approved resolution-indexed implementation
for the issue-stage verification baseline. Its different-counter attribution is
now explicit and tested, not mistaken for prediction-index-consistent training.
A concrete saved-index hardware/interface proposal is documented for separate
approval; no superiority or performance gain is claimed without a closed-loop
comparison. No production predictor or oracle update policy changed.

Final ordinary scope: **48 passed IDs /69 cases**,44913 cycles and1791021
comparisons,zero ordinary mismatches or missing selected witnesses. FE54's24
validators are included (11 deliberate injected errors correctly detected).
Strict FE15 passes3330 cycles/125160 comparisons/118 updates. Real isolated BP05
N1/2/4/8 builds and simulations all pass,3182 cycles/165797 comparisons in total.
Focused GH01, BP01–08 and the required sensitive FE cases also pass. These groups
overlap and are not additive unique coverage.

Default core completion does not close deferred FE-T43/48/49/50/51, EQ07/EQ08,
the exception window, full retirement/CSR/mtval or all FEV crosses. Warnings and
strict-completion semantics remain in force. No million-cycle regression or RTL
mutation campaign was rerun. Final execution totals and hashes are in the latest
completion-audit entry and `build/fetch-stage/final-architecture-audit/FINAL_EVIDENCE.json`.

## Default execution and completion policy (2026-10-16)

The policy remains current. Counts and FE-T15 gaps in this subsection describe
the earlier result-policy audit and are superseded by the final audit above.

```sh
make check-fetch-stage-core JOBS=2
make check-fetch-stage-run
make check-fetch-stage-run SCENARIO=FE-T54
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T48 DIRECTED_CYCLES=500
STRICT_COMPLETION=true make check-fetch-stage-run SCENARIO=FE-T01
python3 tb/frontend/fetch_stage/results_unit.py
```

No manual cycle/repetition/latency override is required for successful execution.
The native/Python result is retained independently of process status:

| Verification status | Default exit | Strict exit |
|---|---:|---:|
| PASS: required selected witnesses completed | 0 | 0 |
| WARN_INCOMPLETE: required evidence missing | 0 | 3 |
| WARN_PROVISIONAL: explicitly unresolved selected contract | 0 | 3 |
| FAIL_MISMATCH: known comparison failed | 1 | 1 |
| FAIL_ENVIRONMENT / FAIL_FRAMEWORK | 2 | 2 |

Precedence is infrastructure2, mismatch1, strict completion3, success0. GNU Make
reports a failing recipe as `Error 3` and itself returns2; the Python/native
completion code in JSON is3. `specification_complete` describes the selected
scope; `full_contract_signoff` remains false. A completed ordinary scope does not
close the excluded exception/protocol contracts. Every scenario and required
variant must produce a report. Missing results, stale/unrelated FE-T54 evidence,
crashes and malformed receipts are hard framework failures, never missing coverage.

Defaults remain uniform sampled execution latency1–64, seed1,32 directed program
repetitions,6000 cycles per ordinary episode and1000000 total-cycle safety limit.
Random traffic keeps its broad latency distributions. FE-T34/47 have a documented
fixed64 causal fixture; FE-T37 selects a reproducible older64/younger1 sequence;
FE-T38 exercises its seven named distributions. Explicit `EXEC_LATENCY_*` options
override the default fixtures for34/37/47. Such custom runs can miss the mandatory
fixture witness and must warn. `DIRECTED_CYCLES`, `DIRECTED_REPETITIONS`, `PROGRAM`,
`REPETITIONS` and `VARIANT` retain their existing override roles. Reports distinguish
requested latency from actual active latency, program marker termination from a
bounded stop, and missing witnesses from canceled residual work.

Directed timing streams restart per episode, independent of catalog ordering and
worker count. Random episodes keep continuous separate streams. Replay records the
stream revision, strict flag and whether a latency override was explicit.

The original saved failure had **zero mismatches**, but FE-T15 missed
`gshare-public-threshold-up`; the old core aggregator returned3 for any nonzero
child. Its saved configuration was N=4. Contrary to the task's N=2 description,
the active source at this task's entry also selects **N=4**; it is preserved.
Shortening all latencies does not reliably obtain the missing gshare witness at
N=4. The gate remains mandatory for completion and its warning remains prominent.
The original detailed N2 audit below remains historical evidence, not a claim about
the current selected configuration.

FE-T54 executes all24 actual validators and checks their structured expected
outcomes. Its injected failures are successful negative validation, not ordinary
DUT failures. Empty runs now correctly reject with framework exit2. The timeout,
missing-training and unknown-dependent fixtures deliberately select strict native
mode to validate incomplete exit3. A successful receipt replaces only the native
FE-T54 delegation placeholder. FE-T43/48/49/50/51 stay present and incomplete; their
limitations are not resolved by warning-only process success. FE-T41's matched
same-edge hypothesis is provisional, not an approved EQ07 contract.

`logs/report.json` preserves native comparisons, provenance, coverage and
obligations. `summary.json` adds scenario/variant counts, actionable warning reasons,
evidence paths and separate execution/completion status; catalog merging retains
`logs/report.native.json`. Approved exact comparisons remain hard failures even
when their provenance includes I assumptions. Legacy `provisional_mismatches`
counters describe evidence confidence, not permission to waive a failed check.
The full aggregate propagates structured warnings and continues independent
groups. It must not print an unqualified all-tests-passed message for warning-only
coverage. Native processes have a120-second wall-clock watchdog; this is separate
from a clean cycle-budget stop.

See the latest section of [COMPLETION_AUDIT.md](COMPLETION_AUDIT.md) for executed
commands, current counts, protected-file hashes and outstanding witnesses.

Historical result-policy validation: default core **47 passed IDs,1 incomplete** (48 selected
IDs including FE54),43,449 cycles and1,728,549 comparisons; full directed **47
passed,6 incomplete,1 provisional** (54 IDs/75 variants),57,459 cycles and2,139,487
comparisons. Both exit0 with warnings and zero ordinary mismatches. FE54 alone
passes all24 validators (847 cycles/30,489 comparisons). Strict FE48 returns3;
strict FE01 returns0. There are37 passing result-policy unit tests. Detailed
native/component totals, expected-negative errors, pending requirements, source
hashes and exact evidence paths are in the latest completion-audit section.

## Historical focused completion audit (2026-10-15)

The [completion audit](COMPLETION_AUDIT.md) records real isolated production
elaborations and short simulations at **N=1,2,4,8**. The current working tree is
**N=2**; its pre-existing user configuration edit was preserved. Canonical short
matrix: **27,190 cycles,719,188 comparisons,zero mismatches**, including three
seeds ×1500 cycles at each N. No million-cycle regression or mutation campaign
was rerun in this audit.

The explicit ordinary scope passes **47 native IDs /62 executed variants plus
FE-T54's24 confidence validators** at N=2:11,508 native cycles and323,790 field
comparisons,zero mismatches. FE-T19 now reaches coherent JAL hit/NT training.
The new RAS-operation ledger requires subsequent public probes; corrected FE-T34
exposes three restored links before another recovery. FE15/31/32/40/44/47 have
stronger gates. Finite ordinary programs also require their termination marker.

**Full specification remains incomplete.** FE-T43/48/49/50/51 retain deferred
contracts/characterization; EQ07 alternatives, EQ08, predictor-agnostic path
checking and remaining FEV crosses are not closed. The full aggregate retains
these obligations. Earlier N4 validation below is historical evidence.

```sh
source private/init.sh
make check-fetch-stage-widths-smoke N_VALUES=1,2,4,8 SMOKE_SEEDS=3 SMOKE_CYCLES=1500
make check-fetch-stage-widths-smoke N_VALUES=4 SCENARIO=FE-T19 SMOKE_SEEDS=0
make check-fetch-stage-core JOBS=2
make check-fetch-stage-run SCENARIO=FE-T54
```

The width workflow edits **disposable source copies only**, reuses cached
fingerprinted builds and never runs a hidden regression/mutation sweep. Its
N_VALUES setting does not select N for default builds. `check-fetch-stage-core`
explicitly excludes FE-T41/43/48/49/50/51 before judging results; FE-T54 executes
actual independent validators. Incomplete ordinary witnesses remain visible warnings
by default and reject completion in strict mode. `DIRECTED_CYCLES`, `DIRECTED_REPETITIONS` and `VARIANT` support
focused runs and are included in replay metadata.

The simulator discrepancy now has a **54-cycle public-input-only reproducer**.
Default Verilator5.040 captures a JAL's taken bit before its EJU rewrite; O0 and
no-DFG agree. Extra eval calls do not fix it. The audit gives static generated-code
evidence and retained vectors. `-fno-dfg` remains enabled. No RTL fix was applied.

## Build and commands

```sh
source private/init.sh
make fetch-stage-build
make check-fetch-stage-run SCENARIO=FE-T09
make check-fetch-stage-run SCENARIO=FE-T18
make check-fetch-stage-run SCENARIO=FE-T30
make check-fetch-stage-run SCENARIO=FE-T36
make check-fetch-stage-framework
make check-fetch-stage-random-framework
make check-fetch-stage-random SEED=7 CYCLES=10000
make check-fetch-stage-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-fetch-stage-mutations JOBS=2
make check-fetch-stage
```

Initialize Conda first if `private/init.sh` cannot activate `core-len5` in a fresh
shell. The aggregate builds once, then runs directed, framework, random-framework,
regression and mutations concurrently. `TEST_JOBS` controls independent groups;
`JOBS` controls regression workers/mutation builds. Each mutation build also uses
four compiler jobs. Existing pc_gen/EJU/fetch-memory commands retain their behavior.
Do not use repository-wide `make check` for this task: it formats production RTL.

| Target | Purpose |
| --- | --- |
| `check-fetch-stage-widths-smoke` | Short real isolated N builds and directed/random smoke; selectable width/scenario. |
| `check-fetch-stage-core` | Declared ordinary scope plus executed FE-T54 confidence; no full regression/mutations. |
| `fetch-stage-build` | Source-fingerprinted real-DUT build only. |
| `check-fetch-stage-run` | All FE-T01–54 entries, or selected `SCENARIO`. Incomplete entries warn; strict completion returns3. |
| `check-fetch-stage-framework` | Independent pure units, native monitor injections, logs, replay/FST and configuration guards. |
| `check-fetch-stage-random` | One deterministic persistent-program execution budget. |
| `check-fetch-stage-random-framework` | Public-journal reconstruction, seeded smoke cases and replay/failure confidence. |
| `check-fetch-stage-regression` | Isolated parallel native processes; merges actual counters and reports handshake-matrix gaps. |
| `check-fetch-stage-mutations` | Private exported RTL variants, original-before/after and source integrity. `MUTATIONS=name,...` selects a focused audit. |
| `check-fetch-stage` | All groups; incomplete coverage is qualified explicitly, even when every group exits0. |

Configuration options follow the existing frameworks: SEED/SEEDS/CYCLES/JOBS/
TEST_JOBS/SCENARIO/LOG_LEVEL/DUMP_WAVES/JOURNAL/GUIDED/WEIGHTS/BUILD_DIR. Additional
options are `PROGRAM`, `REPETITIONS`, `CAMPAIGN=all|architectural|stress|characterization`,
`FETCH_STAGE_PROFILE=exact-I|predictor-agnostic` and `RAS_ORDER=updated|previous|unknown`.
Current event weights are `grant=80,ready=75,response=90`, expressed as percentages.
Unknown names and invalid values fail. Example:

```sh
make check-fetch-stage-random SEED=19 CYCLES=20000 PROGRAM=multi-caller \
  EXEC_LATENCY_MIN=1 EXEC_LATENCY_MAX=64 EXEC_LATENCY_DIST=triangular-late \
  WEIGHTS=grant=50,ready=40,response=70 JOURNAL=full DUMP_WAVES=true
```

## Boundary, configuration and compiler policy

The wrapper has public `fetch_stage` dynamic ports and static configuration outputs
only. It never exports or reads internal BPU/RAS/FIFO/EJU state. FST tracing is
limited to the public wrapper boundary. The model has no Verilator handle.

The sole issue-width selector is production `rtl/packages/len5_config_pkg.sv`.
Default targets compile source-selected N only. The explicit widths-smoke audit
compiled all four N values in independent copies. Current live source for the2026-10-16 result-policy task is N=4,
XLEN/ALEN64, ILEN32, HLEN4,
BTB_BITS4, integrated INIT_C2B=WT, RAS depth4, metadata depth2, request bypass and
registered answer/final-spill buffering. Alternate timing/depth configurations
fail clearly rather than use a mismatched model.

Effective BOOT_PC defaults to the production `fetch_stage` parameter default0;
the package's 0x180 literal is not implicitly wired into that parameter. Optional
`BOOT_PC` changes only the test adapter parameter and selects a different build.
Startup checks every static value against elaboration. Source snapshots, build
locks, dependency export and SHA256 fingerprints prevent stale binary reuse.
Replay width and fingerprint assertions do not select a configuration.

The new target uses **`-fno-dfg` with Verilator 5.040**. Bring-up found a simulator
optimization discrepancy: default optimization produced a JAL output with taken0
despite its matched early-memory flush, while identical RTL/public input sequences
passed with both `-O0` and `-fno-dfg`. No expected value was changed. Diagnostic
builds/traces are under `build/fetch-stage/compiler-audit/`; the original failures
are under `build/fetch-stage/alternating-h5yoxm46/` and
`build/fetch-stage/run/all-62lhsbmi/`. These are simulator-configuration evidence,
not a demonstrated production hardware defect. Narrow UNOPTFLAT waivers document
coarse block dependencies; width warnings remain enabled. Existing standalone
build options are unchanged.

## Independent composition

`fetch_stage_composition.*` adapts the existing models through four different
events: memory request K, memory response R, modeled EJU-to-output-spill acceptance
A, and public backend dispatch D. A is inferred and witnessed later through public
data/metadata; it is never reported as an observed DUT internal handshake.

The PC model owns its independent cursor and approved priorities. The new semantic
BTB/gshare model consumes only public qualified resolution inputs. It keeps tagged
direct-mapped targets, ordinal saturating counters and resolution-time outcome
history. Cold raw direction is taken while the BTB misses. The model uses old
history for update indexing and pre-edge predictions for accepted requests.

The reused memory model freezes each request's predictions/mask and owns separate
outstanding and answered queues. The reused EJU model selects/truncates/revises
that saved answer and owns independent predictive P and confirmed C histories.
The new mixer shifts complete tuples; the final abstract queue has two records
and no full-state ready lookahead. Public output-ready is not EJU acceptance-ready.

No expected PC/return address is obtained from DUT outputs. Actual accepted
transactions serve a separate physical ledger only after comparison with expected
transactions. A discrepancy preserves evidence and quarantines dependent feedback;
it never repairs any model from the DUT. Unaffected fields in the failing sample
and subsequent independent reset checks remain active.

## Programs, backend and latency

`fetch_stage_program.cpp` constructs immutable encoded images with labels and
checked branch/JAL relocation. Families include sequential code, loops, phase and
alternating conditions, interacting branches, deliberate BTB conflicts, repeated
JALs, callers/shared functions, nesting, indirect returns and wrong-path histories.
The same PC returns the same word throughout a program instance. Fault flags and
causes are an explicit persistent per-PC map, attached to physical response lanes.

The backend uses the EJU independent decoder/outcome helper plus new integer
write semantics: ADDI/ANDI/ORI/XORI, LUI/AUIPC, supported integer ALU/shift/compare
operations, all six integer branch conditions, JAL and JALR. x0 is fixed0. Unknown
instructions are rejected, not silently executed as NOPs. This is a limited
semantic engine; FP, CSR and data-memory execution are not implemented.

Each dispatched valid lane receives an identity within its program/epoch, operand
producer IDs, immutable latency sample and speculative register version. Reads
use the most recent older surviving write. Younger versions/events are removed on
recovery. A second in-order retirement abstraction checks surviving PCs and values
against independent committed state. Nested templates explicitly save/restore x1.

Scalar issue, IQ/ROB/branch-capacity bounds and ordered branch execution prevent
younger-ready branches from overtaking older ones. Correct result at e trains and
confirms at e+1. Misprediction confirms at e+1, then trains/redirects/flushes at e+2.
Later backend resume does not flush the refetched frontend again. Confirmation
means branch execution, not architectural retirement.

Execution latency is sampled once per accepted instruction using its own RNG:

| Setting | Meaning |
| --- | --- |
| `EXEC_LATENCY_MIN=1`, `EXEC_LATENCY_MAX=64` | Sampled inclusive range; actual feedback may be later due to dependencies/order. |
| `EXEC_LATENCY_DIST=uniform` | Unbiased bounded integer sampling. |
| `fixed` | `EXEC_LATENCY_FIXED`, default maximum. |
| `triangular-early`, `triangular-late` | Exact descending/ascending integer weights from specification §9. |
| `triangular-mode` | `EXEC_LATENCY_MODE`, default center, exact discrete CDF. |
| `truncated-geometric` | Conditional geometric; `EXEC_GEO_U/EXEC_GEO_V`, default1/8. No cap-at-maximum probability pileup. |
| `bimodal` | `EXEC_SHORT_U/EXEC_SHORT_V`, default1/2; optional SHORT_MIN/MAX and LONG_MIN/MAX intervals. |

The implementation validates parameters, bounds checked CDF arithmetic and fails
instead of biasing an exhausted geometric sampler. FE-T37 finds a reproducible RNG
stream with older L64 and younger L1; FE-T38 runs all seven distributions on the
same selected RTL configuration. Reports distinguish dispatch, sampled readiness,
issue, operand readiness, ordering delay, execution, update and confirmation.

## Training and observable evidence

Learning goals require accepted resolution pulses followed by later public
witnesses. EJU-overwritten raw predictions are labeled inferred; they are never
counted as direct BPU output observations. Training traces distinguish raw BPU,
saved request and effective attached predictions from actual operand-derived
outcomes. A corrected JAL can execute correctly with no backend misprediction.

Cold/warm JAL tests use one immutable static JAL, train through actual execution,
refetch it and require correction suppression plus the correct path. Returns use
real x1 values. The same RET called from several sites demonstrates stale BTB
targets repaired by the newer predictive link. `stale-ras` first trains a canonical
RET with empty RAS, then executes a recognized call followed by a noncanonical
JALR return that intentionally leaves the restricted RAS history unchanged. A
later visit to that same canonical RET can expose a correct BTB but stale RAS;
backend execution must recover from the EJU override. Architectural return accuracy
is evaluated against executed register semantics, not against RAS/BPU agreement.

Random `all` rotates campaigns at program boundaries, not fixed 512-cycle resets.
Architectural episodes execute persistent programs; stress additionally exercises
predictor-only flush while work is in flight; characterization supplies real lane
faults, coordinated recovery and a delayed supplied target. Separate RNGs control
program choices, event/stall timing, memory latency and execution latency. Bounded
guidance chooses missing feasible training families using observed counters.

## Memory, recovery and confidence limits

Default physical service is ordered, positive latency, two outstanding requests,
stable held response and coordinated cancellation. Early memory flush preserves
the current A and older final-spill records. External frontend flush cancels the
output path and memory work. Fault flags/cause0/cause1 remain attached to their
saved lane PCs through shifting and buffering. Unraised causes/faulting words are
don't-care where specified. There is no mtval port or processor retirement proof.

Every request and dynamic instruction is accounted for as delivered/retired,
legitimately canceled or pending. Controlled stop explicitly resets residual
speculative work; it does not claim the running frontend drained itself. Learning
obligation files distinguish public witness, inferred EJU witness, predictor-flush
cancellation and unwitnessed controlled-stop cancellation. Canceling a required
scenario witness cannot satisfy that scenario.

EQ07 ordering remains provisional. FE-T41 tests a deliberately simultaneous
confirmation/restore at public pins; normal architectural scheduling separates
them. EQ08 remains a demonstrated prior full-core defect. Exception uncertainty
invalidates both P and C in the oracle; no clear-both RTL fix is implemented.
Known fetch faults are not relabeled as delayed data faults. The delayed exception
redirect window remains an integration concern; characterization permits the real
intervening requests rather than hiding them with universal grant suppression.

`exact-I` is the implemented exact predictor policy. The named `predictor-agnostic`
profile currently suppresses direct accuracy comparisons but still has an exact-I
path shadow, so it explicitly reports incomplete rather than claiming a complete
predictor-independent oracle. Remaining FEQ01–13 stay in reports. FQ02/03/04
alternative physical protocols and retirement-aware EQ08 redesign are not approved
by successful active-contract runs.

## Coverage, reports and replay

Unique runs live under `build/fetch-stage/{run,validation,regression,mutation,suite}/`.
Native logs include report.json, coverage.json, samples.jsonl, training.jsonl,
per-instance obligations files and optional waves.fst. Immutable program JSONs
contain words, labels, fault maps and a content digest. Build roots retain SHA256
source manifests and snapshots. `source-baseline.json` protects production RTL and
all previous verification implementation files.

TbLogger/TB_* formatting, colors, verbosity, context timestamps, REQ/RSP/SCB and
zero-padded 64-bit addresses are reused. Module summaries retain:

```text
TEST SUCCEEDED > errors: <failed checked records>/<checked records>
TEST FAILED > errors: <failed checked records>/<checked records>
```

Exit0 means execution succeeded, possibly with explicitly incomplete/provisional
verification. Exit1 is a known-field comparison failure;2 is invalid environment,
configuration or framework (including empty/no useful checks and wall-clock
watchdog);3 is an explicitly requested strict completion failure. A clean bounded
cycle stop with missing witnesses warns by default. Infrastructure2 takes precedence
over mismatch1, which takes precedence over strict completion3.
Expected-negative validators succeed only when the intended failure is detected.
`REQUIRE_MATRIX=true` gates the feasible K/R/A/D handshake matrix, not all training,
RAS and architectural sign-off. Internal occupancy and raw overwritten predictor
state remain inferred. Missing temporal goals are not hidden by matrix closure.

Copy `replay_command` from report.json into a fresh directory. It includes source
configuration assertions, seed, policies, program-generation and latency options.
Use `JOURNAL=full` and optional FST for debugging. The independent Python auditor
reconstructs physical request/response words, immutable output PC/word/fault tuples
and backend integer/feedback causality from public journals and program images.
It does not claim to directly reconstruct hidden A or every overwritten BPU field.



## Historical pre-audit validation record (2026-10-15)

In the original implementation phase, only active **N=4** was elaborated.
The later four-width audit above supersedes configuration-execution limitations. The final exact-I directed monitor run covers
54 IDs / 75 variants: **47 IDs passed their implemented gates, seven IDs remain
incomplete**, zero output mismatches, 58,265 cycles and 2,120,976 field comparisons.
Native exit is **3**, and Make reports failure. This is intentional incomplete
verification, not a zero-mismatch whole-suite PASS. Some passing monitors cover
only the implemented subset of the original catalog; the scope column below
lists important remaining subscenarios. **Full contract sign-off is false.**

The stabilized functional/lifecycle regression used seeds 1–100, 10,000 cycles each,
JOBS=4, exact-I, all campaigns, guided, default uniform 1–64 execution latency:

| Metric | Actual result |
| --- | ---: |
| Seeds / cycles | 100 / 1,000,000 |
| Field comparisons / mismatches | 34,815,638 / 0 |
| Accepted predictor updates / confirmations | 109,672 / 49,336 |
| Backend semantic completions / recoveries | 226,810 / 6,423 |
| Fetch requests / public delivered bundles | 273,910 / 187,695 |
| Legitimately canceled fetches / pending after controlled stop | 86,215 / 0 |
| Dynamic instructions / retired abstraction / canceled | 336,817 / 210,155 / 126,662 |
| Feasible K/R/A/D rows | 16 / 16 |
| Public saved-training witnesses / EJU-overwritten inferred witnesses | 78,429 / 24,508 |
| Elapsed regression time | 21.322 seconds on the final fingerprint |

Two earlier staged runs each executed the same million cycles with identical
34,815,638 comparisons and stimulus counts (81.445s before lifecycle reporting,
66.472s with concurrent compilation load). The final canonical run follows the
last CLI validation and aggregate option-forwarding changes, so its replay uses
the final fingerprint. These are **3,000,000 executed substantial-regression
cycles over the same 100 distinct seeds**, not 300 distinct seeds or extra coverage.
`configuration.py` reports the final fingerprint; older binaries reject changed
source snapshots. Focused runs, confidence and mutation evidence are additional,
separately identified validation.

Artifacts:

- [Directed report](../../../build/fetch-stage/run/all-zv4zemuj/logs/report.json).
- [Final canonical regression](../../../build/fetch-stage/regression/regression-u0056wzg/summary.json).
- [Earlier lifecycle regression](../../../build/fetch-stage/regression/regression-43jhjj67/summary.json).
- [Public training/recovery traces](../../../build/fetch-stage/witnesses-jmuovw21/).
- [Guidance comparison](../../../build/fetch-stage/guidance-mc49i70d/summary.json).

Pure validation links the original three model/environment unit executables as
well as the new units. Final counts are **70,548 new checks**, plus **341 PC**,
**16,931 EJU**, and **8,310 fetch-memory** checks, all passing. Counts are assertions,
not distinct functional-coverage bins. The frontend fixture suite includes fixed
ADD/SUB/logical/shift/signed/unsigned words, branch outcomes, x0, rollback, versioned
registers, coherent nested links, real L64/L1 blocking, seven distributions,
static-program termination validation, predictor replacement/saturation and
unknown-control propagation. Unsupported instructions are rejected, not NOPs.

The native confidence validator verifies public injections (request, validity,
flush, instruction, PC, target, fault flag, mask and raised cause0), independent
journal reconstruction, lifecycle conservation/uniqueness, replay and FST replay,
repeated first failure, invalid feedback, empty/incomplete execution, stale source,
width/fingerprint mismatch and malformed configuration. Every expected-negative
case requires its specified nonzero exit. The intentionally incomplete
predictor-agnostic profile exits3. EQ07 previous exits1 with provisional differences;
EQ07 unknown exits3 with zero invented comparisons. No unknown RAS-derived memory
readiness is treated as a known value.

### Directed monitor outcomes

| ID | Implemented monitor result | Variants | Comparisons | Missing gate / scope |
| --- | --- | ---: | ---: | --- |
| FE-T01 | PASS | 1 | 39,563 | Selected witness predicates met. |
| FE-T02 | PASS | 4 | 8,327 | Selected witness predicates met. |
| FE-T03 | PASS | 1 | 39,281 | Selected witness predicates met. |
| FE-T04 | PASS | 1 | 88,631 | Selected witness predicates met. |
| FE-T05 | PASS | 1 | 13,514 | Selected witness predicates met. |
| FE-T06 | PASS | 1 | 3,899 | Selected witness predicates met. |
| FE-T07 | PASS | 1 | 3,752 | Selected witness predicates met. |
| FE-T08 | PASS | 1 | 13,553 | Selected witness predicates met. |
| FE-T09 | PASS | 1 | 14,102 | Selected witness predicates met. |
| FE-T10 | PASS | 1 | 17,554 | Selected witness predicates met. |
| FE-T11 | PASS | 1 | 30,366 | Selected witness predicates met. |
| FE-T12 | PASS | 1 | 104,268 | Selected witness predicates met. |
| FE-T13 | PASS | 1 | 111,779 | Selected witness predicates met. |
| FE-T14 | PASS | 1 | 128,760 | Selected witness predicates met. |
| FE-T15 | PASS | 1 | 113,028 | Opposing-update/index witness; richer before/after threshold crosses remain partial. |
| FE-T16 | PASS | 1 | 14,285 | Selected witness predicates met. |
| FE-T17 | PASS | 4 | 7,796 | Selected witness predicates met. |
| FE-T18 | PASS | 1 | 18,229 | Selected witness predicates met. |
| FE-T19 | INCOMPLETE | 1 | 118,427 | jal-hit-not-taken |
| FE-T20 | PASS | 1 | 22,388 | Selected witness predicates met. |
| FE-T21 | PASS | 3 | 13,701 | Selected witness predicates met. |
| FE-T22 | PASS | 4 | 21,197 | Selected witness predicates met. |
| FE-T23 | PASS | 1 | 14,240 | Selected witness predicates met. |
| FE-T24 | PASS | 1 | 25,432 | Selected witness predicates met. |
| FE-T25 | PASS | 1 | 66,703 | Selected witness predicates met. |
| FE-T26 | PASS | 1 | 32,078 | Selected witness predicates met. |
| FE-T27 | PASS | 1 | 5,873 | Selected witness predicates met. |
| FE-T28 | PASS | 1 | 26,417 | Selected witness predicates met. |
| FE-T29 | PASS | 1 | 25,441 | Selected witness predicates met. |
| FE-T30 | PASS | 1 | 32,726 | Selected witness predicates met. |
| FE-T31 | PASS | 1 | 42,773 | Three fixed caller sites; randomized caller ordering not implemented. |
| FE-T32 | PASS | 5 | 16,336 | Selected witness predicates met. |
| FE-T33 | PASS | 1 | 21,986 | Wrong-path call and surviving-return checks; per-operation return obligation map remains partial. |
| FE-T34 | PASS | 1 | 14,591 | One-entry wrong-path return history; multi-entry drain probe remains partial. |
| FE-T35 | PASS | 1 | 4,004 | Selected witness predicates met. |
| FE-T36 | PASS | 1 | 12,341 | Selected witness predicates met. |
| FE-T37 | PASS | 1 | 2,735 | Selected witness predicates met. |
| FE-T38 | PASS | 7 | 87,314 | Selected witness predicates met. |
| FE-T39 | PASS | 1 | 68,909 | Selected witness predicates met. |
| FE-T40 | PASS | 1 | 5,483 | Native producer timing checked; held-acknowledgment negative fixture incomplete. |
| FE-T41 | PASS | 1 | 2,630 | Selected witness predicates met. |
| FE-T42 | PASS | 1 | 13,736 | Selected witness predicates met. |
| FE-T43 | INCOMPLETE | 1 | 151,589 | characterization observation does not close all specified temporal obligations |
| FE-T44 | PASS | 1 | 152,291 | Commit/branch priority checked; guaranteed simultaneous pending early correction not gated. |
| FE-T45 | PASS | 1 | 3,425 | Selected witness predicates met. |
| FE-T46 | PASS | 1 | 25,874 | Selected witness predicates met. |
| FE-T47 | PASS | 1 | 4,180 | Populated C reset and restart checked; not a guarantee of simultaneous full queues plus both populated histories. |
| FE-T48 | INCOMPLETE | 1 | 25,753 | EQ08 requires separately tagged delayed data-fault context; no fake fetch-fault reproduction |
| FE-T49 | INCOMPLETE | 1 | 153,596 | characterization observation does not close all specified temporal obligations |
| FE-T50 | INCOMPLETE | 1 | 3,611 | characterization observation does not close all specified temporal obligations |
| FE-T51 | INCOMPLETE | 1 | 39,431 | characterization observation does not close all specified temporal obligations |
| FE-T52 | PASS | 1 | 13,658 | Selected witness predicates met. |
| FE-T53 | PASS | 1 | 39,965 | Selected witness predicates met. |
| FE-T54 | INCOMPLETE | 1 | 39,455 | independent negative/confidence validators own these obligations; directed placeholder alone is not completion |

### Learning and recovery trace excerpts

These are single-scenario seed1 traces from `witnesses-jmuovw21`, not inferred
internal RTL probes. Cycles are consuming edges; complete intervening cycles,
public inputs and outputs are in `samples.jsonl`. Raw predictions hidden by EJU
are labeled inferred even when public correction/path effects are checked.

| FE-T09 cycle | Independently checked event |
| ---: | --- |
| 10 | Dynamic branch 3 at PC 0x8 dispatched with miss/rawWT; operands will be31 and0. |
| 66 | Branch 3 executes taken to 0x4; effective miss is wrong. |
| 68 | One T+B+F recovery: old H=0, index 2, counter 2→3; refetch0x4. |
| 78 | Dynamic branch 20 at same PC dispatches saved hit/taken/target 0x4. |
| 93–94 | Branch 20 executes correctly, then updates once at e+1. |
| 302 | Exit branch 80 has operands 0 and 0, actual NT versus saved taken. |
| 304 | T+B+F: counter 3→2 at index 13, NT-mispredict BTB deletion, redirectPC 0xc. |

| FE-T18 cycle | Cold → trained immutable JAL at PC 0x110 |
| ---: | --- |
| 20 | Early acceptance/correction to 0x108, public X=1, grant withdrawn by coordinated cancellation. Raw miss/WT is inferred through EJU. |
| 21 | Public D contains JAL PC 0x110 with rewritten target 0x108, exactly once. |
| 79 | First dynamic JAL executes with effective correct prediction. |
| 80 | Actual update pulse for JAL 5: old H=2/index 6/counter 2→3; target 0x108 installed. |
| 168 | Later acceptance has modeled hit/taken and X=0; correction suppressed. |
| 169 | Public D preserves hit/taken/target 0x108 without rewrite. |
| 225–226 | Dynamic JAL 46 executes correctly, update once, no F. |

| Case / cycle | RAS versus BTB evidence |
| --- | --- |
| FE-T30, 21→65 | RET PC 0x30c, dynamic 7, first caller link 0x14; public effective target 0x14 and correct register result. |
| FE-T30, 117→162 | Same RET, dynamic 30: modeled stale BTB target 0x1c, predictive link 0x14; rewritten public target 0x14, no backend misprediction. Raw stale target is inferred, not directly observed. |
| FE-T36, 72→74 | Empty-RAS RET 0x304 executes to real x1=0x100; confirms e+1, trains/recovers e+2. |
| FE-T36, 159–160 | Noncanonical return has left a restricted-RAS link 0x110. Canonical RET corrects to 0x110 despite modeled correct BTB 0x100; public X and attached target agree with the model. |
| FE-T36, 216–219 | Actual x1 remains 0x100. Execute 216, confirm 217, T+B+F 218, accepted recovery request 0x100 at 219. This establishes RAS-O reachability and recoverability, not an RTL defect. |

### Coverage guidance evidence and limits

Ten paired seeds ×4,096 cycles per policy (81,920 cycles total) gave:

| Actual matched counter | Unguided | Guided |
| --- | ---: | ---: |
| Conditional trained dispatches | 2,414 | 1,844 |
| Cold→warm JAL witnesses | 1,162 | 1,773 |
| Executed stale-BTB returns | 481 | 628 |
| Public saved-training witnesses | 2,991 | 4,053 |
| Inferred training with public EJU effects | 995 | 1,288 |

All 20 runs passed. Guidance improves its targeted goals by selecting persistent
program families at boundaries; it does not improve every counter or establish
exhaustive coverage. Random programs currently vary family and supported lane
layout with configurable repetitions, not arbitrary register/dataflow/layout
synthesis. Three-caller order is fixed; fuller randomized program construction
remains work.

FEV01–04 have accepted channel/occupancy/lane/stall counters. FEV05–10 have exact
training transitions, BTB replacement/deletion, opposing-index interference,
effective predictions and public early-flush witnesses. FEV11–16 have reused P/C
history, distinct return targets, scheduled feedback and recovery checks. FEV17–22
have fault/epoch/reset/confidence/replay evidence. **No percentage closure of all
22 categories is claimed.** Individual operation→future-return obligations,
complete threshold crosses, all latency/occupancy crosses, every producer overlap
and alternative memory/recovery policies are not fully closed.

Each `obligations-*.json` contains request IDs/windows with K/R/A/D times and
cancellation reasons, backend IDs/status/training/confirmation, and learning
statuses. The independent Python auditor checks uniqueness, registered-stage
timing and conservation against accepted transactions. End resets cancel residual
work explicitly; learning canceled before refetch stays unwitnessed. The pre-audit
RAS witness gates were scenario-level. The new per-operation ledger records public
probes and unwitnessed cancellations; it does not claim all operations are covered. That limits FEV13 closure even where exact return comparisons pass.

### Pre-audit gaps and their current disposition

- FE-T19 was originally uncovered. The completion audit now supplies a coherent
  immutable training program and public correction witnesses at all four N values.
- FE-T43/49 record exception flush/delayed redirect observations but do not close
  all cold-predictor, intervening-delivery and intended-RAS temporal goals.
- FE-T48 does not implement a tagged delayed data-fault backend context or claim a
  new EQ08 reproduction. The existing full-core defect remains documented.
- FE-T50 transports a real faulting JAL and its cause, but full faulting-JAL/RET
  speculative policy characterization remains incomplete.
- FE-T51 does not implement integrated FQ02/03/04 alternative physical protocols;
  it is an explicit incomplete catalog entry, not architectural random traffic.
- Raw native FE-T54 delegates external confidence validation. Make/catalog commands
  now execute and attach the24 actual validators; the composite passes. Predictor-agnostic path checking also remains incomplete.
- The scope column identifies further unimplemented subcases in otherwise passing
  monitors. Per-operation RAS witnesses, richer randomized program construction,
  all FEV crosses and all architectural sign-off criteria remain incomplete.
- The current predictor algorithm is now an approved implementation target D;
  producer/composition timing and hidden-state observability remain I; EQ07 alternatives, EQ08 intended
  exception history, delayed redirect and FEQ01–13 retain their questions. No
  physical setup/hold, full ISA, CSR, mtval or ROB retirement proof is claimed.


### Mutation and source-integrity record

All **12 applicable noncyclic mutations compiled and were detected**, zero
survivors, in 110.618s with JOBS=2. Original-before/after both passed 12,959 comparisons
with identical stimulus digest `0xb95afd608db46bfc`. The scoreboard conservatively
classifies their discrepancies as **provisional** because integrated timing/path
selection retains I dependencies, including D fault transport conditioned on that
lane context. This is meaningful detection under exact-I, not 12 confirmed hardware
defects or 12 definitive architectural mutation kills.

| Mutation | First cycle / field | Detected requirement(s) | Classification |
| --- | --- | --- | --- |
| lost-training | 67 / `instr_addr_o` | FM02 | provisional under integrated I dependencies |
| wrong-integrated-initial | 11 / `lane[0].taken` | FE05 | provisional under integrated I dependencies |
| invert-history | 145 / `lane[0].taken` | FE05 | provisional under integrated I dependencies |
| wrong-btb-target | 69 / `lane[1].target` | FE06 | provisional under integrated I dependencies |
| take-without-hit | 10 / `instr_ready_o` | EJ06, FM09 | provisional under integrated I dependencies |
| current-predictions | 11 / `instr_addr_o` | FE06, FM02 | provisional under integrated I dependencies |
| wrong-eju-ready | 13 / `instr_ready_o` | EJ06, FM09 | provisional under integrated I dependencies |
| lost-call-confirm | 287 / `instr_ready_o` | EJ06, FM09 | provisional under integrated I dependencies |
| lost-eju-metadata | 14 / `lane[0].hit` | EJ07, FE06 | provisional under integrated I dependencies |
| early-flush-drops-current-answer | 14 / `issue_valid_o` | EJ07, FE06, FE12, FM06 | provisional under integrated I dependencies |
| drop-error | 16 / `lane[0].error` | FM11 | provisional under integrated I dependencies |
| wrong-fault-pc | 11 / `lane[0].pc` | FE06 | provisional under integrated I dependencies |

[Mutation summary](../../../build/fetch-stage/mutation/audit-jjvnck2c/summary.json)
contains compiled source hashes, first discrepancies, exact requirements and
original-before/after evidence. Earlier warning-fatal builds are explicitly
unexecuted. Only private mutant cores allow nonfatal warnings introduced by their
intentional disconnections; the original target remains warning-strict.

The discarded `early-flush-clears-output` candidate compiled but created a
ready/flush combinational oscillation and aborted without a report. It is **not a
kill**; [retained failed audit](../../../build/fetch-stage/mutation/audit-zg8x1sn0/recovered-summary.json)
records 11 detections plus 1 invalid execution. The replacement
`early-flush-drops-current-answer` is noncyclic and fails checked public output.
The runner now records a missing-report/abort as invalid execution rather than
crashing or counting it as a kill. No production file was edited for either case.

An additional sustained LOOP-G run uses:

```sh
make check-fetch-stage-run SCENARIO=FE-T16 PROGRAM=long REPETITIONS=1024 JOURNAL=full
```

It completed 1,024 actual conditional executions (1,023 taken then 1 NT), 1,025
updates, two recoveries, 5,644 cycles and 290,999 comparisons with zero mismatches,
without periodic reset. [Long training report](../../../build/fetch-stage/run/FE-T16-b5g18_vm/logs/report.json).

Only `makefile` and this new directory were added/changed. The protected-source
SHA256 baseline covers 341 production RTL/configuration and prior PC/EJU/FM files;
all remain byte-identical. Pure inherited units were also rerun unchanged. The
last aggregate-only option-forwarding edit does not change compiled model/driver
sources; final canonical replay/regression uses the final fingerprint. That phase implemented no full
core, alternative RTL width, EQ08 fix or exception redesign. The later completion
audit executed private width builds; it still implements no RTL recovery redesign.

Files:

| Files | Responsibility |
| --- | --- |
| `fetch_stage_tb.sv`, `.core`, `fetch_stage_waivers.vlt` | Real DUT/public wrapper and build, production dependency list, focused simulator waivers. |
| `fetch_stage_components.hh/.cpp` | Config, independent BTB/gshare, latency samplers, integer/versioned backend and ordered scheduler. |
| `fetch_stage_program.cpp` | Immutable encoded/relocated programs, digests, per-lane faults and bounded resolved-path template proof. |
| `fetch_stage_composition.hh/.cpp` | Direct PC/EJU/FM model composition, metadata adapters, mixer and final-output queue. |
| `fetch_stage_driver.hh/.cpp` | Native phases, causal physical memory, scoreboard, journals, coverage and lifecycle/learning reports. |
| `fetch_stage_tb.cpp` | Options, directed catalog and program-level random campaigns. |
| `fetch_stage_configuration.cpp`, `configuration.py`, `run.py` | Source-derived/static-elaborated configuration, stale guards, locks, FuseSoC build and isolated invocation. |
| `fetch_stage_unit.cpp`, `validate.py` | New/inherited pure units, independent public-journal/lifecycle auditors, replay, injections and negative validation. |
| `regress.py`, `suite.py`, `mutate.py` | Parallel isolated campaigns, aggregate verdicts and disposable RTL audits adapted from earlier frameworks. |
| `README.md`, `VERIFICATION.md`, root `makefile` | Usage, evidence/limitations, requirement ledger and new targets. |

Final validation artifact links:

- [Canonical source/configuration regression](../../../build/fetch-stage/regression/regression-u0056wzg/summary.json).
- [26-case framework validation, including expected negatives](../../../build/fetch-stage/validation/framework-sw5ng34j/summary.json).
- [Final random-framework replay validation](../../../build/fetch-stage/random-framework-canonical-console.log) (contains its isolated evidence directory).
- [Aggregate expected-negative orchestration test](../../../build/fetch-stage/suite-confidence-wlb2xf62/summary.json).
- [Protected-source and post-mutation equivalence audit](../../../build/fetch-stage/source-integrity-final.json).

The equivalence audit confirms that only `suite.py` changed after the twelve
mutation executions; every compiled C++/SV/model source is unchanged. The final
aggregate forwards seed, latency and other run options to directed execution and
the configured seed range to regression. The aggregate is expected to fail while
the documented directed catalog gaps remain. It has not been represented as a
passing all-groups run.

[Consolidated final validation](../../../build/fetch-stage/FINAL_VALIDATION.json) records
current fingerprint, the seven incomplete IDs, lifecycle counts and all evidence paths.


The latest report supersedes the historical missing subcases above: counter
threshold witnesses, shuffled callers, multi-entry restoration, repeated-redirect
rejection, pending E+B+early arbitration and populated/full reset setup now have
focused evidence. The public RAS ledger reports644 operations in the final ordinary
run:142 witnessed,497 unwitnessed cancellations and3 unknown exception transitions.
Canceled operations do not count as verified history. No fresh mutation kills or
complete FEV coverage are claimed. See [COMPLETION_AUDIT.md](COMPLETION_AUDIT.md)
for exact evidence, commands, exclusions, source hashes and remaining limitations.
