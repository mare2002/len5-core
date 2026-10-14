# Standalone pc_gen verification

Native C++/Verilator verification of the public pc_gen interface. The independent
[VERIFICATION.md](VERIFICATION.md) contract now incorporates the approved Q1–Q10
decisions. Both profiles enforce async reset, full redirect priority, early jumps
during stalls, exact target pass-through, modular arithmetic and N-aware bundle
progression. Residual acknowledgment/lifecycle/consumer-flush assumptions stay
explicit. This verifies pc_gen alone, not the frontend or processor.

**Current result:** the selected N=4 DUT has a confirmed normal-progression defect
after unaligned supplied targets: `0x701 -> 0x711`, where C3/D requires `0x710`.
Target pass-through itself is correct. T19 and randomized characterization preserve
this evidence and return nonzero. RTL and configuration were not modified.

## Build and run commands

Initialize Conda in your shell first if necessary, then:

```sh
source private/init.sh
make check-pc-gen
make check-pc-gen-framework
make check-pc-gen-random-framework
make check-pc-gen-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-pc-gen-mutations JOBS=2
```

| Target | Action |
| --- | --- |
| `pc-gen-build` | Build only the currently source-selected DUT and native harness; no simulation. |
| `check-pc-gen` | Build and run all T01–T22; SCENARIO selects one. Original DUT failures return nonzero. |
| `check-pc-gen-framework` | Compile independent model/environment units; execute directed profiles, replay/FST, logger, failure injection and stale-configuration guards. Original DUT failures remain failures. |
| `check-pc-gen-random` | Build and run one seeded random campaign; defaults 10000 cycles, all campaigns. |
| `check-pc-gen-random-framework` | Native randomized validation, three synthetic confidence fixtures, four pure coverage-width fixtures, journal/causality/temporal reconstruction, replay, weights and failure paths. |
| `check-pc-gen-regression` | Build once, run SEEDS consecutive seeds in JOBS parallel workers, aggregate independent reports/coverage. REQUIRE_MATRIX fails incomplete required combinations. |
| `check-pc-gen-mutations` | Compile disposable RTL mutations with current production packages, verify detection and compare original before/after. Original baseline failures still yield nonzero. |

Build/setup invocations sharing one configuration should be completed before
starting independent native runs; the multi-seed regression builds once then
safely runs seeds in parallel. FuseSoC setup can replace its build outputs. Every
simulation has a private run directory. No RTL formatting, firmware, Spike,
Cocotb or integration test is used. Existing C++17/FuseSoC/Edalize/Verilator/FST tools
are reused, with the system compiler and no new dependencies.

```sh
# Focused approved scenarios (currently passing).
make check-pc-gen SCENARIO=T09 SEED=7 LOG_LEVEL=LOG_MEDIUM
make check-pc-gen SCENARIO=T12 PC_GEN_CONTRACT=strict

# Reproduce the observed defect, with public-port waveform evidence.
make check-pc-gen SCENARIO=T19 SEED=7 DUMP_WAVES=true LOG_LEVEL=LOG_HIGH

# Instruction-aligned but non-bundle-aligned BOOT; same selected issue width.
make check-pc-gen SCENARIO=T01 BOOT_PC=65924

# One seeded campaign or a longer parallel campaign.
make check-pc-gen-random SEED=17 CYCLES=10000 CAMPAIGN=architectural
make check-pc-gen-regression SEEDS=100 CYCLES=10000 JOBS=4 \
    CAMPAIGN=stress PC_GEN_CONTRACT=strict REQUIRE_MATRIX=true
```

`SEED`, `SEEDS`, `CYCLES`, `JOBS`, `SCENARIO`, `BOOT_PC`, `MAX_CYCLES`,
`LOG_LEVEL`, `DUMP_WAVES`, `PC_GEN_CONTRACT`, `CAMPAIGN`, `GUIDED`, `WEIGHTS`,
`JOURNAL`, `REQUIRE_MATRIX`, `BUILD_DIR`, `FUSESOC`, `VERILATOR` retain existing
conventions. Campaign is `all|architectural|stress|characterization`. Journal is
`auto|full|failures`; normal random mode uses the bounded failure journal instead
of allocating/formating every successful sample. Runtime boot cannot repair or
synchronize expected state: BOOT_PC is an elaboration parameter, split into
unsigned BOOT_PC_HI/LO to avoid CLI truncation.

