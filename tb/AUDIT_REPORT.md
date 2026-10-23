# `tb/` code and verification audit

Date: 2026-10-22. Baseline: `ab26cb1` (clean tracked worktree at audit start).

## Outcome and scope

C++ cleanup, verification infrastructure repairs, focused coverage, and frontend regression execution are complete. **PC-generator, early-jump, and fetch-memory suites pass all seven groups. Fetch-stage executes all five groups without mismatches but remains verification-incomplete.** Its exit status 0 means success with warnings, not specification sign-off.

The user's follow-up prioritized frontend verification and restricted whole-system verification to Spike. Accordingly:

- Reviewed active frontend C++ models, environments, drivers, scoreboards, stimulus, composition/backend utilities, and Python build/regression/evidence infrastructure. Reviewed whole-system C++ checker/adapter/monitor/annotation/logger utilities and the older ALU bench statically.
- Reviewed frontend SV wrappers against current RTL interfaces, lane packing, configuration, and reset/flush behavior; inspected relevant native-memory connections and historical frontend/recovery fixtures. The unchanged memory-backend, LSU, and CU SV suites were not exhaustively audited or executed after the scope clarification.
- Ran frontend suites against current RTL and two whole-system programs with Spike. No ordinary whole-system simulation was used as verification. No production RTL or firmware source changed. Existing mutation suites operate on disposable variants and report production-source integrity separately.
- Applied Ponytail's normal simplification rules to software and conservative rules to architectural verification. Reference-model semantics, assertions, coverage goals, seeds, and diagnostic provenance were retained.

Artifacts are under `build/tb-audit/`, `build/audit-infrastructure/`, `build/audit-sv/`, and the native suite directories indexed below. They are generated evidence, not committed source.

## Findings by severity: repaired

| Severity | Finding and source | Repair and evidence |
| --- | --- | --- |
| High | **Missing coverage could falsely pass a regression.** `tb/frontend/pc_gen/regress.py:15`, `early_jump_unit/regress.py:16`, `fetch_mem_if/regress.py:16` previously substituted `{}` for a missing receipt. `--require-matrix` could then accept a denominator of zero. | Each active campaign must supply the exact matrix schema, unique coordinates, valid required flags, and nonnegative integer counts. Failed seeds retain `coverage_error` and make the aggregate fail, including when matrix closure is optional. Before-fix synthetic producers passed all three CLIs with missing coverage and 0/0 combinations. After-fix tests exercise 22 producer cases per suite; real million-cycle regressions also pass. |
| High | **Buffered output errors could escape final verification status.** PC `pc_gen_scoreboard.cpp:492`, EJU `early_jump_scoreboard.cpp:309`, FM `fetch_mem_scoreboard.cpp:216`, and FE `fetch_stage_driver.cpp:1435` checked streams before their final buffered writes. FE omitted its characterization stream; immutable program/obligation writes were also unchecked. | Explicitly close and check evidence, coverage, characterization, and report streams; check FE program/obligation outputs. EJU/FM finalization errors now return status 2 with a diagnostic instead of escaping main. Pure scoreboard fixtures direct a small report to `/dev/full`: the original matched scoreboard returned normally; repaired code rejects it. FE framework tests additionally induce final buffered/program write errors using `RLIMIT_FSIZE=1`. |
| Medium | **An interrupted fetch-stage run could lose evidence on reuse.** `fetch_stage_driver.cpp:91` protected only an existing `report.json`; other logs were silently truncated. | Reject any nonempty existing logs directory and check stream creation. Six independent preservation cases keep the original bytes and require status 2. No existing evidence is deleted. |
| Medium | **Invalid weights left a dangling logger context.** FE registered `context_.get()` before its throwing weight parser. On constructor failure, members were destroyed without running `Simulator::~Simulator`; main's `TB_ERR` then read the freed context. `fetch_stage_driver.cpp:128`, `fetch_stage_tb.cpp:468`. | Register the logger only after parsing succeeds (`fetch_stage_driver.cpp:147`). Existing malformed-number checks plus missing, nonnumeric, negative, oversized, and unknown weight cases return status 2. Static ownership/lifetime proof is definite; sanitizer execution is not claimed (see limits). |
| Medium | **Current GCC blocked verification builds.** EJU `early_jump_directed.cpp:209` and `:226`; FM `fetch_mem_directed.cpp:61`, `fetch_mem_driver.cpp:83`, `fetch_mem_random.cpp:93`; FE `fetch_stage_driver.cpp:561`. | Separate misleadingly indented independent statements, make an unsigned address literal explicit, and supply the existing `Learning` defaults explicitly. No warnings were disabled. EJU builds and the formerly failing FM/FE mutation builds now compile and execute. |
| Performance | **Repeated formatting allocations and stream construction.** `pc_gen_model.cpp:133`, `:138`, `:162`; these helpers are reused by all frontend benches. | Use bounded hex formatting, direct JSON escaping with reserved string storage, and a fixed initializer list instead of a temporary vector. Preserve the API and exact byte ordering. All 256 byte values, embedded NUL, empty strings, and 1,024 64-bit values are checked. Measured results appear below. |
| Performance | **Quadratic dependency-history lookup.** `fetch_stage_components.cpp:289` performed a full-vector search for each dependency. | Build an ordered identity index once and perform logarithmic lookups. Keep sparse/reordered IDs, the first occurrence of duplicates, rejection order, all assertions, and full diagnostic history. Original and indexed validators both pass 70,660 pure checks with the new fixtures. |

