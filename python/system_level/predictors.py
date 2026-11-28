"""Finite branch-predictor storage: BTBs, counters, GShare, TAGE, SRAM ports and write bypass.

Every structure stores a bounded number of entries indexed by hashed or partial address and history
bits, so aliasing, replacement and capacity effects appear. An ``unlimited`` size keeps the same
learning rules but indexes an exact dictionary, which removes only capacity and aliasing effects.
"""

from collections import Counter, OrderedDict
from dataclasses import dataclass
from math import inf
from random import Random

from .config import UNLIMITED, limit


def mask(bits: int) -> int:
    return (1 << bits) - 1


def fold(history: int, length: int, bits: int) -> int:
    """XOR-fold the youngest ``length`` history bits into ``bits`` bits (TAGE folded history)."""
    if bits <= 0:
        return 0
    history &= mask(length)
    folded = 0
    while history:
        folded ^= history & mask(bits)
        history >>= bits
    return folded


def index_bits(entries: int | float) -> int:
    return 0 if entries == inf else max(0, (int(entries) - 1).bit_length())


class Ports:
    """Per-cycle SRAM port budget; a single-ported array shares the read budget with writes."""

    def __init__(self, spec: dict):
        self.reads = limit(spec["read_ports"])
        self.writes = limit(spec["write_ports"])
        self.single = spec["single_port"]
        self.cycle = -1
        self.used_reads = self.used_writes = 0

    def _roll(self, cycle: int) -> None:
        if cycle != self.cycle:
            self.cycle, self.used_reads, self.used_writes = cycle, 0, 0

    def read(self, cycle: int) -> bool:
        self._roll(cycle)
        used = self.used_reads + self.used_writes if self.single else self.used_reads
        if used >= self.reads:
            return False
        self.used_reads += 1
        return True

    def write(self, cycle: int) -> bool:
        self._roll(cycle)
        used, budget = ((self.used_reads + self.used_writes, self.reads) if self.single
                        else (self.used_writes, self.writes))
        if used >= budget:
            return False
        self.used_writes += 1
        return True


class Bypass:
    """Recently written values, consulted before stale prediction-time metadata during training."""

    def __init__(self, entries: int | str):
        self.capacity = limit(entries)
        self.values: OrderedDict = OrderedDict()

    def get(self, key):
        return self.values.get(key) if self.capacity else None

    def put(self, key, value) -> None:
        if not self.capacity:
            return
        self.values.pop(key, None)
        self.values[key] = value
        if len(self.values) > self.capacity:
            self.values.popitem(last=False)

    def __len__(self) -> int:
        return len(self.values)


