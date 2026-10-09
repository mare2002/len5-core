# LEN5 / Spike differential verification

This optional C++ checker runs the real LEN5 Verilator model against Spike,
tracks accepted instructions through the pipeline, and optionally writes an annotated FST.
No processor RTL is changed. Normal simulation and the existing execution trace
remain available without linking Spike.

The tested instruction scope is **RV64IM and CSR operations on mtvec, mscratch,
mepc, mcause and mtval**, in machine mode with the bare memory emulator. This is
not yet full RV64IMFD verification: floating point, traps/interrupts, other CSRs,
fences, atomics, compressed instructions, MMIO reads and self-modifying code
terminate with an explicit unsupported result. See the limitations below.

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
make verilator-build VERIFICATION=true VERILATOR=/path/to/verilator-5.040/bin/verilator \
    FUSESOC=/path/to/fusesoc JOBS=4

# Build your existing application, using the normal software build flow.
make app PROJECT=load_store

# Run it with checking and no waveforms.
make verilator-sim VERIFICATION=true DUMP_WAVES=false \
    FIRMWARE=build/main.hex MAX_CYCLES=20000

# Enable annotated waveforms for the same run.
make verilator-sim VERIFICATION=true DUMP_WAVES=true \
    FIRMWARE=build/main.hex MAX_CYCLES=20000
make verilator-waves VERIFICATION=true

# The existing benchmark entry points also accept these switches.
make run BENCHMARK=crc32 VERIFICATION=true DUMP_WAVES=false
make run-benchmarks VERIFICATION=true DUMP_WAVES=true -j4

# Remove all other build outputs, retaining the compiled Spike libraries.
make clean-keep-spike
```

`VERIFICATION=false` is the default and preserves ordinary simulation. Setting
`VERIFICATION=true` on `verilator-build`, `verilator-sim`, `verilator-opt`, `run`,
`run-benchmarks` automatically ensures the checker and Spike libraries.
The added verification test suite has been removed. `make check` keeps its
original program/RTL checks; it does not generate separate verification fixtures.
The former `diff-*` Make targets and `DIFF=1` switch have been removed.
`verilator-sim` defaults to `DUMP_WAVES=true`; `verilator-opt`, `run` and
`run-benchmarks` default to `DUMP_WAVES=false`. Explicit `DUMP_WAVES` settings
override these defaults. The defaults
are `SPIKE_SRC=sw/vendor/riscv-isa-sim`, `SPIKE_BUILD=build/spike-build` and
`VERIFICATION_BUILD_DIR=build/diff`. These variables select other locations; an external
Spike Git checkout must have the pinned HEAD, while a copied vendor directory
needs its adjacent lock file. On the tested workstation the tool paths are
`../tool/verilator/5.040/bin/verilator` and
`/home/markospremic/miniconda3/envs/core-len5/bin/fusesoc`; source `private/init.sh`
in a shell with Conda initialized to add the local tools to PATH.

Successful builds save content fingerprints, compiler/configuration identity and
output timestamps. An unchanged invocation skips configure, Make, FuseSoC and
Verilator. Missing libraries are rebuilt; changed source contents, compiler flags
or configuration invalidate the cache, including backdated edits. Build locks
serialize concurrent invocations. Outputs stay under `build/`, outside the source
tree; deleting that build directory requires a new compile, never a new download.
`make clean-keep-spike` removes its other contents, including hidden build stamps,
RTL executables, firmware, logs and waveforms. It retains the entire `SPIKE_BUILD`
directory, including archives, object files and the cache/configuration metadata.
The next verification run rebuilds the RTL model and reuses the Spike libraries.
`make clean` and `make clean-sim` retain their full-clean behavior.

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

The Python scripts support builds; instruction execution, comparison
and FST annotation remain C++:

* `bootstrap_spike.py`: validate local pinned sources, configure only when needed,
  and cache the four Spike reference libraries. It does not clone or download.
* `compile_model.py`: ensure Spike is built, reuse FuseSoC's RTL manifest, invoke
  signal-layout generation, and link the C++ checker into the Verilator simulator.
  It skips the entire model build when its inputs and executable are unchanged.
* `layout.py`: generate `diff_layout.hh` from Verilator XML, including packed-field
  offsets, widths, enum encodings and configuration constants for read-only VPI.
* `util/clean-build.py`: remove build outputs while preserving the configured
  Spike cache, including custom nested cache paths. Directory symlinks are
  removed without deleting their external targets.

The built simulator also accepts:

```sh
build/diff/model/sim-verilator/Vtb_bare --diff --dump_waves true --max_cycles 20000 \
    --diff-recovery 10000 --diff-progress 10000 \
    --diff-output logs/diff +firmware=/absolute/path/program.hex
