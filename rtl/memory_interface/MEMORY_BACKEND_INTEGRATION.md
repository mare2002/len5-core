# Memory backend integration

## Audit of the local tree (before implementation)

The initial working tree contained an unrelated change of `LEN5_MULTIPLE_ISSUES`
from 8 to 4 and `tb/frontend/RTL_VERIFICATION_FINDINGS.md`. Both are preserved.
The active backend is in `rtl/expipe/`, not `rtl/backend/`.

* Fetch requests are accepted on valid/ready, responses are ordered, and a
  prediction FIFO records each accepted bundle. Flush discards the whole FIFO;
  the memory must discard outstanding instruction responses at the same time.
* This tree fetches N 32-bit instructions per request. For N > 1 the emulator
  aligns the request down to N*4 bytes, returning lanes in address order. The
  frontend masks lanes preceding the requested PC. N=1 uses the supplied PC.
* Loads and stores have independent request and response handshakes and buffer
  index tags. Both LSU response-ready outputs are permanently high. Multiple
  buffer entries can await memory. Flush resets speculative load buffer state;
  with one-cycle data responses old tags are drained before new entries issue.
* Masks 01/03/0f/ff describe sizes, not positioned SRAM lanes. Store values are
  right justified. Loads expect right-justified, zero-extended raw values;
  the load buffer sign extender implements signed/unsigned semantics.
* `ONLY_DOUBLEWORD_MEM_ACCESSES` clears load address bits 2:0 but still sends
  the original size mask. The original offset and architectural misalignment
  cannot be recovered at the memory interface. TC_SRAM rejects this mode.
* The branch unit/RS already raises instruction-address-misaligned exceptions
  for bad control-flow targets. Memory alignment checks cover requests that
  actually reach the memory; no extra branch exception is injected.
* Older pending overlapping loads block stores. Store-to-load forwarding uses
  the original addresses/sizes and excludes addresses with `(addr & MMAP_MASK)
  != 0`. No stronger SRAM ordering or bypass is required.
* Legacy memory checks alignment before uninitialized-byte faults. It has a
  sparse byte associative array, writes on falling edges, and reads on rising
  edges (fetch can be combinational before its output spill register).
* `.hex` is byte-wide readmemh with absolute byte address markers; `.txt` is
  absolute address / 32-bit value pairs; other extensions are raw bytes, at
  address zero by default. Firmware selection is `+firmware=<path>`.
* `sw/linker/len5-sim.ld`: ROM 0x10000 + 256 KiB, RAM 0x50000 + 768 KiB;
  simulation boot PC 0x10180. The package BOOT_PC is not the simulation override.
* Serial and exit are output-only byte registers in the firmware. The original
  serial monitor checks acceptance; the original exit monitor checks valid.
  Legacy memory itself treats these as ordinary sparse memory addresses.
* Core reset does not clear the legacy array. TC_SRAM native non-`none` modes
  initialize on reset, so storage power-on reset must be separate from CPU reset.

## Architecture and selection

`len5_config_pkg::MEMORY_BACKEND` is the only backend selector:

```systemverilog
localparam memory_backend_t MEMORY_BACKEND = MEM_BACKEND_LEGACY;
// Or: MEM_BACKEND_TC_SRAM
// MEM_BACKEND_AXI_SIM is reserved and produces an elaboration error.
```

Invalid enum selections also produce an explicit elaboration error. Generate
branches instantiate only the selected backend. The legacy emulator and memory
class are unmodified. The fetch-stage and LSU module ports and CPU RTL are
unchanged. `datapath` selects their responses and instantiates the SRAM protocol
adapter; `tb_bare` instantiates storage only for TC_SRAM:

```text
fetch / LSU -- existing request, grant, response, ready, tag, exception signals
                    |
                datapath generate
                    +-- LEGACY: original external memory ports -> memory_bare_emu
                    +-- TC_SRAM: tc_sram_adapter -> three native ports
                    |                              |
                    |                    tb_bare / tc_sram_storage
                    |                              |
                    |                      one shared tc_sram
                    +-- AXI_SIM: explicit elaboration error (future adapter)
```

The extra datapath ports carry native SRAM signals, initialization-ready, a
response observation struct, MMIO acceptance, and diagnostic occupancy. Legacy
input/output names remain available; native outputs are inactive in that branch.
The observation struct avoids hierarchical references in the simulation monitor.
There is no cache, arbiter, interconnect, AXI dependency, or storage shadow array.
`memory_access_check` and the byte-range helper are separate from SRAM timing.

