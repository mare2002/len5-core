"""Cycle-level LEN5 frontend: PC generation, staged branch prediction, instruction cache, memory
fetch completion FIFO, predecode/early correction, issue queue and branch training.

The structure follows rtl/frontend/fetch_stage.sv:

* ``pc_gen`` issues one aligned fetch block per cycle, steered in the same cycle by the zero-latency
  L0 prediction (RTL ``bpu``). A cycle with any redirect issues no fetch (RTL ``valid_o`` gating).
* ``fetch_mem_if`` forwards the request directly (request spill cell skipped) when the completion FIFO
  has a free reservation; ordered responses fill reserved slots; in drain mode a flushed slot stays
  reserved until its obsolete response returns and is discarded.
* The answer spill cell feeds predecode (``early_jump_unit``) after ``predecode_latency`` cycles. The
  final prediction is applied there, in fetch order, once predecode, direction and BTB data arrived.
* The mixer/output spill cell adds ``output_latency`` cycles before the whole bundle enters the issue
  queue, which the backend reads in the following cycle.

Each dynamic bundle carries the trace position it believes it follows. A redirect from any stage
kills all younger bundles. Wrong-path instructions are never matched against the trace by PC alone.
"""

from collections import deque
from dataclasses import dataclass, field, replace
from math import inf
from random import Random

from .btq import BTQ
from .config import UNIT_FOR, Distribution, distribution, limit
from .image import Image, Static
from .instruction import Instruction
from .metrics import Metrics
from .predictors import BTB, GShare, Ports, TAGE, Bimodal, mask
from .ras import RAS, Checkpoint
from .workload import Timing

STAGES = ("l0", "l1", "final")


def predictor_storage_bits(f: dict, address_bits: int = 64) -> dict:
    """Modeled predictor state bits (None when a structure is unlimited); routing and SRAM overhead excluded."""
    kind = f["predictor"]
    bits: dict[str, int | None] = {}

    def table(entries, width):
        return None if entries == "unlimited" else entries * width

    if kind != "ideal" and f["l0_btb"]["enabled"]:
        l0 = f["l0_btb"]
        slot = (f["fetch_width"] - 1).bit_length() if l0["organization"] == "per_bundle" else 0
        bits["l0_btb"] = table(l0["entries"], 1 + 3 + l0["tag_bits"] + l0["offset_bits"] + l0["counter_bits"] + slot)
    if kind in ("l1_bim", "gshare", "tage"):
        l1 = f["l1_btb"]
        entries = "unlimited" if l1["sets"] == "unlimited" else l1["sets"] * l1["ways"]
        extended = table(l1["extended_entries"], address_bits)
        btb = table(entries, 1 + 3 + 1 + l1["tag_bits"] + l1["offset_bits"])
        bits["l1_btb"] = None if btb is None or extended is None else btb + extended
        bits["bim"] = table(f["bim"]["entries"], f["bim"]["counter_bits"])
    if kind in ("gshare", "len5"):
        g = f["gshare"]
        bits["gshare"] = table(g["entries"], g["counter_bits"])
        bits["gshare_bypass"] = table(g["bypass_entries"], 32 + g["counter_bits"])
    if kind == "tage":
        t = f["tage"]
        sizes = [table(x["entries"], 1 + x["tag_bits"] + t["counter_bits"] + t["useful_bits"]) for x in t["tables"]]
        bits["tage"] = None if None in sizes else sum(sizes)
        bits["tage_bypass"] = table(t["bypass_entries"], 48 + t["counter_bits"] + t["useful_bits"])
    if f["ras"]["enabled"] and not f["ras"]["perfect"]:
        depth = f["ras"]["depth"]
        generation = 1 + (0 if depth == "unlimited" else max(1, (depth - 1).bit_length()) + 1)
        bits["ras"] = table(depth, address_bits + 1 + generation)
    bits["total"] = None if None in bits.values() else sum(bits.values())
    return bits


def memory_latency(spec: dict, rng: Random, dram: Distribution, queue: Distribution) -> tuple[str, int]:
    """Shared L1/L2/LLC/DRAM sampling for the data and instruction caches."""
    cycles = 0
    for level in ("l1", "l2", "llc"):
        cycles += spec[level]["latency"]
        if rng.random() >= spec[level]["miss_probability"]:
            break
    else:
        level = "dram"
        cycles += dram.sample(rng)
    return level, cycles + queue.sample(rng)


@dataclass(slots=True)
class Pred:
    kind: str                # branch | jal | jalr
    taken: bool
    target: int | None
    source: str = ""


@dataclass(slots=True)
class Fetched:
    """One instruction leaving the frontend, with everything needed for recovery and training."""
    static: Static
    index: int | None        # Correct-path trace index; None on the wrong path
    mispredict: bool         # Final prediction differs from the correct-path successor
    bundle: int              # Dynamic fetch-bundle sequence (coalescing key)
    taken: bool
    target: int | None
    history: int             # Speculative global history before this instruction
    ras: object              # RAS checkpoint before this instruction's own action
    action: str              # RAS action applied for this instruction
    meta: dict               # Saved predictor metadata for training
    predicted: int           # Cycle of the final prediction
    wrong: tuple | None = None   # Synthesized (instruction, timing) once a wrong-path entry is dispatched


@dataclass(slots=True)
class Bundle:
    seq: int
    pc: int
    created: int
    slots: list
    trace: int | None        # Trace position of the first slot when the bundle is on the correct path
    preds: list = field(default_factory=list)
    stage_preds: dict = field(default_factory=dict)
    hits: dict = field(default_factory=dict)
    exit: int | None = None
    next_pc: int = 0
    timers: list = field(default_factory=list)
    alive: bool = True
    arrived: bool = False
    due: int = 0
    entered: int = 0
    final_time: int = 0
    lookup: dict | None = None
    lookup_history: int = 0
    done: bool = False
    fetched: list = field(default_factory=list)
    meta: dict = field(default_factory=dict)
    ras_checkpoints: list | None = None   # Per-slot RAS state before each slot's action (pcgen access)
    ras_actions: list | None = None
    ras_reads: list | None = None


