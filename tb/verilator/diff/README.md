# LEN5 / Spike differential verification

This optional C++ checker runs the real LEN5 Verilator model against Spike,
tracks accepted instructions through the pipeline, and optionally writes an annotated FST.
Normal simulation and the existing execution trace remain available without linking
Spike. The FS/fcsr support described below is implemented in the processor RTL
and therefore also applies to ordinary simulation.

The supported instruction scope is **RV64IMFD and CSR operations on mstatus, fcsr,
frm, fflags, mtvec, mscratch, mepc, mcause and mtval**, in machine mode with the legacy or TC_SRAM memory backend. This is
limited to ordinary instruction execution: traps/interrupts, other CSRs,
fences, atomics, compressed instructions, MMIO reads and self-modifying code
terminate with an explicit unsupported result. See the limitations below.

The checker reads the configured serial/exit addresses and SRAM bounds from RTL
metadata. TC_SRAM writes are observed at their rising-edge acceptance; legacy
writes retain falling-edge observation. Use byte-addressed `.hex` firmware for
checked runs. Spike's sparse reference does not assign values to untouched SRAM
bytes, so architectural reads of uninitialized SRAM remain outside the checked
scope. See [memory backend integration](../../../tb/memory/tc_sram/MEMORY_BACKEND_INTEGRATION.md)
for backend selection, measurements, and the executed verification matrix.

## Build and run

Requirements: C++17 compiler, Python 3, FuseSoC/Edalize, zlib development headers,
Verilator **5.040**, and a RISC-V cross compiler for your programs. Waveform
merging uses the C++ FST API bundled with Verilator and needs no conversion program.

Spike is pinned to v1.1.0, commit
`530af85d83781a3dae31a4ace84a573ec255fefa`. Its sources are imported locally into
`sw/vendor/riscv-isa-sim` and ignored by Git, with the same `.vendor.hjson` / `.lock.hjson` convention
as `riscv-opcodes`; the vendoring lock identifies the imported revision. Installed
Spike executables alone are insufficient: the adapter links matching static
libraries with `--enable-commitlog`. Normal builds never download source. Verilator
5.046 removed the XML interface used to derive field layouts, so the optional
build currently requires 5.040 explicitly.

From the repository root:

```sh
# On a fresh checkout, import the pinned Spike sources once.
make vendor-update-spike

# Build the RTL checker; automatically build local Spike libraries if needed.
# Set these paths if the corresponding tools are not on PATH.
make verilator-build-debug VERILATOR=/path/to/verilator-5.040/bin/verilator \
    FUSESOC=/path/to/fusesoc JOBS=4

# Build your existing application, using the normal software build flow.
make app PROJECT=load_store

# Run it with checking and no waveforms.
make verilator-sim-debug DUMP_WAVES=false \
    FIRMWARE=build/main.hex MAX_CYCLES=20000

# Enable annotated waveforms for the same run.
make verilator-sim-debug DUMP_WAVES=true \
    FIRMWARE=build/main.hex MAX_CYCLES=20000
make verilator-waves-debug

# Debug counterparts of the existing benchmark entry points.
make run-debug BENCHMARK=crc32 DUMP_WAVES=false
make run-benchmarks-debug DUMP_WAVES=true -j4

# Remove all other build outputs, retaining the compiled Spike libraries.
make clean-keep-spike
```

The original `verilator-build`, `verilator-sim`, `verilator-opt`, `run` and
`run-benchmarks` targets run ordinary simulation. Their `-debug` counterparts
ensure the checker and Spike libraries and run differential verification.
`verilator-waves-debug` opens the annotated waveform. `VERIFICATION` is no longer
used to select the model. `make check` keeps its original program/RTL checks.
Both `verilator-sim` variants default to `DUMP_WAVES=true` and `DUMP_TRACE=true`;
optimized and benchmark runs default to both disabled. Explicit settings override
these defaults. Normal models live in `BUILD_DIR/normal`; debug models live in
`DEBUG_BUILD_DIR`, which defaults to `BUILD_DIR/debug`. The other defaults are
`SPIKE_SRC=sw/vendor/riscv-isa-sim` and `SPIKE_BUILD=BUILD_DIR/spike-build`.
These variables select other locations; an external
Spike Git checkout must have the pinned HEAD, while a copied vendor directory
needs its adjacent lock file. On the tested workstation the tool paths are
`../tool/verilator/5.040/bin/verilator` and
`/home/markospremic/miniconda3/envs/core-len5/bin/fusesoc`; source `private/init.sh`
in a shell with Conda initialized to add the local tools to PATH.