The missing-receipt checks live in `early_jump_unit/suite_unit.py:17`, reused by the other suite self-tests. Buffered-report fixtures live in each `*_scoreboard_unit.cpp` and run from `validate_random.py`. FE preservation/output checks live in `fetch_stage/validate.py:35`.

## Coverage added and configuration compatibility

The ordinary standalone memory and composed frontend benches intentionally select **depth 2, drain-on-flush 0** (`fetch_mem_if/fetch_mem_tb.sv:2`, `:52`; `fetch_stage/fetch_stage_tb.sv:2`, `:63`). The full core instantiates **depth 8, drain-on-flush 1** from `rtl/packages/len5_config_pkg.sv:122`, `:125`, through `rtl/datapath.sv:98`. This is a real coverage boundary; passing the ordinary C++ oracle does not validate the production drain protocol.

Added `tb/frontend/fetch_mem_if/fetch_mem_drain_tb.sv` and a `drain` target in the existing FuseSoC core. `make check-fetch-mem-if-drain` is included in `check-frontend` (`makefile:292`, `:457`). It uses the source-selected depth/width and an independent public-port queue, exact payload/metadata/fault checks, bounded waits, final count assertions, and a watchdog.

At the actual **N=4/depth=8/drain=1** configuration, positive and repeated runs passed with **29 accepted requests, 22 responses, three new-epoch deliveries, and one current-answer consumption on an early-flush edge**. Verified:

- A flush retains credits for physically unreturned requests; a full queue blocks further acceptance.
- Returning one stale response releases one credit, permitting a new request while other stale responses remain. There is no invented requirement to serialize until total drain.
- Stale responses drain under downstream backpressure and repeated flush without escaping as valid new bundles.
- Mixed completed/pending queues clear correctly on flush, including a simultaneous final response.
- Early flush consumes the current answer on the consuming edge while younger work is canceled.
- New metadata, masks, words, per-lane flags/causes, and reset with outstanding work are checked.

A disposable **test-top-only** override to cancel mode compiled and failed at `fetch_mem_drain_tb.sv:203` with `Flush released an unreturned reservation`, exit 1. No production RTL was mutated for this control. Evidence: `build/audit-sv/drain-evidence.json`, `drain.log`, `drain-repeat.log`, and `drain-negative/command.json`.

This closes a directed drain subset. Randomized native-drain modeling, other compiled widths/depths, and complete EJU/native-memory recovery composition remain unverified.

## Regression results