class ICache:
    """Instruction memory with ordered responses, shared by all hardware threads."""

    def __init__(self, spec: dict, seed: int, stats: Metrics):
        self.spec = spec
        self.rng = Random(f"{seed}:icache")
        self.dram = distribution(spec["dram_latency"])
        self.queue = distribution(spec["queue_delay"], minimum=0)
        self.outstanding: dict[int, deque] = {}
        self.last_due: dict[int, int] = {}
        self.count = 0
        self.cycle = -1
        self.requests = self.responses = 0
        self.stats = stats

    def roll(self, cycle: int) -> None:
        if cycle != self.cycle:
            self.cycle, self.requests, self.responses = cycle, 0, 0

    def can_request(self, cycle: int) -> str:
        self.roll(cycle)
        if self.requests >= limit(self.spec["request_width"]):
            return "icache_request_width"
        if self.count >= limit(self.spec["max_outstanding"]):
            return "icache_outstanding"
        return ""

    def request(self, bundle: Bundle, thread: int, cycle: int, stats: Metrics) -> None:
        level, latency = ("l1", self.spec["l1"]["latency"]) if self.spec["perfect"] else \
            memory_latency(self.spec, self.rng, self.dram, self.queue)
        # The memory contract returns instruction responses in request order.
        bundle.due = max(cycle + latency, self.last_due.get(thread, 0))
        self.last_due[thread] = bundle.due
        self.outstanding.setdefault(thread, deque()).append(bundle)
        self.count += 1
        self.requests += 1
        stats.histograms["icache_outcomes"][level] += 1
        stats.counts["icache_requests"] += 1
        stats.counts["icache_hits" if level == "l1" else "icache_misses"] += 1
        if bundle.trace is None:
            stats.counts["icache_wrong_path_requests"] += 1

    def deliver(self, thread: int, cycle: int, stats: Metrics) -> None:
        self.roll(cycle)
        queue = self.outstanding.get(thread)
        while queue and queue[0].due <= cycle and self.responses < limit(self.spec["response_width"]):
            bundle = queue.popleft()
            bundle.arrived = True
            self.count -= 1
            self.responses += 1
            stats.samples["icache_response_wait"].add(cycle - bundle.due)


class PredictorSet:
    """Branch prediction tables enabled by ``frontend.predictor``; shared or per thread."""

    def __init__(self, f: dict, seed: int, tag: str):
        rng = Random(f"{seed}:predictors:{tag}")
        kind = f["predictor"]
        granule, block = f["instruction_bytes"], f["fetch_width"] * f["instruction_bytes"]
        self.kind = kind
        self.ideal = kind == "ideal"
        self.len5 = kind == "len5"
        l0 = f["l0_btb"]
        self.l0 = None
        if l0["enabled"] and not self.ideal:
            sets = "unlimited" if l0["entries"] == "unlimited" else l0["entries"] // l0["ways"]
            self.l0 = BTB(l0, sets=sets, ways=l0["ways"], granule=granule, block_bytes=block, rng=rng,
                          counter_bits=l0["counter_bits"])
        multi = kind in ("l1_bim", "gshare", "tage")
        l1 = f["l1_btb"]
        self.l1 = BTB(l1, sets=l1["sets"], ways=l1["ways"], granule=granule, block_bytes=block, rng=rng,
                      extended=l1["extended_entries"]) if multi else None
        self.l1_ports = Ports(l1) if multi else None
        self.bim = Bimodal(f["bim"], granule) if multi else None
        self.gshare = GShare(f["gshare"], granule, block, f["fetch_width"]) if kind in ("gshare", "len5") else None
        self.tage = TAGE(f["tage"], granule, rng) if kind == "tage" else None
        self.direction = self.tage or (self.gshare if kind == "gshare" else None)
        spec = f["tage"] if self.tage else f["gshare"]
        self.direction_latency = spec["latency"]
        self.direction_start = spec["start"]
        self.history_length = max([f["gshare"]["history_length"] if self.gshare else 1] +
                                  [t["history_length"] for t in f["tage"]["tables"]] * bool(self.tage))

    def tables(self) -> dict:
        """Trainable arrays and their SRAM write ports (L0 is register based)."""
        result = {}
        if self.l1 is not None:
            result["l1_btb"] = self.l1_ports
            result["bim"] = self.bim.ports
        if self.gshare is not None and not self.len5:
            result["gshare"] = self.gshare.ports
        if self.tage is not None:
            result["tage"] = self.tage.ports
        return result


class Shared:
    """Core-wide frontend resources: instruction cache, shared predictors and training bandwidth."""

    def __init__(self, config: dict, seed: int, stats: Metrics):
        f = config["frontend"]
        self.icache = ICache(f["icache"], seed, stats)
        self.predictors = PredictorSet(f, seed, "shared") if f["smt_predictors"] == "shared" else None
        self.training_cycle = -1
        self.training_used = 0
        self.seed = seed