FuseSoC builds and runs both the ordinary `sim` target and the checked `sim-diff`
target in `len5.core`. The shell build helper fingerprints RTL/checker sources,
tool paths, flags and compiler configuration; unchanged invocations reuse the
model. Spike retains its separate content and compiler fingerprint cache, including
backdated source changes. Missing libraries or an executable are rebuilt. Build
locks serialize concurrent invocations. Outputs stay under `build/`, outside the source
tree; deleting that build directory requires a new compile, never a new download.
`make clean-keep-spike` removes its other contents, including hidden build stamps,
RTL executables, firmware, logs and waveforms. It retains the entire `SPIKE_BUILD`
directory, including archives, object files and the cache/configuration metadata.
The next verification run rebuilds the RTL model and reuses the Spike libraries.
`make clean` and `make clean-sim` retain their full-clean behavior.

Verilator builds show `Building RTL with Verilator...` when rebuilding starts
and `RTL build complete.` after a successful build. Repeated cache checks are
quiet. Spike builds likewise show `Building Spike reference libraries...` and
`Spike reference library build complete.` only when compilation is required.
Spike compiler diagnostics stay in `SPIKE_BUILD/bootstrap.log`.
FuseSoC diagnostics are saved to `DEBUG_BUILD_DIR/build.log` for debug
builds and `BUILD_DIR/normal/build.log` for ordinary builds. A failed build prints
its last 60 output lines and the log path, and still returns a failing status. Set `VERBOSE=true` to enable
FuseSoC's verbose output. `DUMP_WAVES` controls waveform files and
`LOG_LEVEL` controls simulation logging independently.

Vendoring is an explicit maintenance operation, separate from building:

```sh
make vendor-update-spike
# Equivalent: python3 util/vendor.py -U sw/vendor/riscv-isa-sim.vendor.hjson
```

This operation accesses upstream. The descriptor remains pinned to v1.1.0;
changing that revision also requires updating and testing the C++ adapter.

The bootstrap builds libraries only. If `dtc` is absent, it deliberately disables
the unused device-tree generator with `DTC=false`; this does **not** produce a
working Spike CLI/DTB environment. It also supplies `-include cstdint` for old
Spike headers with recent GCC. Ordinary `make verilator-build` has none of these
dependencies.

Python compiles only Spike; the remaining Python helper generates metadata.
RTL elaboration, C++ compilation, linking and simulation are owned by FuseSoC:

* `bootstrap_spike.py`: validate local pinned sources, configure only when needed,
  and cache the four Spike reference libraries. It does not clone or download.
* `scripts/sim/build-verilator.sh`: serialize builds, check the source/configuration
  cache, and print build progress while FuseSoC compiles the model.
* `scripts/sim/prepare-diff.sh`: FuseSoC pre-build hook that supplies Spike include
  paths/libraries and generates the checker metadata before Edalize builds the model.
* `layout.py`: generate `diff_layout.hh` from Verilator XML, including packed-field
  offsets, widths, enum encodings and configuration constants for read-only VPI.
* `util/clean-build.py`: remove build outputs while preserving the configured
  Spike cache, including custom nested cache paths. Directory symlinks are
  removed without deleting their external targets.

Additional checker settings can be passed through the existing Make target:

```sh
make verilator-sim-debug DUMP_WAVES=true MAX_CYCLES=20000 \
    FIRMWARE=/absolute/path/program.hex \
    DEBUG_ARGS="--diff-recovery=10000 --diff-progress=10000 --diff-output=logs/diff"
```

FuseSoC's `sim-diff` target supplies `--diff` independently of `DUMP_WAVES`.
The original targets select ordinary simulation. `run_dir` directs each checked
simulation's artifacts to its own directory while sharing the compiled model.
`--diff-fault operand|cdb|register|store` corrupts one **checker observation** for
testing; it does not modify RTL state. Status 0 means checked execution reached
the existing testbench's normal exit; 1 means a confirmed discrepancy/timeout;
2 means unsupported configuration, reference behavior or output failure. The
checker API reserves 3 for an unfinished check. FuseSoC reports any nonzero simulator
status as a failed run; the precise checker result remains in `report.json`.
A checker pass is not a separate
interpretation of the program's exit byte.

## Architecture and verification coverage

Spike advances an independent architectural stream. Accepted fetches acquire
sequence associations; FIFO frontend identity and active ROB/LSQ tables carry
those records through execution. Commit removes active ROB ownership immediately
without generations. Deferred next-PC checks and complete-prefix comparisons use
the actual LEN5 integer register file. Stores have separate authorization and
external-completion lifetimes. Tentative errors become confirmed at commit or an
irreversible write; FST annotations retain both timestamps.

Store ordering is checked in the checker's program-order queue at the actual
external write, using observed CPU addresses and byte masks. Disjoint older
loads/stores do not block it. Unknown older addresses block the write; overlapping
loads must have captured their values and overlapping stores must have written.
ROB clearance alone does not require older loads to finish on the CDB.