Tools: GCC 16.2.1, system Verilator 5.046 for standalone frontend suites, FuseSoC from the `core-len5` environment. The XML-based Spike integration uses the installed **Verilator 5.040** and pinned Spike v1.1.0 libraries. No dependencies were added or downloaded.

### Before edits

| Suite | Observed result | Evidence |
| --- | --- | --- |
| PC-generator | 7/7 groups passed, including mutations and seeds 1–100 × 10,000 cycles. | `build/pc-gen/suite/all-snknn5rw/summary.json` |
| Early-jump | Build failed on misleading indentation promoted to errors. No baseline native pass claimed. | `build/tb-audit/baseline/check-early-jump.log` |
| Fetch-memory | 6/7 groups passed; directed/framework/random/regression passed. All 16 mutation builds failed on C++ diagnostics, not detected RTL mutants. | `build/fetch-mem-if/suite/all-eajk6u1q/summary.json` |
| Fetch-stage | Directed/framework/random/regression executed without mismatches; mutation builds failed on the incomplete aggregate initializer. Existing completeness warnings remained visible. | `build/fetch-stage/suite/all-lgyzi5lw/summary.json` |

### After repairs

| Suite | Directed evidence | Regression: seeds 1–100 × 10,000 cycles | Mutation result | Aggregate |
| --- | --- | --- | --- | --- |
| PC-generator | 22 scenarios, 8,929 comparisons, zero errors | 6,946,924 comparisons; zero mismatches/environment/framework errors | 8 compiled and detected | 7/7 passed |
| Early-jump | 34 scenarios, 198,106 comparisons, zero errors | 20,077,702 comparisons; zero mismatches/environment/framework errors | 14 compiled and detected | 7/7 passed |
| Fetch-memory | 44 scenarios, 90,133 comparisons; 614 accepted = 579 delivered + 35 canceled; zero pending | 57,693,006 comparisons; zero mismatches/environment/framework errors and pending obligations | 16 compiled and detected | 7/7 passed |
| Fetch-stage | Full catalog plus composite confidence executed; completeness qualifications below | 34,932,920 comparisons; zero mismatches, invalid environments, or framework failures | 12 compiled and detected | All 5 groups executed; **incomplete verification**, exit 0 with warnings |

Post-suite artifact roots:

- `build/pc-gen/suite/all-tajs37ys/summary.json`
- `build/early-jump/suite/all-dcemm066/summary.json`
- `build/fetch-mem-if/suite/all-o2dx1d72/summary.json`
- `build/fetch-stage/suite/all-i59zvz5r/summary.json`

Mutation summaries report identical original-before/after behavior and unchanged production sources. Detection includes explicitly provisional contracts; a killed mutant is checker-sensitivity evidence, not approval of those contracts.

Fetch-stage aggregate: **39,007,792 comparisons, zero mismatches; 951 scenario passes, one provisional scenario, six incomplete scenarios, seven missing witnesses**. Five incomplete cases are explicitly deferred; FE-T47 variant 2 is an unexpected completeness gap. Specifically:

| Case | Remaining obligation |
| --- | --- |
| FE-T41 | Provisional EQ07 same-edge confirmation/restoration ordering. |
| FE-T43 | Complete exception recovery, cold predictor, and intended RAS history. |
| FE-T47 variant 2 | Simultaneously populated histories/full queues/pending control before reset, and later program termination. |
| FE-T48 | Separately tagged delayed data-fault context for EQ08. |
| FE-T49 | Complete delayed-redirect/intervening-dispatch obligations. |
| FE-T50 | Complete faulting JAL/RET characterization. |
| FE-T51 | Alternative grant-on-flush/zero-latency/late-response protocols. |

