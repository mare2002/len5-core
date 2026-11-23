"""Bounded issue and result ports for the unified integer reservation station."""

from collections.abc import Iterator
from dataclasses import dataclass

from .config import INTEGER_UNITS, distribution
from .metrics import Metrics
from .state import Entry


def station_capacity(execution: dict) -> int:
    return sum(execution["units"][name]["rs_size"] for name in INTEGER_UNITS)


def result_slots(unit: dict) -> int:
    latency = distribution(unit["latency"], minimum=0).high
    interval = unit["initiation_interval"]
    # Reserve for the configured pipeline through earliest CDB writeback, plus one waiting result.
    return (latency + interval) // interval + 1


@dataclass(slots=True)
class Result:
    entry: Entry
    wrapper: int
    finished: int | None = None
    local_done: bool = False
    broadcast: bool = False


class UnifiedRS:
    def __init__(self, execution: dict):
        units = execution["units"]
        self.wrappers = tuple(tuple(name for name in INTEGER_UNITS if index < units[name]["count"])
                              for index in range(max(units[name]["count"] for name in INTEGER_UNITS)))
        self.compatible = {
            name: sorted(range(units[name]["count"]), key=lambda index: (len(self.wrappers[index]), index))
            for name in INTEGER_UNITS
        }
        self.capacity = station_capacity(execution)
        self.issue_width = min(len(self.wrappers), execution["unified_issue_width"] or len(self.wrappers))
        self.depth = {name: result_slots(units[name]) for name in INTEGER_UNITS}
        self.slots = [{name: {} for name in wrapper} for wrapper in self.wrappers]
        self.results: dict[int, Result] = {}
        self.forwarded: dict[int, Entry] = {}
        self.buffer_stalled = False

    def choose(self, name: str, used: set[int], lanes: list[tuple[int, int, int]],
               cycle: int) -> tuple[int | None, str]:
        reason = "execution_unit:" + name
        for wrapper in self.compatible[name]:
            if lanes[wrapper][0] > cycle:
                continue
            if len(self.slots[wrapper][name]) == self.depth[name]:
                if wrapper not in used and reason != "wrapper_issue_port":
                    reason = "completion_buffer:" + name
                continue
            if wrapper in used:
                reason = "wrapper_issue_port"
                continue
            return wrapper, ""
        return None, reason

    def issue(self, entry: Entry, wrapper: int) -> None:
        assert len(self.slots[wrapper][entry.kind]) < self.depth[entry.kind]
        result = Result(entry, wrapper)
        self.results[entry.uid] = result
        self.slots[wrapper][entry.kind][entry.uid] = result

    def complete(self, entry: Entry, cycle: int) -> None:
        result = self.results[entry.uid]
        result.finished = cycle
        result.local_done = entry.faulted

    def release(self, result: Result) -> None:
        entry = result.entry
        del self.results[entry.uid]
        del self.slots[result.wrapper][entry.kind][entry.uid]

    def accept_cdb(self, entry: Entry) -> None:
        result = self.results[entry.uid]
        result.broadcast = True
        if result.local_done:
            self.release(result)

    def grants(self, cycle: int) -> Iterator[tuple[int, Entry, int]]:
        self.forwarded.clear()
        for index, units in enumerate(self.slots):
            ready = (result for records in units.values() for result in records.values()
                     if result.finished is not None and not result.local_done)
            oldest = min(ready, key=lambda result: result.entry.uid, default=None)
            if oldest is not None:
                entry = oldest.entry
                self.forwarded[entry.uid] = entry
                oldest.local_done = True
                if oldest.broadcast:
                    self.release(oldest)
                yield index, entry, cycle - oldest.finished

    def squash(self, thread: int, boundary: int) -> None:
        for result in tuple(self.results.values()):
            if result.entry.thread_id == thread and result.entry.uid > boundary:
                self.release(result)

    def observe(self, stats: Metrics, cycles: int = 1) -> None:
        stats.samples["unified_completion_occupancy"].add(
            sum(result.finished is not None for result in self.results.values()), cycles)
        stats.samples["unified_forwarding_backlog"].add(
            sum(result.finished is not None and not result.local_done for result in self.results.values()), cycles)
        stats.counts["unified_completion_buffer_stall_cycles"] += int(self.buffer_stalled) * cycles

    def discard(self) -> None:
        self.results.clear()
        self.forwarded.clear()
        for units in self.slots:
            for records in units.values():
                records.clear()