The issue width has no Make or runtime selector. Set the existing
`LEN5_MULTIPLE_ISSUES` literal in `rtl/packages/len5_config_pkg.sv` to 1, 2, 4 or 8,
then use the same commands. The framework builds only that selected configuration.
`configuration.py` reads that definition and the independent XLEN/ALEN/ILEN/WWIDTH
constants from `len5_pkg.sv`; expressions it cannot evaluate are rejected clearly.
It verifies C is disabled. No generated package or RTL override selects N.

Build roots are `build/pc-gen/model/boot-<canonical-decimal>/issues-<N>-<SHA256>/`.
The fingerprint includes the production packages/module, core definitions, compiled
harness sources/headers, configuration reader, build helper and BOOT_PC. Equivalent
hex/decimal BOOT_PC inputs share a root. Source changes select a new root; a check
also rejects changes during compilation. FuseSoC compiles the original package
files with `--no-export`. Its dependency files still handle incremental builds.
Archived pre-configuration binaries are never selected by the new Make targets.

The helper writes source-derived verification metadata and exact package snapshots beside
the executable after a successful build. Native startup checks the snapshots against
the original source, checks source-derived N/XLEN/ALEN/instruction size/issue bits/
instruction suffix/LWIDTH/BOOT_PC against the elaborated adapter, and constructs the
model from source-derived values. Missing metadata, stale source, unsupported values
or elaboration disagreement return status 2 before simulation. These files describe
the source; they are not an independent issue-width setting. Keep them with a copied
binary and keep the source available for the startup audit.

After `make pc-gen-build`, resolve the current paths instead of naming an old cache:

```sh
pc_gen_model=$(python3 tb/frontend/pc_gen/configuration.py --model-dir)
pc_gen_binary=$(python3 tb/frontend/pc_gen/configuration.py --binary)
fusesoc run --no-export --target sim --tool verilator \
  --build-root "$pc_gen_model" --run polito:len5:pc-gen-tb \
  --run_dir=/absolute/path/to/a/new/run --seed=7 --scenario=all
python3 tb/frontend/pc_gen/validate.py --binary "$pc_gen_binary"
```

Use `configuration.py --boot <BOOT_PC> --build-dir <BUILD_DIR>` when resolving a
nondefault build. Manual FuseSoC setup alone does not produce the native source-audit
metadata; use the supported build helper first. Replay commands include
`--expect_issues=N`, a compatibility assertion that cannot change elaboration.
A different compiled width or a stale production source fails clearly.

Do not run `make check` for this task: that target formats production RTL in
place. The new targets do not format or alter RTL and are not inserted into
the unrelated existing processor regression.

## Components and independence