class Frontend:
    def __init__(self, config: dict, program: list[Instruction], thread_id: int, stats: Metrics,
                 shared: Shared, seed: int, elf: str | None = None):
        f = self.f = config["frontend"]
        self.config = config
        self.program = program
        self.thread_id = thread_id
        self.stats = stats
        self.shared = shared
        self.predictors = shared.predictors or PredictorSet(f, seed, f"thread{thread_id}")
        self.image = Image(program, elf)
        self.width = f["fetch_width"]
        self.block_bytes = self.width * f["instruction_bytes"]
        self.wrong_path = f["wrong_path"]
        self.fifo_depth = limit(f["memory_fifo"]["depth"])
        self.drain = f["memory_fifo"]["drain_on_flush"]
        self.stage_capacity = limit(f["pipeline"]["stage_capacity"])
        self.iq_capacity = limit(f["issue_queue"]["capacity"])
        self.enqueue_width = limit(f["issue_queue"]["enqueue_width"])
        self.pcgen_ras = f["ras"]["enabled"] and f["ras"]["access_stage"] == "pcgen"
        self.ras = RAS(f["ras"]["depth"], stats.counts) if f["ras"]["enabled"] else None
        self.invalidate = f["ras"]["recovery"]["invalidate_corrupted_entries"]
        self.btq = BTQ(f["btq"]["capacity"], stats)
        self.rng = Random(f"{seed}:wrong-path:{thread_id}")
        self.units = {name: distribution(unit["latency"], minimum=0)
                      for name, unit in config["execution"]["units"].items()}
        memory = config["memory"]
        self.dram = distribution(memory["dram_latency"])
        self.queue_delay = distribution(memory["queue_delay"], minimum=0)
        self.store_latency = distribution(memory["store_latency"])
        self.enabled_units = {name for name, unit in config["execution"]["units"].items() if unit["count"]}
        self.history = 0
        self.history_mask = mask(self.predictors.history_length)
        self.seq = 0
        self.private_addresses = 0
        self.fifo: deque[Bundle] = deque()  # Completion FIFO reservations, alive or draining
        self.recovery: tuple | None = None
        self.restart()

    # ------------------------------------------------------------------ state

    def restart(self) -> None:
        """Start, or restart for an SMT replay iteration, fetch at the first trace instruction."""
        self.pc = self.program[0].pc
        self.trace: int | None = 0
        self.bundles: list[Bundle] = []      # Alive bundles before the issue queue, oldest first
        for bundle in self.fifo:
            bundle.alive = False
        self.predecode: deque[Bundle] = deque()
        self.output: deque[Bundle] = deque()
        self.iq: deque[Fetched] = deque()
        self.redirected = -1
        self.recovered_at: int | None = None
        self.awaiting_issue: int | None = None
        # Entries released this cycle become allocatable next cycle (registered RTL pointers/valid bits).
        self.released = {"fifo": (-1, 0), "iq": (-1, 0)}

    def release(self, name: str, cycle: int, count: int = 1) -> None:
        when, freed = self.released[name]
        self.released[name] = (cycle, (freed if when == cycle else 0) + count)

    def busy(self, name: str, cycle: int, occupied: int) -> int:
        when, freed = self.released[name]
        return occupied + (freed if when == cycle else 0)

    @property
    def halted(self) -> bool:
        return self.trace is not None and self.trace >= len(self.program)

    # ------------------------------------------------------------------ backend interface

    def peek(self) -> Fetched | None:
        return self.iq[0] if self.iq else None

    def pop(self, cycle: int) -> Fetched:
        item = self.iq.popleft()
        self.release("iq", cycle)
        if item.index is not None and self.awaiting_issue is not None:
            self.stats.samples["recovery_to_first_correct_issue"].add(cycle - self.awaiting_issue)
            self.stats.histograms["recovery_to_first_correct_issue"][cycle - self.awaiting_issue] += 1
            self.awaiting_issue = None
        return item

    def wrong_path_instruction(self, item: Fetched) -> tuple[Instruction, Timing]:
        if item.wrong is None:
            item.wrong = self.synthesize(item)
        return item.wrong

    def synthesize(self, item: Fetched) -> tuple[Instruction, Timing]:
        """Instruction and timing for a wrong-path instruction (documented approximation).

        Operands come from the static encoding. Memory operations reuse the last correct-path address
        observed at the same PC, otherwise a private non-aliasing address. Execution and memory
        latencies are drawn from the configured distributions. Wrong-path control never mispredicts,
        because its actual outcome is unknown; it is squashed with the older mispredicted branch.
        """
        insn = item.static.instruction
        if UNIT_FOR[insn.kind] not in self.enabled_units:
            insn = Instruction("alu", pc=insn.pc, encoding=insn.encoding)
        address = None
        if insn.kind in ("load", "store"):
            address = self.image.addresses.get(insn.pc)
            if address is None:
                self.private_addresses += 1
                address = (1 << 62) + 64 * self.private_addresses
        insn = replace(insn, address=address, size=insn.size or (8 if address is not None else 0))
        level, cycles = "", 0
        if insn.kind == "load":
            level, cycles = memory_latency(self.config["memory"], self.rng, self.dram, self.queue_delay)
        elif insn.kind == "store":
            cycles = self.store_latency.sample(self.rng) + self.queue_delay.sample(self.rng)
        return insn, Timing(self.units[UNIT_FOR[insn.kind]].sample(self.rng), level, cycles, False, 0)

    def schedule_recovery(self, branch, cycle: int) -> None:
        """Backend misprediction detection: flush and redirect after the RTL redirect delay."""
        if self.recovery is None or branch.uid < self.recovery[0].uid:
            self.recovery = (branch, cycle + self.f["redirect_delay"], cycle)

    def apply_recovery(self, cycle: int) -> None:
        if self.recovery is None or self.recovery[1] > cycle:
            return
        branch, _, detected = self.recovery
        self.recovery = None
        item = branch.fetch
        insn = self.program[branch.index]
        actual = insn.next_pc if insn.next_pc is not None else item.static.pc + item.static.size
        taken = actual != item.static.pc + item.static.size
        for bundle in self.bundles:
            self.kill(bundle, cycle)
        self.bundles.clear()
        self.predecode.clear()
        self.output.clear()
        self.stats.counts["iq_flushed_instructions"] += len(self.iq)
        self.iq.clear()
        # Speculative history: the branch's own checkpoint plus its actual outcome.
        self.history = item.history
        if item.static.cfi == "branch":
            self.history = ((self.history << 1) | taken) & self.history_mask
        if self.ras is not None:
            self.ras.restore(item.ras, self.invalidate)
            self.ras.apply(item.action, item.static.pc + item.static.size)
        self.pc = actual
        self.trace = branch.index + 1
        self.redirected = cycle
        self.recovered_at = self.awaiting_issue = cycle
        self.stats.counts["fe_redirects:backend"] += 1
        self.stats.samples["branch_resolution_to_recovery"].add(cycle - detected)
        self.stats.histograms["fe_redirect_latency:backend"][cycle - detected] += 1

    def kill(self, bundle: Bundle, cycle: int) -> None:
        bundle.alive = False
        self.stats.counts["fe_bundles_killed"] += 1
        if not self.drain and not bundle.arrived and bundle in self.fifo:
            # Cancel mode frees the reservation; memory still returns, and discards, the response.
            self.fifo.remove(bundle)
            self.release("fifo", cycle)

    # ------------------------------------------------------------------ prediction stages

    def slots(self, pc: int) -> list[Static]:
        end = pc - pc % self.block_bytes + self.block_bytes
        result = []
        while pc < end:
            item = self.image.at(pc)
            result.append(item)
            pc += item.size
        return result

    def oracle(self, bundle: Bundle) -> list:
        preds, index = [], bundle.trace
        for item in bundle.slots:
            if index is None or index >= len(self.program):
                preds.append(None)
                continue
            actual = self.program[index].next_pc
            taken = actual is not None and actual != item.pc + item.size
            preds.append(Pred(item.cfi or "jal", True, actual, "ideal") if taken else None)
            index = None if taken else index + 1
        return preds

    def l0_stage(self, bundle: Bundle) -> list:
        p = self.predictors
        if p.ideal:
            return self.oracle(bundle)
        preds = []
        hits = bundle.hits["l0"] = []
        for item in bundle.slots:
            hit = p.l0.predict(item.pc) if p.l0 is not None else None
            hits.append(hit)
            if hit is None:
                preds.append(None)
                continue
            kind, target, taken = hit
            if p.len5:
                # RTL bpu: BTB hit qualified by the gshare counter in the PC cycle.
                taken, meta = p.gshare.predict(item.pc, 0)
                bundle.meta.setdefault(item.pc, {})["gshare"] = meta
            preds.append(Pred(kind, taken, target, "l0"))
        return preds

    def l1_stage(self, bundle: Bundle) -> list:
        p = self.predictors
        preds = [replace(pred) if pred is not None else None for pred in bundle.preds]
        hits = bundle.hits["l1"] = []
        for i, item in enumerate(bundle.slots):
            hit = p.l1.predict(item.pc)
            hits.append(hit)
            pred = preds[i]
            if hit is not None:
                kind, target, taken = hit
                # A valid early RAS target is never replaced by a later BTB response.
                keep = pred is not None and pred.source == "ras" and kind in ("ret", "coroutine")
                pred = preds[i] = Pred(kind, taken, pred.target if keep else target, "ras" if keep else "l1")
            if pred is not None and pred.kind == "branch":
                pred.taken, meta = p.bim.predict(item.pc)
                bundle.meta.setdefault(item.pc, {})["bim"] = meta
        return preds

    def choose_exit(self, bundle: Bundle, preds: list) -> tuple[int | None, int]:
        for i, pred in enumerate(preds):
            if pred is not None and pred.taken and pred.target is not None:
                return i, pred.target
        last = bundle.slots[-1]
        return None, last.pc + last.size

    def walk(self, bundle: Bundle) -> tuple[list, int | None]:
        """Trace positions and misprediction flags of the instructions the bundle delivers."""
        index, result = bundle.trace, []
        end = len(bundle.slots) if bundle.exit is None else bundle.exit + 1
        for i, item in enumerate(bundle.slots[:end]):
            if index is not None and index >= len(self.program):
                break  # End of the trace: no correct-path instruction exists past this point.
            if index is None:
                result.append((None, False))
                continue
            insn = self.program[index]
            assert insn.pc == item.pc, f"trace PC {insn.pc:#x} differs from fetched PC {item.pc:#x}"
            predicted = bundle.next_pc if i == bundle.exit else item.pc + item.size
            wrong = insn.next_pc is not None and predicted != insn.next_pc
            result.append((index, wrong))
            index = None if wrong else index + 1
        return result, index

    def early_ras(self, bundle: Bundle) -> None:
        """Early RAS access: read and update with call/return types from L0/L1 metadata."""
        if bundle.ras_checkpoints is None:
            bundle.ras_checkpoints = []
        else:
            self.ras.restore(bundle.ras_checkpoints[0], self.invalidate)
            bundle.ras_checkpoints = []
        actions, reads = [], []
        end = len(bundle.slots) if bundle.exit is None else bundle.exit + 1
        for i, item in enumerate(bundle.slots):
            bundle.ras_checkpoints.append(self.ras.checkpoint())
            pred = bundle.preds[i] if i < end else None
            action = {"call": "push", "ret": "pop", "coroutine": "pop_push"}.get(pred.kind if pred else "", "none")
            reads.append(self.ras.top() if action in ("pop", "pop_push") else None)
            actions.append(action)
            if action != "none":
                self.ras.apply(action, item.pc + item.size)
        bundle.ras_actions, bundle.ras_reads = actions, reads

    def steer(self, bundle: Bundle, preds: list, stage: str, cycle: int) -> None:
        """Adopt a stage prediction; redirect when the followed exit or target changes."""
        old = (bundle.exit, bundle.next_pc)
        bundle.preds = preds
        bundle.stage_preds[stage] = preds
        if self.pcgen_ras:
            for i, pred in enumerate(preds):
                read = bundle.ras_reads[i] if bundle.ras_reads else None
                if pred is not None and pred.kind in ("ret", "coroutine"):
                    if read is None:
                        read = self.ras.top()  # First classification as a return at this stage.
                    if read[0] is not None:
                        pred.target, pred.source = read[0], "ras"
        bundle.exit, bundle.next_pc = self.choose_exit(bundle, preds)
        if bundle.created == cycle:
            if self.pcgen_ras:
                self.early_ras(bundle)
            self.pc = bundle.next_pc
            self.trace = self.walk(bundle)[1]
        elif (bundle.exit, bundle.next_pc) != old:
            self.redirect(bundle, stage, cycle)

    def redirect(self, bundle: Bundle, source: str, cycle: int) -> None:
        for other in self.bundles:
            if other.seq > bundle.seq:
                self.kill(other, cycle)
        self.bundles = [b for b in self.bundles if b.alive]
        self.predecode = deque(b for b in self.predecode if b.alive)
        self.output = deque(b for b in self.output if b.alive)
        if self.pcgen_ras and not bundle.done:
            self.early_ras(bundle)  # Undo younger speculative RAS operations; re-apply this bundle's.
        self.pc = bundle.next_pc
        self.trace = self.walk(bundle)[1]
        self.redirected = cycle
        self.stats.counts["fe_redirects:" + source] += 1
        self.stats.samples["fe_redirect_latency:" + source].add(cycle - bundle.created)
        self.stats.histograms["fe_redirect_latency:" + source][cycle - bundle.created] += 1

    def action(self, item: Static) -> str:
        if not self.predictors.len5:
            return item.action
        # LEN5 early-jump unit: only `jal x1` pushes and only the canonical `jalr x0, 0(x1)` pops.
        if item.cfi == "jal" and item.instruction.raw_rd == 1:
            return "push"
        return "pop" if item.instruction.encoding == 0x00008067 else "none"

    def final_stage(self, bundle: Bundle) -> tuple[list, list, list]:
        """Predecode with the final direction, target and RAS information.

        Returns the slot predictions, the RAS actions and the per-slot RAS checkpoints.
        """
        p = self.predictors
        lookup = bundle.lookup or {}
        preds, actions, checkpoints = [], [], []
        index = bundle.trace
        for i, item in enumerate(bundle.slots):
            prior = bundle.preds[i] if i < len(bundle.preds) else None
            actual = self.program[index].next_pc if index is not None and index < len(self.program) else None
            if p.ideal:
                pred = self.oracle(bundle)[i]
            elif item.cfi == "branch":
                if p.len5:
                    pred = prior if prior is not None and prior.kind == "branch" else None
                else:
                    taken = lookup[item.pc][0] if item.pc in lookup else None
                    if taken is None and p.bim is not None:
                        taken = p.bim.predict(item.pc)[0]
                    if taken is None:
                        taken = prior is not None and prior.kind == "branch" and prior.taken
                    pred = Pred("branch", taken, item.target, "final")
            elif item.cfi == "jal":
                pred = Pred("jal", True, item.target, "final")
            elif item.cfi == "jalr":
                pred = self.indirect(bundle, i, item, prior, actual)
            else:
                pred = None  # Predecode removes predictions on non-control slots (aliasing).
            action = self.action(item) if item.cfi else "none"
            checkpoints.append(self.ras.checkpoint() if self.ras is not None and not self.pcgen_ras else None)
            if self.ras is not None and not self.pcgen_ras and action != "none":
                self.ras.apply(action, item.pc + item.size)
            preds.append(pred)
            actions.append(action)
            if index is not None:
                index = index + 1 if actual in (None, item.pc + item.size) else None
            if pred is not None and pred.taken and pred.target is not None:
                break
        preds.extend([None] * (len(bundle.slots) - len(preds)))
        return preds, actions, checkpoints

    def indirect(self, bundle: Bundle, i: int, item: Static, prior: Pred | None, actual: int | None) -> Pred | None:
        """Return target priority: valid RAS top > L1 BTB > L0 BTB > unresolved (fall through).

        Only BTB data that has already arrived for this bundle is used. The LEN5 preset corrects only
        canonical returns from its RAS and otherwise keeps the PC-cycle BTB prediction.
        """
        p, stats = self.predictors, self.stats.counts
        returning = self.action(item) in ("pop", "pop_push")
        on_path = actual is not None
        if p.len5:
            l1_target = None
            l0_target = prior.target if prior is not None and prior.taken else None
        else:
            l1 = bundle.hits.get("l1", [None] * len(bundle.slots))[i]
            l0 = bundle.hits.get("l0", [None] * len(bundle.slots))[i]
            l1_target = l1[1] if l1 is not None else None
            l0_target = l0[1] if l0 is not None else None
        btb = l1_target if l1_target is not None else l0_target
        if returning:
            stats["ras_returns_recognized"] += 1
            stats["ras_returns_on_path"] += on_path
        if returning and self.ras is not None:
            if self.f["ras"]["perfect"] and on_path:
                self.stats.histograms["return_target_source"]["perfect"] += 1
                return Pred("jalr", True, actual, "ras")
            top = bundle.ras_reads[i] if self.pcgen_ras and bundle.ras_reads and bundle.ras_reads[i] else self.ras.top()
            if top[0] is not None:
                if on_path:
                    stats["ras_valid_predictions"] += 1
                    stats["ras_correct_predictions"] += top[0] == actual
                    self.stats.histograms["return_target_source"]["ras"] += 1
                    if btb is not None and btb != top[0]:
                        if top[0] == actual:
                            stats["ras_override_correct"] += 1
                        elif btb == actual:
                            stats["ras_override_harmful"] += 1
                return Pred("jalr", True, top[0], "ras")
            if on_path:
                stats["ras_fallback_reason:" + top[1]] += 1
        source = "l1" if l1_target is not None else "l0" if l0_target is not None else ""
        if returning and on_path:
            self.stats.histograms["return_target_source"][source or "none"] += 1
            if source:
                stats[f"ras_fallback_{source}"] += 1
                stats[f"ras_fallback_{source}_correct"] += btb == actual
            else:
                stats["ras_no_prediction"] += 1
        if p.len5:
            return prior
        return Pred("jalr", True, btb, source) if source else None  # None: fetch continues sequentially.

    # ------------------------------------------------------------------ cycle

    def step(self, cycle: int) -> int:
        self.apply_recovery(cycle)
        delivered = self.to_issue_queue(cycle)
        self.advance_predecode(cycle)
        self.advance_fifo(cycle)
        self.timers(cycle)
        self.fetch(cycle)
        return delivered

    def to_issue_queue(self, cycle: int) -> int:
        if not self.output:
            return 0
        bundle = self.output[0]
        if bundle.entered + self.f["pipeline"]["output_latency"] > cycle:
            return 0
        count = len(bundle.fetched)
        # RTL issue_queue accepts a bundle only when every valid instruction has a free entry.
        if self.busy("iq", cycle, len(self.iq)) + count > self.iq_capacity or count > self.enqueue_width:
            self.stats.counts["fe_stall:issue_queue_full"] += 1
            self.stats.occupancy_failure("issue_queue", stall=True)
            return 0
        self.output.popleft()
        self.bundles.remove(bundle)
        self.iq.extend(bundle.fetched)
        correct = sum(item.index is not None for item in bundle.fetched)
        counts = self.stats.counts
        counts["fe_instructions_fetched"] += count
        counts["fe_correct_path_fetched"] += correct
        counts["fe_wrong_path_fetched"] += count - correct
        if correct and self.recovered_at is not None:
            self.stats.samples["recovery_to_first_correct_fetch"].add(cycle - self.recovered_at)
            self.stats.histograms["recovery_to_first_correct_fetch"][cycle - self.recovered_at] += 1
            self.recovered_at = None
        return count

    def advance_predecode(self, cycle: int) -> None:
        """Answer spill cell -> early-jump unit/mixer -> output spill cell, one bundle per cycle."""
        if not self.predecode:
            return
        bundle = self.predecode[0]
        if not bundle.done:
            if cycle < bundle.final_time:
                return
            p = self.predictors
            if p.direction is not None:
                if bundle.lookup is None:
                    self.start_lookup(bundle, cycle)
                    return
                if bundle.lookup_history != self.history:
                    if self.f["history"]["stale_policy"] == "relookup":
                        # The lookup missed older bundles' outcomes: re-read with the repaired history.
                        self.stats.counts["fe_history_repairs"] += 1
                        self.start_lookup(bundle, cycle)
                        return
                    self.stats.counts["fe_stale_history_predictions"] += 1
            self.finalize(bundle, cycle)
            if not bundle.alive:
                return
        if len(self.output) < self.stage_capacity:
            self.predecode.popleft()
            bundle.entered = cycle
            self.output.append(bundle)

    def start_lookup(self, bundle: Bundle, cycle: int) -> None:
        p = self.predictors
        if not p.direction.ports.read(cycle):
            self.stats.counts["fe_direction_read_conflicts"] += 1
            bundle.lookup = None
            bundle.final_time = max(bundle.final_time, cycle + 1)
            return
        lookup = {}
        for item in bundle.slots:
            if item.cfi != "branch":
                continue
            if p.tage is not None:
                base = p.bim.predict(item.pc)[0] if p.bim is not None else False
                taken, meta = p.tage.predict(item.pc, self.history, base)
                lookup[item.pc] = (taken, {"tage": meta})
            else:
                taken, meta = p.gshare.predict(item.pc, self.history)
                lookup[item.pc] = (taken, {"gshare": meta})
        bundle.lookup = lookup
        bundle.lookup_history = self.history
        bundle.final_time = max(bundle.final_time, cycle + p.direction_latency)

    def finalize(self, bundle: Bundle, cycle: int) -> None:
        old = (bundle.exit, bundle.next_pc)
        old_actions = bundle.ras_actions
        preds, actions, checkpoints = self.final_stage(bundle)
        bundle.stage_preds["final"] = bundle.preds = preds
        bundle.exit, bundle.next_pc = self.choose_exit(bundle, preds)
        bundle.done = True
        if self.pcgen_ras:
            end = len(bundle.slots) if bundle.exit is None else bundle.exit + 1
            actions = actions + ["none"] * (len(bundle.slots) - len(actions))
            if [a for a in actions[:end]] != [a for a in (old_actions or ["none"] * len(bundle.slots))[:end]] or \
                    (bundle.exit, bundle.next_pc) != old:
                # Early RAS updates used L0/L1 call/return metadata that predecode contradicts.
                self.ras.restore(bundle.ras_checkpoints[0], self.invalidate)
                checkpoints = []
                for i, item in enumerate(bundle.slots):
                    checkpoints.append(self.ras.checkpoint())
                    if i < end and actions[i] != "none":
                        self.ras.apply(actions[i], item.pc + item.size)
                if (bundle.exit, bundle.next_pc) == old:
                    self.stats.counts["fe_ras_repairs"] += 1
                    self.redirect(bundle, "ras_repair", cycle)
            else:
                checkpoints = bundle.ras_checkpoints
        if (bundle.exit, bundle.next_pc) != old:
            self.redirect(bundle, "final", cycle)
        self.record(bundle, actions, checkpoints, cycle)

    def record(self, bundle: Bundle, actions: list, checkpoints: list, cycle: int) -> None:
        """Final outcome of the bundle: speculative history, statistics and issue-queue records."""
        history = before = self.history
        any_branch = taken_branch = False
        walk, _ = self.walk(bundle)
        for i, (index, wrong) in enumerate(walk):
            item = bundle.slots[i]
            pred = bundle.preds[i]
            taken = i == bundle.exit
            meta = dict(bundle.meta.get(item.pc, ()))
            if bundle.lookup and item.pc in bundle.lookup:
                meta.update(bundle.lookup[item.pc][1])
            if index is not None or self.wrong_path != "bubble":
                bundle.fetched.append(Fetched(
                    item, index, wrong, bundle.seq, taken, pred.target if pred is not None else None, history,
                    checkpoints[i] if i < len(checkpoints) else None, actions[i] if i < len(actions) else "none",
                    meta, cycle))
            if item.cfi == "branch":
                any_branch, taken_branch = True, taken_branch or taken
                if self.f["history"]["update"] == "per_branch":
                    history = ((history << 1) | taken) & self.history_mask
            if index is not None and item.cfi:
                self.prediction_statistics(bundle, i, item, index)
        if self.f["history"]["update"] == "per_bundle" and any_branch:
            history = ((before << 1) | taken_branch) & self.history_mask
        self.history = history
        self.stats.counts["fe_bundles_finalized"] += 1

    def prediction_statistics(self, bundle: Bundle, i: int, item: Static, index: int) -> None:
        """Per-stage accuracy for correct-path control instructions, counted once at the final stage."""
        actual = self.program[index].next_pc
        if actual is None:
            return
        counts = self.stats.counts
        taken = actual != item.pc + item.size
        kind = ("cond" if item.cfi == "branch" else "return" if self.action(item) in ("pop", "pop_push")
                else "indirect" if item.cfi == "jalr" else "direct")
        counts[f"bp_{kind}_instructions"] += 1
        for stage in ("l0", "l1"):
            if stage in bundle.hits:
                counts[f"bp_{stage}_{'hits' if bundle.hits[stage][i] is not None else 'misses'}"] += 1
        previous = None
        for stage in STAGES:
            if stage not in bundle.stage_preds:
                continue
            pred = bundle.stage_preds[stage][i]
            predicted_taken = pred is not None and pred.taken and pred.target is not None
            correct = (pred.target if predicted_taken else item.pc + item.size) == actual
            counts[f"bp_{stage}_predictions"] += 1
            counts[f"bp_{stage}_correct"] += correct
            if kind == "cond":
                counts[f"bp_{stage}_conditional"] += 1
                counts[f"bp_{stage}_direction_correct"] += predicted_taken == taken
            elif taken:
                counts[f"bp_{stage}_target_predictions"] += 1
                counts[f"bp_{stage}_target_correct"] += correct
            if previous is not None and previous != correct:
                counts[f"bp_override_{'useful' if correct else 'harmful'}:{stage}"] += 1
            previous = correct

    def timers(self, cycle: int) -> None:
        for bundle in list(self.bundles):
            if not bundle.alive or bundle.done:
                continue
            for timer in sorted(bundle.timers):
                due, stage = timer
                if due > cycle:
                    continue
                bundle.timers.remove(timer)
                if stage == "l1" and not self.predictors.l1_ports.read(cycle):
                    bundle.timers.append((cycle + 1, stage))
                    self.stats.counts["fe_l1_read_conflicts"] += 1
                    continue
                preds = self.l1_stage(bundle) if stage == "l1" else self.l0_stage(bundle)
                self.steer(bundle, preds, stage, cycle)
                if not bundle.alive:
                    return

    def advance_fifo(self, cycle: int) -> None:
        self.shared.icache.deliver(self.thread_id, cycle, self.stats)
        while self.fifo and self.fifo[0].arrived:
            bundle = self.fifo[0]
            if not bundle.alive:
                self.fifo.popleft()  # Obsolete response discarded at the head (drain mode).
                self.release("fifo", cycle)
                self.stats.counts["fetch_fifo_discarded_responses"] += 1
                continue
            if len(self.predecode) >= self.stage_capacity:
                return
            self.fifo.popleft()
            self.release("fifo", cycle)
            bundle.entered = cycle
            self.predecode.append(bundle)
            p = self.predictors
            bundle.final_time = cycle + self.f["pipeline"]["predecode_latency"]
            if p.l1 is not None:
                bundle.final_time = max(bundle.final_time, bundle.created + self.f["l1_btb"]["latency"])
            if p.direction is not None and p.direction_start == "response":
                self.start_lookup(bundle, cycle)
            return  # One bundle per cycle enters the answer spill cell.

    def fetch(self, cycle: int) -> None:
        counts = self.stats.counts
        if self.redirected == cycle:
            counts["fe_stall:redirect"] += 1
            return
        if self.halted:
            counts["fe_stall:end_of_trace"] += 1
            return
        if self.trace is None and self.wrong_path == "bubble":
            counts["fe_stall:wrong_path_bubble"] += 1
            return
        if self.busy("fifo", cycle, len(self.fifo)) >= self.fifo_depth:
            counts["fe_stall:fetch_fifo_full"] += 1
            self.stats.occupancy_failure("fetch_fifo", stall=True)
            return
        if reason := self.shared.icache.can_request(cycle):
            counts["fe_stall:" + reason] += 1
            return
        self.seq += 1
        bundle = Bundle(self.seq, self.pc, cycle, self.slots(self.pc), self.trace)
        p = self.predictors
        if p.ideal or (p.l0 is not None and self.f["l0_btb"]["latency"] == 0):
            self.steer(bundle, self.l0_stage(bundle), "l0", cycle)
        else:
            if p.l0 is not None:
                bundle.timers.append((cycle + self.f["l0_btb"]["latency"], "l0"))
            self.steer(bundle, [None] * len(bundle.slots), "fallthrough", cycle)
            del bundle.stage_preds["fallthrough"]
        if p.l1 is not None:
            bundle.timers.append((cycle + self.f["l1_btb"]["latency"], "l1"))
        if p.direction is not None and p.direction_start == "pc":
            self.start_lookup(bundle, cycle)
        self.bundles.append(bundle)
        self.fifo.append(bundle)
        self.shared.icache.request(bundle, self.thread_id, cycle, self.stats)
        counts["fe_bundles_fetched"] += 1
        counts["fe_wrong_path_bundles"] += bundle.trace is None

    # ------------------------------------------------------------------ training

    def train(self, cycle: int) -> None:
        """Train from the BTQ head, in order, only after irrevocable commitment of the head."""
        shared, stats = self.shared, self.stats
        if shared.training_cycle != cycle:
            shared.training_cycle, shared.training_used = cycle, 0
        if self.btq.entries and not self.btq.entries[0].safe and self.btq.confirmed_waiting:
            stats.counts["btq_head_of_line_blocking_cycles"] += 1
        budget = limit(self.f["btq"]["training_width"])
        tables = self.predictors.tables()
        written: dict[str, int] = {}
        while self.btq.entries and shared.training_used < budget and self.btq.entries[0].safe:
            fetched = self.btq.entries[0].fetched
            needed = [name for name in (("l1_btb", "bim", "gshare", "tage") if fetched.static.cfi == "branch"
                                        else ("l1_btb",)) if name in tables]
            granted = []
            for name in needed:
                if self.f["btq"]["coalesce"] and written.get(name) == fetched.bundle:
                    continue  # Masked write into a row already granted to this fetch bundle.
                if not tables[name].write(cycle):
                    stats.counts["btq_sram_conflicts"] += 1
                    stats.counts["btq_sram_conflicts:" + name] += 1
                    return
                granted.append(name)
            written.update(dict.fromkeys(granted, fetched.bundle))
            shared.training_used += 1
            self.apply_training(self.btq.pop(), cycle)

    def apply_training(self, entry, cycle: int) -> None:
        fetched = entry.fetched
        item = fetched.static
        insn = self.program[entry.index]
        actual = insn.next_pc if insn.next_pc is not None else item.pc + item.size
        taken = actual != item.pc + item.size
        action = self.action(item)
        kind = {"push": "call", "pop": "ret", "pop_push": "coroutine"}.get(action, item.cfi)
        p, counts = self.predictors, self.stats.counts
        # BTBs learn actual return targets too: they are the fallback when the RAS entry is invalid.
        if p.l0 is not None:
            if p.len5 and fetched.mispredict and not taken:
                p.l0.delete(item.pc)  # RTL btb del_entry on a not-taken misprediction
            else:
                p.l0.train(item.pc, kind, taken, actual, counts, "l0_btb")
        if p.l1 is not None:
            p.l1.train(item.pc, kind, taken, actual, counts, "l1_btb")
        if item.cfi == "branch" or p.len5:
            if p.bim is not None:
                p.bim.train((p.bim.index(item.pc), 0), taken)
            if p.gshare is not None:
                meta = fetched.meta.get("gshare")
                if meta is None:
                    index = p.gshare.index(item.pc, p.gshare.committed_history if p.gshare.committed else fetched.history)
                    meta = index, p.gshare.table.get(index)
                p.gshare.train(item.pc, meta, taken, counts)
            if p.tage is not None and "tage" in fetched.meta:
                p.tage.train(fetched.meta["tage"], taken, counts, self.stats.histograms)
        counts["btq_trained"] += 1
        self.stats.samples["btq_prediction_to_training"].add(cycle - fetched.predicted)
        self.stats.samples["btq_confirmation_to_training"].add(cycle - entry.confirmed)
        self.stats.samples["btq_residence"].add(cycle - entry.allocated)

    # ------------------------------------------------------------------ statistics

    def observe(self, cycles: int = 1) -> None:
        stats = self.stats
        stats.samples["fetch_fifo_occupancy"].add(len(self.fifo), cycles)
        stats.samples["issue_queue_occupancy"].add(len(self.iq), cycles)
        stats.occupy("fetch_fifo", len(self.fifo), self.fifo_depth, cycles)
        stats.occupy("icache_outstanding", len(self.shared.icache.outstanding.get(self.thread_id, ())),
                     limit(self.f["icache"]["max_outstanding"]), cycles)
        stats.occupy("issue_queue", len(self.iq), self.iq_capacity, cycles)
        stats.occupy("predecode_stage", len(self.predecode), self.stage_capacity, cycles)
        stats.occupy("output_stage", len(self.output), self.stage_capacity, cycles)
        stats.occupy("btq", len(self.btq.entries), self.btq.capacity, cycles)
        stats.occupy("btq_confirmed", self.btq.confirmed_waiting, self.btq.capacity, cycles)
        if self.ras is not None:
            stats.occupy("ras_logical_depth", self.ras.logical, None, cycles)
            stats.occupy("ras_valid_entries", self.ras.physically_valid(),
                         None if self.ras.unbounded else self.ras.depth, cycles)
        p = self.predictors
        if p.tage is not None:
            stats.occupy("tage_bypass", len(p.tage.bypass), p.tage.bypass.capacity, cycles)
        elif p.gshare is not None and not p.len5:
            stats.occupy("gshare_bypass", len(p.gshare.bypass), p.gshare.bypass.capacity, cycles)

    def finish(self) -> None:
        p = self.predictors
        if p.tage is not None:
            self.stats.histograms["tage_useful"].update({str(k): v for k, v in p.tage.useful_histogram().items()})
            for i, (spec, valid) in enumerate(zip(p.tage.tables, p.tage.valid)):
                self.stats.counts[f"tage_valid_entries:t{i}"] = valid
                if spec["entries"] != "unlimited":
                    self.stats.counts[f"tage_capacity:t{i}"] = spec["entries"]
