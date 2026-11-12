# Reservation-station allocation queues

`rtl/common/rs_alloc_fifo.sv` implements the shared allocation queue. Instances
are inside `arith_rs` (ALU, multiplier, divider), `arith_rs_fpu`, `branch_rs`, and
the legacy `op_only_rs`. The LSU has one shared instance before its load/store
buffers: independent queues would permit memory insertion order to change and
invalidate the buffers' cross-dependency snapshots.

## Configuration

The user configuration, derived `Len5Cfg`, FuseSoC parameters, simulator argument
filter, and top-level testbench overrides expose these fields for each prefix
`ALU`, `MULT`, `DIV`, `FPU`, `BU`, and `LSU`:

| Suffix | Default | Meaning |
| --- | --- | --- |
| `USE_FIFO` | 0 | Elaborate the registered queue instead of direct allocation |
| `FIFO_DEPTH` | 4 | Queue entries; any positive depth when enabled |
| `ISSUE_WIDTH` | 1 | Allocation-channel limit, between 1 and global `ISSUE_WIDTH` |

Increasing global `ISSUE_WIDTH` does not implicitly increase these limits. Set
the desired per-unit widths explicitly. Physical execution-unit counts and
arithmetic/FPU scheduling policies are unchanged. Branch allocation accepts an
ordered prefix into its existing circular station; branch execution remains
ordered. The LSU retains its existing single-insertion restriction, even when
its configured channel limit is larger than one. Its unused input channels are
zero, and only output channel zero can transfer. Widening memory insertion
requires redesigning the load/store dependency snapshots and is outside this
change. The disconnected legacy operand-only wrapper exposes `USE_FIFO` and
`FIFO_DEPTH` module parameters and retains its single allocation channel.

## Ordering, timing and forwarding

With buffering disabled, a generate branch connects allocation directly to the
station, masks inactive channels, and forwards matching CDB operands without
registers or added cycles. Existing issue routing still ranks all eligible global
lanes before mapping them to local channels. A high-numbered global lane can
therefore occupy local channel zero.

With buffering enabled, the FIFO retains head, tail, count and valid state.
Push readiness depends only on registered count, the configured channel limit,
and flush. Neither downstream readiness nor current pops contribute capacity.
Pushes occupy distinct slots that were invalid before the edge. Output channels
select consecutive entries from the registered head; a younger channel cannot
transfer unless every older channel transfers. There is no empty fall-through.
Pointers explicitly wrap for arbitrary depths, including one. Assertions check
valid-slot allocation, valid-slot removal, occupancy against the valid bitmap,
and push/pop capacity bounds.

Every valid entry independently forwards each unresolved operand on a matching
valid CDB ROB tag. The same forwarding function runs on insertion and on outgoing
operands, so a broadcast on either transfer edge is retained. Ready operands are
never overwritten. `OPERANDS` determines the stored operand count: two for
integer arithmetic, branches and the shared LSU, three for the FPU, and one for
the legacy operand-only station. Flush suppresses transfers and has priority over
all register updates; reset and flush invalidate the entire queue.

`common_cells/fifo_v3.sv` was inspected as a reference for registered occupancy,
explicit pointer wrap, asynchronous reset and flush. It is single-push/single-pop
and cannot supply per-entry operand wakeup; no vendor source was changed or
copied. Existing priority encoders and arithmetic execution selection remain in
use.

## Verification

`make check-rs-alloc-fifo` runs an independent queue scoreboard for 80 elaborated
configurations, each for 600 cycles. It covers global widths 1/2/4/8, channel
limits one and full width, depths 1/2/3/4/7, enabled/bypassed queues, one/two/three
operands, full/stalled/draining phases, randomized simultaneous transfers,
partial acceptance, operand wakeup, both forwarding boundaries, ready operands,
reset while occupied, flush and repeated ROB tags. It compares readiness against pre-edge occupancy.
The test includes non-prefix downstream readiness and sparse input validity.

`check-multiple-exec-config.py --cases fifo-width-1,fifo-width-2,fifo-width-4,fifo-width-8`
checks full-core elaboration with different per-unit widths and enabled FIFOs.
`check-multiple-exec-integration.py --simulate --cases default,fifo-mixed`
compares the mixed integer, floating-point, branch and memory program with Spike.
`make check-branch-rs-alloc` verifies multiple branch allocations, ordered
execution and completion, operand forwarding, backpressure, flush and tag reuse
with the FIFO both enabled and disabled. The existing RS and physical
execution-unit regression scripts also include the
new module and explicitly select their original allocation widths.

Simulation and structural elaboration establish functional and combinational
connectivity evidence. No synthesis, static timing analysis or PPA measurement is
claimed.