| File | Responsibility |
| --- | --- |
| [pc_gen_tb.sv](pc_gen_tb.sv) | Test-only flat port adapter around the unchanged DUT. Connects resolution fields by name. Exposes only static elaboration configuration and public DUT outputs; no reference behavior. |
| [configuration.py](configuration.py), [pc_gen_configuration.cpp](pc_gen_configuration.cpp) | Source parsing, configuration fingerprints and native source/elaboration audit; no DUT behavior. |
| [pc_gen_model.hh](pc_gen_model.hh), [pc_gen_model.cpp](pc_gen_model.cpp) | DUT-independent behavioral cursor, per-output expected/known fields, semantic transitions and confidence/assumption metadata. No Verilator dependency. |
| [pc_gen_environment.hh](pc_gen_environment.hh), [pc_gen_environment.cpp](pc_gen_environment.cpp) | Abstract fetched instruction records, availability, prediction history, redirects, held early requests, branch recovery throttling and reset epochs. |
| [pc_gen_driver.hh](pc_gen_driver.hh), [pc_gen_driver.cpp](pc_gen_driver.cpp) | Deterministic public-port setup, input readback, settled snapshots, rising/falling edges and stopped-clock probes. |
| [pc_gen_scoreboard.hh](pc_gen_scoreboard.hh), [pc_gen_scoreboard.cpp](pc_gen_scoreboard.cpp) | Requirement-tagged comparisons, bounded history, journal/report generation and observed functional coverage. |
| [pc_gen_tb.cpp](pc_gen_tb.cpp) | CLI and the T01-T22 directed scenario catalog. Semantic stimuli are shared with the random generator. Directed burst lengths and random campaigns use the explicit seed. |
| [pc_gen_random.hh](pc_gen_random.hh), [pc_gen_random.cpp](pc_gen_random.cpp) | Seeded semantic scenarios, weighted actions, bounded coverage feedback and reproducible payload/latency streams. |
| [regress.py](regress.py), [validate_random.py](validate_random.py), [mutate.py](mutate.py) | Isolated parallel seed regressions, coverage merging, native replay/causality/coverage/failure validation. |
| [pc_gen_tb.core](pc_gen_tb.core) | Native FuseSoC integration; depends only on LEN5 packages and the shared logger. Compiles only this production module and the test-only wrapper. |
| [pc_gen_unit.cpp](pc_gen_unit.cpp), [pc_gen_scoreboard_unit.cpp](pc_gen_scoreboard_unit.cpp), [validate.py](validate.py) | Model/causality invariants and native integration/failure-path validation. |
| [check-pc-gen.sh](../../../scripts/sim/check-pc-gen.sh) | Build serialization, private run directories and console capture. |

The model owns its expected cursor. Ordinary progression consumes an address
interval for the offered bundle, rather than copying the RTL's increment
bit-slicing/negation algorithm. Recovery uses the independently described
instruction's successor or supplied target. Early operands refer to an older
fetched instruction or a generated saved return prediction, never current DUT
pc_o. There is no internal-state observation, force, repair or synchronization.

Configuration is read from source-derived build metadata and checked once against
constants explicitly exposed by the test wrapper. These are the elaborated
BOOT_PC and package widths, not dynamic DUT state. All input and output monitors read public wrapper ports. The expected
model and environment receive stimulus/configuration only; neither accepts an
`Outputs` object or a DUT handle. Actual acceptance is counted separately from
expected acceptance, so a bad valid/ready output cannot advance the oracle.

Architectural scenarios fetch live records before generating J/R/E. Resolution
payloads and the mispredict qualifier are checked against stored prediction and
execution descriptions. Mature returned records gate early jumps; reset and
recovery invalidate younger histories. Accepted early metadata updates the
generated instruction's predicted successor, so a saved return prediction can
later be corrected by branch resolution. This remains a small causal model,
not a BPU/RAS/memory/backend simulation. Directed availability is two cycles; random bundle maturity is ordered and
varies from two to twelve cycles; synthetic timing and simultaneous cases remain interface stress.

Raw combination tests, correct pc_gen resolutions not emitted by the present
producer, and consecutive recovery pulses have the `interface_stress` category.
Raw targets use `characterization` while approved PC behavior remains exact.
Unused metadata is explicitly don't-care; unresolved sidebands have unknown expectations. They are retained in reports, not called unreachable
or silently omitted.


## Contract profiles and residual details

| Behavior | proposed | strict |
| --- | --- | --- |
| Reset, PC transitions, all event priorities, sequential formula, raw targets | Definitive D (C5 A/D). | Same definitive checks. |
| Selected early metadata | Exact older base+offset, D. | Same exact check. |
| Commit-overridden/reset/idle early metadata | Explicit don't-care, no comparison. | Same. |
| R-overridden J metadata | Q4 unknown; consumer flush window not observable. | Same. |
| Ordinary valid without E/R/J | Required high after release, zero during reset. | Same. |
| Control-cycle valid | Existing I/Q5 suppress E/R, keep J offer. | Unknown. |
| Control-ready | I/Q5 ready=1 for sole active E or R. | Unknown. |
| Idle/reset/shared losing-request ready | Unknown, not an always-high golden requirement. | Same. |

