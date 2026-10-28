# Frontend verification model update — 2026-10-28

This update covers the four supported verification targets: PC generator,
early-jump unit with the real RAS, fetch-memory interface, and complete fetch
stage. Production RTL is unchanged by this update. R12 is excluded.

The reference models describe approved behavior using architectural addresses,
instruction decoding, abstract histories and transaction queues. They do not
read DUT registers, infer expected values from observed targets, copy RTL state
encodings, or repair expected history after a mismatch.

## Problems and their verification consequences

| Finding | Current status | Verification consequence |
| --- | --- | --- |
| R01 | Open: execution-confirmed RAS history can contain younger operations squashed by an older exception. | Keep EQ08 uncertainty/characterization. R11 does not make execution confirmation equivalent to retirement. |
| R02 | Open: generic exception flush and handler redirect occur on different cycles. | Preserve FE-T49's incomplete recovery-window classification. A supplied redirect or working MRET does not prove precise exception entry. |
| R03 | RTL previously fixed: serialized MRET issue, dedicated MEPC redirect, Moore redirect state and trap/MRET mstatus updates. | Frontend models check the externally supplied redirect, priority and cancellation. Full-core CU/CSR evidence is separate; no CSR model is invented inside the frontend oracle. |
| R04 | Open: external interrupt routing/WFI support is unfinished. | Supplied interrupt-shaped PC tests do not establish interrupt delivery. |
| R05 | RTL previously fixed: fetch access/page faults save the faulting instruction PC to MTVAL; data-address faults keep the CU-selected CSR address; exception cause comes from the held commit entry. | Continue exact PC/fault/cause transport checks. Frontend-only tests cannot prove CSR writes. |
| R06 | Native drain mode now retains reservations for canceled requests until their ordered responses return, discarding stale clean/fault responses. | Keep separate cancel and drain contracts. Never clear the model's physical obligations while testing a noncancelable memory. |
| R07 | Completion reservations gate request admission; returned results can buffer under consumer stalls; allocation and its response can coincide. | Check capacity/conservation, ordered association and zero-latency metadata/payload/fault identity. Full queues do not gain same-edge credit lookahead. Out-of-order/unsolicited responses remain invalid. |
| R08 | Approved resolution-indexed gshare training remains unchanged. | Keep the independent Policy A model and temporal training witnesses; do not substitute saved-index Policy B. |
| R09 | RTL previously fixed redundant RET correction; stale-RAS preference remains. | Correct only when a nonempty RAS disagrees with a qualified taken BTB prediction, or that prediction is absent. An accepted canonical RET still pops once. |
| R10 | RTL and PC model previously fixed held early-correction request admission. | Suppress new fetch offers while early correction is asserted; preserve target metadata, response draining, downstream acceptance and redirect priority. |
| R11 | Approved behavior; the old alternative oracle was wrong. | Apply a qualified surviving confirmation to C, then restore P from that resulting abstract history. Reject `previous` and `unknown` ordering settings. |

## R09: prediction agreement and accepted return are separate decisions

Suppose the independent predictive history is `[0x108, 0x20c]`. A canonical RET
with a BTB hit, taken=1 and target `0x20c` needs no EJU correction, no target
rewrite and no early memory flush. When the bundle is accepted, P becomes
`[0x108]`. With consumer readiness low, neither a pop nor a pending correction
is created. The next accepted RET must therefore see `0x108`.

A BTB miss, not-taken entry, or different target still requires correction to
`0x20c`. Empty RAS history does not invent a return target. JAL retains its
separately approved policy: hit-and-taken suppresses correction without requiring
decoded-target equality. Recognition remains JAL x1 and exact `0x00008067` RET.

EJ-T14 now exercises all hit/taken/equality combinations at each active lane,
including a stalled offer and subsequent returns that expose missing/extra pops.
Independent model units exercise the same contract for N=1/2/4/8; these are
mathematical fixtures, not four RTL elaborations. Two disposable RTL mutations
check that redundant correction and suppression accidentally disabling a pop are
detected.

The old FE-T25 failure was six field comparisons: request-valid, response-ready
and early memory flush, each at post-edge and falling-edge samples of cycle 174.
The old model invented a redundant RET flush, which also changed expected memory
handshakes. They were propagated consequences of one obsolete expectation.
FE-T29 now requires a matching return to preserve prediction metadata.
FE-T36 continues checking the distinct stale-RAS case and backend recovery;
suppressing redundant correction does not solve stale history.

## R11: confirmation belongs in the restored history

Given C=`[0x808]`, a surviving call confirmation with link `0x908` and recovery
on the same edge produce C'=P'=`[0x808,0x908]`. A confirmed return on the same
edge instead removes the last confirmed entry before restoration. A speculative
frontend push/pop offered on the flush edge is canceled and contributes nothing.

This is an abstract event rule, independent of RTL arrays or next-state wires.
It applies to both the default and conservative `established` model profiles.
It assumes a qualified surviving confirmation; it does not authorize confirmation
of squashed instructions or resolve EQ08 exception survival.

EJ-T20 retains the operation/confirmation/flush/readiness matrix and later return
witnesses. FE-T41 retains its explicit simultaneous interface-stress history and
joins the supported core gate. Normal backend confirmation and recovery still
occur on separate edges. Historical runs using `previous` remain historical
negative evidence; new runs reject that setting with exit 2, as they do `unknown`.
Framework validators and FE-T54 receipts now require those rejections rather than
accepting provisional comparisons or silently weakening approved expectations.

## R06/R07: distinguish logical cancellation from physical completion

The C++ memory and full-frontend suites explicitly select ordered cancel mode
with depth two. Their transaction model reserves capacity until a returned result
can leave completion storage; downstream answer storage is separate. These runs
cannot prove native-memory draining.

