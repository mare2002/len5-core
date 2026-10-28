# pc_gen black-box verification specification

## Current model contract — 2026-10-28

The approved R10 rule remains active in both model profiles: while early
correction is asserted, offer no new fetch request, but keep its target/metadata
live and preserve higher-priority redirects. Existing responses and downstream
acceptance retain their obligations. The current PC model already implements
this rule; this update audits it rather than adding a second PC oracle.

See the [cross-module change and scenario report](../MODEL_UPDATE_2026-10-28.md)
for validation receipts and problem dispositions. Production RTL is unchanged;
R12 is excluded. Current source selects N=8. Older audit-era configurations,
counts and alternative-policy results below are historical and are superseded
by this dated contract where they conflict. Build launchers exclude repository
`build/` from FuseSoC discovery even with a custom BUILD_DIR, preventing archived
core copies from overriding the live verification sources.


Current contract revision: `approved-2026-10-14`. The user's Q1–Q10 design decisions
are independent specification evidence, classified D below. Scope is solely the
public ports of `rtl/frontend/pc_gen.sv`, on `feat-verification`. Production RTL and
configuration must remain unchanged. [README.md](README.md) describes execution and
the current audit results. Prior results under earlier assumptions are historical;
they do not override this contract or prove processor correctness.

## Evidence and requirement status

| Label | Meaning | Treatment |
| --- | --- | --- |
| A | Architectural requirement | Independent oracle within the supported ISA scope. |
| D | Explicit documentation or user-approved functional design decision | Definitive comparison; approval is independent of RTL agreement. |
| I | Inferred producer/consumer integration contract | Named assumption and provisional mismatch. |
| O | RTL-only observation | Characterization evidence, never a golden rule. |
| Q | Remaining specification detail | Unknown field, separate observation, no arbitrary expected value. |

The full priority, async reset, bundle successor, early correction independent of
memory readiness, supplied address pass-through and stalled prediction changes
are now D. ISA branch fall-through contributes A to C5. Losing acknowledgments and
actual flush timing are separate from PC selection. Reports contain each field's
requirement, evidence, assumptions, known status and disposition (`required`,
`dont_care`, `unresolved`). Only known values are compared. An exact PC check is
never disabled because a supplemental priority diagnosis lacks prior context.

### Source inventory

Paths are relative to the repository root; links are relative to this document.

| ID | Source | Relevant evidence |
| --- | --- | --- |
| S1 | [pc_gen.sv](../../../rtl/frontend/pc_gen.sv) | Current ports, BOOT_PC parameter, edge/reset behavior, priority comment, observable output behavior. |
| S2 | [fetch_stage.sv](../../../rtl/frontend/fetch_stage.sv) | The active instance `u_pc_gen`; every pin connection; prediction is available in the same cycle as PC. |
| S3 | [fetch_pkg.sv](../../../rtl/packages/fetch_pkg.sv), [len5_pkg.sv](../../../rtl/packages/len5_pkg.sv), [len5_config_pkg.sv](../../../rtl/packages/len5_config_pkg.sv) | Resolution/prediction types, instruction/address widths, bundle width, unsupported C extension. |
| S4 | [fetch_mem_if.sv](../../../rtl/frontend/fetch_mem_if.sv), [spill_cell_flush.sv](../../../rtl/common/spill_cell_flush.sv) | Fetch ready/valid boundary, request buffering/bypass, ordered responses, prediction FIFO and flush. |
| S5 | [bpu.sv](../../../rtl/frontend/bpu.sv), [gen_valid_instr.sv](../../../rtl/frontend/gen_valid_instr.sv) | Bundle PCs, prediction selection, skipped lanes before the starting PC. |
| S6 | [early_jump_unit.sv](../../../rtl/frontend/early_jump_unit.sv), [ras.sv](../../../rtl/frontend/ras.sv) | JAL/call and return correction, older fetched PC as base, sign-extended offset, requests held while issue is blocked. |
| S7 | [datapath.sv](../../../rtl/datapath.sv), [backend.sv](../../../rtl/expipe/backend.sv), [exec_stage.sv](../../../rtl/expipe/exec-units/exec_stage.sv) | Hierarchical routing of branch resolution, commit redirect, ready feedback and flush. |
| S8 | [branch_unit.sv](../../../rtl/expipe/exec-units/branch_unit.sv), [branch_cu.sv](../../../rtl/expipe/exec-units/branch_cu.sv) | Resolution originates from an executed instruction; misprediction notification, frontend acknowledgment and wait for backend flush. |
| S9 | [commit_stage.sv](../../../rtl/expipe/commit-unit/commit_stage.sv), [commit_cu.sv](../../../rtl/expipe/commit-unit/commit_cu.sv), [csrs.sv](../../../rtl/expipe/register-file/csrs.sv) | Trap/MRET redirect producer, CSR-derived target, shared frontend ready input. |
| S10 | [ARCHITECTURE.md](../../verilator/diff/ARCHITECTURE.md), [README.md](../../../README.md), [doc/notes/todo.txt](../../../doc/notes/todo.txt) | Eight-instruction fetch bundles, verification boundaries and historical limitations. No standalone authoritative pc_gen specification was found. |
| S11 | [frontend.core](../../../rtl/frontend.core), [packages.core](../../../rtl/packages.core), [len5.core](../../../len5.core), [makefile](../../../makefile) | Active RTL filesets, package ordering, simulator options and boot override. |
| S12 | [tb_macros.hh](../../verilator/tb_macros.hh), [tb_macros.cpp](../../verilator/tb_macros.cpp), [len5_tb.cpp](../../verilator/len5_tb.cpp) | Shared logger, verbosity, context timestamps and simulation loop. |
| S13 | [alu_tb.cpp](../../expipe/alu/alu_tb.cpp), [tb_components.cpp](../../expipe/alu/tb_components.cpp), [alu_tb.core](../../expipe/alu/alu_tb.core), [ALU makefile](../../expipe/alu/makefile) | Closest C++ module-test organization, transactions, driver, monitors, scoreboard and summary strings. |
| S14 | [diff README](../../verilator/diff/README.md), [VALIDATION.md](../../verilator/diff/VALIDATION.md), [checker.cpp](../../verilator/diff/checker.cpp), [monitor.cpp](../../verilator/diff/monitor.cpp) | Existing differential reports, status codes, failure fields and historical test results. |
| S15 | [load_store_order_tb.sv](../../expipe/load-store-unit/load_store_order_tb.sv), [check-load-store.sh](../../../scripts/sim/check-load-store.sh) | Existing directed module regression using an independent behavioral environment. |
| S16 | [tb_bare.sv](../../tb_bare.sv), [len5_utils.svh](../../len5_utils.svh), [memory_bare_emu.sv](../../memory/memory_bare_emu.sv), [copy-logs.sh](../../../scripts/sim/copy-logs.sh) | SV console messages, instruction traces, cycle statistics and artifact links. |

