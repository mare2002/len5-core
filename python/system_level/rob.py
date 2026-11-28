"""ROB allocation and retirement policies shared by the cycle scheduler."""

from heapq import heappop, heappush
from itertools import chain

from math import inf

from .config import BLOCK_ARCHITECTURES, IDEAL_ARCHITECTURES, commit_architecture, limit
from .state import Entry


class ROB:
    def __init__(self, size: int, architecture: str):
        self.size = limit(size)
        self.len5 = commit_architecture(architecture) == "len5_ooo_commit"
        self.unbounded = architecture in IDEAL_ARCHITECTURES
        self.unlimited = self.unbounded or self.size == inf
        self.individual = self.unbounded or architecture in BLOCK_ARCHITECTURES
        self.entries: dict[int, Entry] = {}
        self.slots: dict[int, Entry] = {}
        self.free = list(range(size)) if self.individual and not self.unlimited else []
        self.tail = 0
        self.clear_index = 0
        self.released: dict[int, Entry] = {}

    @property
    def full(self) -> bool:
        if self.unlimited:
            return False
        return not self.free if self.individual else self.tail in self.slots or self.reuse_delayed

    @property
    def reuse_delayed(self) -> bool:
        return self.tail in self.released

    @property
    def clear_entry(self) -> Entry | None:
        if self.len5:
            return self.slots.get(self.clear_index) or self.released.get(self.clear_index)
        return None

    @property
    def head(self) -> Entry | None:
        return next(iter(self.entries.values()), None)

    def add(self, entry: Entry) -> None:
        assert not self.full
        if self.individual:
            # With no free slots, existing indices form a dense prefix.
            entry.slot = heappop(self.free) if self.free else len(self.slots)
        else:
            entry.slot = self.tail
            self.tail = self.tail + 1 if self.unlimited else (self.tail + 1) % self.size
        self.entries[entry.uid] = self.slots[entry.slot] = entry

    def remove(self, entry: Entry) -> None:
        assert self.slots[entry.slot] is entry
        del self.entries[entry.uid], self.slots[entry.slot]
        if self.individual:
            heappush(self.free, entry.slot)
        else:
            self.released[entry.slot] = entry

    def squash(self, removed: list[Entry]) -> None:
        for entry in removed:
            self.remove(entry)
        if not self.individual:
            assert not self.entries
            self.tail = self.clear_index = 0
            self.released.clear()

    def advance_clear(self, cycle: int) -> str:
        entry = self.clear_entry
        if entry is None:
            return ""
        entry.mem_clear = True
        # The current cycle's broadcast can satisfy this control-path check.
        critical = entry.instruction.control
        if critical and (not entry.done or entry.timing.mispredict or entry.faulted):
            return "rob_clear_wait_cycles"
        if self.clear_index == self.tail and self.full:
            uncleared = any(e is not entry and not e.mem_clear
                            for e in chain(self.slots.values(), self.released.values()))
            if not (self.reuse_delayed and uncleared):
                return "rob_clear_wait_cycles"
        self.clear_index = self.clear_index + 1 if self.unlimited else (self.clear_index + 1) % self.size
        return "rob_clear_cdb_bypasses" if critical and entry.completed == cycle else ""

    def retirement_candidate(self) -> Entry | None:
        entries = iter(self.entries.values())
        head = next(entries, None)
        if head is None or head.faulted:
            return None
        if head.done and (head.kind != "store" or head.serviced):
            return head
        if self.len5 and (work := next(entries, None)) is not None:
            # Guard against a stale memory-clear bit after the cursor wraps.
            if head.instruction.control:
                return None
            # The RTL compares the raw destination index, even if the work entry has no write.
            head_rd = head.instruction.destination
            work_rd = work.instruction.raw_rd
            waw = head_rd is not None and head_rd[1] == work_rd
            if (work.done and work.mem_clear and work.kind != "store" and
                    not (work.timing.mispredict or work.faulted or waw)):
                return work
        return None
