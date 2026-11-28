# LEN5 system-level OoO simulator

This configurable microarchitectural performance model compares retirement policies on the same instruction stream and execution resources. It models timing, dependencies, bandwidth and storage. Register data are opaque result tokens. Instruction semantics, numerical results and RTL cycle equivalence are outside the model.

## Install and run

Use Python 3.11 or later. From the repository root, install the dependencies and run the simulator.

```sh
python3 -m venv python/system_level/.venv
python/system_level/.venv/bin/python -m pip install -r python/system_level/requirements.txt
make sim-run
make sim-test
```

The Python Makefile uses that virtual environment when present. Set `PYTHON` to use another interpreter. The default YAML enables Normal OoO, LEN5 OoO commit and basic-block OoO commit and generates a random workload. Add `ideal_commit` and `ideal_commit_ooo` to `architectures.enabled` to include the ideal baselines in a run, benchmark suite or sweep.

| Root Make target | Behavior |
| --- | --- |
| `make sim-run` | Run the workload from YAML and plot the comparison |
| `make sim-run-benchmarks` | Build and run the enabled benchmarks in `SUITE` and generate a suite dashboard and overview figures |
| `make sim-plots` | Regenerate plots from saved JSON, with optional `INPUT` to choose one report |
| `make sim-sweep` | Run all sweep presets, or choose one with `PRESET` or `SWEEP` |
| `make sim-list-benchmarks` | List source benchmarks in the selected suite |
| `make sim-test` | Run the simulator tests |
| `make sim-help` | Show target options |
| `make sim-clean-results` | Remove the selected build directory's `simulation/` tree |

```sh
make sim-run CONFIG=python/system_level/config/custom.yaml RUN_NAME=custom
make sim-run BUILD_DIR=build/experiment INSTRUCTIONS=10000 SEEDS="41 42 43"
make sim-run-benchmarks SUITE=embench BENCHMARKS="crc32 matmult-int" SEEDS=30
make sim-plots INPUT=build/simulation/single/custom/statistics.json
```

Paths passed to Make are relative to the checkout root unless absolute. `BUILD_DIR` defaults to the root `build/`. `RUN_NAME` sets the directory name and a repeat receives a numeric suffix. `OUTPUT` selects a new directory inside `BUILD_DIR/simulation/`. `SEEDS=30` runs 30 consecutive paired seeds starting at `simulation.seed`. A space-separated list gives explicit seeds. Without an override, a single run uses `simulation.seed` and sweeps and benchmarks use `analysis.seeds`. `NO_PLOTS=1` saves results for later plotting. The existing CLI remains available with `PYTHONPATH=python python -m system_level` and supports explicit values with `--seeds`.

| Files | Role |
| --- | --- |
| `config.py`, `config.yaml` | Defaults, YAML validation and execution resource configuration |
| `instruction.py`, `workload.py`, `spike.py` | Instruction metadata, synthetic dependencies, Spike decoding and paired timing samples |
| `simulator.py`, `rob.py`, `state.py` | Cycle scheduling, forwarding and retirement policies |
| `memory.py`, `blocks.py` | Memory service, physical registers, adjacent merges and selective recovery |
| `analysis.py`, `metrics.py`, `storage.py` | Paired experiments, measurements, occupancy and bit estimates |
| `benchmarks.py`, `results.py`, `plots.py` | Firmware and Spike orchestration, result layout and figures |
| `frontend.py`, `image.py` | Frontend pipeline, I-cache, completion FIFO, issue queue and static instruction image |
| `predictors.py`, `ras.py`, `btq.py` | BTBs, bimodal, GShare, TAGE, SRAM ports and bypass; RAS; branch training queue |
| `frontend_plots.py` | Frontend, prediction, RAS, training and occupancy figures |

### Configuration

The [example YAML](config.yaml) lists the supported keys. Partial YAML files inherit these defaults. `simulation.dispatch_width` controls how many instructions enter the backend per cycle and corresponds to LEN5's RTL `ISSUE_WIDTH`. A `null` `cdb_width` or `commit_width` inherits `dispatch_width`. Set either width explicitly to study it independently. [RTL dispatch routing](../../rtl/expipe/exec-units/exec_stage.sv)

Each execution-unit class has its own reservation station (RS) with a configurable `rs_size` and `rs_issue_width`. Its `count` and `initiation_interval` determine when execution lanes can accept work. Each station selects its oldest ready instructions independently, so several stations can start instructions in one cycle even with `dispatch_width: 1`. Latency controls how long execution takes after a start. The optional `execution.shared_rs` mapping, such as `{size: 24, issue_width: 4}`, selects a single station with its own issue width. Set the unit count and corresponding synthetic mix weights to zero to disable a unit. [RTL reservation-station scheduling](../../rtl/expipe/exec-units/arith_rs.sv)

Remove the former `simulation.issue_width` key from existing YAML files. Use `simulation.dispatch_width` for admission sweeps and `execution.units.<unit>.rs_issue_width` for execution-issue sweeps.

Cycle and distance distributions accept `{type: fixed, value: 3}`, `{type: uniform, min: 5, max: 12}`, or `{type: weighted, values: [4, 12], weights: [9, 1]}`. The initiation interval is independent of the sampled latency. Synthetic instruction mix weights are relative. Dependency generation selects older latest writers using distance, chain and load-dependence settings. Register locality controls selection from a hot subset. Explicit synthetic dependency graphs can cross register banks. Branch outcomes, addresses and timing samples are seeded. A replay keeps the original sample.

### Two-thread SMT

Set `smt.mode` to `disabled` for the original single-thread run, `enabled` for two threads, or `both` to report each enabled architecture in both modes. `threads: 2` specifies the supported SMT organization. `initial_priority` accepts thread 0 or 1. The dispatch policy is `majority_feedback` with `tie_policy: retain_priority`. Build and trace generation use the same Spike workflow in every mode.

```sh
make sim-run SMT=both
make sim-run-benchmarks SMT=both SUITE=embench SEEDS=10
make sim-sweep SMT=both SWEEP='simulation.rob_size=[16,32,64]'
```

Each thread has its own ROB, architectural register state, register dependencies, applicable commit state, store buffer, and branch recovery. Basic-block mode also gives each thread its own physical register pools, logical block order, and checkpoints. The single shared pool of `basic_block.max_active_blocks` slots is allocated on demand, and each occupied slot has an owner. `rob_size`, physical-register capacities, and store-buffer capacity are per thread. Reservation stations, execution units, the CDB, the load buffer, outstanding request limits, and memory service bandwidth are shared. Both program instances address independent address spaces, with independent store ordering and no cross-thread memory dependencies, coherence, or synchronization.

In each cycle the priority thread dispatches until it stalls or fills the available slots. The other thread can use the remaining slots. Priority switches only when the first thread used more slots than the second. Execution selects oldest ready operations across both threads using global allocation age. CDB tags identify the producer's thread and ROB identity. A branch recovery clears only the affected thread. LEN5 lookahead in both single-thread and SMT runs waits when the ROB head is an unresolved branch or jump. This prevents a stale memory-clear flag from allowing a younger instruction to update architectural state before recovery.