class Assoc:
    """Set-associative tagged storage with LRU, tree-PLRU, FIFO or random replacement."""

    def __init__(self, sets: int | str, ways: int | str, policy: str, rng: Random):
        self.unbounded = UNLIMITED in (sets, ways)
        self.sets = limit(sets)
        self.ways = 1 if self.unbounded else ways
        self.policy = policy
        self.rng = rng
        self.lines: dict[int, list] = {}
        self.state: dict[int, list | int] = {}
        self.valid = 0

    @property
    def capacity(self) -> float:
        return inf if self.unbounded else self.sets * self.ways

    def _line(self, index: int) -> list:
        line = self.lines.get(index)
        if line is None:
            line = self.lines[index] = [None] * self.ways
            self.state[index] = list(range(self.ways)) if self.policy == "lru" else 0
        return line

    def _touch(self, index: int, way: int) -> None:
        if self.policy == "lru":
            order = self.state[index]
            order.remove(way)
            order.append(way)
        elif self.policy == "plru" and self.ways > 1:
            # Tree bits point away from the most recently used half.
            bits, node, low, high = self.state[index], 1, 0, self.ways
            while high - low > 1 and node < self.ways:
                mid = (low + high) // 2
                right = way >= mid
                bits = bits | (1 << node) if not right else bits & ~(1 << node)
                node, low, high = (2 * node + right, mid if right else low, high if right else mid)
            self.state[index] = bits

    def _victim(self, index: int, line: list) -> int:
        free = next((way for way, item in enumerate(line) if item is None), None)
        if free is not None:
            return free
        if self.policy == "lru":
            return self.state[index][0]
        if self.policy == "fifo":
            way = self.state[index]
            self.state[index] = (way + 1) % self.ways
            return way
        if self.policy == "random":
            return self.rng.randrange(self.ways)
        bits, node, low, high = self.state[index], 1, 0, self.ways
        while high - low > 1 and node < self.ways:
            mid = (low + high) // 2
            right = bool(bits & (1 << node))
            node, low, high = (2 * node + right, mid if right else low, high if right else mid)
        return low

    def lookup(self, index: int, tag: int):
        line = self.lines.get(index)
        if line is None:
            return None
        for way, item in enumerate(line):
            if item is not None and item[0] == tag:
                self._touch(index, way)
                return item[1]
        return None

    def insert(self, index: int, tag: int, value) -> bool:
        """Insert or update; return True when a valid different entry was evicted."""
        line = self._line(index)
        for way, item in enumerate(line):
            if item is not None and item[0] == tag:
                line[way] = [tag, value]
                self._touch(index, way)
                return False
        way = self._victim(index, line)
        evicted = line[way] is not None
        self.valid += not evicted
        line[way] = [tag, value]
        self._touch(index, way)
        return evicted

    def remove(self, index: int, tag: int) -> None:
        line = self.lines.get(index)
        for way, item in enumerate(line or ()):
            if item is not None and item[0] == tag:
                line[way] = None
                self.valid -= 1


@dataclass(slots=True)
class BTBEntry:
    kind: str           # branch | jal | jalr | call | ret | coroutine
    target: tuple       # ("offset", value) or ("extended", index)
    counter: int
    pc: int             # Slot address, used by per-bundle entries (not a tag check)