FE-T47 was investigated with a **50,000-cycle** focused run: 4,048,493 comparisons, zero mismatches, the same two witnesses still missing. Increasing the budget did not close it. `fetch_stage_driver.cpp:1077` requires all occupancy/history/control conditions simultaneously; `:1150` stalls the consumer once confirmed history exists. The evidence establishes an unreachable-in-this-run stimulus goal, not an RTL defect or a proven impossibility. See `build/fetch-stage/run/FE-T47-70y2spj1/logs/report.json`. The wrapper intentionally preserves an incomplete warning at default policy; do not use its status 0 as sign-off.

After the final logger-registration ordering change, both FE framework targets passed again against the final fingerprint, including the added malformed-weight and output-preservation cases. Their receipts are `build/fetch-stage/validation/framework-ql_q85io/summary.json` and `random-2a9xbpi2/summary.json`. The full FE aggregate above preceded only that constructor-order change; its valid stimulus/model semantics are unchanged. Final named PC framework, random-framework, and 100-seed regression gates also passed (`build/tb-audit/post/pc-gen-final-gates.log`).

### Whole-system verification: Spike only

Fresh application images were built using the existing software flow. Both current-core runs used the TC_SRAM configuration and Spike, with waves and instruction traces disabled:

| Run | Result |
| --- | --- |
| `hello_world` | Status 0; 14,122 commits, 11,164 checkpoints, 2,958 out-of-order commits, 932 frontend recoveries; zero discrepancies. |
| `load_store` | Status 0; 2,716 checked commits; zero discrepancies. |
| Injected register observation fault | Expected status 1; confirmed first-commit mismatch at PC `0x10180`, cycle 22, tick 45; report expected `332160`, observed `332161`. |
| One-cycle timeout | Expected rejection, status 1; zero commits, confirmed timeout, reason `simulation ended without normal program exit`. |

Receipts: `build/tb-audit/spike-{hello-world,load-store,register-fault,timeout}/logs/diff/report.json`. Successful exit logs also show application exit code zero. The hello-world receipt explicitly retains one terminal next-PC obligation; this run is not proof of every possible successor after program termination.

These programs are not exhaustive ISA/FPU/exception tests. Prior F/D findings in `tb/verilator/diff/VALIDATION.md` are historical evidence and were not revalidated here. No claim is made about full trap/interrupt synchronization or the unresolved frontend recovery contracts.

## Performance measurements

All measurements compare original and repaired code with unchanged inputs/output checks. Five alternating rounds reduce ordering bias; CPU time is preferred because concurrent builds caused substantial wall-time variation. These are measured workloads, not general PPA or full-suite throughput claims.

### Shared formatting

GCC `-std=c++17 -O2`, CPU affinity 7; **200,000 calls per function per round**. Allocation counts instrument global `operator new`; they count calls, not peak memory. All checksums match.

| Function | Median process CPU before → after | Allocations before → after |
| --- | --- | --- |
| `hex64` | 0.075756 s → 0.027458 s | 400,000 → 200,000 |
| `json_quote` | 0.190009 s → 0.038585 s | 400,000 → 400,000 |
| `inputs_json` | 1.734900 s → 0.662741 s | 6,000,000 → 3,200,000 |

A real PC-generator **10,000-cycle, seed-17, full-journal** run was also paired five times before/after. Median child CPU was **1.538064 s → 0.843027 s**; contended wall medians were 4.921258 s → 2.387416 s. All ten runs returned zero and produced the same **57,994,573-byte journal**, SHA256 `474b00fc75d0d2881b1fd7d1803d0521eb2c0be5a3fede32d26eea5f21f6394a`. This demonstrates unchanged sampled behavior and improved CPU cost for that journaling workload; it does not establish the same speedup with bounded journals, FST, another suite, or another host.

Evidence: `build/tb-audit/performance/{format_bench.cpp,format-cpu.json,pc-gen-paired.json}` and their raw logs. Historical unpaired wall timings are retained but were not used for the improvement claims.

### Backend history validation

The original algorithm scanned the entire vector for each dependency. The repaired validator builds the existing identity structure as a map of ID to record pointer and performs `O(log N)` lookup; with at most two dependencies/record, validation is `O(N log N)` instead of quadratic. It preserves arbitrary sparse/reordered IDs and every original lifecycle/bandwidth/dependency check. It stores one additional record pointer per identity relative to the previous set; peak-memory improvement is not claimed.