Conventional commit grants alternate round-robin among threads with an eligible candidate. Basic-block local retirement shares the same global budget. Ideal Commit retires safe entries independently in each thread without a shared commit limit. Whole-block publication accounts for instructions that already passed local retirement. Merges operate on adjacent blocks in the same thread's logical order, independent of the shared slot numbers. Merge and flush engines alternate priority between requesting threads and each has one core-wide width. Loads share responses with stores, while each store buffer preserves its own order and competes round-robin for drain slots.

With no workload assignments, both SMT threads receive the configured program. `smt.workloads.thread_0` and `thread_1` can instead name benchmarks in the selected suite. Both names may be the same. Either assignment can also be a mapping of overrides from `workload`, with an optional `name` for reports. For example, `{name: short, type: random, instructions: 100}` creates a synthetic workload and `{name: app, type: spike, trace: traces/app.log}` reads a Spike trace. Trace paths are relative to the YAML file. An omitted assignment inherits the top-level workload.

```yaml
smt:
  mode: both
  workloads:
    thread_0: aha-mont64
    thread_1: cubic
  measurement:
    reference_thread: auto
```

Set `reference_thread` to `auto`, 0, or 1. Auto runs each program in isolation on Normal OoO with the built-in default execution, branch, memory, and simulator settings and timing seed 42. For synthetic workloads, calibration uses the program from the first paired seed. The program taking more cycles is the reference. Ties select thread 0, including identical programs. The choice and calibration cycle counts are reused across architectures, seeds, and hardware sweep points for that pair. An explicit thread selection bypasses calibration.

The reference completes one iteration. The other thread repeats after its own instructions commit, stores drain, and recovery finishes. Replay resets only that thread's position and architectural register state. The other thread and shared hardware keep running, and producer IDs remain unique across iterations. The simulation ends after all phases of the reference's completion cycle. Commits from the repeated thread's current iteration count toward IPC, and an unfinished iteration is reported as partial. `simulation.max_cycles` is an error guard. Legacy fixed-cycle configurations must remove their policy and window settings. SMT-disabled runs still execute the top-level workload once.

For SMT benchmark runs, `PAIR_MODE=same` generates identical pairs and is the default. `PAIR_MODE=all` includes those pairs and each mixed combination once. Use `PAIR_MODE=ordered` for the full N×N matrix including both thread assignments and the diagonal. All three modes take the selected `BENCHMARKS`, or the entire suite when omitted. The CLI accepts the same values through `--pair-mode`.

Supply `BENCHMARK_PAIRS` to replace the automatic selection, or set `smt.benchmark_pairs` in YAML for a saved list. A list passed on the command line also overrides the YAML list. With neither an explicit pair list, a mode override, nor a benchmark selection, two named thread workloads specify one pair. Benchmark labels use `A + B`, and mixed pairs show two isolated references alongside the SMT result.

```sh
make sim-run-benchmarks SMT=both PAIR_MODE=same BENCHMARKS='crc32 cubic'
make sim-run-benchmarks SMT=both PAIR_MODE=all BENCHMARKS='crc32 cubic'
make sim-run-benchmarks SMT=both PAIR_MODE=ordered BENCHMARKS='crc32 cubic' JOBS=4
make sim-run-benchmarks SMT=both BENCHMARK_PAIRS='crc32:cubic'
```

The runner builds each trace once. Workers cache parsed programs and initial timing samples within each invocation. Timings are keyed by seed, benchmark, thread, iteration, and dynamic instruction index, so an isolated run sees the same samples as the thread's first SMT iteration. An unassigned workload retains its original initial seed stream.

Aggregate and per-thread IPC use the same elapsed core cycles. Reports include the reference and repeated workloads, calibration cycles, completed iterations, and committed instructions in the unfinished iteration. Each isolated baseline runs once. Weighted speedup sums each thread's SMT IPC divided by its isolated IPC. `sequential_cycles` records the isolated time for one iteration of each program. Weighted speedup uses all measured commits, including additional repeated work.

Reports put `smt_mode` beside the existing architecture name. SMT reports also include per-thread counters and occupancy samples under `threads` indexed by `thread_id`, and tag thread-local events when event recording is enabled. Suite heatmaps use one color scale per metric across architectures. Sweep curves distinguish SMT with separate markers. Shared resource utilization comes from the one shared structure. SMT-only figures draw only the applicable series.

### Parallel experiments

Set `simulation.parallel.workers: auto` in YAML or pass `JOBS=auto` from Make. Auto uses up to four workers, capped by available CPUs and the number of independent runs. Set `JOBS=1` for sequential execution, or pass an integer such as `JOBS=2`, `JOBS=4`, or `JOBS=8`. The Python CLI accepts `--jobs`. These settings apply to single workloads, benchmark suites, and sweeps.

```sh
make sim-run-benchmarks SMT=both JOBS=4 BENCHMARK_PAIRS='aha-mont64:cubic cubic:cubic'
make sim-sweep SMT=both JOBS=4 SWEEP='simulation.rob_size=[16,32,64]'
```

The process pool runs isolated calibration and baselines first, then joint SMT simulations. Each joint run keeps both hardware threads in one process. The parent aggregates the results in plan order and writes plots and CSV/JSON under `BUILD_DIR/simulation/`. Per-run JSON uses pair, sweep point, architecture, mode, seed, and isolated thread when applicable. The parent reports the worker count, actual calibrations, isolated simulations and joint simulations. Set `VERBOSITY=quiet|normal|verbose` on Make or `--verbosity` on the CLI. Normal prints periodic counts and the final report paths. During benchmark simulation a failed work item is recorded with its identity, independent simulations continue, and the command returns an error after publishing the partial report. A trace preparation or infrastructure failure can prevent a batch from starting or finishing. `make sim-plots` uses the saved reports directly.

### Spike traces

The simulator accepts the output of the existing `make spike-trace` target. Put its build output inside the simulator directory. The target invokes Spike with `-l --log-commits` and builds the application with `-DSPIKE_CHECK`.

```sh
make spike-trace PROJECT=hello_world BUILD_DIR="$PWD/build/simulation/trace_artifacts/manual"
riscv64-unknown-elf-nm build/simulation/trace_artifacts/manual/spike/main.elf | awk '$3 == "main" {print "0x" $1}'
```

Spike's reset ROM and LEN5 runtime initialization can still execute CSRs. Set `trace_start_pc` to the linked entry of the CSR-free region, for example the `main` address reported above. `trace_skip` can also skip a given number of dynamic records before searching for the start PC. Save this example as `python/system_level/spike.yaml`, adjusting the PC for your binary.

```yaml
workload:
  type: spike
  trace: ../../build/simulation/trace_artifacts/manual/sim-common/spike-trace.log
  trace_start_pc: 0x10228
  trace_stop_at_self_jump: true
  instructions: null
```

```sh
make sim-run CONFIG=python/system_level/spike.yaml SEEDS="42 43 44"
```