Architectural facts used here are limited to four-byte base instructions,
instruction alignment without C, branch fall-through, JAL's signed PC-relative
target, and JALR target-bit handling. The base ISA has no architectural delay
slot. See the [RISC-V ratified unprivileged specification, base instruction
formats and control transfers, version 20260120](https://docs.riscv.org/reference/isa/v20260120/unpriv/rv32.html).
These architectural rules do not specify a microarchitectural fetch handshake,
redirect priority, reset value, or a signal named `early_jump_target_o`.

## DUT, configuration and connectivity

### Active and historical instances

The active module is `rtl/frontend/pc_gen.sv:16`; its active RTL instantiation is
`rtl/frontend/fetch_stage.sv:157`, named `u_pc_gen`. Its normal system hierarchy
is `tb_bare.u_datapath.u_fetch_stage.u_pc_gen`.

There is a second module with the same name in `rtl-vm/frontend-vm/pc_gen.sv`,
instantiated as `pc_gen_u` in `rtl-vm/frontend-vm/frontend.sv:100`. Its older
interface and readiness gating differ, and the instance's prediction ports do
not even match that module declaration. [rtl-vm/README.md](../../../rtl-vm/README.md)
explicitly excludes these files from the supported bare-metal core. Never
compile both variants or use the VM variant as an oracle for this task.

The only module parameter is XLEN-bit `BOOT_PC`, default `64'h0`. The active
fetch stage and datapath pass their BOOT_PC parameters down unchanged. Distinguish:

| Configuration source | Value in this tree | Effect on this DUT |
| --- | --- | --- |
| Standalone pc_gen default | `0x0000000000000000` | Actual default reset address. |
| `len5_config_pkg::BOOT_PC` | `0x180` | Separate package constant; importing the package does not override the module parameter. |
| `len5.core` Verilator option | `-GBOOT_PC=65920`, or `0x10180` | Top-level testbench override propagated through datapath/fetch_stage; confirmed by existing logs. |
| `len5_pkg::{XLEN,ALEN,ILEN}` | 64, 64, 32 bits | 64-bit byte addresses; four-byte instructions. |
| `LEN5_MULTIPLE_ISSUES` | 4 at this audit | Four-instruction, 16-byte fetch bundle; read the source on every build. |
| `LEN5_MULTIPLE_ISSUES_BITS`, `ILEN_BIT_SUFF` | 2, 2 at this audit | Derived package constants; not independent DUT parameters. |
| `LEN5_C_EN` | 0, explicitly unsupported | No variable instruction length input exists at this interface. |
| `FETCH_REQ_SPILL_SKIP`, `FETCH_ANS_SPILL_SKIP` | 1, 0 | Surrounding request path is bypassed; answer path is buffered. |

HLEN, BTB_BITS, RAS_DEPTH, and MEMIF_FIFO_DEPTH influence the environment, not
pc_gen parameters. The N-way bundle is a fetch width, not N branch
resolutions per cycle: the resolution interface is scalar (S10).

### All direct pin producers and consumers

All qualifiers and clock/reset pins are one-bit `logic`. Input address payloads
`comm_except_pc_i`, `pred_target_i`, `early_jump_base_i` and
`early_jump_offs_i`, and output addresses `pc_o` and `early_jump_target_o`,
are XLEN bits. The two remaining outputs, `valid_o` and `bu_ready_o`, are
one-bit `logic`. `bu_res_i` is the packed resolution input described in the interface section
below. All ports have one direction; there are no inouts or independently selectable
address widths. Offset signedness is a payload interpretation, not a signed
SystemVerilog port declaration.

| pc_gen pins | Direct connection in fetch_stage | Relevant upstream/downstream modules |
| --- | --- | --- |
| `clk_i`, `rst_ni` | Fetch-stage clock and reset | Datapath and tb_bare; C++ harness generates them. There is no clock enable input. |
| `comm_except_raised_i`, `comm_except_pc_i` | Same-named fetch-stage inputs | Datapath routes backend `fetch_except_*`; `commit_stage`/`commit_cu` produce them using CSR information. |
| `bu_res_valid_i`, `bu_res_i` | `bu_pcgen_valid_i`, `bu_res_i` | Backend/exec_stage route `branch_unit.fe_pcgen_valid_o` and `fe_res_o`; branch_cu sequences the request. |
| `pred_target_i`, `pred_taken_i` | `taken_pred.target`, `taken_pred.hit & taken_pred.taken` | `gen_valid_instr` selects the earliest eligible taken prediction from `bpu`; bpu contains `btb` and `gshare`. |
| `mem_ready_i` | `memif_pcgen_ready` | `fetch_mem_if.fetch_ready_o`, from its request `spill_cell_flush`; influenced by instruction-memory readiness, not a fetched-data response. |
| `early_jump_valid_i`, `early_jump_base_i`, `early_jump_offs_i` | `early_jump_valid`, `early_jump_base`, `early_jump_offs` | `early_jump_unit`, using fetched instruction/prediction from fetch_mem_if, output spill readiness, and `ras` for returns. |
| `pc_o` | `curr_pc` | Read directly by `bpu.curr_pc_i` and `gen_valid_instr.pc_i`. Through bpu prediction PCs it reaches fetch_mem_if and the memory request address. There is no separate direct pc_gen-to-memory address wire. |
| `valid_o` | `pcgen_memif_valid` | `fetch_mem_if.fetch_valid_i`, then request spill valid and `instr_valid_o`. |
| `bu_ready_o` | `bu_pcgen_ready_o` | Routed through datapath/backend to branch_unit/branch_cu and also `commit_stage.fe_ready_i`. It acknowledges control redirects, not memory requests. |
| `early_jump_target_o` | `early_jump_target` | `early_jump_unit.early_jump_target_i`; used to populate corrected prediction metadata for an older instruction. |

Other relevant connections: early_jump_unit's `mem_flush_o` flushes fetch_mem_if
and the external instruction-memory path. Datapath's misprediction/exception
flush reaches fetch_mem_if, early_jump_unit, RAS and the output spill cell;
exception flush also reaches bpu. `instr_mixer` and `spill_cell_flush` consume
the corrected instruction/prediction bundle before issue. These modules explain
the inputs but are not inside the standalone DUT.

`flush_i`, `flush_bpu_i`, `issue_ready_i`, memory response valid/data, instruction
exceptions, call/return confirmations, IRQ, sleep and fetch-enable are **not**
pc_gen pins. Do not add imaginary events or input controls for them. Model their
effects only through the actual inputs listed above. In particular, a surrounding
flush alone does not command a PC load or reset.


## Interface and approved behavior

The interface comprises `clk_i`, active-low `rst_ni`, exception qualifier/target
`comm_except_raised_i`/`comm_except_pc_i`, `bu_res_valid_i` and `bu_res_i` fields
`mispredict`, `taken`, `pc`, `target`, current prediction `pred_taken_i`/
`pred_target_i`, memory readiness `mem_ready_i`, and `early_jump_valid_i`/
`early_jump_base_i`/`early_jump_offs_i`. Observable outputs are `pc_o`, `valid_o`,
`bu_ready_o`, `early_jump_target_o`. No missing event identity, flush input,
exception output, early acknowledgment, opcode or memory-response port is invented.
The test adapter exposes static elaboration constants only in addition to these ports.

Let W=XLEN=64, S=4, N=`LEN5_MULTIPLE_ISSUES`, B=S*N. All address results are reduced
modulo 2^W. For the independent fetch cursor x:

```
sequential(x) = ((x / B) + 1) * B  modulo 2^W
T_E = comm_except_pc_i
T_R = bu_res_i.taken ? bu_res_i.target : bu_res_i.pc + S
T_J = early_jump_base_i + signed(early_jump_offs_i)
T_P = pred_target_i
```

The signed displacement is represented in two's complement at W bits, with
unsigned modular addition avoiding C++ signed overflow. Supplied target bits are
preserved exactly, including low bits and high/nonexecutable-looking addresses.
Only ordinary sequential progression aligns to the next bundle boundary. The
formula also applies after an unaligned robustness target. A partial bundle does
not advance by x+B. No producer's alignment/fault/JALR/trap computation is modeled
as pc_gen behavior.

| ID | Approved observable requirement | Evidence / residual detail |
| --- | --- | --- |
| C1 | Async active-low assertion immediately establishes BOOT_PC; dominates all events; valid=0 during reset. Release offers BOOT_PC without an invented delay. | D/Q1; control-ready during reset unspecified. |
| C2 | Without an active redirect or accepted ordinary fetch, PC holds. A stalled prediction alone cannot advance it. | D/Q3/Q8. |
| C3 | At an accepted ordinary rising edge, qualified prediction loads its exact target; otherwise use the bundle successor above. | D/Q6/Q7/Q8. |
| C4 | Commit exception loads its supplied target regardless of memory readiness and overrides R/J/P. | D/Q2/Q5/Q7; valid cancellation on control cycles remains a named I/Q5 policy. |
| C5 | Effective branch recovery is valid && mispredict; taken loads supplied target, not-taken loads the resolved instruction PC+4. R overrides J/P independent of readiness. | A/D/Q2/Q5/Q7; source acknowledgment separate. |
| C6 | Selected early correction loads supplied older base+signed displacement, independent of readiness; meaningful early-target metadata equals that sum. Active early correction suppresses ordinary fetch valid. | D/Q3/Q4/Q7; R10 request suppression approved 2026-10-28; held producer lifecycle not fully settled. |
| C7 | Inactive qualifiers make their payload irrelevant to qualified PC behavior. | D interface qualification; noncanonical branch encodings separately exercised. |
| C8 | Synchronous PC transitions occur only at consuming rising edges; falling/stopped-clock samples hold, except async reset. | D/Q1/Q8. Sideband/valid combinational checks retain their own evidence. |
| C9 | Older applicable early correction overrides the speculative current taken prediction. | D; direct JAL arithmetic is architectural context, RAS target remains a prediction corrigible by later R. |

Ordinary acceptance requires `valid_o && mem_ready_i`; the model computes its
expected acceptance from independently specified valid qualification. No new
ordinary request is accepted while J is active; previously accepted requests
retain their cancellation/drain obligations. Selected redirect acceptance denotes the PC
correction, not acknowledgment/cancellation of every offered source. Reset
suppresses ordinary acceptance. Input values are stable around consuming edges;
Verilator cannot prove physical setup/hold.

## Complete external event catalog

| Event | Public condition | Context and variations |
| --- | --- | --- |
| Z / U | Reset assertion / release | Clock-stopped async assertion, hold, active controls, release with requests. |
| F / S | mem_ready=1 / 0 | Ready, stall onset, long holds and release; no memory-response transaction is inferred. |
| E | comm_except_raised | Supplied exception/trap/interrupt/MRET-shaped target; architectural traffic needs live commit context. |
| R-T / R-N | valid && mispredict, taken / not taken | Live mature older resolution; direction or taken-target error. |
| R-C | valid && !mispredict | Correct BPU resolution does not normally reach pc_gen; standalone qualification stress. |
| R-I | !valid with arbitrary resolution fields | Poisoned fields cannot recover PC. |
| P / P-N | pred_taken / !pred_taken | Current speculative bundle, changes during stalls, qualified target at accepted edge. |
| J / J-I | early_valid / !early_valid | Older decoded JAL or saved RAS address, signed offsets, holds and consecutive corrections; inactive payload noise. |
| H / D | Rising edge / between-edge changes | Registered timing, clock-stopped pulses, combinational qualification. |

## Legal, conditional and illegal combinations

Ready/stall and R-T/R-N are mutually exclusive definitions. Effective R requires
both branch-valid and mispredict. P may accompany any correction; J/P is not a
contradiction because their instruction ages differ. Every E/R/J/P combination is
admissible standalone pin stress; its PC result is defined below. Memory
readiness never prohibits E, R or J. Concurrent control acknowledgments are not
inferred from priority. Integrated E/R/J overlaps require independently valid
instruction histories and producer cancellation; the conservative architectural
generator allows at most one of E/R/J plus P. Multi-control rows are excluded
from its coverage denominator because its abstract scheduling policy serializes
producers, not because pc_gen rejects them.

Resolutions from nonexistent/squashed/immature instructions, reuse after request
release, unstable held early payloads and misaligned architectural instructions
are environment errors in the architectural campaign. Pin characterization may
offer absent histories or unaligned targets without changing their independently
approved PC semantics: pc_gen has no identity or fault port. Illegal environmental
history must not be confused with a DUT PC failure. N outside 1/2/4/8, C-enabled
variable lengths and multiple scalar resolutions are unsupported configurations.

## Event matrix, priority and timing

Approved ordering is **reset > E > R > J > P > sequential**. The older early
correction outranks current speculation; a return prediction can still be corrected
later by execution. Distinct targets expose priority, while equal targets exercise
no-change events without claiming to distinguish priority observationally.
`H` is the independently retained cursor. Every R row crosses taken/not-taken.

| Row | E R J P | Selected event | M=0 PC after edge | M=1 PC after edge | early-target disposition |
| --- | --- | --- | --- | --- | --- |
| X0 | 0 0 0 0 | hold / sequential | H | sequential(x) | Don't-care |
| X1 | 0 0 0 1 | hold / prediction | H | T_P | Don't-care |
| X2 | 0 0 1 0 | early | T_J | T_J | Exact T_J |
| X3 | 0 0 1 1 | early | T_J | T_J | Exact T_J |
| X4 | 0 1 0 0 | recovery | T_R | T_R | Don't-care |
| X5 | 0 1 0 1 | recovery | T_R | T_R | Don't-care |
| X6 | 0 1 1 0 | recovery | T_R | T_R | Q4 consumer flush window |
| X7 | 0 1 1 1 | recovery | T_R | T_R | Q4 consumer flush window |
| X8 | 1 0 0 0 | commit | T_E | T_E | Don't-care |
| X9 | 1 0 0 1 | commit | T_E | T_E | Don't-care |
| X10 | 1 0 1 0 | commit | T_E | T_E | Don't-care, including winning commit target |
| X11 | 1 0 1 1 | commit | T_E | T_E | Don't-care, including winning commit target |
| X12 | 1 1 0 0 | commit | T_E | T_E | Don't-care |
| X13 | 1 1 0 1 | commit | T_E | T_E | Don't-care |
| X14 | 1 1 1 0 | commit | T_E | T_E | Don't-care, including winning commit target |
| X15 | 1 1 1 1 | commit | T_E | T_E | Don't-care, including winning commit target |

The 48 non-reset row/readiness/direction bins and 32 raw reset row/readiness bins
are exercised separately. Reset always selects BOOT_PC and valid=0; metadata is
unused, ready unspecified. Input changes are evaluated with clock low, then
independent pre-edge snapshots, consuming edge/model transition, settled post-edge
samples and falling samples. Async probes have no rising edge. E/R/J assertions
without a consuming edge do not redirect PC. After redirect deassertion, hold or
normal progression uses the retained target; losing deasserted requests have no
latent effect. Sustained J reloads its held target at each applicable edge; this
pin-level check does not invent a producer acknowledgment or duplicate-execution rule.

### Output qualification and profiles

Both `proposed` and `strict` enforce all approved PC rules, selected early metadata,
ordinary valid, async reset and timing. Both profiles suppress ordinary fetch
valid while J is active, as approved for R10. PC correction and target metadata
remain live; response draining and downstream acceptance are unaffected.
Proposed retains existing I/Q5 integration hypotheses: suppress ordinary valid
on E/R; sole active E or R sees ready=1. Strict leaves E/R-only control-cycle valid
and control-ready unknown. Neither
asserts idle/reset ready or acknowledgment of simultaneous losing requests. This
narrows the old always-high ready observation to its producer interface meaning;
constant RTL ready is not an independent idle/reset requirement. No profile may
reintroduce memory-gated early correction or disable its selected metadata check.
Old `--early_accept=ready|unknown` and `--early_target=arithmetic|unknown` choices
are rejected as obsolete, status 2. `level`/`relevant` remain compatibility aliases.

The early consumer is the early-jump unit/input-buffer metadata path. Branch
recovery drives backend misprediction flush into `fetch_stage.flush_i` and hence
this consumer. `issue_cu` produces a flush episode and `branch_cu` offers recovery
in MIS_LOAD_PC and can hold it in MIS_WAIT_FE. The public pc_gen boundary has no
consumer-valid or flush acknowledgment. We cannot prove the ignored-metadata
window for arbitrary held R+J requests, so X6/X7 sideband remains Q, while their
PC check is definitive. Commit-overridden metadata is explicitly unused by the
approved decision. Actual flush delivery/content remains integration scope.

## Independent verification architecture and audit policy

`ReferenceModel` consumes only Inputs and source-derived Config, retains its own
Field cursor, and uses the mathematical addresses above. It has no Verilator
handle or actual-PC parameter. `Simulator` checks public input readback, uses
independent expected cursor to build architectural history, advances the model
before observing the settled DUT edge, and never copies observations back.
Uninitialized expected state remains unknown under hold/sequential until reset or
an independently supplied absolute redirect establishes it. Residual sideband/
handshake uncertainty is tracked per field and does not poison a now-defined PC
transition. A malformed-history annotation cannot erase approved pin behavior.

`Environment` records instruction IDs, PCs, epoch, fetch/availability cycles,
prediction and actual branch results, direct signed displacement or saved return
address. It checks mature live identity, producer-appropriate payloads and held
request stability. Correct resolutions complete through the abstract BPU path.
Reset invalidates every record; recovery cancels younger records and leaves
unaffected older records live. Current offers accepted during J are recorded before
cancellation. Branch recovery waits for abstract backend resume. Latency/retention
are declared scheduling policies, not copied BPU/ROB/memory implementations.
No DUT output establishes instruction history or selects constraints.

`Scoreboard` independently checks every known field at pre/post/falling/probe/async
phases. Confirmed, provisional, injected, environment and framework errors remain
separate. Additional C9 priority exclusion requires a known **matched** pre-edge
PC; a prior divergence cannot prove a secondary priority bug. Exact known C9 PC
comparisons remain active even with unknown/unmatched prior context. Three
synthetic confidence fixtures cover unverified provisional context, verified
context and definitive exact comparison with unknown context. Sampled records,
field comparisons, transactions, cycles and mismatch counts are different metrics.
Zero meaningful comparisons yields incomplete status, never success.

## Directed verification T01–T22

| Test | Exercised behavior / requirements | Update |
| --- | --- | --- |
| T01 | Async assertion/hold/release, BOOT and first fetch; C1/C2/C8 | Definitive in both profiles. |
| T02 | Sequential from every N lane and partial bundles; C2/C3 | Configuration-derived; all active lanes. |
| T03 | Stalls of 1/2/N/long and release; C2/C3 | Retained. |
| T04 | P and P-N, qualified target and every target lane; C3/C7 | Added 13-cycle stall with changing predictions and stopped-clock final target before acceptance, Q8. |
| T05 | Older taken recovery, both M, target/direction miss; C4/C5 | Recovery timing/priority definitive. |
| T06 | Older not-taken PC+4 from every lane/final lane, then successor; C5/C3 | Bundle-independent recovery. |
| T07 | Correct/nonvalid resolution with poisoned fields; C7 | Retained standalone qualification. |
| T08 | Live commit context with both M; C4 | Approved memory-independent redirect. |
| T09 | Older JAL signed min/zero/max, both M, J>P, crossing bundle; C6/C9 | Exact PC and relevant metadata definitive. |
| T10 | RAS-shaped correction then execution correction; C6/C5 | Return prediction not an architectural target guarantee. |
| T11 | Held J across ready/stall and release; C6/C9 | Repeated PC correction checked, producer lifecycle still declared I. |
| T12 | Complete row/M/R direction matrix; C4/C5/C6/C9 | Added ordinary step after losing requests deassert, no latent correction. |
| T13 | Reset every raw row/M, release with active requests; C1/priority | Approved reset and full priority. |
| T14 | Equal/conflicting consecutive redirect types; C3–C6/C9 | Artificial consecutive R remains interface stress. |
| T15 | Same PC/boot/partial bundle/adjacent/far targets; C3–C6 | Active width only. |
| T16 | Clock-stopped pulses, falling/stable PC; C8/C7 | No setup/hold claim. |
| T17 | 32-bit/sign/wrap/negative underflow; C3/C5/C6 | Definitive XLEN modular arithmetic. |
| T18 | Reset during stall/held active events; C1/C2/epochs | Retained. |
| T19 | Target low bits 01/10/11 for E/R-T/R-N/J/P, hold then sequential; C3–C7 | Raw targets exact, added next ordinary edge; pre-fix discrepancy retained as historical evidence. |
| T20 | Each inactive/losing field poisoned independently; C7/priority | Definitive selected PC, sideband correctly qualified. |
| T21 | E/R override J with distinct metadata; C4/C5/Q4 | Commit don't-care, branch-overridden unknown; PC definitive. |
| T22 | Supplied trap/MRET/vectored-interrupt-shaped targets; C4/Q10 | Added supplied vector-shaped address; producer calculations outside scope. |

Non-bundle-aligned instruction-aligned and high-bit BOOT builds remain selectable
by BOOT_PC without editing RTL configuration. Pure model/environment/coverage
fixtures exercise all supported widths mathematically; only the user's current
N is elaborated. Runtime results for other widths must not be claimed.

## Seeded randomization and functional coverage

Generator policy **v3** preserves separate splitmix64-derived mt19937_64 event,
payload and latency streams and deterministic integer draws. It now revises
predictions during stalls and gives low-bit characterization requests exact Q7
semantics, including not-taken recovery source PCs. v2 stimulus evidence stays
historical; the same seed/configuration/policy/weights/profile has identical v3
stimulus. Architectural traffic has causal live histories and aligned addresses;
interface stress offers rare legal simultaneous controls with equal/conflicting
targets; characterization records residual outputs/absent histories/raw addresses
but still checks approved functional behavior. A confirmed invariant failure in
characterization is a DUT failure, not automatically unresolved.

Existing weighted guidance boosts under-exercised legal matrix rows without
manufacturing history. P changes while stalled do not record prediction history
until the accepted ordinary edge. All random draws, lane selection, address
categories, fetch histories and denominators use source N. Replay records N,
BOOT, policy v3, seed, contract, weights, guidance and cycles and rejects incompatible
elaboration via `--expect_issues`. No DUT value drives guidance expected state.

| Coverage | Observed category |
| --- | --- |
| V01/V02 | Event row/M/R direction and raw branch qualifier encodings. |
| V03 | Planned versus matched public selected outcomes; failing/unresolved outcomes separate. |
| V04/V14 | Reset/release combinations and supplied BOOT/alignment. |
| V05/V06 | Expected starting lane, resolved lane, matched target lane/address relation, N-aware denominators. |
| V07/V08 | Branch cause/direction, early source/signed offsets/ready/P. |
| V09/V10 | Adjacent campaign-window sequences and completed/interrupted/unfinished stall bursts. |
| V11/V12 | Qualified losing targets equal/distinct, inactive mutations, public address/boundary/wrap classes. |
| V13/V15 | Sampling phase, known-state changes, required/don't-care/unresolved fields and checked requirements. |
| V16 | Live record ages, epoch cancellation. |
| V17 | Exact **matched** supplied-target low bits by E/R-T/R-N/J/P; characterization goals for 01/10/11. |
| V18 | Actual prediction changes during adjacent stalled cycles, separate per campaign. |

Coverage matrices and exclusions are separate per campaign. Architectural rows
with multiple independent E/R/J sources, immature ages 0/1 and unreachable immediate
post-reset/flush source sequences are excluded with policy reasons. N=1 aligned
same-bundle/distinct-address bins are excluded for architectural/stress streams;
characterization may use byte addresses within the four-byte bundle. Nonexistent
lanes and empty stall-length categories are excluded. Failing outputs do not earn
matched outcome coverage. Required matrix completion is not exhaustive functional
verification, sideband consumer proof or full contract sign-off.

## Q1–Q10 decisions, residual scope and evidence

| ID | Resolved approved decision | Remaining detail / outside standalone scope | Tests and observed discrepancy |
| --- | --- | --- | --- |
| Q1 | Async reset, BOOT immediately, reset dominates, no valid reset fetch, no release delay. | bu_ready during reset remains Q. | T01/T13/T18, both profiles: no discrepancy. |
| Q2 | Reset>E>R>J>P>sequential is D. | Losing source ack Q5; integrated reachability Q9. | T12/T13/T14/T20: no redirect discrepancy. |
| Q3 | Applicable J redirects despite M=0; older base+signed displacement, higher E/R overrides. | Producer WAIT_ISSUE holds until issue/flush; no J ack exists; exact duplicate/lifetime/cancellation contract still I. Memory flushing outside scope. | T09/T10/T11/T12: no discrepancy. Historical ready-gated hypothesis rejected for current checking. |
| Q4 | Selected J metadata exact; commit-overridden, reset and idle unused values are don't-care. | R+J consumer flush window remains Q; actual flush correctness outside scope. | T09/T21 plus per-field characterization: no required metadata discrepancy. Historical always-arithmetic hypothesis superseded. |
| Q5 | Ordinary valid&&M acceptance, E/R independent of M, E outranks R; J suppresses new fetch valid (R10). | E/R-only valid qualification and sole-active ready retain established I policy; idle/reset/shared losing acknowledgments not defined. | T03/T05/T08/T12: PC checks pass; residual checks explicit per profile. |
| Q6 | B=4N, bundle-interval successor and supported 1/2/4/8 are D; source is sole selector. | Whole-core width support/scheduling is outside scope; only selected N elaborated. | T02/T04/T06 and BOOT variants; T19 checks normal alignment after raw target; historical pre-fix mismatch. |
| Q7 | Targets exact, modular arithmetic, no extra alignment/fault validation; only normal successor aligns. | Executability/fault/JALR target validation belongs producers. | T15/T17/T19: pass-through passes; pre-fix successor retained low bits; current selected DUT passes after the user's RTL correction. |
| Q8 | Stable consuming inputs, stalled P may change, final accepted P controls successor. | Physical setup/hold outside Verilator. | Strengthened T04, V18/random stalls: no discrepancy. |
| Q9 | Younger cancellation, older survival, exception precedence, no delayed losing event after deassertion. | Physical memory/frontend/backend/ROB flush cannot be verified here; abstract timing/reachability still I. | T12/T18/environment unit checks; standalone PC selection checked, no queue-content claims. |
| Q10 | Trap via mtvec, interrupt direct/vector, MRET via mepc. pc_gen forwards supplied commit address. | Producer calculations explicitly outside scope; inspect-only concerns in commit_stage not verified/fixed. | T22 synthetic supplied targets pass; not an MRET integration test. |

Active report `unresolved_questions` is Q1/Q3/Q4/Q5/Q9 **residual details**, with all
Q1–Q10 retained in `specification_status`. Resolved questions are not deleted from
the design record. Legacy alternative Q3 ready-gating and Q4 always-arithmetic
reports remain prior provisional evidence, not current confirmed RTL defects.

## Historical discrepancy and audit evidence

This record predates the user's RTL correction; it is retained as historical
evidence. The subsequent suite orchestration change does not modify RTL or the
reference-model contract.

Selected production configuration at this audit: N=4, B=16, source
`rtl/packages/len5_config_pkg.sv:37`. In T19 the supplied target `0x701` is accepted
exactly, then held. With E/R/J/P all deasserted and M=1 at cycle 6, independent C3/D
expected PC is `0x710`, actual is `0x711`. The falling sample preserves the same
mismatch (C8/D). Low bits 2 and 3 similarly persist. Fifteen target/source cases
produce 30 field mismatches, representing one underlying normal-progression
alignment defect. Read-only inspection explains that the RTL adds a multiple of
four to the existing PC, preserving low bits. This expression is evidence of the
defect and is not copied into the oracle. No production change is permitted.

The original unit, directed, seeded, replay and mutation audits remain required.
[README.md](README.md) records completed current results and artifact paths.
Validation orchestrators continue checking their own failure/replay/coverage paths
even when original DUT scenarios fail, record `framework_checks_passed_dut_failed`,
and return nonzero. They never relabel a failing original DUT as passing.

## Existing logging conventions to preserve

### Logs actually examined

Ignored build products were explicitly searched; this analysis did not rely
only on tracked test source. The workspace contains 18 ordinary simulation logs
under `build/embench/logs/sim/` and 18 checked logs under
`build/embench_debug/logs/sim/`, with 18 checked-run `logs/diff/report.json` files.
All 36 console logs were scanned for logger prefixes and failure/timeout
summaries; representative contents were inspected in full or by selected lines
from `crc32.log`, `cubic.log`, and `nettle-sha256.log`. Both
`build/normal/build.log` and `build/debug/build.log` were inspected too.

The simulation logs contain 180 `[CONFIG]`, 36 `[LOG   ]` and 36 `[OK!   ]`
messages. All 18 JSON statuses are `passed`; no C++ `[ERR!  ]`, `[WARN  ]`,
failed/unsupported differential result or archived ALU module-test log was
found in this inventory. Memory-emulator `WARNING:` messages do occur.
Consequently, failure formatting below is verified from its logger/checker
source, not falsely claimed observed in a failing archived run. Stored
file/line numbers are those of the producing build and may differ from current
source. The logs are local ignored evidence, not a portable regression dataset.

### Shared C++ logger: exact formatting and verbosity

Reuse `TbLogger` and `TB_*` macros from `polito:len5:verilator-common` (S12).
The logger's bracket timestamp is `VerilatedContext::time()`, or 0 without a
context. It is **not a cycle count**. The outer field contains `basename(file)`,
the source line number and a `>` separator. Each message ends in a newline.

| Macro/method | Prefix and color | Output stream | Gate and formatting |
| --- | --- | --- | --- |
| `TB_LOG(lvl,...)` | `[LOG   ]`, no ANSI color | stdout | `lvl <= configured level`; prefix formatted as `%-35s`, then ` [%5lu] ` and body. |
| `TB_SUCCESS(lvl,...)` | `[OK!   ]`, bold green `\033[1;32m`, reset `\033[0m` around prefix | stdout | Same level gate; colored prefix formatted as `%-46s`, then ` [%5lu] ` and body. |
| `TB_CONFIG(...)` | `[CONFIG]`, bold `\033[1m`, reset after prefix | stdout | Always printed; colored prefix `%-44s`, immediately followed by body; **no timestamp**. |
| `TB_WARN(...)` | `[WARN  ]`, bold yellow `\033[1;33m`, reset after prefix | stderr | Always printed; `%-46s [%5lu] ` and body. |
| `TB_ERR(...)` | `[ERR!  ]`, bold red `\033[1;31m`, reset after prefix | stderr | Always printed; `%-46s [%5lu] ` and body. Logging does not itself stop execution or set exit status. |
| `TB_DEBUG(...)`, `TB_INFO(...)` | Same as TB_LOG | stdout | Aliases of `LOG_DEBUG` and `LOG_HIGH`. |

The field before padding is `[PREFIX] basename:line >`; colored variants wrap
that entire prefix, not the timestamp/body. Field widths are minimum widths,
so large time/line values expand. ANSI escape bytes are included in the widths;
the existing numbers compensate for them. Preserve those exact prefix spellings,
spaces and escapes by using the shared code, not a custom lookalike logger.

Level enum values are `LOG_NONE=0`, `LOG_LOW=1`, `LOG_MEDIUM=2`, `LOG_HIGH=3`,
`LOG_FULL=4`, `LOG_DEBUG=5`. Default is medium. All names are accepted by the
string setter, with medium supplied by its fallback; invalid numeric values
also select medium. The command-line `--log_level` paths currently pass a
string: text `"3"` therefore falls back to medium rather than selecting high.
The C++ integer setter supports 0..5, but existing CLI help's `(0-3)` text
does not accurately describe the string path. The ALU-specific Make default
`LOG_NORMAL` also falls back to medium, and alu_tb.cpp later forces LOG_LOW.
These are infrastructure quirks to document, not behavior to copy into the new
harness: preserve canonical named options and honor the selected level.

At LOG_NONE, configuration/warnings/errors still print; successful messages
at LOG_LOW do not. LOG_NONE does not silence a hypothetical TB_LOG(LOG_NONE,...),
because its comparison is inclusive. Respect the logger's actual gate.

Recommended module-message assignments follow S13: LOW startup/final summary,
MEDIUM successful checked responses and notable event notices, HIGH input
requests, FULL detailed cycle snapshots, DEBUG environment/model internals.
The last two are a proposed allocation consistent with existing enum levels;
the logger itself defines no additional FULL/DEBUG semantics.

### Observed console examples and cycle reporting

These are verbatim lines from `build/embench/logs/sim/crc32.log`, with ANSI escapes
removed solely for readability:

```text
[LOG   ] len5_tb.cpp:194 >          [    0] Starting simulation...
[   62537] MEM EMU > WARNING: reading uninitialized INSTRUCTION at 0000000000012160
[   78099] TB > Program exit with code: 0x00 (SUCCESS)
[OK!   ] len5_tb.cpp:233 >          [78100] Simulation completed successfully.
```

Configuration lines in the stored file retain `\x1b[1m` / `\x1b[0m`, e.g.
`[CONFIG] len5_tb.cpp:159 >` followed by aligned `Log level set to 2`.
Redirecting stdout/stderr to a file does not disable color. FuseSoC's surrounding
lines include `INFO: Running`, `INFO: Running pre_run script prepare_dirs`,
`INFO: Running simulation` and, for ordinary runs,
`INFO: Running post_run script copy_logs`. Do not attribute these to TbLogger.

The normal C++ loop uses two context ticks per full clock cycle and increments
time by one per toggle. The differential monitor explicitly records
`Stamp{time/2,time}`. SV helpers use `$time`, typically `[%8t]`, for `MEM EMU >`,
`SERIAL MONITOR >` and `TB >`. The execution report's `total CPU cycles` comes
from mcycle and is different again. The stored CRC32 timestamp 78100 must not
be described as 78100 CPU cycles.

The new harness should keep the shared time prefix, use two ticks per cycle,
and append explicit `cycle=<n> phase=<pre|post|async>` in its body. Define
cycle n as the zero-based nth consuming rising edge since simulation start,
including reset edges; report post-reset cycle or epoch separately if useful.
That definition is a new module-test convention and must be printed, not
silently inferred from the logger timestamp or CPU statistics.

### PASS/FAIL summaries and failure diagnostics

There is no single universal repository string `PASS`/`FAIL`. Preserve the
C++ module-test format for pc_gen:

```text
TEST SUCCEEDED > errors: <errors>/<transactions>
TEST FAILED > errors: <errors>/<transactions>
```

The first is `TB_SUCCESS(LOG_LOW,...)`, the second `TB_ERR(...)` (S13).
`transactions` should mean checked cycle/sample records for this module;
count a failing record once even if several fields fail, and report separate
field-check and event counts. State that definition in configuration/report
output. Follow with counts for coverage holes and characterization; do not
report unverified fields as zero-error checks.

Other existing formats, to recognize but not conflate:

- Whole-core C++ normal completion: `Simulation completed successfully.` via
  TB_SUCCESS; timeout: `Simulation timeout expired. Exiting...` via TB_ERR.
- SV exit report: `[%8t] TB > Program exit with code: 0x%h (SUCCESS)` in green
  or `(FAILURE)` in red, surrounded by blank lines, followed by bold
  `### EXECUTION REPORT` and aligned statistics. `$finish` can occur in either
  case. Harness completion alone is not the program result.
- Directed load/store test: `PASS: load/store ordering, forwarding, delayed
  tags, queue reuse, and flush`; assertions use `$fatal(1,...)` with got/expected
  values or a missing-completion reason (S15).
- Trace comparison script: ` ## SUCCESS: Execution traces match` or
  `### ERROR: Execution traces differ`, then ` ## First 10 differences:` and
  the first 11 diff lines; artifact `trace.diff`, failing exit 1 on differences.
- Aggregate scripts use `### SUCCESS: all checks passed!`, `### SUCCESS: <suite>
  benchmark passed !`, `### ERROR: <suite> benchmark failed !`,
  `## All tests passed : <total>/<total>]`, `## Number of failed tests :
  <failed>/<total>`, and per-case ` ### FAIL : benchmark <name> with COPT=<opt>;`.
  These are wrapper summaries, not a template for per-cycle DUT messages.

ALU diagnostics use `SCB > Received response without request!`,
`Received wrong result!` and
`RSP > op: %-5s rs1: 0x%016lx | rs2: 0x%016lx --> res: 0x%016lx (expected: 0x%016lx)`.
Requests use `REQ >`; successful responses use `RSP >`. pc_gen should retain
`REQ >`, `RSP >`, `SCB >`, `-->`, `(expected: ...)`, and zero-padded 16-digit
hexadecimal addresses while substituting meaningful PC event/field names.

A pc_gen mismatch must log the requirement ID, scenario/seed/configuration,
cycle/time/phase, epoch, all event qualifiers, old model PC, winner, compared
field, actual value and expected value. Include full resolution PC/direction/
target and early base/offset in adjacent diagnostic lines, plus a bounded input
history and waveform/report path. Failures must remain visible at every level.
Use portable 64-bit formatting; do not truncate the seed or high PC bits.

The differential console summary is uncolored stderr:
`Differential verification: status <n>; <count> commits; report <path>/report.json`.
Observed checked CRC32 example:
`Differential verification: status 0; 29432 commits; report logs/diff/report.json`.
Its report uses `status` values `passed`, `failed`, `unsupported`, `incomplete`,
`reason`, integer counters, `timestamp_unit: "original FST tick"`, and
`discrepancies`. Source-defined discrepancy fields include `expected`, `actual`,
`cycle`, `event_time`, `confirmation_time`, `stage`, `field`, identity/tag fields,
`confirmed` and `squashed`. Those diagnostics are not printed as TB_ERR lines.
The optional checker returns 0/1/2/3 for those respective statuses (S14).

For the future module report, follow those status/reason/expected/actual/time
names where useful, with pc_gen fields and no fabricated commit/ROB counters.
Failures at this module's declared interface are immediately relevant; it does
not need architectural speculative-error confirmation. Return nonzero for
failures, timeout, invalid configuration and incomplete required coverage.
The ALU harness currently returns 0 even after TEST FAILED, and ordinary core
timeout does not independently change its return value. Those are existing
limitations, not requirements to preserve. Keep text conventions while making
automation receive a reliable result.

### Output-file and build conventions

| Existing artifact | Location/convention |
| --- | --- |
| C++ raw waveform | `logs/waves.fst` relative to run working directory; controlled by `--dump_waves=true|false` independently of logging. |
| Instruction text trace | `logs/sim-trace.log`; SV format `[%5t] core %3d: 0x%16h (0x%8h)`, followed by the existing commit detail/register-value line. pc_gen has no instruction/commit trace to emit in this format. |
| Ordinary core artifacts | Model under `build/normal/sim-verilator/`; copy-logs hook makes relative symlinks in `BUILD_DIR/sim-common` for waves, trace and optional VCDs. These are replaceable shared convenience links. |
| Checked application artifacts | `build/sim-common/logs/`, or `SIM_RUN_DIR/logs/`; checker in `logs/diff/`. |
| Checked benchmark artifacts | `build/<suite>_debug/run/<benchmark>/logs/`; console under `build/<suite>_debug/logs/sim/<benchmark>.log`. Each run has its own working directory. |
| Ordinary benchmark console | `build/<suite>/logs/sim/<benchmark>.log`, capturing stdout and stderr together with `> ... 2>&1`; compiler console separately under `logs/compiler/`. |
| Differential outputs | `logs/diff/report.json`; with waves: `events.bin`, `annotated.fst`, `annotated.gtkw`, `fields.json`. With waves disabled, only the report; stale waveform products are removed. |
| Build diagnostics | `build/normal/build.log`, `build/debug/build.log`; cached build helper prints `## Building RTL with Verilator...` / `## RTL build complete.`. Failure prints last 60 lines and `RTL build failed; see <path>`. Unchanged cache checks are quiet. |
| Older trace/suite checks | `build/sim-common/{sim-trace.log,spike-trace.log,trace.diff,<suite>-check.log}`. Not the new module coverage report format. |

The future module run should use isolated artifacts under
`BUILD_DIR/pc-gen/run/<case>-<seed>/logs/`, retaining `waves.fst` in that logs
directory and a console log per run. `logs/report.json` and `logs/coverage.json`
are proposed module artifacts, not existing repository schemas. Print their
paths via TB_CONFIG. Keep replay stimulus/history in that run directory and
keep build/compiler output separate. Optional convenience links may follow
copy-logs.sh, but parallel run evidence must never depend on a shared link that
another run can replace. No artifact should be written in RTL source folders.

### Existing infrastructure limitations relevant to this phase

The ALU test provides the right organizational/logger precedent, but its source
also has a malformed `req>rs2` expression, post-eval driving, an unconditional
trace dump, a forced log level and an unconditional zero exit. Do not reproduce
these mechanics. VALIDATION.md records historical `check-alu` blockage by 13
width-expansion warnings; that historical result was not rerun here.

Legacy `tb/frontend/front_end_tb.sv`, `B_Front_end_TB.sv` and `tb/cu/` files use
old frontend types, `.valid` resolution fields and obsolete/absolute includes;
they are not current pc_gen unit specifications. The separate differential
verification suite described in older validation entries has been removed,
as current README states. There is no discovered existing pc_gen module test
or module coverage framework to extend directly.

Do not use `make check` to validate this framework: it invokes the formatter
with `--inplace` and can modify RTL (S11). Use the targeted `check-pc-gen` and
`check-pc-gen-framework` commands documented beside the implementation.


## Historical approved-contract validation

See [README current audit results](README.md#historical-approved-contract-audit-results) and
[approved-contract-audit.json](../../../build/pc-gen/approved-contract-audit.json)
for exact commands, counts and reproducible evidence. Build and independent
framework checks pass; the original selected N=4 DUT fails T19 under the approved
contract. The two mixed 100-seed regressions retain the same defect (22216 field
mismatches each); architectural and stress 100-seed campaigns pass. Across these
four campaigns: 4000000 cycles and 25712444 independent field comparisons.
Required combinations and declared feature goals close in all campaigns without
crediting failing outcomes. This does not convert the original DUT failure into a
pass. All eight disposable mutations compile and are detected; original before/
after results remain identical. Partial BOOT and real-failure/FST replay checks
pass. Production source/configuration hashes remain unchanged for all 331 files.

## Complete-suite execution and result messages

`make check-pc-gen` now builds only the selected DUT once, then runs all standalone
verification groups through `suite.py`: T01–T22, independent model/environment and
framework checks, randomized framework/confidence/coverage checks, a single-seed
random run, the configured multi-seed regression, disposable mutations, and
orchestration self-tests. `make check-pc-gen-run` preserves the former directed-only
behavior and accepts SCENARIO=T01..T22. Existing focused group targets remain.

TEST_JOBS bounds parallel groups (default JOBS); JOBS bounds regression seeds and
mutation builds. All artifacts are isolated beneath a unique build/pc-gen/suite
run directory. Group output is collected into separate logs, emitted without
interleaving, and retained with command/exit/timing evidence in summary.json.
Every scheduled group finishes even when another fails. Any unexpected failure,
incomplete required coverage, missing executable or build error makes the command
nonzero; only all successful groups produce `All tests passed`.

Each directed scenario reports `Test successfully passed` after meaningful checks
with no new mismatches, or `Test failed` on a mismatch/exception/empty case. Native
module summaries keep the established LEN5 TEST SUCCEEDED/TEST FAILED format and
add the explicit completion verdict. Python case validators print the same
verdict, including expected nonzero exit status for intentional negative tests.
This changes presentation and scheduling; it does not alter reference-model
rules, event constraints, coverage denominators or mismatch classifications.

## Historical implementation evidence (superseded contracts)

The following records preserve earlier Q3/Q4 hypotheses, original audit findings,
and evidence provenance. References to provisional PC rules, policy v1/v2,
eight-instruction runs, or old selectable hypotheses describe prior phases only.
The approved contract above is authoritative; the old hypotheses are no longer
available as golden options. Earlier zero-mismatch results did not include the
new exact post-unaligned sequential checks.

## 13. Constrained-random implementation and evidence policy

The implementation now extends the existing framework; [README.md](README.md)
contains commands, exact generation policy, artifact schemas and validation results.
[pc_gen_random.cpp](pc_gen_random.cpp) implements policy `v2`, using three explicit
seed streams for event choices, payloads and environment latencies. The behavioral
reference-model transitions and confidence classifications are unchanged.

Architectural stimuli require independently fetched live mature instruction IDs.
Responses mature in order after 2..12 abstract cycles; all lanes of a bundle share
maturity. This is an I environment policy, not a reproduced memory FSM. An older
unprocessed early jump prevents younger backend events. A direct JAL already
predicted taken is not corrected by the present early producer (I, S6); target
errors can receive later branch resolution. A return's saved prediction and
execution target are generated independently and never revised from the DUT.
Correct branch resolutions update only the abstract BPU history. Branch recovery
waits 2..13 cycles for abstract backend resume, retaining S8/Q9 producer restrictions.
An older ordinary commit event may interrupt that wait, including R-to-E on
consecutive cycles; younger or unresolved control instructions cannot be bypassed.

The proposed Q9 cancellation policy still applies only when control consumption
is known. Unknown control consumption requires a reset before normal history can
resume. Unknown ordinary bundle progression may resume after an independently
supplied accepted final-lane prediction (C3); it does not discard prior live history.
No expected state is synchronized from observed outputs. An abstract N × 64 instruction
window applies fetch backpressure; unresolved controls cannot silently retire due
to age. Ordinary/completed and dead records can be discarded. The window is a
simulation resource bound, not the implementation depth of a hardware queue.

Architectural higher-control overlaps remain conditional and are exercised by the
standalone stress campaign. Architectural V01 includes X0-X5 and X8-X9 with both
readiness levels and both R directions: 20 bins. The other 28 bins are excluded
from that denominator with Q2/Q3/Q9 reasons and retained in stress's 48-bin matrix.
R-C and malformed/stale histories are not architectural events. Immediate
reset/commit/recovery-to-control transitions excluded by the conservative source
policy are recorded separately from legal pin-level transitions. Architecture
reset interruption supports one live control source and current P (16 raw rows);
stress covers all 32 rows. Unknown/checkable output counts and requirement evidence
remain explicit in each campaign. Characterization's denominators describe
observations, not approved correctness of undefined outputs.

Weights select semantic episodes, with separate prediction/readiness percentages.
Burst/hold durations, old-instruction locations, signed offsets, target boundaries,
reset pulses and overlapping requests are randomized. Equal-target and fully
distinct-source episodes are separated. Coverage guidance biases under-hit observed
combinations at bounded opportunities; architectural source availability and stable
held data remain constraints. Bias toward missing fall-through histories and equal
fall-through/prediction targets never derives payloads from DUT outputs. Disabling
guidance produces an unassisted weighted workload. The same seed/configuration/
policy gives the same sequence irrespective of parallel jobs, verbosity and waves.

V01-V16 now include campaign-specific matrix arrays, extended feature goals and
observed counters. Reports distinguish offered pins, planned contract events and
matched public outcomes; equal targets cannot prove internal selection. V12
separately records known matched arithmetic crossing 32-bit/sign/W-bit boundaries
using the relevant public input base, rather than mislabeling any cursor redirect
as an arithmetic carry. Remaining gaps and exclusions are published. Unknown
Q4 observations are stored in a separate representative characterization journal;
compact random logging never silently removes unspecified outcomes.

Regression runs reuse FuseSoC's single built model and native processes with unique
per-seed artifacts. All comparison failures retain nonzero status and provenance.
Q3 memory-ready acceptance and Q4 always-arithmetic sideband remain explicit
alternative hypotheses: discrepancies against them are provisional, not confirmed
RTL defects. Q1-Q10 remain unresolved in every report and passing any campaign
still does not provide full contract sign-off.


Validation retains zero discrepancies for proposed and conservative directed runs
and 46 independent framework checks. Three principal seeded campaigns each run
100 seeds × 10,000 cycles: guided proposed, guided conservative, and unguided
proposed; all checked comparisons pass. Proposed guidance closes the declared
20/48/48 campaign combination bins, 16 architectural single-source reset rows,
all 32 stress/characterization reset rows, and 234/350/350 extended goals.
Conservative gaps remain explicitly unknown/contract-gated. Q3/Q4 alternative
hypothesis evidence remains provisional. README links the exact reports and
comparison counts. Byte-identical successful replay, identical first injected
failure, nonzero failure/completion statuses, journal-derived coverage/causality,
normal logging, long-run resource bounds and absence of production RTL changes
were checked. These results do not resolve Q1-Q10 or provide full sign-off.


Definitive C9 relational diagnostics require a matched known pre-edge PC context.
After a prior provisional PC discrepancy, holding the real old PC can be
indistinguishable from choosing the current prediction; that cannot become a
confirmed priority failure using an unverified expected old PC. All independently
computed exact PC comparisons continue unchanged. Two synthetic scoreboard
cases verify this distinction and an actual observable priority violation.
Saved return predictions are abstract independently supplied context records;
complete call/RAS execution and integrated reachability proof remain Q9 work.


## 14. Configuration-aware implementation and independent audit

The user-selected verification range is N={1,2,4,8}; N is read only from
`rtl/packages/len5_config_pkg.sv`, never a Make/runtime width override. The current
source selects 8. Source-derived configuration and immutable package snapshots
are checked against adapter constants before constructing the model. BOOT_PC is
still the independent module elaboration parameter; the package's 0x180 does not
implicitly override it. Width, package/module/harness sources and canonical
BOOT_PC enter the build fingerprint. Unsupported values and stale/replay mismatch
are configuration errors, not DUT comparisons. See README for exact commands.

The model's mathematical successor remains `((pc/B)+1)*B`, B=4N, under the
selected bundle/modular contract. Single issue has B=4 and no partial instruction-
aligned bundle starts. R-N uses its older resolved PC+4, and J uses older base plus
signed displacement, irrespective of N. The supported verification range and
requested formula supply independent implementation guidance in this phase;
existing I/Q6 integrated scheduling provenance and conservative unknown behavior
remain visible. This does not resolve acceptance, executable address ownership,
C support, other widths, or complete processor configuration validity.

T02/T06 cover every selected lane. T04 visits each predicted target lane; T09 adds
signed crossings from the final lane; T15 uses width-derived adjacent/prior/same
bundle targets. T01 and the non-bundle-aligned BOOT_PC builds retain reset value
without rounding. No T01-T22 scenario was removed. Random bundle histories,
prediction lanes, source locations, progress, burst lengths N/N+1, resource limits,
coverage and journal reconstruction use the same source configuration. Policy v2
retains separate event/payload/latency streams, explicit replay width and all
provisional profiles.

Configuration-dependent coverage exclusions are explicit: N=1 distinct same-
bundle addresses and mature ages 2..N are impossible, as are 3..N stall lengths
when N<3; lanes >=N never exist. N=1 cannot have an instruction-aligned but
non-bundle-aligned boot. Raw pin matrices remain 20 architectural and 48 stress/
characterization direction-sensitive bins. Higher control collisions stay Q2/Q9
stress. Pure fixtures validate all four goal denominators; only the selected
N=8 DUT has execution evidence. Random-only proposed regressions close the
selected-width goals without borrowing directed coverage. Finite goal closure
is not exhaustive verification.

The independent audit found no observed-state dependency in model transitions,
no unknown-state repair, and no RTL expression mirrored as the ordinary oracle.
Two provenance omissions were corrected explicitly: prior cursor assumptions
survive sequential advancement and ready-gated early holding, and wrapping
fallthrough/ordinary arithmetic carries Q7. Expected address values, known-state
transition rules and profiles were not changed. A completed-cycle reporting
error on a pre-edge framework abort was corrected separately: completed post
observations, pre-edge offers, sampled records, checked records, field comparisons
and confirmed/provisional errors are distinct counters.
Campaign-local stall/transition histories now stop across separated campaign
windows; interrupted stalls cannot cover completed length bins or fabricate
consecutive event pairs. Post-edge known-state transitions use the independent
pre-edge state, while input/reset changes have separate settlement counters.
Synthetic gap fixtures and contiguous journal reconstruction validate this fix.

The environment's generated identities, ordered availability, correctly predicted
BPU-only resolutions, held early source/payloads, reset epochs, squashes, branch
resume and commit age restrictions were reviewed and tested. Return predictions
are independent context records; full RAS/call execution and producer reachability
remain Q9. Unknown control consumption requires independently justified reset;
unknown ordinary progression can resume from an accepted supplied prediction.
No actual PC supplies either restoration.

Known output fields are compared at pre/post/falling/probe/reset settlement. C9
continues to require a matched known pre-edge PC for a definitive priority
relation. Exact PC comparisons continue after divergence. Synthetic confidence
cases verify both definitive eligibility and exclusion of a secondary false
priority diagnosis. Coverage feedback reads exercised input combinations; observed
DUT addresses classify coverage/characterization only and never select golden
transitions or generated source PCs.

Validation: 136 pure model/environment checks; all 22 directed scenarios under
both profiles; 18 native random cases; two synthetic confidence cases; four pure
coverage configurations; three negative configuration guards; byte-identical
successful FST replay and identical first injected failure/history. Final selected-
width campaigns run 100 seeds × 10,000 cycles per proposed/conservative profile:
2,000,000 cycles, 12,265,868 comparisons, zero mismatches. Proposed goals close
234/350/350; conservative goals retain 125/147/147 gaps because unresolved
acceptance/progression/output contracts remain unknown. BOOT_PC 0x10184 and
0x8000000000000004 also pass at N=8. No other N was compiled or executed.

Eight controlled RTL-copy mutations compiled and were detected: sequential step
and partial-bundle successor (C3/T02), prediction-over-early priority (C9/T09),
stall hold (C2/T03), not-taken fallthrough (C5/T06), early older base (C6/T09),
reset value (C1/T01), fetch suppression (C4/T05). None survived. The original
post-mutation run passed; production RTL was never edited. Mutation detection
under provisional contracts is not independent approval of Q1/Q3/Q4/Q5/Q6.
README links the retained source/build/failure evidence and final reports.

Q1-Q10 remain open, with Q6's build-selection mechanism and requested verification
range now implemented but its integrated scheduling contract still provisional.
Alternative Q3 ready-gated acceptance and Q4 always-arithmetic collision sideband
retain their hypotheses and provisional evidence. J > P remains C9/D. Other
priorities, acknowledgments, repetitions, canceled producer histories and Q10
MRET target calculation were not silently promoted to confirmed requirements.
