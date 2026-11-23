"""Basic-block maps, adjacent merging, and bandwidth-limited selective recovery."""

from collections import Counter
from dataclasses import dataclass, field
from heapq import heappop, heappush

from .instruction import Instruction, Register
from .memory import Memory, overlaps
from .metrics import Metrics
from .state import Entry

Physical = tuple[str, int]


class Registers:
    def __init__(self, config: dict, *, unbounded: bool = False):
        self.unbounded = unbounded
        self.capacity = ({"x": 31, "f": 32} if unbounded else
                         {"x": config["integer_physical"], "f": config["fp_physical"]})
        self.free = {"x": list(range(31, self.capacity["x"])),
                     "f": list(range(32, self.capacity["f"]))}
        self.architectural = {**{("x", i): ("x", i - 1) for i in range(1, 32)},
                              **{("f", i): ("f", i) for i in range(32)}}
        self.refs: Counter[Physical] = Counter(self.architectural.values())
        self.values = dict.fromkeys(self.refs, 0)
        self.freed = 0

    def occupancy(self, bank: str) -> int:
        return self.capacity[bank] - len(self.free[bank])

    def allocate(self, bank: str) -> Physical:
        if self.free[bank]:
            index = heappop(self.free[bank])
        else:
            assert self.unbounded
            index = self.capacity[bank]
            self.capacity[bank] += 1
        physical = bank, index
        assert physical not in self.refs
        self.refs[physical] = 1
        self.values[physical] = 0
        return physical

    def release(self, physical: Physical) -> None:
        assert self.refs[physical] > 0
        self.refs[physical] -= 1
        if not self.refs[physical]:
            del self.refs[physical], self.values[physical]
            heappush(self.free[physical[0]], physical[1])
            self.freed += 1

    def write(self, physical: Physical, uid: int) -> None:
        # Older broadcasts still wake their own readers but cannot overwrite a newer version.
        self.values[physical] = max(self.values[physical], uid)

    def publish(self, mapping: dict[Register, Physical]) -> None:
        for reg, physical in mapping.items():
            self.release(self.architectural[reg])
            self.architectural[reg] = physical


@dataclass
class Span:
    start: int
    count: int = 0
    retired: int = 0
    store_count: int = 0
    sealed: bool = False
    branch: Entry | None = None
    mapping: dict[Register, Physical] = field(default_factory=dict)
    ownership: dict[str, int] = field(default_factory=lambda: {"x": 0, "f": 0})
    stores: list[Entry] = field(default_factory=list)
    discarded_destinations: list[Physical] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return self.sealed and self.retired == self.count

    def map_register(self, reg: Register, physical: Physical) -> None:
        bank, index = physical
        if reg in self.mapping:
            self.ownership[bank] &= ~(1 << self.mapping[reg][1])
        self.mapping[reg] = physical
        self.ownership[bank] |= 1 << index


@dataclass
class Group:
    age: int
    spans: list[Span]
    complete_since: int | None = None
    recovering: bool = False
    slot: int = -1
    thread_id: int = 0

    @property
    def complete(self) -> bool:
        return all(span.complete for span in self.spans)

    @property
    def ownership(self) -> dict[str, int]:
        bits = {"x": 0, "f": 0}
        for span in self.spans:
            for bank in bits:
                bits[bank] |= span.ownership[bank]
        return bits


@dataclass
class Recovery:
    cycle: int
    pending: int = 0


@dataclass
class Reclaim:
    group: Group
    spans: list[Span] = field(default_factory=list)
    release_slot: bool = False
    recoveries: list[Recovery] = field(default_factory=list)