Trace paths are relative to the configuration file. The parser pairs each hart's disassembly and commit lines, uses the encoding for register dependencies, and reads addresses from the commit records. It also accepts disassembly-only or commit-only logs. It supports the modeled RV64 integer, M, common F/D and compressed forms. It rejects CSR, trap, fence, atomic and unsupported ISA operations in the selected region, reporting the PC and encoding. Consecutive PCs give branch direction and dynamic targets when available. `trace_stop_at_self_jump` optionally excludes the first standard-width `j .` and the remaining exit loop, as the repository's trace comparison does. Set a positive instruction limit to compare a prefix. A trace region starts with its live-in registers available.

## Benchmark runs

Use **Spike 1.1.0** to reproduce the validated setup. LEN5 pins commit `530af85d83781a3dae31a4ace84a573ec255fefa`. The build tested on all 18 enabled Embench benchmarks used that revision with `--enable-commitlog`. [LEN5 vendor lock](../../sw/vendor/riscv-isa-sim.lock.hjson)

The runner accepts other Spike builds if they support `--log-commits`, produce the commit-log format accepted by the parser, and support `--debug-cmd` for bounded trace capture.

Put Spike with commit logging enabled, its device-tree compiler if needed, and the LEN5 RISC-V cross-toolchain on `PATH`. `SPIKE`, `RISCV_EXE_PREFIX`, and `SPIKE_TIMEOUT` can override tool settings. `make sim-run PROJECT=hello_world` builds that application with `app-spike`. `make sim-run-benchmarks` defaults to Embench and builds with `benchmark-spike`. Both use LEN5's `SPIKE_CHECK` firmware and Spike memory map. Generated ELFs, logs and traces go to `BUILD_DIR/simulation/trace_artifacts/`. Benchmark runs require a space-free build path, as do LEN5's firmware Make targets.

`SUITE` selects the source suite. `BENCHMARKS` selects a space-separated list and takes precedence over `BENCHMARK`, which selects one benchmark. With neither set, the runner uses the stock LEN5 Embench selection, which excludes `minver`. The bundled CoreMark sources require a timer port before the existing firmware build can compile them.

The default configuration samples up to 3,000 instructions from the linked `main` of each benchmark. Spike first checks firmware completion, then a bounded debug run collects commit records for the sample. This keeps repeated full-trace logging out of short experiments. Set `workload.instructions: null` for a full trace. A bounded benchmark sample with an automatically selected start PC uses the longest contiguous CSR-free region within the requested prefix if that prefix contains CSRs. The report gives the actual region, original limit and detected CSR positions. An explicit start PC or a full trace uses the strict parser on the selected region. Each benchmark reuses the same trace and timing samples across all enabled architectures for every paired seed.

## Timing and memory

### Unified integer reservation station

Append `_unified_rs` to any architecture name in `architectures.enabled` to compare the two reservation-station organizations under the same commit policy:

```yaml
architectures:
  enabled: [normal_ooo, normal_ooo_unified_rs, len5_ooo_commit, len5_ooo_commit_unified_rs]
execution:
  unified_issue_width: null  # Defaults to one issue per wrapper per cycle.
```

The other three variants are `basic_block_ooo_commit_unified_rs`, `ideal_commit_unified_rs`, and `ideal_commit_ooo_unified_rs`. The unified integer station has the sum of the three configured ALU, MUL, and DIV `rs_size` values, shared by both SMT threads. A unit with count zero contributes its configured capacity but has no execution lane. The station creates `max(ALU_count, MUL_count, DIV_count)` wrappers. For counts 3, 2, and 1, wrapper 0 has all three unit types, wrapper 1 has ALU and MUL, and wrapper 2 has ALU. The optional `unified_issue_width` caps total integer starts across wrappers. The ALU, MUL, and DIV `rs_issue_width` settings govern their separate stations. With a unified variant and `shared_rs` configured, that pool applies to the remaining unit classes. Dispatch and CDB widths retain their existing meanings.

Instructions enter the shared station without a wrapper assignment. In dispatch-age order, each ready instruction takes the available compatible wrapper with the fewest unit types, breaking ties by wrapper index. Each grant masks that wrapper for the rest of the cycle. A wrapper can start an ALU while its divider is still executing a previous instruction. The unified integer lanes honor their configured initiation intervals in both modes. Other statistical execution units retain the existing simplified lane model.

Each wrapper arbitrates one local result per cycle, choosing the oldest instruction among completed results still waiting for that port. If MUL and ALU in one wrapper finish in cycle 5, the older result can forward in 5 and wake a unified-station dependent for cycle 6. The other result can forward in 6 and wake its dependent for cycle 7. The CDB arbitrates independently with the existing policy. It may wake a consumer first and still handles ROB writeback. FP, branch, and memory stations receive integer results over the CDB.

At issue, each lane reserves a finite result slot until both the local port and CDB have served the result. The depth per functional unit is `ceil((max_execution_latency + 1) / initiation_interval) + 1` based on its configured latency distribution. The extra slot absorbs a queued completion. A full bank backpressures that lane and a squash releases only the affected thread's younger reservations. The simulator records unified RS occupancy and full-stall cycles, per-wrapper issue counts and utilization, local grants and delays, completion queue occupancy, and result-buffer stalls. These appear with existing execution-unit and CDB statistics in the CSV, JSON, and benchmark dashboard. Paired IPC ratios compare each unified variant with its separate counterpart.

The unified integer station is a proposed organization. LEN5's integer RTL instantiates separate arithmetic stations, each with local forwarding among its own lanes. A unified implementation would need shared age selection, compatible-wrapper grant masking, and result/tag fanout across the full station. The storage estimate includes the reserved result slots, tags, and control fields. It excludes combinational arbitration, wiring, and the synthesis cost of the extra ports.

### Unified RS with branch forwarding

Append `_unified_rs_branch_forwarding` to any of the five base commit architecture names. For example, enable `len5_ooo_commit_unified_rs` and `len5_ooo_commit_unified_rs_branch_forwarding` to compare the same commit policy and wrappers with and without the branch input. The same options apply to SMT and single-thread runs.

Each wrapper uses its existing local result grant to drive both the unified integer station and the Branch RS. An ALU, MUL, or DIV result granted in cycle N can supply branch or jump operands in that cycle, including operands of an entry dispatched in N. The branch can issue in N+1 when all its operands and its execution lane are ready. If older results delay the wrapper grant, a CDB broadcast may supply the operand first. The wrapper still sends at most one result per cycle. Branch results and integer-to-FP or integer-to-memory dependencies continue through the CDB, and resolution, writeback, retirement, and recovery use their existing pipeline phases.

The benchmark dashboard and reports compare each branch-forwarding variant with its corresponding unified-RS variant. Branch RS operand counts record dependencies satisfied by either path. Wakeup counts attribute each ready instruction to the path that supplied its final operand. The wakeup lead measures cycles from a direct wakeup to that producer's later CDB broadcast, for producers that broadcast during measurement. It measures the operand timing advantage before branch scheduling, which can still wait for an available lane. These statistics include speculative work. The storage estimate is shared with the unified variant because the added result fanout and operand selection are combinational. The existing LEN5 Branch RS takes incoming operands from the CDB. [Branch RS RTL](../../rtl/expipe/exec-units/branch_rs.sv)