```

`--diff` enables checking independently of `--dump_waves`. Omitting it preserves ordinary simulation.
`--diff-fault operand|cdb|register|store` corrupts one **checker observation** for
testing; it does not modify RTL state. Status 0 means checked execution reached
the existing testbench's normal exit; 1 means a confirmed discrepancy/timeout;
2 means unsupported configuration, reference behavior or output failure. The
checker API reserves 3 for an unfinished check. A checker pass is not a separate
interpretation of the program's exit byte.

## Architecture and verification coverage

Spike advances an independent architectural stream. Accepted fetches acquire
sequence associations; FIFO frontend identity and active ROB/LSQ tables carry
those records through execution. Commit removes active ROB ownership immediately
without generations. Deferred next-PC checks and complete-prefix comparisons use
the actual LEN5 integer register file. Stores have separate authorization and
external-completion lifetimes. Tentative errors become confirmed at commit or an
irreversible write; FST annotations retain both timestamps.

See [the signal map and architecture](ARCHITECTURE.md) for exact handshakes,
out-of-order commit semantics, per-stage verified fields, waveform layout and
unsupported interfaces. The generated artifacts are `logs/diff/report.json`,
`annotated.fst`, `annotated.gtkw`, `fields.json` and an event spool; the original
`logs/waves.fst` is preserved. With waves disabled, only `logs/diff/report.json`
is produced by the checker; comparison journaling and FST merging are skipped.
Stale waveform artifacts are removed when reusing a directory without waves.

Application verification outputs live under `build/sim-common/logs/`. Verified
benchmark outputs live under `build/<suite>/run/<benchmark>/logs/`, separately
for each parallel run; their existing console logs remain under
`build/<suite>/logs/sim/<benchmark>.log`. `SIM_RUN_DIR` overrides the working
directory for a direct simulation. `VERIFICATION_ARGS` supplies additional
checker options, such as `--diff-recovery 20000` or `--diff-fault cdb`.

`DUMP_TRACE=true` enables the existing committed-instruction text log, independently
of checking and waveforms. Each entry contains the logger timestamp, core ID,
instruction PC and encoding, followed by a line containing the destination-register
value when a register is written. The existing logger buffers commit notifications
by ROB order; its timestamp is the time the buffered entry is printed.
For verified applications the file is `build/sim-common/logs/sim-trace.log`;
for verified benchmarks it is `build/<suite>/run/<benchmark>/logs/sim-trace.log`.
Ordinary FuseSoC runs retain the `build/sim-common/sim-trace.log` link.
`verilator-sim` defaults to tracing enabled, while optimized/benchmark runs default
to tracing disabled. An explicit `DUMP_TRACE=true/false` overrides either default.

This switch does not change firmware compilation or relax checker coverage.
Programs using the default floating-point startup still hit unsupported FS/CSR
or FP boundaries, and the known CSR operand bug is still reported. Verification
failures and unsupported exits propagate as failing Make targets.

## Validation

The prior validation results are recorded in `VALIDATION.md`; the separate
verification test programs and runners have since been removed. Existing
applications and benchmark runs continue to use the same C++ checker.

The checker exposes an existing register-source CSR bug: LEN5 supplies zero for
`csrw mscratch,t0` when Spike expects 256; the existing `hello_world` startup
similarly fails its mtvec write. RTL remains unchanged. The existing ALU target
is blocked by width warnings. See [actual results and known failures](VALIDATION.md)
for details; unsupported FP/trap behavior is not counted as verified execution.