class BTB:
    """Tagged BTB keyed by instruction slot or by fetch block, with short target offsets.

    Targets beyond the offset range use a separate direct-mapped extended-target table when one is
    configured. Partial tags and extended-target overwrites can produce wrong targets, as in hardware.
    """

    def __init__(self, spec: dict, *, sets: int | str, ways: int | str, granule: int, block_bytes: int,
                 rng: Random, extended: int | str = 0, counter_bits: int = 2):
        self.spec = spec
        self.store = Assoc(sets, ways, spec["replacement"], rng)
        self.granule = granule
        self.block_bytes = block_bytes
        self.per_bundle = spec["organization"] == "per_bundle"
        self.tag_bits = spec["tag_bits"]
        self.offset_bits = spec["offset_bits"]
        self.extended_capacity = limit(extended)
        self.extended: dict = {}
        self.counter_max = mask(counter_bits)
        self.counter_mid = 1 << (counter_bits - 1)

    def key(self, pc: int) -> tuple[int, int]:
        address = (pc - pc % self.block_bytes if self.per_bundle else pc) // self.granule
        if self.store.unbounded:
            return address, 0
        sets = int(self.store.sets)
        return address % sets, (address // sets) & mask(self.tag_bits)

    def _target(self, entry: BTBEntry) -> int | None:
        kind, value = entry.target
        if kind == "offset":
            return entry.pc + value
        return self.extended.get(value)

    def predict(self, pc: int) -> tuple[str, int | None, bool] | None:
        """Return (kind, target, taken) for the slot at ``pc`` or None on a miss."""
        entry = self.store.lookup(*self.key(pc))
        if entry is None or (self.per_bundle and entry.pc != pc):
            return None
        taken = entry.kind != "branch" or entry.counter >= self.counter_mid
        # Partial tags can alias: the stored offset is applied to the requesting slot.
        target = (pc + entry.target[1]) if entry.target[0] == "offset" else self._target(entry)
        return entry.kind, target, taken

    def encode(self, pc: int, target: int) -> tuple | None:
        offset = target - pc
        if -(1 << (self.offset_bits - 1)) <= offset // 2 < (1 << (self.offset_bits - 1)):
            return "offset", offset
        if not self.extended_capacity:
            return None
        index = pc // self.granule if self.extended_capacity == inf else (pc // self.granule) % int(self.extended_capacity)
        self.extended[index] = target
        return "extended", index

    def train(self, pc: int, kind: str, taken: bool, target: int, stats: Counter, name: str) -> None:
        set_index, tag = self.key(pc)
        entry = self.store.lookup(set_index, tag)
        if entry is not None and self.per_bundle and entry.pc != pc and not taken:
            return
        if entry is None or (self.per_bundle and entry.pc != pc):
            if not taken:
                return  # Allocation only for taken control flow, as in BOOM's BTBs.
            encoded = self.encode(pc, target)
            if encoded is None:
                stats[name + "_unstorable_targets"] += 1
                return
            counter = self.counter_mid if kind == "branch" else self.counter_max
            if self.store.insert(set_index, tag, BTBEntry(kind, encoded, counter, pc)):
                stats[name + "_replacements"] += 1
            stats[name + "_allocations"] += 1
            return
        entry.kind = kind
        if kind == "branch":
            entry.counter = min(self.counter_max, entry.counter + 1) if taken else max(0, entry.counter - 1)
        if taken:
            encoded = self.encode(pc, target)
            if encoded is not None:
                entry.target = encoded

    def delete(self, pc: int) -> None:
        self.store.remove(*self.key(pc))


class Counters:
    """Saturating counters; finite arrays alias by index, unlimited tables use exact keys."""

    def __init__(self, entries: int | str, bits: int, initial: int | None = None):
        self.unbounded = entries == UNLIMITED
        self.entries = limit(entries)
        self.max = mask(bits)
        self.mid = 1 << (bits - 1)
        self.initial = self.mid - 1 if initial is None else initial
        self.values: dict = {}

    def get(self, index) -> int:
        return self.values.get(index, self.initial)

    def set(self, index, value: int) -> None:
        self.values[index] = max(0, min(self.max, value))

    def update(self, value: int, taken: bool) -> int:
        return min(self.max, value + 1) if taken else max(0, value - 1)


class Bimodal:
    """PC-indexed direction counters read with the L1 BTB."""

    def __init__(self, spec: dict, granule: int):
        self.table = Counters(spec["entries"], spec["counter_bits"])
        self.ports = Ports(spec)
        self.granule = granule

    def index(self, pc: int):
        address = pc // self.granule
        return address if self.table.unbounded else address % int(self.table.entries)

    def predict(self, pc: int) -> tuple[bool, tuple]:
        index = self.index(pc)
        value = self.table.get(index)
        return value >= self.table.mid, (index, value)

    def train(self, meta: tuple, taken: bool) -> None:
        index, _ = meta
        self.table.set(index, self.table.update(self.table.get(index), taken))


def train_counter(table: Counters, bypass: Bypass, key, saved: int, taken: bool, stats: Counter, name: str) -> None:
    """Read-modify-write without a training read port: use bypass, else the saved prediction value."""
    current = table.get(key)
    fresh = bypass.get(key)
    if fresh is not None:
        stats[name + "_bypass_hits"] += 1
        base = fresh
    else:
        base = saved
        if saved != current:
            stats[name + "_lost_updates"] += 1
    if saved != current:
        stats[name + "_stale_metadata"] += 1
    value = table.update(base, taken)
    table.set(key, value)
    bypass.put(key, value)


class GShare:
    """Global-history XOR PC counters; history is speculative or committed (LEN5 RTL)."""

    def __init__(self, spec: dict, granule: int, block_bytes: int, fetch_width: int):
        self.spec = spec
        self.table = Counters(spec["entries"], spec["counter_bits"])
        self.ports = Ports(spec)
        self.bypass = Bypass(spec["bypass_entries"])
        self.granule = granule
        self.block_bytes = block_bytes
        self.fetch_width = fetch_width
        self.length = spec["history_length"]
        self.committed = spec["history"] == "committed"
        self.committed_history = 0
        self.bits = index_bits(self.table.entries)

    def index(self, pc: int, history: int):
        history &= mask(self.length)
        if self.table.unbounded:
            return pc, history
        if self.spec["organization"] == "per_bundle":
            rows = max(1, int(self.table.entries) // self.fetch_width)
            row_bits = index_bits(rows)
            hashed = fold(history, self.length, row_bits) if self.spec["history_compression"] == "xor_fold" else history
            row = ((pc // self.block_bytes) ^ hashed) % rows
            return row * self.fetch_width + (pc % self.block_bytes) // self.granule % self.fetch_width
        hashed = fold(history, self.length, self.bits) if self.spec["history_compression"] == "xor_fold" else history
        return ((pc // self.granule) ^ hashed) % int(self.table.entries)

    def predict(self, pc: int, history: int) -> tuple[bool, tuple]:
        if self.committed:
            history = self.committed_history
        index = self.index(pc, history)
        value = self.table.get(index)
        return value >= self.table.mid, (index, value)

    def train(self, pc: int, meta: tuple, taken: bool, stats: Counter) -> None:
        index, saved = meta
        if self.spec["train_index"] == "recompute":
            # LEN5 RTL: the write index uses the history at training time (R08 Policy A).
            index = self.index(pc, self.committed_history if self.committed else 0)
            saved = self.table.get(index)
        train_counter(self.table, self.bypass, index, saved, taken, stats, "gshare")
        if self.committed:
            self.committed_history = ((self.committed_history << 1) | taken) & mask(max(1, self.length))


@dataclass(slots=True)
class TageEntry:
    tag: int
    counter: int
    useful: int


class TAGE:
    """BOOM-inspired TAGE with folded history, provider/alternate selection and usefulness aging."""

    def __init__(self, spec: dict, granule: int, rng: Random):
        self.spec = spec
        self.tables = spec["tables"]
        self.storage: list[dict] = [{} for _ in self.tables]
        self.valid = [0] * len(self.tables)
        self.ports = Ports(spec)
        self.bypass = Bypass(spec["bypass_entries"])
        self.granule = granule
        self.rng = rng
        self.counter_max = mask(spec["counter_bits"])
        self.counter_mid = 1 << (spec["counter_bits"] - 1)
        self.useful_max = mask(spec["useful_bits"])
        self.use_alt = 8  # Four-bit USE_ALT_ON_NA counter, initially at its midpoint.
        self.updates = 0
        self.resets = 0

    def location(self, table: int, pc: int, history: int) -> tuple:
        spec = self.tables[table]
        length = spec["history_length"]
        address = pc // self.granule
        if spec["entries"] == UNLIMITED:
            return (address, history & mask(length)), 0
        bits = index_bits(spec["entries"])
        index = (address ^ (address >> bits) ^ fold(history, length, bits)) % spec["entries"]
        tag_bits = spec["tag_bits"]
        tag = (address ^ fold(history, length, tag_bits) ^ (fold(history, length, tag_bits - 1) << 1)) & mask(tag_bits)
        return index, tag

    def taken(self, counter: int) -> bool:
        return counter >= self.counter_mid

    def predict(self, pc: int, history: int, base: bool) -> tuple[bool, dict]:
        locations = [self.location(i, pc, history) for i in range(len(self.tables))]
        hits = []
        saved = []
        for i, (index, tag) in enumerate(locations):
            entry = self.storage[i].get(index)
            saved.append((entry.tag, entry.counter, entry.useful) if entry else None)
            if entry is not None and entry.tag == tag:
                hits.append(i)
        provider = hits[-1] if hits else None
        alt = hits[-2] if len(hits) > 1 else None
        alt_taken = self.taken(saved[alt][1]) if alt is not None else base
        if provider is None:
            prediction, used_alt = base, False
        else:
            counter, useful = saved[provider][1], saved[provider][2]
            provider_taken = self.taken(counter)
            weak = counter in (self.counter_mid - 1, self.counter_mid)
            used_alt = self.spec["use_alt_on_weak"] and weak and useful == 0 and self.use_alt >= 8
            prediction = alt_taken if used_alt else provider_taken
        return prediction, {"locations": locations, "saved": saved, "provider": provider, "alt": alt,
                            "alt_taken": alt_taken, "base": base, "used_alt": used_alt, "prediction": prediction}

    def _entry(self, table: int, index, saved: tuple, stats: Counter) -> TageEntry:
        """Training-time state for one entry, from bypass or saved metadata (no extra read port)."""
        current = self.storage[table].get(index)
        fresh = self.bypass.get((table, index))
        if fresh is not None:
            stats["tage_bypass_hits"] += 1
            values = fresh
        else:
            values = saved
            if current is not None and saved != (current.tag, current.counter, current.useful):
                stats["tage_lost_updates"] += 1
        if current is not None and saved != (current.tag, current.counter, current.useful):
            stats["tage_stale_metadata"] += 1
        return TageEntry(*values)

    def _write(self, table: int, index, entry: TageEntry) -> None:
        self.valid[table] += index not in self.storage[table]
        self.storage[table][index] = entry
        self.bypass.put((table, index), (entry.tag, entry.counter, entry.useful))

    def train(self, meta: dict, taken: bool, stats: Counter, histograms: dict) -> None:
        provider, alt = meta["provider"], meta["alt"]
        locations, saved = meta["locations"], meta["saved"]
        histograms["tage_provider"]["base" if provider is None else f"t{provider}"] += 1
        stats["tage_alt_used"] += meta["used_alt"]
        if provider is not None:
            index, _ = locations[provider]
            entry = self._entry(provider, index, saved[provider], stats)
            provider_taken = self.taken(entry.counter)
            weak = entry.counter in (self.counter_mid - 1, self.counter_mid)
            if weak and entry.useful == 0 and provider_taken != meta["alt_taken"]:
                self.use_alt = min(15, self.use_alt + 1) if meta["alt_taken"] == taken else max(0, self.use_alt - 1)
            if provider_taken != meta["alt_taken"]:
                entry.useful = (min(self.useful_max, entry.useful + 1) if provider_taken == taken
                                else max(0, entry.useful - 1))
            entry.counter = min(self.counter_max, entry.counter + 1) if taken else max(0, entry.counter - 1)
            self._write(provider, index, entry)
        if meta["prediction"] != taken:
            start = 0 if provider is None else provider + 1
            candidates = [i for i in range(start, len(self.tables))
                          if saved[i] is None or saved[i][2] == 0]
            if candidates:
                # Prefer the shortest free table; occasionally skip one to spread allocations.
                choice = candidates[1] if len(candidates) > 1 and self.rng.random() < .5 else candidates[0]
                index, tag = locations[choice]
                stats[f"tage_allocations:t{choice}"] += 1
                stats["tage_allocations"] += 1
                if index in self.storage[choice]:
                    stats["tage_replacements"] += 1
                counter = self.counter_mid if taken else self.counter_mid - 1
                self._write(choice, index, TageEntry(tag, counter, 0))
            elif start < len(self.tables):
                stats["tage_allocation_failures"] += 1
                for i in range(start, len(self.tables)):
                    index, _ = locations[i]
                    current = self.storage[i].get(index)
                    if current is not None and current.useful:
                        current.useful -= 1
        self.updates += 1
        period = limit(self.spec["useful_reset_period"])
        if self.updates % period == 0:
            # Alternate clearing the high and low usefulness bits, as in TAGE's graceful aging.
            bit = (self.useful_max + 1) >> 1 if self.resets % 2 == 0 else 1
            for table in self.storage:
                for entry in table.values():
                    entry.useful &= ~bit
            self.resets += 1
            stats["tage_useful_resets"] += 1

    def useful_histogram(self) -> Counter:
        return Counter(entry.useful for table in self.storage for entry in table.values())