Five alternating rounds at CPU 7 validate chains of 1,000/5,000/10,000/20,000 records three times each, plus ten matching acceptance/diagnostic fixtures. Median process CPU for the complete fixed round: **3,181.649 ms → 184.165 ms (17.28×)**. Full pure units pass on both implementations with the new fixtures (70,660 checks). Existing per-cycle backend scans and full histories were retained; no corresponding complete-simulation speedup is claimed.

Reproducer/evidence: `build/tb-audit/performance/benchmark_backend_history.py`, `backend_history_benchmark.cpp`, `backend-history-results.json`, and per-round logs.

## Remaining findings and recommendations

These were not silently treated as repaired. “Source-verified” means the mechanism is established by code inspection, with runtime execution status stated separately.

| Severity / confidence | Location and issue | Recommended follow-up |
| --- | --- | --- |
| High, source-verified; runtime not executed | `tb/expipe/alu/alu_tb.cpp:181` always returns 0 after reporting scoreboard errors. `tb_components.cpp:108` logs an orphan response then still calls `front()` on an empty queue. | Repair ALU pass/fail and orphan handling before relying on that bench. Its simulation was deferred under the frontend verification focus. |
| Medium, source-verified; runtime not executed | ALU generator leaks request allocations (`alu_tb.cpp:144`); raw monitor/scoreboard ownership is not cleaned up; `%14` at `:259/:270` omits ALU_SLTU, and `%(...-1)` excludes final corner/ROB entries. Time-based seed at `:89` impedes replay; no downstream backpressure is generated. | Use value ownership/RAII, deterministic explicit seeds, complete enum/index ranges, draining, and handshake/ROB-index checks with focused regression proof. Do not fold this into frontend oracle changes. |
| Medium, source-verified bounds risk; no sanitizer run | `tb/verilator/tb_macros.cpp:82`, `:98`, `:112`, `:125`, `:138` copy source paths with unbounded `strcpy` into 256 bytes, then use unbounded `sprintf`. Long checkout/source paths can overrun the buffers. | Remove the mutable basename copy and use safe prefix construction while preserving ANSI/alignment and complete diagnostics; add a long-path test. |
| Medium, source-verified policy gap | Native calls in the three submodule `regress.py` runners and their `suite.py:23` group runners have no wall-clock watchdog. Cycle limits cannot stop a process hung outside the cycle loop or a stalled build. FE already has `results.process`. | Define a project timeout policy and apply it with preserved per-case failure evidence. Avoid imposing a short fixed bound on deliberately large/FST workloads. No hanging process was observed. |
| Medium, source-verified annotation risk; runtime untested | `tb/verilator/diff/annotate.cpp:193/:203` accepts trailing partial `Event` data as EOF. GTKWave/legend streams at `:240/:312` lack final error checks; final FST flushing happens after the writer error check. | Reject partial records and failed final writes; test truncated journals and failing sinks. Checker result comparison itself was not modified. Spike waves-on annotation was not exercised in this audit. |
| Medium, source-verified configuration mismatch; execution deferred | Recovery reproducer `frontend/early_jump_unit/recovery/recovery_tb.sv:4` and `exercise.py:76` use `0x1000`, outside current TC_SRAM IMEM `0x10000` / DMEM `0x50000`. `run.py:31` changes copied issue width, not this map. | Update or retire the historical whole-system reproducer; any replacement validation must use Spike per current user scope. Its four-entry RAS capture also needs a depth guard/adaptation for other depths. |
| Medium, observed coverage gap | FE-T47 remains incomplete even at 50,000 cycles; ordinary standalone oracles still cover depth-2 cancel mode. | Construct a causal FE-T47 stimulus that reaches every simultaneous precondition; add randomized drain-mode and composed recovery verification without weakening existing witnesses. |
| Low, source-verified stale-artifact risk; no current false pass reproduced | `scripts/sim/benchmark-diff.py:42` reuses numbered directories and `:58` reads an existing checker receipt without a freshness guard. It does separately check process/program status. | Use private run directories or reject stale receipts. Consequences require a failed/nonreporting producer; ordinary current simulations were not observed to do this. |
| Low, source-verified pass-criteria boundary | `len5_tb.cpp:265` passes `gotFinish()` to the differential checker; the application's nonzero exit byte is not incorporated directly into checker status. Spike agreement and application correctness are separate. | Application regressions must check the program exit byte as well as Spike status, as `benchmark-diff.py` does. No nonzero-program fixture was run here. |
| Low, source-verified resource risk; constructor-failure path untested | `tb/verilator/diff/spike_adapter.cpp:50` owns its log sink through a raw `FILE*`; a later constructor exception bypasses `Impl::~Impl`. | Convert that sink to RAII while retaining processor-before-sink destruction order; test initialization failure. |