### Pipeline and memory timing

Event-driven mode runs deterministic cycle phases and schedules execution completions and memory responses on heaps. The conventional ROBs complete the previous commit-stage batch and accept new completed entries before CDB arbitration. The basic-block ROB locally retires previous CDB results and reclaims or merges blocks. The pipeline then services stores, arbitrates the CDB, processes due execution and memory events, selects ready RS entries, and dispatches. The oldest eligible RS entry wins subject to resource availability. The CDB holds completed requests when it runs out of lanes. Optional LEN5 priority serves stores first and walks batches of remaining source classes. Event logs can be enabled with `simulation.record_events`.

The ALU, multiplier, divider, and FP stations forward a nonfaulting execution result to same-thread dependents in their own station, including entries dispatched in the completion cycle. With one cycle of execution latency and selection in cycle 2, the result forwards locally in cycle 3 and the dependent can issue in cycle 4. The producer still broadcasts in cycle 4 or later for ROB writeback and consumers in other stations, which can issue from cycle 5 onward. The optional pooled RS shares capacity while retaining separate forwarding domains. Wakeup events from local forwarding have `source: local`. [Integer RS](../../rtl/expipe/exec-units/arith_rs.sv) · [FP RS](../../rtl/expipe/exec-units/arith_rs_fpu.sv)

Both execution modes support zero execution latency. Use `{type: fixed, value: 0}`, `{type: uniform, min: 0, max: 3}`, or `{type: weighted, values: [0, 1], weights: [0.8, 0.2]}` under `execution.units.<unit>.latency`. An instruction selected in cycle 2 with latency 0 finishes in cycle 2. A locally forwarded consumer can issue in cycle 3. The earliest broadcast is cycle 3, so a CDB-dependent consumer can issue in cycle 4 or later. Initiation intervals and separate memory service times still apply.

Statistical mode keeps the same seeded execution/memory samples, finite RS and memory queues, dispatch and per-RS widths, CDB, retirement and recovery rules. For units outside the unified integer wrappers, it models the configured number of starts each cycle and omits per-instance initiation-interval reservations. Quiescent single-thread runs can skip to the next timed event. Use event-driven mode when the other units' initiation intervals or lane utilization matter.

Loads independently sample the configured conditional L1, L2 and LLC miss rates. Latencies add for levels visited, including DRAM on an LLC miss, plus a sampled queue delay. They reserve a load-buffer entry at dispatch and an outstanding slot and, on an L1 miss, an MSHR at issue. The shared response bandwidth can add queueing beyond the sampled delay. The load buffer releases after its result broadcasts. A younger overlapping load waits for an older store's memory response. Unknown addresses conservatively alias. There is no store-to-load forwarding. Stores prepare their address/data, broadcast readiness, receive architectural authorization, and launch in program order through a bounded store queue. Responses preserve store visibility order. Simulation includes draining the final authorized stores.

## Retirement and recovery

- **Normal OoO** accepts consecutive ready entries from the ROB head into the commit stage, up to the configured width.
- **LEN5 OoO commit** gives the head priority. Its only alternative is the work cursor immediately after the head and any consecutive lookahead entries already accepted. The candidate must have completed, be eligible for OoO commit, have passed the sequential memory-clear walk, and pass the RTL's raw destination-index WAW check. The RTL compares integer and FP destination indices and can compare raw nonwriter index bits. The walk marks its current entry and advances at most one slot per cycle, subject to the full-tail restriction. An eligible CDB result can unblock a matching control transfer in that cycle. The model repeats commit selection for each configured lane. [ROB RTL](../../rtl/expipe/commit-unit/rob.sv)
- **Basic-block OoO commit** locally retires the oldest completed entries, freeing individual ROB slots immediately. Monotonic allocation identities distinguish different occupants of a reused slot. Persistent register results live in independently sized integer and FP PRFs. An original block allocates one physical destination per distinct architectural register. On repeated writes, older results can still wake their own consumers. Only newer broadcasts can replace the persistent value. Issuing consumers latch their input versions before slot or register reuse can affect them. The architectural map starts with 31 integer and 32 FP live registers. Blocks end at control transfers, store or instruction limits, or when resource pressure requires sealing. A load that overlaps an earlier store in its current block starts a new block so it can wait for the store response without holding back store authorization. Both block policies authorize stores when the group's turn comes at the head and every instruction in the group has locally retired. Store retirement records address and data preparation, so the group can publish its architectural map and authorize stores before their memory responses. The store buffer then drains in program order.

Each merge consumes an adjacent younger, completed group into its older neighbor. By default the older group may still have outstanding work. The younger map takes priority, while outstanding writers pin their old destinations and unresolved branches retain a shadow suffix boundary. Two groups with overlapping undrained stores cannot merge. Uncontested merges preserve the age order of store records. The store limit applies only to newly created blocks. Arbitration starts at the oldest eligible pair and recomputes legality after each successful merge, so chains and independent pairs can use the same cycle's bandwidth.


**Ideal Commit** uses an unbounded value ROB and conventional architectural register files. Pending register versions live in the ROB. Each thread's ROB grows on demand, ignores `simulation.rob_size`, and reports actual occupancy. It retires all safe completed entries in the retirement phase immediately following their broadcast or final safety condition. Freed slots are available to dispatch later in that cycle. Unrelated work can bypass an outstanding nontrapping operation. Retirement preserves producer order and writes to the same architectural destination. Unresolved control transfers and potentially faulting memory operations protect younger state. Memory operations retire in order, and stores use the existing authorization, queue and service phases. A mispredicted branch flushes younger work when it can safely retire, using the existing frontend redirect and replay. An explicitly marked fault stops the simulation when the completed fault reaches the ROB head. The timing model has no functional trap-handler execution.

The baseline removes ROB capacity and commit bandwidth limits under these safety rules. Dispatch, reservation stations, execution units, the CDB and memory still have their configured limits. Basic-block OoO can recover from branch speculation through its own policy. Ideal Commit's unbounded ROB has no finite hardware storage estimate, so its storage fields are null and its IPC appears in the performance comparisons.

**Ideal Block Commit** (`ideal_commit_ooo`) uses the basic-block retirement, physical-register, and recovery model. It grows each thread's ROB and both physical-register banks on demand. The block pool also grows on demand. It retires every completed, nonfaulting entry locally, performs every eligible merge, and publishes ready groups in program order in the same cycle. The configured ROB size, active-block count, physical-register capacities, commit width, and merge width do not apply. Merge eligibility, branch recovery and flush bandwidth, and the execution and memory limits still apply. In SMT the block pool grows for both threads, and each thread retains its own block order and checkpoints.

Speculative local retirement can release a ROB slot while the group is still awaiting publication. An explicitly faulted entry keeps its group incomplete, so the group's stores remain unauthorized. A completed fault stops simulation when it is at the ROB head in the oldest group and previously authorized stores have drained. The model does not execute trap handlers or expose partial architectural register state from a faulting group. Reports retain actual block and ROB occupancy and merge counts. Retirement and merge bandwidth utilization and finite storage are unavailable for this baseline.

