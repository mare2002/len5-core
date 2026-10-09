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
`530af85d83781a3dae31a4ace84a573ec255fefa`. Installed Spike executables alone are
insufficient: the adapter needs matching source headers and static libraries
built with `--enable-commitlog`. The build rejects another revision. Verilator
5.046 removed the XML interface used to derive field layouts, so the optional
build currently requires 5.040 explicitly.

From the repository root:

```sh
# Build isolated reference libraries (downloads the pinned source on first use).
make diff-spike JOBS=4

# Set these paths if the corresponding tools are not on PATH.
make diff-build VERILATOR=/path/to/verilator-5.040/bin/verilator \
    FUSESOC=/path/to/fusesoc JOBS=4

# Run all tracker and real hardware integration tests.
make diff-test RISCV_EXE_PREFIX=/path/to/bin/riscv64-unknown-elf

# Run a byte-wide readmemh image linked for tb_bare.BOOT_PC (currently 0x10180).
make diff-run FIRMWARE=build/diff/tests/memory_branch.hex MAX_CYCLES=20000
gtkwave build/diff/run/logs/diff/annotated.gtkw
```

`diff-build` and `diff-spike` are explicit setup steps; `diff-run` and `diff-test`
use the existing build. `SPIKE_SRC`, `SPIKE_BUILD` and `DIFF_BUILD_DIR` select
other locations. On the tested workstation the existing tool paths are
`../tool/verilator/5.040/bin/verilator` and
`/home/markospremic/miniconda3/envs/core-len5/bin/fusesoc`. The validation used
`SPIKE_SRC=/tmp/len5-spike-src SPIKE_BUILD=/tmp/len5-spike-build`.

The bootstrap builds libraries only. If `dtc` is absent, it deliberately disables
the unused device-tree generator with `DTC=false`; this does **not** produce a
working Spike CLI/DTB environment. It also supplies `-include cstdint` for old
Spike headers with recent GCC. Ordinary `make verilator-build` has none of these
dependencies. `make diff-unit` tests the tracker and FST writer without Spike,
FuseSoC or an RTL build (`VERILATOR_ROOT` defaults to `/usr/share/verilator`).

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