Historical `frontend/front_end_tb.sv` / `B_Front_end_TB.sv` reference obsolete interfaces and lack meaningful checking; active manifests do not use them. Their completion is not passing coverage. Current four public wrappers otherwise map the reviewed RTL interfaces consistently; no SV interface repair was necessary.

Residual PC Q1/Q3/Q4/Q5/Q9, EJU EQ questions, FM FQ questions, predictor-agnostic checking, all temporal Cartesian crosses, all widths/parameter combinations, and full-system trap/interrupt behavior remain explicit limits. Mathematical N=1/2/4/8 unit fixtures are not alternate RTL builds. Short reset-only PC/EJU random budgets can produce valid known checks without useful functional coverage; regression matrix requirements and coverage receipts remain essential.

## Executed commands and evidence index

Commands ran from the repository root. Suite commands below were executed before and after edits; shell redirection placed complete output under `build/tb-audit/{baseline,post}/`. No repository-wide `make check`/`make format` was run because those workflows can rewrite production RTL and include verification outside the narrowed scope.

```sh
export PATH=/home/markospremic/miniconda3/envs/core-len5/bin:$PATH
make check-pc-gen JOBS=4 TEST_JOBS=3 SEEDS=100 CYCLES=10000 REQUIRE_MATRIX=true
make check-early-jump JOBS=4 TEST_JOBS=3 SEEDS=100 CYCLES=10000 REQUIRE_MATRIX=true
make check-fetch-mem-if JOBS=4 TEST_JOBS=3 SEEDS=100 CYCLES=10000 REQUIRE_MATRIX=true
make check-fetch-stage JOBS=4 TEST_JOBS=3 SEEDS=100 CYCLES=10000 REQUIRE_MATRIX=true
make check-pc-gen-framework check-pc-gen-random-framework check-pc-gen-regression \
  SEEDS=100 CYCLES=10000 JOBS=4 REQUIRE_MATRIX=true
make check-fetch-stage-framework check-fetch-stage-random-framework JOBS=4
make check-fetch-mem-if-drain BUILD_DIR="$PWD/build/audit-sv"
SCENARIO=FE-T47 VARIANT=2 DIRECTED_CYCLES=50000 MAX_CYCLES=60000 \
  LOG_LEVEL=LOG_NONE make check-fetch-stage-run JOBS=4
python3 tb/frontend/pc_gen/suite_unit.py --output build/audit-infrastructure/pc_gen
python3 tb/frontend/early_jump_unit/suite_unit.py --output build/audit-infrastructure/early_jump_unit
python3 tb/frontend/fetch_mem_if/suite_unit.py --output build/audit-infrastructure/fetch_mem_if
python3 tb/frontend/fetch_stage/results_unit.py
python3 tb/frontend/fetch_stage/history_audit_unit.py
/usr/bin/g++ -std=c++17 -O2 -Wall -Wextra -Werror \
  tb/frontend/pc_gen/pc_gen_model.cpp tb/frontend/pc_gen/pc_gen_environment.cpp \
  tb/frontend/pc_gen/pc_gen_unit.cpp -o build/tb-audit/pc-gen-unit
build/tb-audit/pc-gen-unit
/usr/bin/g++ -std=c++17 -O2 -I tb/frontend/pc_gen \
  build/tb-audit/performance/format_bench.cpp \
  build/tb-audit/performance/pc_gen_model.before.cpp \
  -o build/tb-audit/performance/format-before
/usr/bin/g++ -std=c++17 -O2 -I tb/frontend/pc_gen \
  build/tb-audit/performance/format_bench.cpp \
  build/tb-audit/performance/pc_gen_model.after.cpp \
  -o build/tb-audit/performance/format-after
python3 build/tb-audit/performance/benchmark_backend_history.py
git diff --check
git diff --name-only -- rtl
```