Both conventional ROBs transfer results at handoff in cycle N and commit them in cycle N+1. An ordinary commit can complete while the next batch is accepted. Sequential allocation can first reuse a handed-off slot in cycle N+1, and the tail cannot skip an occupied slot. A prepared store can receive authorization when it is already at the head and the commit stage is ready. Its retirement still waits for the modeled memory response and CDB completion. The store-preparation broadcast remains part of the Python execution model. [RTL commit stage](../../rtl/expipe/commit-unit/commit_stage.sv)

Branch resolution occurs at CDB broadcast. Without the frontend, the model uses the younger part of the correct-path dynamic trace as a speculative work proxy and replays it after recovery. With the frontend, mispredictions come from the modeled predictors and the wrong path is fetched as described under [Frontend and branch prediction](#frontend-and-branch-prediction). Program order and the branch snapshot restore the dependency map.

Normal OoO and LEN5 OoO commit start frontend redirection at detection and stop dispatch. Younger instructions can still occupy queues and execute speculatively. A completed mispredicted branch enters the commit stage from the ROB head in cycle N. It commits, flushes the younger instructions, and blocks new commit acceptance and store authorization in cycle N+1. Correct-path dispatch can resume in cycle N+2 if the frontend timer has expired and resources are available. An older detected misprediction can supersede a younger redirect, and its flush discards the younger recovery record. LEN5's memory-clear walk prevents irreversible lookahead commits past an unresolved or mispredicted branch. [RTL backend flush](../../rtl/expipe/commit-unit/commit_cu.sv)

Basic-block OoO commit invalidates younger work at detection before any of that cycle's younger results can broadcast. Recovery detaches any invalid suffix of the branch's merged group, preserves its older span and starts frontend redirection immediately. The flush resource reclaims younger resident groups in reverse age order and charges one operation for a detached suffix that preserves its group's slot. PRF, store and block allocations from invalid groups remain reserved until the relevant flush operation. Correct-path dispatch can use already available resources as soon as redirection finishes. Merging and flushing use separate widths, and unaffected groups may merge during recovery when enabled.

With event logging enabled, `commit_accept` records conventional ROB handoff, `commit` records architectural retirement, and `mispredict` and `backend_flush` record branch detection and flush. `commit_stage_occupancy` samples accepted entries awaiting retirement. `rob_reuse_delayed_cycles` counts dispatch stalls on slots handed off in the same cycle. LEN5 reports `rob_clear_wait_cycles` for a blocked clear cursor and `rob_clear_cdb_bypasses` for advances enabled by the current broadcast. `recovery_pending_cycles` counts cycles awaiting a backend flush. `recovery_wait_for_rob_head_cycles` counts only those cycles with older instructions still in the ROB. `recovery_detection_to_flush` gives the delay for each branch that reaches the head, and `recovery_pending_rob_occupancy` samples outstanding entries during the wait. `recovery_dispatch_extra_delay` measures how long dispatch takes to resume after the frontend timer expires.

## Frontend and branch prediction

The optional cycle-level frontend replaces the abstract `branch.misprediction_probability` and `branch.recovery_latency` model with real fetch, prediction and refill timing. It is off by default, so existing configurations and results are unchanged. Enable it for every architecture with `frontend.enabled: true`, or per architecture with a variant name such as `basic_block_ooo_commit@tage` in `architectures.enabled`. A variant is a configuration overlay of the `frontend`, `simulation`, `execution`, `basic_block`, `memory` and `branch` sections and always enables the frontend. Define your own under `frontend.variants`, or use a built-in one:

| Built-in variant | Overlay |
| --- | --- |
| `l0_only`, `l1_bim`, `gshare`, `tage`, `ideal` | `frontend.predictor` |
| `len5` | LEN5 RTL predictor: 16-entry direct-mapped full-tag BTB, HLEN=4 gshare and a 4-entry RAS |
| `ideal_frontend` | Ideal predictor, perfect I-cache, perfect RAS, unlimited fetch FIFO, IQ, BTQ and fetch bandwidth |
| `ideal_backend` | TAGE frontend with unlimited ROB, RS, execution lanes, CDB, commit, blocks, PRFs, merge/flush and memory queues |
| `ideal_both` | Both of the above |
| `unlimited_tage`, `unlimited_ras`, `unlimited_btq` | Unlimited storage only; predictors still learn and can mispredict |
| `perfect_ras`, `no_ras`, `ideal_icache` | Oracle return targets, RAS disabled, always-hit I-cache |

```sh
make sim-run CONFIG=python/system_level/config/frontend.yaml PROJECT=hello_world
make sim-run-benchmarks CONFIG=python/system_level/config/frontend.yaml SEEDS=3 BENCHMARKS="wikisort slre"
make sim-sweep PRESET=ras-depth CONFIG=python/system_level/config/frontend.yaml
```

The [frontend example](config/frontend.yaml) compares the LEN5, bimodal, gshare, TAGE and ideal frontends. Sweep presets `frontend-predictor`, `fetch-fifo`, `issue-queue`, `btq-capacity` and `ras-depth` plot IPC and the frontend metrics against the swept setting. Sweeping any `frontend.*` path enables the frontend for that sweep. Each result directory stores the resolved configuration of every variant under `configs/point-N/<architecture>@<variant>.yaml`. The value `unlimited` removes one capacity or bandwidth limit and never stands for a large finite number. Storage capacity, bandwidth, latency and prediction quality are separate keys: an `unlimited` TAGE or RAS still learns and mispredicts; `predictor: ideal` and `ras.perfect` are oracles.

### Pipeline

The model follows [fetch_stage.sv](../../rtl/frontend/fetch_stage.sv). Each row is one RTL element and its modeled timing.

| RTL element | Model |
| --- | --- |
| `pc_gen` + `bpu` | One aligned block of `fetch_width` slots per cycle. A zero-latency L0 prediction steers the next PC in the same cycle. A cycle with any redirect issues no fetch, as `valid_o` does. |
| `fetch_mem_if` request spill cell | Skipped, as with `FETCH_REQ_SPILL_SKIP`. A request leaves when the completion FIFO has a reservation credit and the I-cache accepts it. |
| `completion_fifo` | `memory_fifo.depth` reservations hold metadata until the ordered response leaves. Credit and the IQ's free entries come from registered state, so a slot freed in cycle N is reusable in N+1. With `drain_on_flush`, a flushed reservation stays occupied until its obsolete response returns and is discarded. In cancel mode the slot frees at once, but the memory transaction still occupies I-cache outstanding and response bandwidth. |
| Answer spill cell → `early_jump_unit` | `predecode_latency` cycles. The final prediction is applied here in fetch order, one bundle per cycle, when predecode, direction and BTB data have all arrived. |
| `instr_mixer` + output spill cell | `output_latency` cycles. Two bundles per spill cell (`stage_capacity`). |
| `issue_queue` | `issue_queue.capacity` entries. A bundle enters only when all its instructions fit; the backend dispatch stage reads it in the next cycle at `simulation.dispatch_width`. |

With a 1-cycle I-cache, an instruction fetched in cycle 1 dispatches in cycle 5, matching the RTL register stages. Instruction memory reuses the data cache's L1/L2/LLC/DRAM sampling with its own `frontend.icache` parameters, request and response bandwidth and in-order responses. The I-cache is shared by SMT threads.

Backend recovery follows the existing commit policies. The conventional ROBs detect a misprediction at CDB broadcast. Issue stops immediately, the frontend flushes and redirects `redirect_delay` cycles later (`branch_cu` MIS → MIS_LOAD_PC and `issue_cu` S_FLUSH), and the backend flush still happens at commit. Basic-block commit invalidates younger blocks at detection and redirects after the same delay. The frontend refetches from the correct target instead of waiting for a sampled recovery timer.

### Predictors and timing

| `frontend.predictor` | Stage 0 (PC cycle) | L1 stage | Final stage (predecode) |
| --- | --- | --- | --- |
| `l0_only` | L0 BTB | | L0 counters, decoded direct targets |
| `l1_bim` | L0 BTB | L1 BTB + bimodal | Bimodal, decoded targets |
| `gshare` | L0 BTB | L1 BTB + bimodal | GShare |
| `tage` | L0 BTB | L1 BTB + bimodal | TAGE with the bimodal base |
| `len5` | BTB hit × gshare (committed history) | | Only JAL and canonical `ret` corrected, as in the early-jump unit |
| `ideal` | Correct-path oracle | | Oracle |

The L0 is a register-based, set-associative BTB with direction counters and the configured replacement. The L1 BTB is a set-associative SRAM with short target offsets plus a direct-mapped extended-target table, so partial tags and extended-target overwrites can produce wrong targets. Both can be keyed per slot or per fetch block. Each stage's prediction arrives at its own latency. A later stage that changes the followed exit or target redirects fetch and kills all younger bundles. GShare and TAGE lookups start when the instruction response arrives (`start: response`) or in parallel with the I-cache (`start: pc`). The final prediction waits for both the lookup and predecode. Predecode identifies conditional branches, JAL/JALR, calls, returns and coroutine swaps; computes direct targets; removes predictions on non-control slots; and selects the oldest reachable taken control-flow instruction. A JALR without a target falls through.

The speculative global history is updated in fetch order at the final stage, one bit per conditional branch or one per bundle (`history.update`). A lookup that started before older bundles finalized used stale history. `history.stale_policy: relookup` re-reads the tables with the repaired history (a history-only correction); `use_stale` keeps the prediction and counts it. Backend recovery restores the branch's own history plus its actual outcome.

TAGE uses folded-history index and tag hashes, parallel lookups of all tables, provider and alternate selection, a USE_ALT_ON_NA counter for weak new entries, 3-bit counters, usefulness counters, allocation into a longer table with a free useful bit, usefulness decay on failed allocation and periodic alternate-bit aging. Training uses the metadata saved at prediction time, so it needs no extra SRAM read port. A write-bypass buffer supplies values written since then. Without a bypass hit, a stale saved value overwrites the newer update; the model counts that as a lost update. GShare follows the same rule. Each SRAM has read and write ports per cycle, optionally as one shared port. A prediction read has priority over a training write. A training write blocked by a port conflict stalls the queue head.

### Return address stack

The RAS is a circular buffer of full return addresses with valid bits and write generations, a stack pointer, a live-entry count and a logical depth. Calls push the return address, which is PC plus the instruction length. Returns read the valid top and pop. `jalr` with `rd` and `rs1` both link registers but different (x1/x5) pops, then pushes. A pop moves the pointer without destroying data. With predecode access, each dynamic call or return updates the RAS once, in fetch order, at the final stage. With `access_stage: pcgen`, the update uses L0/L1 call/return metadata. When predecode disagrees, that update is undone and reapplied, and younger bundles refetch, which the model counts as a RAS repair.

For a recognized return the target priority is a valid RAS top, then the L1 BTB, then the L0 BTB, then none. Only BTB data that has already arrived for that bundle counts, and a later L1 response never replaces a valid early RAS target. An invalid top, caused by underflow, overflow loss or corruption, falls back to the BTBs, and the reason is recorded. The BTBs keep learning actual return targets through normal training for that fallback. A RAS prediction never overrides an older taken branch in the same bundle.

Each control instruction carries only the stack pointer, live count, logical depth, the push generation and the saved top entry. Recovery restores the pointer and the top address. It then invalidates live entries below the top whose generation shows that a squashed younger push overwrote them, and finally applies the recovering instruction's own RAS action once. Unaffected older entries are kept. The same checkpoints serve frontend redirects, conventional ROB recovery and basic-block flushes. They live on the backend entry, by stable allocation id, so block merges, selective flushes, slot reuse and BTQ drops cannot change them. An `unlimited` depth never overwrites; `perfect: true` is a separate oracle.

### Branch training queue

Successfully dispatched control instructions (RTL issue) allocate BTQ entries, oldest first, while capacity lasts. A full queue drops the remaining training opportunities and never stalls dispatch, execution or commit. Recovery does not depend on the BTQ. An entry is confirmed when its instruction commits (conventional ROBs and Ideal Commit) or when its basic block's group completes. Younger groups can confirm first. An entry becomes safe at irrevocable commitment: instruction commit, or block publication. Training leaves only from the head of each thread's queue, in order, once the head is safe, so a younger confirmed entry never trains while an older instruction can still squash it. Recovery removes all younger entries, including confirmed ones, and keeps the mispredicted branch's own entry. Wrong-path entries are always removed before they become safe, so wrong-path training is impossible. Training uses the original fetch PC, history and saved metadata with the actual outcome. It is limited by `btq.training_width` and the SRAM write ports. With `coalesce`, entries from the same fetch bundle share one masked row write.

### Wrong-path modes

| `wrong_path` | Behavior |
| --- | --- |
| `bubble` | Fetch stops when the followed path leaves the trace; only frontend corrections or backend recovery restart it |
| `frontend` | Wrong-path bundles use the I-cache, completion FIFO, predecode, history, RAS and IQ but wait at the IQ head until recovery flushes them |
| `full` | Wrong-path instructions also dispatch and use the ROB, blocks, PRFs, RS, execution units, load/store buffers, memory and CDB, then are squashed |

The frontend tracks the correct-path trace position separately from the fetch PC and never identifies a dynamic instruction by PC. Wrong-path encodings come from the ELF (`workload.elf`, set automatically for benchmark runs), or else from PCs seen in the trace; other PCs decode as 4-byte non-control filler. Wrong-path operands come from the encoding. Execution and memory latencies are sampled from the configured distributions. A load or store uses the last correct-path address at that PC, otherwise a private non-aliasing address. Wrong-path loads do not wait for wrong-path stores. Wrong-path control instructions never mispredict, because their real outcomes are unknown. Wrong-path work never updates architectural state or trains predictors.

### Statistics

Every report adds an `occupancy` section. For each structure it gives the capacity, the time-weighted mean over all simulated cycles including idle ones, the mean as a percentage of capacity, the peak, a histogram, empty and full cycles and percentages, allocation failures and stall cycles. Unlimited structures report `capacity: unlimited` with a null percentage and full count. The structures are the ROB, each RS, load and store buffers, outstanding loads, MSHRs, CDB backlog, block slots and both PRFs. Frontend runs add the fetch FIFO, I-cache outstanding requests, both spill-cell stages, the IQ, the BTQ, confirmed BTQ entries, the RAS logical depth, valid RAS entries and the predictor bypass buffers. SMT reports put shared structures in the aggregate and private ones under each thread. All values are in `comparison.csv`/`summary.csv` as `occupancy:<structure>:<field>` and in `occupancy.csv`. Frontend runs add a `frontend` section, exported as `frontend:<metric>`.

| Metric | Definition |
| --- | --- |
| `fetch_ipc`, `correct_path_fetch_ipc` | Instructions entering the IQ per cycle; only correct-path ones |
| `issue_ipc`, `committed_ipc` | Dispatched (all paths) and committed instructions per cycle |
| `frontend_starvation` | Fraction of cycles whose dispatch stopped on an empty IQ, outside recovery |
| `backend_starvation` | Fraction of cycles whose dispatch stopped on a backend resource with a non-empty IQ |
| `mpki`, `conditional_mpki`, `target_mpki`, `return_mpki` | Backend-detected mispredictions per 1000 committed instructions, by type |
| `l0_accuracy`, `l1_accuracy`, `final_accuracy` | Correct next-PC predictions per stage over correct-path control instructions, counted once at the final stage; `*_direction_accuracy` covers conditional branches and `*_target_accuracy` taken non-conditional transfers |
| `bp_override_useful/harmful:<stage>` | A stage made a previously wrong prediction correct, or a correct one wrong |
| `fe_redirects:<source>` | Redirects from `l0` (delayed), `l1`, `final`, `ras_repair` and `backend` |
| `ras_coverage`, `ras_accuracy`, `return_accuracy` | Correct-path returns with a valid RAS top; correct valid RAS predictions; returns not mispredicted by the backend |
| `ras_fallback_reason:<reason>`, `ras_fallback_l1/l0(_correct)` | Invalid-top causes and the BTB fallbacks with their accuracy |
| `ras_override_correct`, `ras_override_harmful` | A valid RAS target that differed from the BTB target and was right, or was wrong while the BTB was right |
| `btq_*` | Allocations, drops by path, trained, flushed and confirmed-then-flushed entries, head-of-line blocking cycles (head not yet safe while confirmed entries wait) and SRAM conflicts; latency samples for prediction→training, issue→confirmation, confirmation→training and residence |
| `branch_resolution_to_recovery`, `recovery_to_first_correct_fetch`, `recovery_to_first_correct_issue` | Detection to frontend flush; flush to the first correct-path bundle in the IQ; flush to its dispatch |
| `tage_*` | Provider and usefulness histograms, allocations per table, allocation failures, replacements, resets, bypass hits, stale metadata, lost updates and valid entries per table |
| `predictor_storage_bits` | Modeled predictor state, or null when any structure is unlimited |

Accuracy counts only correct-path predictions; wrong-path work appears separately as `fe_wrong_path_fetched`, `wrong_path_dispatched` and `icache_wrong_path_requests`. Stall reasons are mutually exclusive per dispatch cycle: the first applicable reason in the order redirect, recovery, empty IQ, wrong-path hold, then backend resources.

`simulation.warmup_instructions` simulates that many committed instructions first, then restarts every statistic while predictor, cache and pipeline state stay warm. The report's `warmup` section gives the boundary. SMT runs reject a warm-up because they measure until the reference workload completes.

### Figures

When frontend statistics exist, plots go under `plots/frontend`, `branch_prediction`, `ras`, `training`, `queue_occupancy`, `memory`, `recovery` and `ideal_comparison`. Single runs and sweeps draw grouped bars per architecture: throughput, starvation, wrong-path work, accuracy by stage, stacked MPKI, redirect sources, overrides, RAS events and accuracy, return target sources, BTQ events, latencies and conflicts, recovery latencies and the I-cache. They also draw TAGE provider, allocation and usefulness distributions, IPC against predictor storage, annotated heatmaps of mean, percentage, peak, empty, full and failure occupancy, and occupancy histograms. Sweeps add curves of IPC, MPKI, return MPKI and BTQ drops against the swept capacity. Benchmark suites draw annotated benchmark × architecture heatmaps of IPC, fetch IPC, starvation, MPKI, accuracy per stage, RAS coverage and return accuracy, return MPKI, BTQ drop rate, I-cache hit rate and recovery latency. They add occupancy heatmaps and IPC relative to the first variant of the same backend. The existing dashboard and suite figures include every `@variant`; its paired ratios still compare backend architectures only.

### Assumptions and limitations

- Traces cover the correct path only. Wrong-path operands, addresses and outcomes are approximated as described above.
- One request per fetch block; an instruction that straddles the block end is fetched with its block.
- The `len5` preset uses this model's RAS and BTQ-based commit-time training. The RTL restores its RAS from a resolution-time confirmed copy and trains the BTB and gshare at branch resolution, so `len5` matches the RTL's prediction structure and early-jump corrections, not its training timing (see [R01](../../tb/frontend/RTL_VERIFICATION_FINDINGS.md)).
- Write generations are unbounded integers in Python; hardware would use wrapping tags compared against the checkpoint.
- The bimodal table trains from its current value; only GShare and TAGE model saved-metadata staleness.
- I-cache hits and misses are sampled per request from one seeded stream per run, not from a tag array, so different wrong paths change later samples.
- Statistical mode steps every cycle when the frontend is enabled. The unified RS needs finite ALU, MUL and DIV counts.
- The Python model was not compared cycle by cycle against an RTL simulation, because the FuseSoC flow was unavailable. Its pipeline latencies come from the RTL sources and directed tests pin them.

## Reports and sweeps

```sh
make sim-sweep PRESET=merge-width
make sim-sweep PRESET=flush-width
make sim-sweep PRESET=branch-flush
make sim-sweep INSTRUCTIONS=1500
make sim-sweep SWEEP='simulation.dispatch_width=[2,4,8]'
make sim-sweep SWEEP='memory.l1.miss_probability=[0.05,0.15]'
```

Presets plot IPC versus merge width, flush width, maximum blocks, misprediction rate across flush widths, physical registers, ROB size and modeled storage. Sweep axes use dotted YAML paths and YAML lists. Join two paths with `+` to vary them together. Use repeated `--sweep` options with the CLI for a Cartesian product. A number selects fixed latency for a distribution and a YAML mapping sets the full distribution.

```sh
PYTHONPATH=python python -m system_level sweep \
  --sweep 'simulation.dispatch_width=[2,4,8]' \
  --sweep 'execution.units.alu.rs_size=[4,12]'
```

| Directory under `BUILD_DIR/simulation/` | Main outputs |
| --- | --- |
| `single/<run_name>/` | Resolved `config.yaml`, full `statistics.json`, `comparison.csv`, per-seed results, and `plots/` |
| `benchmarks/<suite_name>/` | `summary.csv`, `summary.json`, `per_seed_results.csv`, speedup tables, `individual_benchmarks/`, `summary.md`, `dashboard.html`, and suite-wide `plots/` |
| `sweeps/<sweep_name>/` | `results.csv`, full `statistics.json`, IPC summary, paired improvements, and `plots/` |
| `trace_artifacts/` | Firmware and Spike inputs, kept separately from statistics |

### Reading a benchmark matrix

Open `dashboard.html` directly in a browser. All controls and data needed to explore the matrix are embedded. The neighboring CSV and JSON links open the complete saved measurements. Rows select the program on thread 0, columns the program on thread 1. Swapping programs can change scheduling and sampled outcomes. The dashboard shows the measured direction only, outlines identical workloads, and marks unmeasured cells with hatching. A failed work item is identified in the pair detail. A partially measured cell shows its contributing seed count.

Pick an architecture, execution view and metric. Heatmap cells show rounded values and mark missing results with an em dash. Hover or focus a cell for its full-precision estimate, interval, reference thread, completion cycles and IPC. Click it for a compact comparison of all architectures. Filter both axes by entering one or more comma-separated names. Sort by name or normal OoO isolated IPC. The highest/lowest buttons select an observed cell within the filter. On a narrow screen the matrix pane scrolls and the comparison appears beneath it.

For a mixed pair, **serial pair IPC** uses two complete isolated iterations, total instructions divided by their summed cycles. The isolated view also shows each thread's isolated IPC. **SMT aggregate IPC** and each thread's **SMT IPC** use the same core-cycle denominator and include any partial iteration through reference completion. An SMT-disabled suite shows single-thread IPC. **Weighted speedup** sums each thread's measured IPC divided by its own sampled isolated IPC. The relative view includes each thread's IPC ratio and weighted speedup. Architecture IPC ratios use matching pair orientation, seeds, workload and reference policy. A value above 1 favors the numerator. Missing comparisons stay blank. The suite overview gives each pair equal weight and reports the geometric mean of the pair-level mean ratios. Existing CSV tables retain their original aggregation, including the per-seed geometric means. Seed intervals are deterministic percentile bootstrap estimates; a single seed has no uncertainty interval.

### Plot selection and regeneration

```yaml
plotting:
  preset: essential  # essential | detailed | none
```

- **essential** generates the offline dashboard and suite-wide plots. IPC heatmaps are under `plots/performance/` as `ipc.png`, `thread_0_ipc.png`, `thread_1_ipc.png` and `isolated_ipc.png` where the corresponding data exists. The preset also includes architecture ratios, weighted speedup, improvement distribution, geometric means, backend pressure, basic-block engine use, storage breakdown and throughput versus storage when applicable. Architecture-ratio and weighted-speedup heatmaps also have PDF copies. `summary.md` links the available figures, raw data, and largest observed gains and regressions.
- **detailed** adds a bounded set of ROB, CDB and issue-utilization matrices for SMT suites. Figure count is independent of the number of pairs or seeds.
- **none** writes raw data and the suite Markdown overview. Single workloads and sweeps also honor the preset; their IPC figure is `plots/performance/ipc.png`.

```bash
make sim-plots INPUT=build/simulation/benchmarks/embench/summary.json PLOT_PRESET=essential
make sim-plots INPUT=build/simulation/benchmarks/embench/summary.json PLOT_PRESET=detailed
```

Regeneration reads saved JSON and publishes figures after rendering succeeds. It removes stale PNG, PDF and SVG figures from that report's `plots/` directory and leaves CSV, JSON, logs and sibling experiments intact. Use `OUTPUT` to render a separate copy. Raw statistics remain available with every preset, including counters outside the dashboard selection.

### Simulation and reporting performance

Timing sampling advances the original per-instruction random streams but initializes a generator only for outcomes that actually draw from it. Occupancy statistics use existing physical-register free lists and one execution-lane scan for shared and thread totals. Event records are built only when recording is enabled. The suite reuses the per-pair aggregate rows for its CSV and small-seed confidence intervals reuse repeated bootstrap samples. The shared SMT merge histogram records one observation per core cycle.

Occupancies are sampled at cycle end and include still-reserved flush state. Issue throughput counts starts per cycle. Aggregate issue utilization uses the sum of each station's peak starts, bounded per station by its size, issue width and execution-lane count. Older reports used the former global issue width as the denominator. The effective instruction window counts dispatched useful instructions that have not yet committed. Merge delay counts eligible pairs left after that cycle's merge budget. Flush histograms count reclamation operations, including partial restoration. The extra dispatch stall counter counts resource stalls that the outstanding reclamation can resolve. Cache outcome counts include requests from squashed attempts. All architectures reuse the same per-instruction outcomes for each paired seed.

### Storage assumptions and limits

The conventional designs include the architectural RF, value-bearing ROB, register-status tags and control bits. The LEN5 estimate adds its memory/order-critical and clearance fields and cursor state. The block design includes PRFs, physical-tag ROB entries, full maps and ownership bitmaps for every block slot, the architectural physical map, valid/write fields, register and ROB free state, allocation ordering, store-to-block links and budgeted checkpoint maps. Full block maps use `31 * ceil(log2(P_INT)) + 32 * ceil(log2(P_FP))` bits per block, plus `P_INT + P_FP` ownership bits. Resolved spans coalesce, so the estimate provisions a shadow per unresolved boundary. A hardware implementation can clear invalidated events and latch forwarded operands using bounded tags. Python's monotonic identities, object graphs and checkpoint dictionaries are bookkeeping and do not set the estimated hardware bit widths.

The estimates include RS operand and scheduling state, load and store buffer records and ordering bits, and one CDB result latch per execution lane. SMT duplicates private files, ROBs, commit/recovery control, store buffers, and PRF allocation state. It adds a one-bit owner to every shared RS, load-buffer and block entry, and to each buffered CDB result. A shared block pool of 16 entries with 64 physical registers in each bank uses `16 * (378 + 128 + 1) = 8,112` bits (1,014 bytes) for maps, ownership and thread tags. Checkpoint, control, and value storage are accounted separately. The conventional RF and block PRF value subtotals at 64 bits per register are 8,064 and 16,384 bits under SMT.

The figures report modeled state bits and rounded-up bytes. The expanded accounting applies to both modes, so storage totals in older reports can differ. Merge and flush widths affect arbitration and update ports. Their widths alone do not imply more state bits. The estimator excludes execution pipelines, combinational CDB wires, cache and predictor state, shared memory-service queues, and implementation-specific ECC, multiport overhead, routing, and timing costs. Any `unlimited` backend capacity or bandwidth makes the estimate null, like the ideal baselines; the frontend reports its own `predictor_storage_bits`. The model has no functional address generation, fault or CSR execution, or captured wrong-path trace. In statistical mode, SMT retains the simplified execution-lane model and advances the shared scheduler cycle by cycle. Use event-driven mode when modeling initiation intervals matters.