The native SV memory test uses the selected N and `FETCH_MEMIF_FIFO_DEPTH`
(currently N=8, depth=8, drain mode). It checks retained full-queue credits, stale
responses under issue backpressure, repeated/returning-response flush collisions,
new-epoch metadata and faults, early-flush consumption, reset and a zero-latency
allocation/response with independently generated request and response records.
The tests must preserve this scope distinction in their reports.

The existing completion scenarios are also retained and reverified: FM-T41 fills
all reserved/completed slots and checks credit recovery; FM-T42 flushes a
buffered result while a younger response returns; FM-T43 resets mixed
pending/completed work; FM-T44 repeatedly reuses the completion ring with
distinct metadata and faults. These scenarios already existed; this update does
not claim to have introduced them. The PC generator retains T01–T22 and its
approved R10 model rather than duplicating that model in the frontend harness.

FE-T47 had a stale reset trigger: it required two requests still awaiting a
physical response even after those responses had filled completion storage under
consumer backpressure. It could then stall indefinitely and report missing reset
and program-termination witnesses with zero RTL mismatches. The trigger now
counts `outstanding + completed == depth`, retaining every other precondition:
nonempty P/C histories, trained predictor state, full answer/output buffers and
pending backend control work. This fixes scenario scheduling without relaxing
reset coverage or changing the expected hardware behavior.

## Verification infrastructure fixes

With a custom BUILD_DIR, the launchers previously ignored that destination but
left the repository's default `build/` discoverable by FuseSoC. An archived
baseline checkout there could supply duplicate core names. The first audit run
compiled the old EJU model even though the manifest fingerprint described the
current files. Those initial results are excluded from current validation.

All four launchers now also mark repository `build/` with FUSESOC_IGNORE. The
rebuilt dependency manifests/exported C++ are audited for the actual current
source paths and RET rule. This is a verification discovery fix, with no RTL
change. The frontend rejects retired order options before simulator setup so the
normal invalid-configuration report is produced; the EJU validator checks its
startup rejection diagnostic directly. Model units retain uncertainty tests for
unresolved EQ08 rather than making approved EQ07 artificially unknown.

## Validation and limits

The source-selected N=8 runs finished successfully. Each regression used
100 seeds × 10,000 cycles with the required matrix enabled. All four regressions
had zero confirmed/provisional mismatches and zero environment/framework errors.

| Target | Directed validation | Regression field checks | Mutations detected |
| --- | --- | ---: | ---: |
| PC generator | 22 scenarios; all seven suite groups pass | 6,948,463 | 8/8 |
| EJU with RAS | 34 scenarios; all seven suite groups pass | 20,966,893 | 16/16 |
| Fetch-memory C++ cancel mode | 44 scenarios; all seven suite groups pass | 95,731,727 | 16/16 |
| Complete frontend | Supported core: **49 IDs / 82 cases**, all pass; full catalog retains five declared deferrals | 38,099,214 | 12/12 |

The full frontend suite exits 0 with explicit incomplete warnings only for
FE-T43/48/49/50/51. Its supported core has zero missing witnesses, mismatches,
invalid environments or framework failures. FE-T25, FE-T29, FE-T36, FE-T41 and
FE-T47 all pass. The core's 82 cases reflect the selected N=8 variants; older
configuration case counts are historical.

Native drain mode also passes at N=8/depth=8: 30 accepted requests, 23 responses,
four ordinary deliveries and one early-flush consumption. The reset case
intentionally cancels seven outstanding requests. Clean/fault association and
the same-edge allocation/response case are checked against independently
constructed records.

Pure model/environment fixtures, negative-validator exits, replay/FST equality,
coverage guards, source/cache guards and suite orchestration are included in the
corresponding gates. Mutations are built only in disposable copies under build/;
all 52 mutations are detected. They measure checker sensitivity, not production
bug counts. No production RTL changes were made to obtain passing comparisons.

Current receipts:

- [PC suite](../../build/frontend-model-sync-yvj2s2vx/verified-gates/pc-gen/suite/all-0lr3i0_b/summary.json).
- [EJU suite](../../build/frontend-model-sync-yvj2s2vx/verified-gates/early-jump/suite/all-8pj8r35j/summary.json).
- [Memory suite](../../build/frontend-model-sync-yvj2s2vx/verified-gates/fetch-mem-if/suite/all-mz1qi0ib/summary.json).
- [Frontend suite](../../build/frontend-model-sync-yvj2s2vx/verified-gates/fetch-stage/suite/all-lnyc5l0m/summary.json).
- [Frontend supported core](../../build/frontend-model-sync-yvj2s2vx/verified-gates/fetch-stage/core/ordinary-ctw9r4rb/summary.json).
- [Consolidated results](../../build/frontend-model-sync-yvj2s2vx/summary.json), [compiled source audit](../../build/frontend-model-sync-yvj2s2vx/compiled-source-audit.json), and [RTL/R12 integrity](../../build/frontend-model-sync-yvj2s2vx/integrity.json).

All **260** production RTL files retain their original SHA-256 values. The R12
section is byte-for-byte unchanged. Python/shell syntax checks and diff whitespace
checks pass. Initial runs that compiled archived cores and intermediate runs made
before the final source edits are retained in build/ for diagnosis; the receipts
above identify the final validated builds.

This is frontend verification evidence. It does not close R01, R02, R04,
stale-RAS prediction quality, unresolved producer contracts, randomized native
frontend drain-mode coverage, or full processor retirement/CSR sign-off. The
previous MRET/MTVAL integration work is documented, but was not rerun here.
R12 is not reassessed.