Early correction is no longer provisional or memory-gated in either profile.
Historical `EARLY_ACCEPT=ready|unknown` and `EARLY_TARGET=arithmetic|unknown` choices
are rejected with status 2 rather than weakening approved checks. `level` and
`relevant` remain harmless compatibility aliases. The earlier ready-gated and
always-arithmetic provisional mismatch evidence remains in the historical section
of VERIFICATION.md; it is not evidence of current RTL defects.

Outstanding standalone details concern Q1/Q5 ready during reset/idle and losing
acknowledgments; Q3 held producer lifecycle; Q4 branch-overridden consumer flush
window; Q9 precise integration scheduling/cancellation. All Q1–Q10 statuses stay
in report `specification_status`; active `unresolved_questions` lists only residual
Q1/Q3/Q4/Q5/Q9. Trap/interrupt/MRET target construction Q10 is outside scope.

## Randomization, coverage and replay

Policy v3 uses separate event/payload/latency streams, weighted semantic scenarios,
causal architectural records and actual observed coverage deficits. It permits
prediction updates during stalls, and checks raw byte targets in characterization
instead of making approved PC behavior unknown. All lanes and coverage denominators
adapt to source N. Architectural traffic excludes invalid identities/misaligned
instructions and conservatively serializes E/R/J producers. Pin stress covers all
legal rows; characterization covers raw/absent-history requests and residual fields.

Weights retain their existing syntax and defaults:

```
normal=40,stall=20,branch=15,early=10,commit=5,overlap=5,reset=5,prediction=25,ready=65
```

Set `GUIDED=false` for unassisted weighted runs. With guidance enabled even zero
base event weights do not prohibit a legal under-covered row. Guidance never
creates an impossible live instruction. Same policy/config/seed/profile/weights
replays deterministically; v3 intentionally changes v2 streams. Per-seed replay
commands contain exact options and `--expect_issues=N` as a guard, not selector.
Replace NEW_REPLAY_DIRECTORY with a new directory before executing the command.
Detailed debug replay uses `--journal=full --log_level=LOG_HIGH --dump_waves=true`.

V01–V16 retain event/qualification/priority/stall/sequence/lane/target/boundary/
reset/state/causal-age categories. V17 adds matched raw-target low-bit classes;
V18 counts observed stalled prediction updates. Counters are split by campaign
and distinguish offered rows from checked output outcomes. Matrix closure is not
exhaustive sign-off. Failed outputs do not earn matched outcome coverage. Unknown
and don't-care output sample counters are separate. The reports preserve requirement
provenance, live IDs/epochs, selected event and the recent eight-sample failure journal.

## Logs, reports and exit status

The shared TbLogger/TB_* macros, ANSI prefixes, verbosity levels, context timestamps,
zero-based consuming cycles and REQ/RSP/SCB messages are preserved. Addresses use
zero-padded 64-bit hex. Ordinary random runs do not log every cycle. Failure records
include scenario/requirement/evidence, seed/cycle/phase, inputs, previous independent
PC, selected event, expected/actual values, bounded recent history and replay.
Summaries retain `TEST SUCCEEDED > errors: <errors>/<transactions>` and
`TEST FAILED > errors: <errors>/<transactions>`. Field comparisons, checked
transactions, cycles and sampled records are separate counts.

| Native status | Meaning |
| --- | --- |
| 0 | Selected checks passed with meaningful comparisons; residual scope remains. |
| 1 | Confirmed/provisional/injected output mismatch. |
| 2 | Invalid configuration, environment or framework error. |
| 3 | Empty/incomplete/timeout evidence. |

Make itself normally exits 2 when a failing recipe returns 1; report.json preserves
the native status. Framework validation can report `framework_checks_passed_dut_failed`:
its meta checks pass, original DUT still fails and the command returns nonzero.
Mutation summary similarly separates detection from original baseline failure.

