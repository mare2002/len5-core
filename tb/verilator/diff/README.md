# LEN5 / Spike differential verification

This optional C++ checker runs the real LEN5 Verilator model against Spike,
tracks accepted instructions through the pipeline, and writes an annotated FST.
No processor RTL is changed. Normal simulation and the existing execution trace
remain available without linking Spike.

The tested instruction scope is **RV64IM and CSR operations on mtvec, mscratch,
mepc, mcause and mtval**, in machine mode with the bare memory emulator. This is
not yet full RV64IMFD verification: floating point, traps/interrupts, other CSRs,
fences, atomics, compressed instructions, MMIO reads and self-modifying code
terminate with an explicit unsupported result. See the limitations below.

## Build and run

Requirements: C++17 compiler, Python 3, FuseSoC/Edalize, zlib development headers,
Verilator **5.040**, and a RISC-V cross compiler for the tests. GTKWave's
`fst2vcd` is used by the integration tests; merging itself uses the C++ FST API
bundled with Verilator and needs no conversion program.

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
make diff-build VERILATOR=/path/to/verilator-5.040/bin/verilator \
    FUSESOC=/path/to/fusesoc JOBS=4

# Equivalent entry through the ordinary RTL build target:
make verilator-build DIFF=1

# Run all tracker and real hardware integration tests.
make diff-test RISCV_EXE_PREFIX=/path/to/bin/riscv64-unknown-elf

# Run a byte-wide readmemh image linked for tb_bare.BOOT_PC (currently 0x10180).
make diff-run FIRMWARE=build/diff/tests/memory_branch.hex MAX_CYCLES=20000
gtkwave build/diff/run/logs/diff/annotated.gtkw
```

`diff-build`, `diff-run` and `diff-test` automatically ensure their build dependencies.
`diff-spike` remains available to build just the reference libraries. The defaults
are `SPIKE_SRC=sw/vendor/riscv-isa-sim`, `SPIKE_BUILD=build/diff/spike-build` and
`DIFF_BUILD_DIR=build/diff`. These variables select other locations; an external
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
dependencies. `make diff-unit` tests dependency caching, the tracker and FST writer without Spike,
FuseSoC or an RTL build (`VERILATOR_ROOT` defaults to `/usr/share/verilator`).

The Python scripts support builds and tests; instruction execution, comparison
and FST annotation remain C++:

* `bootstrap_spike.py`: validate local pinned sources, configure only when needed,
  and cache the four Spike reference libraries. It does not clone or download.
* `compile_model.py`: ensure Spike is built, reuse FuseSoC's RTL manifest, invoke
  signal-layout generation, and link the C++ checker into the Verilator simulator.
  It skips the entire model build when its inputs and executable are unchanged.
* `layout.py`: generate `diff_layout.hh` from Verilator XML, including packed-field
  offsets, widths, enum encodings and configuration constants for read-only VPI.
* `tests/diff/build_test.py`: exercise initial build, cache reuse, missing outputs,
  backdated edits, flag/configuration changes, failed builds and pin validation.
* `tests/diff/run.py`: compile firmware, run real LEN5/Spike checks and injected
  faults, and independently validate annotated FST contents and GTKWave markers.

The built simulator also accepts:

```sh
build/diff/model/sim-verilator/Vtb_bare --diff --max_cycles 20000 \
    --diff-recovery 10000 --diff-progress 10000 \
    --diff-output logs/diff +firmware=/absolute/path/program.hex
```

`--diff` forces waveform recording. Omitting it preserves ordinary simulation.
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
`logs/waves.fst` is preserved.

## Validation

**27 tracker tests and 13 real LEN5/Spike runs pass their expected outcomes.**
These include four injected faults and four explicit unsupported boundaries.
The existing load/store regression passes; ordinary and checker-disabled
execution traces match. FST values and automatic marker timestamps are checked
with GTKWave's independent converter.

The checker exposes an existing register-source CSR bug: LEN5 supplies zero for
`csrw mscratch,t0` when Spike expects 256; the existing `hello_world` startup
similarly fails its mtvec write. RTL remains unchanged. The existing ALU target
is blocked by width warnings. See [actual results and known failures](VALIDATION.md)
for details; unsupported FP/trap behavior is not counted as verified execution.
