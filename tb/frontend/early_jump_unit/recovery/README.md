# Full-core recovery audit reproducer

This is a separate, observational integration experiment. It instantiates the
existing `tb_bare` with the **complete production datapath and memory emulator**.
It does not replace the standalone EJU/RAS oracle or feed internal state into it.
The SystemVerilog monitor reads pipeline signals and RAS arrays solely to explain
actual execution. There are no forced signals, synthetic confirmations, injected
exceptions, or RTL recovery changes.

From the repository root:

```sh
source private/init.sh
python3 tb/frontend/early_jump_unit/recovery/run.py --width 2
python3 tb/frontend/early_jump_unit/recovery/run.py --width 4
```

If Conda activation is unavailable in a noninteractive shell, first source your
Conda `etc/profile.d/conda.sh`. Required tools are the existing FuseSoC, Verilator,
C++ compiler and `riscv64-unknown-elf-{gcc,objcopy,objdump,nm}`.

Each command creates an isolated directory under `build/early-jump/recovery/`,
copies the RTL/testbench dependencies, and changes **only the copied configuration**
to the requested width. The live configuration remains the source of all other
settings and is never written. This explicit audit-only width override is not a
second configuration selector for the ordinary standalone Make targets. New build
directories avoid stale binaries; captured elaborated widths must match the request.
`FUSESOC_IGNORE` prevents the parent repository from discovering private libraries.
Dependencies are exported into each build to avoid relative include-path aliases.

The firmware contains real RV64 instructions, no compressed encodings:

- `exception_call.S`: committed older call; long DIVU; dependent misaligned LD;
  younger JAL x1; trap-handler RET exposing the stale predicted link.
- `exception_return.S`: committed older call; changed x1; long DIVU; dependent
  faulting LD; younger mispredicted canonical RET exposing a squashed confirmed pop.
- `empty_return.S`: no calls, canonical RET with empty RAS; actual BU recovery,
  correct target issue and architectural register-write enable at the destination.

WFI parks the wrong-path issue stream; it does not produce the exception. Gaps are
filled with valid NOPs so incidental prefetch does not introduce unrelated illegal
instruction exceptions. The trap RET is an intentional prediction witness, not
an MRET implementation or an operating-system exception handler.

`exercise.py --root <capture-directory>` reuses a compiled full-core binary for new
firmware experiments, creating a new `experiments/cases-*` directory each time.
It saves exact assembly, ELF, disassembly, memory image, `cycles.csv`, `waves.fst`,
logs and `result.json`. The latter checks confirmation/exception ordering, actual
ROB residency and removal, lack of earlier ROB retirement, actual C/P contents,
and subsequent return behavior. `latest-experiment.txt` points to the latest run.
The simulator records 300 cycles including ten reset cycles per firmware.

CSV `pre` records sample immediately before the consuming rising edge. A state
update at cycle c appears in the next pre-edge row c+1. `post_previous` rows are
falling-edge observations at the start of the next numbered driver cycle. RAS
array addresses are meaningful **only where the corresponding validity bit is 1**.
All numeric CSV fields are hexadecimal. Qualify PC/data fields with their valid
signals; inactive branch-target/misprediction wires are not execution events.

Exit zero means the requested experiment produced its required evidence. For the
two exception programs, `status: reproduced` means **the recovery defect was
observed**, not that the RTL passed a correctness test. Missing evidence returns
nonzero and `not_reproduced`; the simulator alone only reports capture completion.
The empty-RAS control uses `status: passed`. See [the audit](../ARCHITECTURE_AUDIT.md#e-full-core-execution-follow-up)
for limitations, secondary observations, EQ07 and N=2/N=4 results.