Artifact roots retain existing conventions:

- Model: `build/pc-gen/model/boot-<decimal>/issues-<N>-<fingerprint>/` with build.log.
- Runs: isolated `build/pc-gen/run/<scenario>-<seed>-<suffix>/console.log` and `logs/`.
- Per-run logs: `report.json`, `coverage.json`, `samples.jsonl`, `characterization.jsonl`, optional `waves.fst`.
- Validation: `build/pc-gen/validation/directed-*` and `random-*`, including unit/confidence/coverage fixtures and summary.json.
- Regression: `build/pc-gen/regression/<campaign>-<profile>-<suffix>/summary.json`, private seed directories and console logs.
- Mutation: `build/pc-gen/mutation/audit-*/summary.json`, disposable mutant sources/builds, original before/after evidence.

## Current audit results

Current audit details and final completed counts are recorded below. The older
N=8 zero-mismatch campaigns preceded the approved raw-target successor checks.
Only N=4 has been compiled and executed in this phase; all-width pure C++ fixtures
are mathematical/collector tests and do not imply four DUT builds.


The final machine-readable audit is
[approved-contract-audit.json](../../../build/pc-gen/approved-contract-audit.json).
All commands below used **N=4**, XLEN=64, ILEN=32, C disabled. The user-selected
`rtl/packages/len5_config_pkg.sv:37` remained untouched. Hashes of all 331 production
files match the beginning of this task, including the user's pre-existing N=4 edit.

| Validation | Actual result |
| --- | --- |
| FuseSoC/Verilator build | Successful current N=4 build; source/elaboration and replay-width checks pass. |
| Directed suite | All 22 scenarios executed; 21 pass, T19 fails with 30 confirmed PC comparisons. Seed 1: 1390 cycles, 8929 comparisons. Seed 7 proposed: 8917 comparisons; strict: 7987; both retain the same 30 mismatches. |
| Independent units | 341 native model/environment checks pass; pure mathematical widths 1/2/4/8, no alternate RTL configuration builds. |
| Directed framework validation | 11 native cases plus configuration/policy guards complete; logger/replay/FST and PC/valid injection, invalid environment, framework error, empty/timeout statuses verified. Meta checks pass; original DUT failures produce nonzero. |
| Random framework validation | 16 native cases, three synthetic scoreboard confidence cases, four pure coverage-width fixtures, two obsolete-policy guards, causal/matrix/stall/sequence reconstruction and incomplete aggregate checks complete. Meta checks pass; original characterization failures retained. |
| Partial-bundle BOOT | BOOT_PC=65924 (`0x10184`), N=4: T01/T02/T04 pass with 46/176/210 comparisons. |
| Real failure replay | Seed 1, policy v3, 10000 cycles, same digest and identical first discrepancy including recent history; LOG_HIGH/full journal/FST saved. |
| Mutation audit | Eight disposable mutants compile and are detected; no survivors. Seven have confirmed detections; fetch-suppression mutant is detected under retained provisional Q5 valid qualification. Original before/after results and stimulus are identical, retaining T19 failure. Audit returns nonzero for failed original baseline. |

Large-regression counts exclude extra directed/framework/replay/mutation executions:

| Regression (each seeds 1–100, 10000 cycles/seed, JOBS=4) | Cycles | Comparisons | Confirmed PC mismatches | Runtime excluding build | Required combinations / feature goals |
| --- | --- | --- | --- | --- | --- |
| All campaigns, proposed | 1000000 | 6946907 | 22216 | 8.12 s | Architectural 20/20, 203/203; stress 48/48, 319/319; characterization 48/48, 334/334. |
| All campaigns, strict | 1000000 | 5452565 | 22216 | 8.25 s | Same complete declared goals. |
| Architectural, proposed | 1000000 | 6207249 | 0 | 2.88 s | 20/20, 203/203. |
| Interface stress, proposed | 1000000 | 7105723 | 0 | 2.90 s | 48/48, 319/319. |

