"""Per-thread branch training queue allocated at issue (Python dispatch).

Entries are confirmed out of order (instruction commit for a conventional ROB, block completion for
basic-block commit) and become safe at irrevocable architectural commitment. Training leaves only
from the head, in program order, and only once the head is safe. The queue never stalls the backend:
a full queue drops the training opportunity. Recovery state lives on the backend entry, not here.
"""

from collections import deque
from dataclasses import dataclass, field

from .config import limit
from .metrics import Metrics


@dataclass(slots=True)
class TrainingEntry:
    uid: int                 # Stable dynamic identity (monotonic allocation id)
    thread_id: int
    index: int | None        # Correct-path trace index; None on the wrong path
    fetched: object          # Frontend record: fetch PC, slot, history, predictions and metadata
    allocated: int
    confirmed: int | None = None
    safe: bool = False
    group: list = field(default_factory=list)


class BTQ:
    def __init__(self, capacity: int | str, stats: Metrics):
        self.capacity = limit(capacity)
        self.entries: deque[TrainingEntry] = deque()
        self.by_uid: dict[int, TrainingEntry] = {}
        self.confirmed_waiting = 0
        self.stats = stats

    def allocate(self, uid: int, thread_id: int, index: int | None, fetched: object, cycle: int) -> bool:
        if len(self.entries) >= self.capacity:
            self.stats.counts["btq_dropped"] += 1
            self.stats.counts["btq_dropped_wrong_path" if index is None else "btq_dropped_correct_path"] += 1
            self.stats.occupancy_failure("btq")
            return False
        entry = TrainingEntry(uid, thread_id, index, fetched, cycle)
        self.entries.append(entry)
        self.by_uid[uid] = entry
        self.stats.counts["btq_allocated"] += 1
        return True

    def confirm(self, uid: int, cycle: int) -> None:
        entry = self.by_uid.get(uid)
        if entry is not None and entry.confirmed is None:
            entry.confirmed = cycle
            self.confirmed_waiting += 1
            self.stats.samples["btq_issue_to_confirmation"].add(cycle - entry.allocated)

    def commit(self, uid: int, cycle: int) -> None:
        self.confirm(uid, cycle)
        entry = self.by_uid.get(uid)
        if entry is not None:
            entry.safe = True

    def flush_younger(self, uid: int) -> None:
        while self.entries and self.entries[-1].uid > uid:
            entry = self.entries.pop()
            del self.by_uid[entry.uid]
            self.stats.counts["btq_flushed"] += 1
            if entry.confirmed is not None:
                self.confirmed_waiting -= 1
                self.stats.counts["btq_confirmed_flushed"] += 1

    def clear(self) -> None:
        self.entries.clear()
        self.by_uid.clear()
        self.confirmed_waiting = 0

    def pop(self) -> TrainingEntry:
        entry = self.entries.popleft()
        del self.by_uid[entry.uid]
        self.confirmed_waiting -= entry.confirmed is not None
        return entry
