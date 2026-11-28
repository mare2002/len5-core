"""Online counters, occupancy samples, and optional cycle event logs."""

from collections import Counter, defaultdict
from dataclasses import dataclass, field
from math import inf


@dataclass
class Sample:
    count: int = 0
    total: int = 0
    peak: int = 0

    def add(self, value: int, cycles: int = 1) -> None:
        self.count += cycles
        self.total += value * cycles
        if value > self.peak:
            self.peak = value

    def report(self) -> dict:
        return {"samples": self.count, "total": self.total, "peak": self.peak,
                "mean": self.total / self.count if self.count else 0.0}


@dataclass
class Occupancy:
    """Time-weighted occupancy of one finite or unlimited structure."""
    capacity: float | int | None = None
    cycles: int = 0
    total: int = 0
    peak: int = 0
    empty: int = 0
    full: int = 0
    failures: int = 0
    stalls: int = 0
    histogram: Counter = field(default_factory=Counter)

    def add(self, value: int, capacity, cycles: int = 1) -> None:
        self.capacity = capacity
        self.cycles += cycles
        self.total += value * cycles
        self.peak = max(self.peak, value)
        self.histogram[value] += cycles
        self.empty += cycles if not value else 0
        self.full += cycles if value >= capacity else 0

    def report(self) -> dict:
        finite = self.capacity not in (None, inf)
        mean = self.total / self.cycles if self.cycles else 0.0
        percent = lambda value: 100 * value / self.cycles if self.cycles else 0.0
        return {"capacity": self.capacity if finite else "unlimited", "cycles": self.cycles,
                "mean": mean, "mean_percent": 100 * mean / self.capacity if finite and self.capacity else None,
                "peak": self.peak, "empty_cycles": self.empty, "empty_percent": percent(self.empty),
                "full_cycles": self.full if finite else None, "full_percent": percent(self.full) if finite else None,
                "allocation_failures": self.failures, "stall_cycles": self.stalls,
                "histogram": {str(k): v for k, v in sorted(self.histogram.items())}}


class Metrics:
    def __init__(self, record_events: bool, thread_id: int | None = None):
        self.counts: Counter[str] = Counter()
        self.samples: defaultdict[str, Sample] = defaultdict(Sample)
        self.histograms: defaultdict[str, Counter] = defaultdict(Counter)
        self.occupancy: defaultdict[str, Occupancy] = defaultdict(Occupancy)
        self.events: list[dict] | None = [] if record_events else None
        self.thread_id = thread_id
        self.iteration: int | None = None

    def event(self, cycle: int, name: str, **fields: int | str) -> None:
        if self.events is not None:
            if self.thread_id is not None:
                fields["thread_id"] = self.thread_id
            if self.iteration is not None:
                fields.setdefault("iteration", self.iteration)
            self.events.append({"cycle": cycle, "event": name, **fields})

    def occupy(self, name: str, value: int, capacity, cycles: int = 1) -> None:
        self.occupancy[name].add(value, inf if capacity is None else capacity, cycles)

    def occupancy_failure(self, name: str, stall: bool = False) -> None:
        record = self.occupancy[name]
        record.failures += 1
        record.stalls += stall

    def report(self) -> dict:
        report = {"counts": dict(self.counts), "samples": {k: v.report() for k, v in self.samples.items()},
                  "histograms": {k: dict(v) for k, v in self.histograms.items()}}
        if self.occupancy:
            report["occupancy"] = {k: v.report() for k, v in sorted(self.occupancy.items()) if v.cycles}
        return report