Total: **400 seed executions, 4000000 cycles, 25712444 comparisons, 44432 confirmed
PC mismatches**. The two mixed regressions fail on the same underlying normal
alignment defect; their mismatches occur exclusively in characterization and
include propagated PC differences on later hold/falling samples. These are not
44432 independent defects. No provisional mismatches or unexpected environment/
framework errors occurred in these four regressions. Architectural and stress
portions of both profiles also report zero mismatches.

There are no remaining declared feature or required combination gaps. Raw reset
coverage is 32/32 in stress/characterization; architectural reset traffic exercises
16/32 raw rows because its E/R/J producer policy serializes sources. Unreachable
architectural rows are excluded with reasons, and full raw reset dominance is
covered by T13/pin stress. These denominators do not include idle/overridden
metadata correctness, physical flush proof, actual address-map executability or
unimplemented producer protocols. Full coverage does not establish exhaustive
correctness; T19 demonstrates a failure despite coverage closure.

Mutation evidence (55.93 s for the audit) records first detection:

| Mutation | Requirement / scenario | Detection classification |
| --- | --- | --- |
| Ordinary PC+4 instead of bundle successor | C3 / T02 | Confirmed. |
| PC+B instead of partial-bundle boundary | C3 / T02 | Confirmed. |
| Current prediction outranks older J | C9 / T09 | Confirmed. |
| Advance during stall | C2 / T03 | Confirmed. |
| Not-taken recovery omits +4 | C5 / T06 | Confirmed. |
| Wrong older early base | C6 / T09 | Confirmed metadata, plus PC discrepancy. |
| Wrong BOOT reset value | C1 / T01 | Confirmed async/edge reset. |
| Fetch not suppressed on recovery | C4 / T05 | Provisional Q5 contract, reported separately. |

Evidence locations:

- [Directed result](../../../build/pc-gen/run/all-1-kqtHFl/logs/report.json) and [focused T19](../../../build/pc-gen/approved-focused-uv5atlxe/T19/logs/report.json).
- [Framework summary](../../../build/pc-gen/validation/directed-9eupxaxl/summary.json) and [random framework summary](../../../build/pc-gen/validation/random-c648xk50/summary.json).
- [Mixed proposed regression](../../../build/pc-gen/regression/all-proposed-v5l4nt6g/summary.json) and [mixed strict regression](../../../build/pc-gen/regression/all-strict-ozyx3len/summary.json).
- [Architectural regression](../../../build/pc-gen/regression/architectural-proposed-p46kvs6f/summary.json) and [stress regression](../../../build/pc-gen/regression/stress-proposed-c_wtnts1/summary.json).
- [Mutation audit](../../../build/pc-gen/mutation/audit-u6v45cj_/summary.json), original before/after logs and private mutant builds.
- [Seed-1 actual failure replay](../../../build/pc-gen/approved-regression-replay-g2ga2130/summary.json); its logs contain full sample journal and waves.fst.
- [Partial-BOOT lane/prediction tests](../../../build/pc-gen/approved-boot-lanes-dt1trszf/summary.json).

Reproduction commands:

```sh
source private/init.sh
make check-pc-gen SCENARIO=T19 SEED=7 DUMP_WAVES=true LOG_LEVEL=LOG_HIGH
make check-pc-gen-regression SEED=1 SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-pc-gen-regression SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true PC_GEN_CONTRACT=strict
make check-pc-gen-mutations JOBS=2
```

Updated files are the model `.cpp/.hh`, driver `.cpp`, directed test `.cpp`, random
`.cpp/.hh`, scoreboard/coverage `.cpp/.hh`, both unit `.cpp` files, validation,
random-validation, regression and mutation Python scripts, and README/VERIFICATION.
Existing test-only adapter, FuseSoC files, Make targets, configuration parser and
build helper are reused unchanged in this phase. Generated evidence remains in
build/. Remaining scope limitations are the residual Q1/Q3/Q4/Q5/Q9 details and
Q10 redirect-producer verification, physical timing and integration cancellation;
no full-frontend or processor correctness claim is made.