Whole-system commands used only differential verification. Application builds additionally put `/home/markospremic/Documents/epfl_len5/tool/riscv/bin` on PATH:

```sh
make verilator-build-debug DEBUG_BUILD_DIR="$PWD/build/tb-audit/spike" \
  VERILATOR=/home/markospremic/Documents/epfl_len5/tool/verilator/5.040/bin/verilator JOBS=4
make app PROJECT=hello_world BUILD_DIR="$PWD/build/tb-audit/firmware"
make verilator-opt-debug DEBUG_BUILD_DIR="$PWD/build/tb-audit/spike" \
  VERILATOR=/home/markospremic/Documents/epfl_len5/tool/verilator/5.040/bin/verilator \
  FIRMWARE="$PWD/build/tb-audit/firmware/main.hex" \
  SIM_RUN_DIR="$PWD/build/tb-audit/spike-hello-world" \
  MAX_CYCLES=100000 DUMP_WAVES=false DUMP_TRACE=false JOBS=4
make app PROJECT=load_store BUILD_DIR="$PWD/build/tb-audit/firmware-load-store"
mkdir -p build/tb-audit/spike-load-store build/tb-audit/spike-register-fault build/tb-audit/spike-timeout
build/tb-audit/spike/sim-diff-verilator/Vtb_bare --diff --max_cycles=100000 \
  --dump_waves=false --dump_trace=false --log_level=LOG_LOW \
  --run_dir="$PWD/build/tb-audit/spike-load-store" \
  +firmware="$PWD/build/tb-audit/firmware-load-store/main.hex"
build/tb-audit/spike/sim-diff-verilator/Vtb_bare --diff --max_cycles=100000 \
  --dump_waves=false --dump_trace=false --log_level=LOG_LOW --diff-fault=register \
  --run_dir="$PWD/build/tb-audit/spike-register-fault" \
  +firmware="$PWD/build/tb-audit/firmware/main.hex"
build/tb-audit/spike/sim-diff-verilator/Vtb_bare --diff --max_cycles=1 \
  --dump_waves=false --dump_trace=false --log_level=LOG_LOW \
  --run_dir="$PWD/build/tb-audit/spike-timeout" \
  +firmware="$PWD/build/tb-audit/firmware/main.hex"
```

Exact expanded compiler/simulator arguments for generated tests are retained in `build/tb-audit/output-before/{summary,matched-summary}.json`, suite/regression reports, `build/audit-sv/drain-negative/command.json`, and the benchmark drivers/raw logs. The missing-coverage before-fix reproductions are under `build/audit-infrastructure/{pc_gen,early_jump_unit,fetch_mem_if}/all-*/summary.json`; after-fix self-tests retain all 22 cases in their `suite-checks-*` directories.

Final native regression logs, frame/replay checks, pure units, output-failure fixtures, and `git diff --check` passed as qualified above. `git diff --name-only -- rtl` is empty. No sanitizer success is claimed: a lifecycle-only ASAN harness could not link because `/usr/lib64/libasan.so.8.0.0` is absent; no dependency installation was attempted. No synthesis/PPA, exhaustive SV-memory/LSU/CU suite, full ISA compliance, alternate native width sweep, or full architectural sign-off was performed.