The actual upstream source and license are vendored, unmodified, at
`rtl/vendor/tech_cells_generic/`. The pinned revision is
[`55cb54513e2d426be5992d311cb9d5dbcad10c78`](https://github.com/pulp-platform/tech_cells_generic/blob/55cb54513e2d426be5992d311cb9d5dbcad10c78/src/rtl/tc_sram.sv).
Normal builds do not fetch a moving branch or require a new dependency download.
The vendor README describes updates. Narrow Verilator waivers cover upstream
style and unused initialization metadata; the source is not edited for warnings.

## Configuration and supported operating modes

| Package setting | Default | Meaning / constraints |
|---|---|---|
| `MEMORY_BACKEND` | `MEM_BACKEND_LEGACY` | Select one backend |
| `SRAM_BASE_ADDR` | `64'h0001_0000` | Byte address, eight-byte aligned |
| `SRAM_SIZE_BYTES` | `1024 * 1024` | At least eight, multiple of eight, no address-space wrap |
| `SRAM_LATENCY` | `1` | Only 1 is supported by this adapter |
| `SRAM_SIM_INIT` | `"none"` | Native `none`, `zeros`, `ones`, or `random` |
| `SERIAL_ADDR` | `64'h2000_0000` | Output-only device base |
| `EXIT_ADDR` | `64'h2000_0100` | Output-only device base |

The default SRAM covers `[0x10000, 0x110000)`, including the existing linker ROM
and RAM. Both are read/write/execute in this simulator; the linker labels do not
establish memory permissions. Changing the window requires matching firmware
link addresses and the testbench boot PC. The normal FuseSoC simulation override
is `-GBOOT_PC=65920` (`0x10180`), not `0x80000000` or the package's `0x180`.
Non-power-of-two capacities are allowed; validation precedes index truncation.

The SRAM uses `DataWidth=64`, `ByteWidth=8`, `NumPorts=3`, and `NumWords=SIZE_BYTES/8`.
The adapter rejects latency zero and values above one. Inspection of upstream
latency zero showed an asynchronous read mux whose output can change on both
request changes and writes to the held address. Reusing the latency-one metadata
path would return mismatched data; a zero-latency implementation would need its
own acceptance/response path, stall capture and frontend combinational-path
validation. It is not enabled or presented as verified. Higher latency similarly
needs a matching validity/metadata pipeline and more reservation accounting.

`LEN5_C_EN=1` is already unsupported by this CPU and is explicitly rejected here.
`ONLY_DOUBLEWORD_MEM_ACCESSES=1` is also explicitly rejected: it discards the
original load offset before this interface but retains the original size mask.
The LSU's aligned-load byte selector and its existing right-justified
store-forwarding path need a separate audit/fix before enabling that mode. This
implementation does not silently reinterpret every physical 64-bit transfer as
an architectural doubleword. Default byte/halfword/word/doubleword operations and
existing store-to-load forwarding are supported.

## Native port mapping and data conversion

| TC_SRAM signal | Port 0: fetch | Port 1: load | Port 2: store |
|---|---|---|---|
| `req_i` | Accepted bundle beat, if valid | Accepted valid load | Accepted valid write |
| `we_i` | Permanently 0 | Permanently 0 | Permanently 1 |
| `addr_i` | `(beat_address-base)>>3` | `(load_address-base)>>3` | `(store_address-base)>>3` |
| `wdata_i` | Zero / unused | Zero / unused | `store_data << (8*offset)` |
| `be_i` | Zero / unused | Zero / unused | `size_mask << offset` |
| `rdata_o` | Two 32-bit lanes / selected half | Shift and zero-extend requested bytes | Ignored |

The offset is `cpu_address[2:0]` because the configured base is eight-byte aligned.
Only masks `01`, `03`, `0f`, `ff` are accepted for data operations. Byte lane 0
holds the lowest-address byte. A byte write at offset 3 therefore drives
`be=08` and puts its low byte in `[31:24]`. Partial stores preserve all disabled
bytes. Loads return a right-justified zero-extended raw value; signed extension
remains exclusively in the LSU. All naturally aligned legal offsets are covered.

For `LEN5_MULTIPLE_ISSUES=N`, the existing instruction response contains **N
32-bit instructions**. For N=1 the original PC selects the lower or upper half
of one SRAM word. For N>1 the request is aligned down to N*4 as in legacy; each
beat fills two consecutive lanes. A bundle takes `ceil(N/2)` native reads. The
frontend's existing lane mask handles a PC in the middle of the aligned bundle.
Widths 1, 2, 4, and 8 were exercised. N must match the package and be a power of
two. The single 64-bit instruction port cannot return a four-instruction bundle
in one SRAM access; no duplicate instruction storage is introduced to hide this.

## Acceptance, timing, reservations, and backpressure

Each channel has two reserved response slots. A grant requires free credit and
completed initialization. Acceptance is `request && grant`; SRAM `req_i` only
asserts for accepted, decoded accesses. Fetch reserves one slot for the whole
bundle and issues its remaining beats internally. Channels do not share credit.
A rejected operation still reserves a slot and returns an ordered exception
response, without accessing SRAM.

For loads/stores and a one-beat fetch, the request/write is sampled at E0, the
registered result is available after E0, and response acceptance is sampled at
E1. The monitor calls this one-cycle latency. No extra response pipeline stage
is inserted:

```text
rising edge                  E0       E1       E2       E3
accepted load                A        B        C        D
native read sampled          A        B        C        D
response consumed            -        A        B        C
store written                W0       W1       W2       W3
store completion consumed    -        W0       W1       W2
```

For the local four-instruction configuration:

```text
rising edge                  E0       E1       E2       E3       E4
accepted fetch bundle        A        -        B        -        C
native instruction read      A[0:1]   A[2:3]   B[0:1]   B[2:3]   C[0:1]
bundle response consumed     -        -        A        -        B
```

The result falls through directly from the SRAM output register when ready.
If stalled, the response buffer captures data and metadata before the upstream
output can change. SRAM re-reads its held read address even without `req_i`, so
holding only a valid bit would be incorrect. Tags, data, exception flags and codes
are stored together; no idle SRAM output is treated as a response. Store tags
are not retired until the registered completion; a stalled completion cannot
reissue the write. MMIO uses the same acceptance/completion accounting.

The two-entry reservation count includes pending native reads and buffered
responses. Actual buffer occupancy counts only captured results. Independent
ordered channels preserve tag order while allowing concurrent load/store/fetch
activity. Store tag allocation/reuse remains in the LSU.

Credit depends on registered reservation count, not combinational response-ready.
This avoids a ready-to-grant path through LEN5's packed frontend signals. A buffer
that became completely full regains request credit on the cycle after a response
is consumed, giving one recovery bubble. Continuously ready loads and stores
still accept one request per clock, and fetch issues one **native beat** per
clock. The directed test checks 32 consecutive cycles of native traffic with all
three ports, and two outstanding requests under backpressure. Full-core LSU
ready is always high; measured load/store stalls were zero.

## Flush and reset

Instruction flush immediately gates response-valid and native fetch issuance,
then clears the fetch assembly state, pending validity and both response slots.
An already sampled SRAM read may still update the native output, but its validity
is discarded. No old bundle can be associated with a post-flush request. The
post-flush stream starts when flush deasserts and a new request is accepted.

Reset clears all adapter reservations, metadata, valid bits and assembly state;
no requests or responses are active while reset is asserted. It does not undo
an already accepted store. Data responses are not flushed by the instruction
flush signal. The current LSU always accepts them, and the one-cycle response
path drains old load tags before newly allocated entries can issue after a core
flush; extending latency requires revisiting that constraint.

`tc_sram_storage` has a separate one-time power-on reset, not the CPU reset.
Native initialization runs first, firmware is deposited on the following falling
edge, and only then `initialized_o` allows adapter grants. Subsequent CPU resets
clear bridge state but preserve firmware and data even for `SimInit="zeros"`,
`"ones"`, or `"random"`. This separation is necessary because upstream reinitializes
its array whenever its own reset is asserted.

## Faults and address validation

Alignment has priority over access fault, matching legacy. Natural alignment is
1/2/4/8 bytes for the four data sizes and four bytes for instructions. A bad
original fetch PC faults its lanes before aligned bundle reads can occur. Branch
and jump target exceptions already generated by the CPU are not duplicated in
control-flow logic; the adapter checks requests that actually reach memory.

For a supported size, validity requires `address >= base`, `bytes <= size`, and
`address-base <= size-bytes`. No overflowing `address+bytes` comparison and no
truncated SRAM index decides validity. The final byte is checked. Unsupported
masks, below-base, beyond-end, crossing, and unmapped addresses fault. Each fetch
lane has its own bounds result. Memory-map configuration rejects wraparound,
unaligned windows, overlapping devices, and devices overlapping SRAM.

Returned causes are `E_I_ADDR_MISALIGNED`, `E_LD_ADDR_MISALIGNED`,
`E_ST_ADDR_MISALIGNED`, `E_I_ACCESS_FAULT`, `E_LD_ACCESS_FAULT`, and
`E_ST_ACCESS_FAULT`. Data exception responses retain their original tags. Faulting
stores cannot assert native `req_i` or the MMIO acceptance pulse. No ECC, parity,
page, illegal-instruction, ecall, or ebreak handling is added here.

## MMIO and firmware agreement

Serial and exit are two eight-byte-aligned, disjoint output-device regions.
Naturally aligned 1/2/4/8-byte writes at the exact configured base are supported;
the monitor uses the low byte. Reads, instruction fetches, offsets inside these
regions (including UART status/input offsets), and other unmapped addresses
fault. Supported MMIO writes never reach SRAM and never produce SRAM bounds
faults. Their side effect occurs once at accepted rising-edge write, followed by
the normal one-cycle store completion. Response stalls do not repeat it. Legacy
monitor behavior remains as before.

`sw/makefile` generates `len5_memory_map.h` using `scripts/gen-memory-map.py` and
force-includes it for application and runtime compilation. The RTL package is the
source for both firmware and testbench defaults; the generator requires literal
64-bit hexadecimal MMIO constants. Existing testbench parameters can still
be overridden; in that case explicitly override firmware `LEN5_SERIAL_ADDR` and
`LEN5_EXIT_ADDR` using `CDEFS` as well. Changing package constants alone is the
normal, single-source procedure. Rebuild both simulator and firmware afterward.

Both device addresses must have `(address & MMAP_MASK) != 0` so the existing LSU
cannot forward stores into MMIO loads. A configuration assertion enforces this.
For addresses below the default excluded region, adjust `MMAP_MASK` consistently.
To add a peripheral, extend `memory_access_check`'s decode and a simulation
monitor, reserve a disjoint region, update firmware constants, and verify
accepted-event side effects. Do not add peripheral behavior to `tc_sram`.

## Firmware loading and native initialization

Use the existing `+firmware=<path>` selection. With FuseSoC this is
`--firmware=<path>`; the existing make targets accept `FIRMWARE=<path>`.

* `.hex`: byte-wide hexadecimal tokens and absolute byte `@address` markers,
  including sparse regions and line/block comments. This matches the existing
  `objcopy -O verilog` output, not a word-wide SRAM `$readmemh` image.
* `.txt`: hexadecimal absolute byte address / 32-bit word pairs. Each word is
  deposited as four little-endian bytes.
* Other extensions: raw binary bytes starting at zero by default, preserving the
  legacy convention. For an objcopy binary linked at the normal base, pass
  `+firmware_base=10000` (hex, without `0x`). The finite SRAM correctly rejects a
  default binary load at address zero when the base is 0x10000.

Every deposited byte is bounds checked; overflow, malformed addresses/tokens,
empty images and regions outside the configured window fail with a diagnostic.
Sparse holes and untouched byte lanes retain native initialization. There is no
initialized-byte bitmap and no access fault merely for reading unwritten SRAM.
The simulation-only loader lives beside storage, using just the immediate
`u_sram.sram` array reference because upstream exposes no initialization API.
Protocol RTL contains no file I/O or testbench hierarchy. This is one authoritative
array, not a functional copy populated later.

Verilator 5.040 incorrectly converts a typed string passed to upstream's untyped
`SimInit` parameter into numeric zero. The wrapper passes a packed ASCII constant
for the selected native mode, leaving upstream unchanged. Loader tests verified
all four modes on 5.040. Two-state Verilator does not establish four-state X
propagation for `none`; no substitute uninitialized-byte semantics are introduced.
Random initialization uses upstream `$urandom`; its sequence is simulator-specific.

## Collision semantics

At latency one, upstream samples read data before its nonblocking byte writes.
Simultaneous instruction/load reads and a store of the same SRAM word see the
old word; subsequent reads see the updated enabled bytes. Upstream loops through
ports in ascending order, so later ports win overlapping simultaneous writes.
Only port 2 can write here, eliminating write/write contention. No bypass changes
these semantics. The test scoreboard samples expected reads before applying
stores. A multi-beat fetch is not an atomic memory snapshot across all beats.
The existing LSU ordering and forwarding remain responsible for architectural
load/store dependencies.

## Build and run commands

Prerequisites: FuseSoC/Edalize, a C++ compiler, RISC-V GCC, Python 3, and Verilator.
Full-core and Spike verification below used **Verilator 5.040**; adapter tests also
ran on **5.046**. The current Spike XML integration requires 5.040. Put that
Verilator first on PATH (setting only a make variable may leave Edalize using a
different binary). The tested machine used:

```sh
export PATH=/home/markospremic/Documents/epfl_len5/tool/verilator/5.040/bin:/home/markospremic/miniconda3/envs/core-len5/bin:/home/markospremic/Documents/epfl_len5/tool/riscv/bin:$PATH
export OBJCACHE=
export MAKEFLAGS='--jobserver-style=pipe -j4 CXX=/usr/bin/g++'
```

The jobserver setting avoids isolated PID-namespace FIFO collisions in this build
environment. It is not an RTL requirement. The common simulator options include
`-fno-dfg` for the existing 5.040 early-jump metadata optimizer discrepancy recorded
in `tb/frontend/RTL_VERIFICATION_FINDINGS.md` T01. Both backends use the same flag.
Existing UNOPTFLAT waiver text was made compatible with the changed diagnostic
prefix; scopes and signal patterns were preserved. New logic does not disable
width, latch, multidriver, or protocol warnings.

Build and run legacy (the checked-in default):

```sh
make verilator-build
make app PROJECT=hello_world
make verilator-sim FIRMWARE=build/main.hex MAX_CYCLES=100000 DUMP_WAVES=false
```

To select TC_SRAM in place, change **only** `MEMORY_BACKEND` in
`rtl/packages/len5_config_pkg.sv` to `MEM_BACKEND_TC_SRAM`, then use those same
commands. To keep a simultaneous legacy build without changing the working
configuration, use an isolated snapshot:

```sh
python3 scripts/sim/prepare-memory-backend.py TC_SRAM build/memory-backend/tc-source
make -C build/memory-backend/tc-source verilator-build
make -C build/memory-backend/tc-source verilator-sim \
  FIRMWARE="$PWD/build/main.hex" MAX_CYCLES=100000 DUMP_WAVES=false
```

Use a new destination if the snapshot already exists; the helper refuses to
overwrite results. It copies local source modifications, selects one enum, and
places `FUSESOC_IGNORE` in the parent build directory so FuseSoC does not discover
snapshot cores as duplicates. It does not track later source edits automatically.

The simulator can also be called directly (create `logs/` in the run directory):

```sh
mkdir -p build/memory-backend/direct/logs
cd build/memory-backend/direct
../tc-source/build/normal/sim-verilator/Vtb_bare \
  --dump_waves false --dump_trace false --max_cycles 100000 \
  +firmware=../hello/main.hex +memory_report=memory-performance.json
```

For binary firmware use an absolute path and `+firmware_base=10000`. With make,
pass `FUSESOC_ARGS='--firmware_base=10000 --memory_report=/absolute/report.json'`.
Reports are otherwise written in the simulator's working directory.

Build the checked simulators (requires the existing pinned Spike source import;
see `tb/verilator/diff/README.md` for first-time setup):

```sh
make verilator-build-debug
export SPIKE_SRC="$PWD/sw/vendor/riscv-isa-sim"
export SPIKE_BUILD="$PWD/build/spike-build"
make -C build/memory-backend/tc-source verilator-build-debug
```

Reproduce the firmware and comparisons from the repository root:

```sh
make -C sw app PROJECT=hello_world BUILD_DIR="$PWD/build/memory-backend/hello"
make -C sw app PROJECT=load_store BUILD_DIR="$PWD/build/memory-backend/load_store" CDEFS=-DSPIKE_CHECK
make -C sw app PROJECT=shift BUILD_DIR="$PWD/build/memory-backend/shift" CDEFS=-DSPIKE_CHECK
make -C sw benchmark SUITE=embench BENCHMARK=crc32 \
  BUILD_DIR="$PWD/build/memory-backend/crc32" LINKER="$PWD/sw/linker/len5-sim.ld" CDEFS=-DSPIKE_CHECK
python3 scripts/sim/compare-memory-backends.py \
  --legacy build/debug/sim-diff-verilator/Vtb_bare \
  --tc-sram build/memory-backend/tc-source/build/debug/sim-diff-verilator/Vtb_bare \
  --firmware hello=build/memory-backend/hello/main.hex \
  --firmware load_store=build/memory-backend/load_store/main.hex \
  --firmware shift=build/memory-backend/shift/main.hex \
  --firmware crc32=build/memory-backend/crc32/main.hex
```

The absolute linker path works around the existing benchmark submake's relative
linker-path problem. `compare-memory-backends.py` requires successful program
termination, successful Spike reports, matching serial strings and matching
retirement counts at exit; a simulator that merely times out is not a pass.
Each report records the exact command and firmware SHA-256.

## Executed verification

Results below were collected on the local four-issue checkout, with ordinary
forwarding enabled and the default SRAM window. Logs/artifacts stay under `build/`.
No generated binaries or firmware are part of the source change.

| Verification | Status | Evidence / scope |
|---|---|---|
| Legacy ordinary FuseSoC build and hello execution | PASS | `build/memory-backend/legacy-final-build.log`, `legacy-final-hello/console.log` |
| TC_SRAM ordinary FuseSoC build and hello execution | PASS | `tc-final-build.log`, `tc-final-hello/console.log` |
| Existing make/FuseSoC run flow and performance plusarg | PASS | `tc-fusesoc-run.log`, `tc-fusesoc-performance.json` |
| Raw binary full-core hello with relocated load base | PASS | `tc-binary-hello/console.log`, `+firmware_base=10000`; same cycles/retirement as hex |
| Legacy and TC_SRAM Spike builds | PASS | `legacy-final-diff-build.log`, `tc-final-diff-build.log` |
| Hello, load_store, shift, CRC32 on both, with Spike | PASS | `comparison/report.json`; all eight runs report no discrepancies and successful exit |
| Existing enabled application set at O0/O1/O2 on both backends | PASS | `application-comparison/report.json`; hello_world, load_store, shift; **18 successful Spike runs** |
| Directed and random adapter verification | PASS | `build/tc-sram/report.json`, seeds **1–100**, **10,000 random cycles each**, plus directed setup/drain |
| Fetch-width variants N=1,2,8 | PASS | `build/tc-sram-width{1,2,8}/seed-{1,2,3}.log`, 10,000 random cycles per seed |
| Firmware formats / native initialization | PASS | `build/tc-sram-loader/`; 12 positive format/mode combinations and 7 malformed/out-of-bounds rejections, all on 5.040; also exercised on 5.046 |
| Configuration validation | PASS | `build/tc-sram-config/report.json`: valid map, rejected latency 0/2, overlapping/unaligned/wrapping windows, fractional word size, forwarding-mask violation, doubleword-only/compressed mode |
| Reserved AXI and invalid enum selections | PASS | `build/memory-backend-selection/report.json`, explicit elaboration diagnostics |
| Relocated MMIO full-core hello | PASS | `remap-hello/console.log`: serial 0x40000000, exit 0x40000100; firmware header generated from that configuration |
| Existing standalone LSU tests | PASS | `load-store.log`, `bash scripts/sim/check-load-store.sh` |
| New HDL Verible lint, Python syntax, diff whitespace | PASS | `new-lint.log`; commands below |
| Repository-wide `make check` | **BLOCKED / command failed** | `make-check.log`: existing ALU `ctl_i` is 4 bits but cases/enum are 6 bits; five fatal width warnings before later checks |
| Excluded applications / all benchmark suite entries | NOT RUN | Existing exclusions are timer, alu_mult, alu_div; only CRC32 from Embench was executed |
| Full-core trap/exception differential comparison | NOT SUPPORTED | Existing checker stops at exception/interrupt recovery; adapter exception generation is independently tested |
| Four-state unknown propagation | NOT RUN | Verilator is two-state; no four-state simulator result claimed |
| SRAM latency 0 or >1 functional tests | NOT SUPPORTED | Explicitly rejected and rejection tested |

The adapter scoreboard is independent byte-level reference storage used only in
the testbench. It checks native request addresses, masks and data, then predicts
responses and tags from accepted transactions, comparing even while responses
are stalled. Directed cases cover every legal data offset and size, both fetch
halves, partial/repeated writes, all misalignments, bounds/overflow/MMIO faults,
all three concurrent ports, read-before-write collision, two reservations,
32-cycle uninterrupted throughput, fetch flush and reset with pending requests.
Random cases mix legal/illegal addresses, masks, tags, ready stalls, simultaneous
ports and flushes. Final reads of every word check that rejected stores and reset
did not corrupt the reference contents. Coverage assertions require faults,
stalls, full reservations, MMIO events, collisions and flushes.

Spike checks the retired instruction stream, operand/register values and external
store stream for the supported execution scope. The testbench waits 50 cycles
after exit, so the final Spike count includes a timing-dependent number of idle
loop commits (for example load_store: 2764 legacy, 2743 TC_SRAM). Both have **2716**
retired instructions at the common exit sample. This is not an architectural
mismatch. No independent full-core SRAM-array dump comparison was added; physical
contents are checked by the adapter scoreboard and architectural writes by Spike.
Speculative fetch/load counts can differ because frontend recovery timing changes.

The enabled application's O0/O1/O2 matrix was run independently of the failing
ALU prerequisite, using the existing programs and the integrated Spike checker.
The repository already excludes `timer`, `alu_mult` and `alu_div`. In particular,
the latter two contain accesses to address 136, below the configured SRAM base;
silently aliasing those into SRAM would violate the finite memory map. Their
existing exclusion was not changed. Reproduce the 18-run matrix with:

```sh
matrix_args=()
for opt in 0 1 2; do
  for app in hello_world load_store shift; do
    name="${app}-O${opt}"
    make -C sw app PROJECT="$app" COPT="-O$opt" CDEFS=-DSPIKE_CHECK \
      BUILD_DIR="$PWD/build/memory-backend/application-regression/$name"
    matrix_args+=(--firmware "$name=build/memory-backend/application-regression/$name/main.hex")
  done
done
python3 scripts/sim/compare-memory-backends.py \
  --legacy build/debug/sim-diff-verilator/Vtb_bare \
  --tc-sram build/memory-backend/tc-source/build/debug/sim-diff-verilator/Vtb_bare \
  --output build/memory-backend/application-comparison "${matrix_args[@]}"
```

Commands for the standalone verification:

```sh
SEEDS=100 CYCLES=10000 JOBS=4 bash scripts/sim/check-tc-sram.sh
# Equivalent make entry point: make check-tc-sram SEEDS=100 CYCLES=10000 JOBS=4
python3 scripts/sim/check-tc-sram-loader.py
python3 scripts/sim/check-tc-sram-config.py
python3 scripts/sim/check-memory-backend-selection.py \
  build/normal/sim-verilator/polito_len5_len5_0.1.1.vc
bash scripts/sim/check-load-store.sh
make check  # currently fails at the existing ALU width mismatch
verible-verilog-lint --rules=line-length=length:160 \
  --waiver_files=rtl/misc/verible-lint.waiver rtl/memory_interface/*.sv \
  tb/memory/tc_sram_storage.sv tb/memory/memory_protocol_monitor.sv tb/memory/tc_sram/*.sv
python3 -m py_compile scripts/gen-memory-map.py scripts/sim/*tc-sram*.py \
  scripts/sim/prepare-memory-backend.py scripts/sim/compare-memory-backends.py \
  scripts/sim/check-memory-backend-selection.py
git diff --check
```

For another bundle width, copy `len5_config_pkg.sv` to a generated configuration,
change only `LEN5_MULTIPLE_ISSUES`, then run
`TC_SRAM_CONFIG=/absolute/config.sv TC_SRAM_BUILD_DIR=/absolute/builddir SEEDS=3 CYCLES=10000 bash scripts/sim/check-tc-sram.sh`.
This tests the adapter configuration; it does not claim full-core verification of
all CPU widths. Configuration and loader scripts report each tested case and
preserve its build/run log. Expected `$fatal` rejections may produce a nonzero
simulator exit; the scripts explicitly require those failures.

## Performance measurements

Both models used identical firmware, Verilator 5.040, N=4, no caches or prefetcher,
and the same simulator flags. Cycles and retired instructions are sampled by
`memory_protocol_monitor` at accepted program exit, before the testbench's idle
termination delay. These counts may differ by a cycle from CSR/debug printouts.

| Firmware | Retired (both) | Legacy cycles | TC_SRAM cycles | Cycle increase | Legacy IPC | TC_SRAM IPC |
|---|---:|---:|---:|---:|---:|---:|
| hello_world | 14,121 | 24,110 | 25,749 | 6.80% | 0.585691 | 0.548410 |
| load_store | 2,716 | 2,859 | 2,880 | 0.73% | 0.949983 | 0.943056 |
| shift | 2,714 | 2,857 | 3,723 | 30.31% | 0.949947 | 0.728982 |
| Embench crc32 | 29,384 | 30,837 | 31,719 | 2.86% | 0.952881 | 0.926385 |

All required per-channel measurements for hello_world are below. Latency includes
response-ready stalls and excludes canceled fetches. Request counts include
accepted speculative requests, which need not retire. Outstanding averages are
per active core cycle. Buffer occupancy for TC_SRAM counts captured skid slots,
excluding the native pipeline; legacy counts its pending output/spill responses.

| Metric | Legacy fetch | SRAM fetch | Legacy load | SRAM load | Legacy store | SRAM store |
|---|---:|---:|---:|---:|---:|---:|
| Accepted requests | 16,356 | 12,213 | 2,654 | 2,654 | 2,616 | 2,616 |
| Completed responses | 12,682 | 9,609 | 2,654 | 2,654 | 2,616 | 2,616 |
| Requests/cycle | 0.678391 | 0.474310 | 0.110079 | 0.103072 | 0.108503 | 0.101596 |
| Average latency (cycles) | 1.570415 | 2.282235 | 1.000000 | 1.000000 | 1.000000 | 1.000000 |
| Maximum outstanding | 2 | 2 | 1 | 1 | 1 | 1 |
| Average outstanding | 0.913853 | 0.869665 | 0.110079 | 0.103072 | 0.108503 | 0.101596 |
| Maximum buffer occupancy | 2 | 2 | 1 | 0 | 1 | 0 |
| Average buffer occupancy | 0.913853 | 0.110373 | 0.110079 | 0 | 0.108503 | 0 |
| Request stall cycles | 6,840 | 12,585 | 0 | 0 | 0 | 0 |
| Response stall cycles | 8,109 | 1,897 | 0 | 0 | 0 | 0 |

All four programs' complete port measurements are in
`build/memory-backend/comparison/report.json` and each run's
`memory-performance.json`. The monitor is observational and adds no RTL delay.

Investigation of shift shows the instruction-port width limit directly:
TC_SRAM accepts **0.499866 bundles/cycle**, has exactly **2.0-cycle** average fetch
latency and **zero** response stall cycles or captured response occupancy. Its
1850 request stall cycles are the second-beat issuance slots. The four-instruction
interface needs two 64-bit reads; this workload reaches that limit. Larger buffers
or arbitration changes cannot supply more than two instructions per native read.
The load/store path has one-cycle latency, no response-buffer occupancy and zero
request/response stalls in all measured full-core programs. Thus the measured
regressions are fetch width/latency effects, not global serialization. There is
one documented buffer-full recovery bubble, but no steady-state response bubble.

## Limitations and adding AXI later

* Latency one, uncompressed instructions, and original load offsets are required.
  Rejected configurations do not silently fall back to legacy behavior.
* SRAM bounds and native untouched-memory behavior intentionally differ from the
  sparse legacy emulator's uninitialized-byte access faults.
* Only two output devices are implemented; UART reads/status offsets fault.
* Full-core verification uses Verilator 5.040 and the current Spike supported
  subset. Exception recovery, four-state X behavior, and all benchmark programs
  are not signed off by this work. The pre-existing ALU regression failure remains.
* The adapter is synthesizable protocol logic; storage/firmware loading is a
  simulation integration. A physical macro wrapper would replace `tc_sram_storage`
  and supply appropriate initialization readiness.

For AXI, add a new adapter under `rtl/memory_interface/` using the same existing
LEN5 request/response channels. Instantiate it in the currently rejected generate
branch and connect its own simulation storage/interconnect only in that branch.
Reuse byte-range checks/MMIO policy where appropriate, but implement AXI-specific
IDs, independent channels, response buffering and errors in that adapter. Revisit
LSU flush/tag reuse for its longer outstanding latency before enabling selection.
Pin and license AXI dependencies at that point; none are required by TC_SRAM.
Keep legacy as the default, preserve all existing frontend/LSU ports, and add the
new backend to the same directed, randomized, loader and full-core comparisons.

## File inventory

Added:

* `rtl/memory_interface/{memory_backend_pkg,memory_access_check,memory_response_buffer,tc_sram_adapter}.sv`
* `rtl/memory_interface/MEMORY_BACKEND_INTEGRATION.md`
* `rtl/vendor/tech_cells_generic/{tc_sram.sv,LICENSE,README.md}`
* `tb/memory/{tc_sram_storage.sv,tc_sram_loader.svh,memory_protocol_monitor.sv}`
* `tb/memory/tc_sram/{tc_sram_adapter_tb.sv,tc_sram_loader_tb.sv,tc_sram_config_tb.sv,waivers.vlt}`
* `scripts/gen-memory-map.py`
* `scripts/sim/{prepare-memory-backend.py,check-tc-sram.sh,check-tc-sram-loader.py,check-tc-sram-config.py,check-memory-backend-selection.py,compare-memory-backends.py}`

Modified:

* `rtl/packages/len5_config_pkg.sv`, `rtl/datapath.sv`, `tb/tb_bare.sv`
* `len5.core`, `rtl/packages.core`, `rtl/datapath.core`, `makefile`
* `rtl/misc/{packages,expipe,fpu,frontend}-waivers.vlt`
* `sw/makefile`, `sw/device/runtime/len5.h`
* `tb/verilator/diff/{monitor.cpp,spike_adapter.cpp,spike_adapter.hh,README.md}`

The pre-existing `LEN5_MULTIPLE_ISSUES=4` edit and frontend findings file were
preserved. No frontend, LSU, legacy memory emulator, or upstream SRAM source
behavior was edited.