class Blocks:
    def __init__(self, config: dict, memory: Memory, stats: Metrics,
                 pool: list[Group | None] | None = None, thread_id: int = 0, *, unbounded: bool = False):
        self.config = config
        self.stats = stats
        self.pool = pool
        self.unbounded = unbounded
        self.thread_id = thread_id
        self.memory = memory
        self.prf = Registers(config["registers"], unbounded=unbounded)
        self.groups: list[Group] = []
        self.reclaim: dict[int, Reclaim] = {}
        self.owners: dict[int, Span] = {}
        self.reserved = 0
        self.age = 0

    @property
    def open_span(self) -> Span | None:
        if self.groups and not self.groups[-1].spans[-1].sealed:
            return self.groups[-1].spans[-1]
        return None

    def seal(self) -> None:
        if (span := self.open_span) is not None:
            span.sealed = True

    def can_allocate(self, instruction: Instruction) -> str:
        span = self.open_span
        kind, dest = instruction.kind, instruction.destination
        if span is not None and (
            (kind == "store" and span.store_count >= self.config["max_stores_per_new_block"])
            # A load that waits for a store's memory response cannot complete in the same block.
            or (kind == "load" and any(overlaps(store.instruction, instruction) for store in span.stores))
        ):
            span.sealed = True
            span = None
        if span is None and not self.unbounded and (None not in self.pool if self.pool is not None
                             else self.reserved >= self.config["max_active_blocks"]):
            return "block_capacity"
        if (not self.prf.unbounded and dest is not None and (span is None or dest not in span.mapping)
                and not self.prf.free[dest[0]]):
            # Closing a partially filled block lets its results replace the architectural map.
            if span is not None:
                span.sealed = True
                self.stats.counts["register_pressure_block_splits"] += 1
            return "integer_prf" if dest[0] == "x" else "fp_prf"
        return ""

    def insert(self, entry: Entry, cycle: int) -> None:
        span = self.open_span
        if span is None:
            span = Span(entry.index)
            group = Group(self.age, [span], thread_id=self.thread_id)
            if self.pool is not None:
                if self.unbounded and None not in self.pool:
                    self.pool.append(None)
                group.slot = self.pool.index(None)
                self.pool[group.slot] = group
            self.groups.append(group)
            self.reserved += 1
            self.age += 1
            self.stats.counts["blocks_created"] += 1
        span.count += 1
        self.owners[entry.uid] = span
        dest = entry.instruction.destination
        if dest is not None:
            if dest not in span.mapping:
                span.map_register(dest, self.prf.allocate(dest[0]))
                self.stats.counts["physical_allocations"] += 1
            else:
                self.stats.counts["physical_destination_reuses"] += 1
            entry.physical = span.mapping[dest]
            self.prf.refs[entry.physical] += 1
        if entry.kind == "store":
            span.stores.append(entry)
            span.store_count += 1
        limit = self.config["max_instructions"]
        if entry.instruction.control:
            span.branch = entry
        if entry.instruction.control or (limit is not None and span.count == limit):
            span.sealed = True
        group = self.groups[-1]
        slot = {"block_slot": group.slot} if self.pool is not None else {}
        self.stats.event(cycle, "block_dispatch", index=entry.index, block=group.age,
                         physical=entry.physical[1] if entry.physical is not None else -1, **slot)

    def release_group(self, group: Group) -> None:
        self.reserved -= 1
        if self.pool is not None:
            assert self.pool[group.slot] is group
            self.pool[group.slot] = None

    def reset_registers(self) -> None:
        freed = self.prf.freed
        self.prf = Registers(self.config["registers"], unbounded=self.unbounded)
        self.prf.freed = freed

    def discard_speculation(self) -> None:
        self.groups.clear()
        self.reclaim.clear()
        self.owners.clear()
        self.reserved = 0
        self.prf.refs = Counter(self.prf.architectural.values())
        self.prf.values = {p: self.prf.values[p] for p in self.prf.refs}
        for bank, size in self.prf.capacity.items():
            self.prf.free[bank] = [index for index in range(size) if (bank, index) not in self.prf.refs]

    def write(self, entry: Entry) -> None:
        if entry.physical is not None:
            self.prf.write(entry.physical, entry.uid)

    def read(self, reg: Register) -> int:
        for group in reversed(self.groups):
            for span in reversed(group.spans):
                if reg in span.mapping:
                    return self.prf.values[span.mapping[reg]]
        return self.prf.values[self.prf.architectural[reg]]

    def retire(self, entry: Entry) -> None:
        span = self.owners.pop(entry.uid)
        span.retired += 1
        self.release_destination(entry)

    def release_destination(self, entry: Entry) -> None:
        if entry.physical is not None:
            self.prf.release(entry.physical)

    def squash(self, entry: Entry) -> None:
        span = self.owners.pop(entry.uid)
        if entry.physical is not None:
            span.discarded_destinations.append(entry.physical)

    def resolve(self, entry: Entry) -> None:
        span = self.owners[entry.uid]
        assert span.branch is entry
        span.branch = None

    def compact(self, group: Group) -> None:
        older = group.spans[0]
        kept = [older]
        for younger in group.spans[1:]:
            if older.branch is not None:
                kept.append(younger)
                older = younger
                continue
            assert younger.complete
            for reg, physical in younger.mapping.items():
                if reg in older.mapping:
                    self.prf.release(older.mapping[reg])
                older.map_register(reg, physical)
            older.count += younger.count
            older.retired += younger.retired
            older.stores.extend(younger.stores)
        group.spans = kept

    def publish(self, cycle: int) -> int:
        committed = 0
        while self.groups:
            group = self.groups[0]
            # A store retires locally after preparation, so its group can complete before memory service.
            if not group.complete or group.recovering:
                break
            for span in group.spans:
                for store in span.stores:
                    self.memory.authorize(store, cycle)
                self.prf.publish(span.mapping)
                committed += span.count
            self.groups.pop(0)
            self.release_group(group)
            self.stats.counts["block_groups_published"] += 1
            self.stats.event(cycle, "block_publish", block=group.age)
        return committed

    def candidates(self, conflicts: set[tuple[int, int]]) -> list[int]:
        candidates = []
        for index in range(1, len(self.groups)):
            older, younger = self.groups[index - 1:index + 1]
            if older.recovering or younger.recovering or not younger.complete:
                continue
            if self.config["merging"]["require_older_complete"] and not older.complete:
                continue
            if any(overlaps(a.instruction, b.instruction) for o in older.spans for a in o.stores if not a.serviced
                   for y in younger.spans for b in y.stores if not b.serviced):
                conflicts.add((older.age, younger.age))
                continue
            candidates.append(index)
        return candidates

    def merge(self, cycle: int, width: int | None = None) -> int:
        for group in self.groups:
            if group.complete and group.complete_since is None:
                group.complete_since = cycle
            if len(group.spans) > 1 and group.spans[0].branch is None:
                self.compact(group)
        conflicts: set[tuple[int, int]] = set()
        candidates = self.candidates(conflicts)
        self.stats.samples["merge_candidates"].add(len(candidates))
        merged = 0
        if width is None:
            width = len(self.groups) - 1 if self.unbounded else self.config["merging"]["width"]
        for _ in range(width):
            if not candidates:
                break
            index = candidates[0]
            younger = self.groups.pop(index)
            older = self.groups[index - 1]
            before = self.prf.freed
            older.spans.extend(younger.spans)
            self.compact(older)
            self.release_group(younger)
            merged += 1
            assert younger.complete_since is not None
            self.stats.samples["merge_wait"].add(cycle - younger.complete_since)
            self.stats.samples["registers_freed_per_merge"].add(self.prf.freed - before)
            self.stats.event(cycle, "merge", older=older.age, younger=younger.age,
                             older_complete=int(older.complete))
            candidates = self.candidates(conflicts)
        self.stats.counts["merge_store_conflict_pair_cycles"] += len(conflicts)
        self.stats.counts["merges_delayed_by_bandwidth"] += len(candidates)
        self.stats.counts["merges"] += merged
        return merged

    def invalidate(self, branch: Entry, cycle: int) -> None:
        span = self.owners[branch.uid]
        index = next(i for i, group in enumerate(self.groups) if any(s is span for s in group.spans))
        group = self.groups[index]
        split = next(i for i, s in enumerate(group.spans) if s is span) + 1
        younger = self.groups[index + 1:]
        recovery = Recovery(cycle)
        for other in younger:
            self.schedule_reclaim(other, other.spans, True, recovery)
            other.spans = []
        del self.groups[index + 1:]
        if split < len(group.spans):
            self.schedule_reclaim(group, group.spans[split:], False, recovery)
            del group.spans[split:]
            self.stats.counts["merged_groups_restored"] += 1
        self.stats.samples["younger_blocks_invalidated"].add(len(younger))
        self.stats.samples["blocks_preserved"].add(index + 1)
        if not recovery.pending:
            self.stats.samples["block_reclamation_cycles"].add(0)

    def schedule_reclaim(self, group: Group, spans: list[Span], release: bool, recovery: Recovery) -> None:
        for span in spans:
            for store in span.stores:
                assert not store.authorized
                store.valid = False
        group.recovering = True
        task = self.reclaim.setdefault(group.age, Reclaim(group))
        task.spans.extend(spans)
        task.release_slot |= release
        task.recoveries.append(recovery)
        recovery.pending += 1

    def flush(self, cycle: int, width: int | None = None) -> int:
        if width is None:
            width = self.config["flushing"]["width"]
        reclaimed = sorted(self.reclaim, reverse=True)[:width]
        for age in reclaimed:
            task = self.reclaim.pop(age)
            before = self.prf.freed
            for span in task.spans:
                for physical in span.mapping.values():
                    self.prf.release(physical)
                for physical in span.discarded_destinations:
                    self.prf.release(physical)
                for store in span.stores:
                    assert not store.valid and not store.authorized
                    del self.memory.store_buffers[self.thread_id][store.uid]
            if task.release_slot:
                self.release_group(task.group)
                self.stats.counts["flushed_block_slots"] += 1
            task.group.recovering = False
            for recovery in task.recoveries:
                recovery.pending -= 1
                if not recovery.pending:
                    self.stats.samples["block_reclamation_cycles"].add(cycle - recovery.cycle)
            self.stats.samples["registers_freed_per_flushed_block"].add(self.prf.freed - before)
            self.stats.event(cycle, "flush", block=age, slot_released=int(task.release_slot))
        self.stats.counts["flush_operations"] += len(reclaimed)
        return len(reclaimed)

    def reclaim_blocks_dispatch(self, stall: str, destination: Register | None) -> bool:
        if stall == "block_capacity":
            return any(task.release_slot for task in self.reclaim.values())
        spans = [span for task in self.reclaim.values() for span in task.spans]
        if stall == "store_buffer_full":
            return any(span.stores for span in spans)
        assert destination is not None
        refs = Counter(p for span in spans for p in (*span.mapping.values(), *span.discarded_destinations)
                       if p[0] == destination[0])
        return any(count == self.prf.refs[p] for p, count in refs.items())

    def observe(self, cycles: int = 1) -> None:
        self.stats.samples["block_occupancy"].add(self.reserved, cycles)
        self.stats.samples["flush_backlog"].add(len(self.reclaim), cycles)
        self.stats.samples["integer_prf_occupancy"].add(self.prf.occupancy("x"), cycles)
        self.stats.samples["fp_prf_occupancy"].add(self.prf.occupancy("f"), cycles)