See [the signal map and architecture](ARCHITECTURE.md) for exact handshakes,
out-of-order commit semantics, per-stage verified fields, waveform layout and
unsupported interfaces. The generated artifacts are `logs/diff/report.json`,
`annotated.fst`, `annotated.gtkw`, `fields.json` and an event spool; the original
`logs/waves.fst` is preserved. With waves disabled, only `logs/diff/report.json`
is produced by the checker; comparison journaling and FST merging are skipped.
Stale waveform artifacts are removed when reusing a directory without waves.

Application verification outputs live under `build/sim-common/logs/`. Verified
benchmark outputs live under `build/<suite>_debug/run/<benchmark>/logs/`, separately
for each parallel run; their console logs live under
`build/<suite>_debug/logs/sim/<benchmark>.log`. `SIM_RUN_DIR` overrides the working
directory for a direct simulation. `DEBUG_SUITE_DIR` overrides the debug suite
output root for both firmware and simulation artifacts. Debug benchmarks build
their own firmware under `build/<suite>_debug/run/<benchmark>/` (for Embench,
`build/embench_debug/run/<benchmark>/`) with `-DSPIKE_CHECK` automatically appended
to any supplied `CDEFS`.
`DEBUG_ARGS` supplies additional
checker options, such as `--diff-recovery 20000` or `--diff-fault cdb`.

`DUMP_TRACE=true` enables the existing committed-instruction text log, independently
of checking and waveforms. Each entry contains the logger timestamp, core ID,
instruction PC and encoding, followed by a line containing the destination-register
value when a register is written. The existing logger buffers commit notifications
by ROB order; its timestamp is the time the buffered entry is printed.
For verified applications the file is `build/sim-common/logs/sim-trace.log`;
for verified benchmarks it is `build/<suite>_debug/run/<benchmark>/logs/sim-trace.log`.
Ordinary FuseSoC runs retain the `build/sim-common/sim-trace.log` link.
`verilator-sim` defaults to tracing enabled, while optimized/benchmark runs default
to tracing disabled. An explicit `DUMP_TRACE=true/false` overrides either default.

Verification failures and unsupported exits propagate as failing Make targets.

## FS and fcsr

`mstatus.FS` resets to Off (`00`). Software can enable it with `csrs mstatus,t0`
where `t0=0x6000`, as the existing `__riscv_flen` startup already does. The RTL
stores only Off and Dirty (`11`); writes of Initial/Clean map to Dirty, as allowed
by the [privileged specification](https://docs.riscv.org/reference/isa/v20260120/priv/machine.html).
`mstatus.SD` reflects Dirty. There is no instruction-driven FS state machine.
The checker currently accepts software using Off/Dirty; writing Initial/Clean
returns unsupported because the pinned Spike retains those states.

`fcsr` is writable state with `frm` and `fflags` aliases. Committed FP exception
flags accumulate even for instructions with source f0. Static instruction rounding
modes override `frm`; dynamic rounding uses `frm`. FS=Off rejects FP arithmetic,
moves, loads/stores and FP CSR accesses through the illegal-instruction path.
The CSR source-register decode and the ready indication for decoded exceptions
have also been corrected. These are functional RTL fixes requested with FS support.

The checker compares actual `mstatus` and `fcsr` at complete architectural
checkpoints, alongside integer and floating-point registers and the previously supported CSRs.
It does not mask FS or SD differences and does not force Spike's FS to Dirty.
Both models execute the firmware's initialization sequence. The initial `fcsr`
value is checked without writing it through Spike's FS-sensitive write hook.
Reference lookahead stops at an unsupported instruction while older instructions
continue to be checked; this permits the normal exit store before the trailing WFI.

F/D checking includes arithmetic, fused operations (all three operands), conversions,
comparisons, classification, moves and loads/stores. Source and destination register
banks are decoded independently; f0 is writable. Results and all 32 floating-point
registers are compared as raw bits, including NaN boxing. Existing fcsr checkpoints
check accrued exception flags and rounding-mode state. The checker reports RTL
mismatches without normalizing them to Spike's results. In particular, the current
RTL's FLW zero extension differs from the NaN boxing required with D enabled.

For Embench, `run-debug` and `run-benchmarks-debug` automatically append
`-DSPIKE_CHECK` to omit `mcycle`/`minstret` measurements and keep their firmware
separate from ordinary benchmarks. No explicit `CDEFS` setting is needed:

```sh
make run-debug BENCHMARK=crc32 DUMP_WAVES=false
```

This option leaves the standard FS/fcsr startup enabled and preserves the benchmark's
result check. It omits software timing output; the RTL testbench still prints its
execution statistics.

## Validation

Validation results are recorded in `VALIDATION.md`. Existing applications and
benchmark runs continue to use the same C++ checker.

See [performance measurements and profiling](PERFORMANCE.md) for the measured
bottlenecks, optimization results, and reproducible benchmark commands.

See [actual results and known failures](VALIDATION.md) for the latest FS/fcsr
validation and historical results. Unsupported trap behavior is not counted
as verified execution.
