"""Online counters, occupancy samples, and optional cycle event logs."""

from collections import Counter, defaultdict
from dataclasses import dataclass


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


class Metrics:
    def __init__(self, record_events: bool, thread_id: int | None = None):
        self.counts: Counter[str] = Counter()
        self.samples: defaultdict[str, Sample] = defaultdict(Sample)
        self.histograms: defaultdict[str, Counter] = defaultdict(Counter)
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

    def report(self) -> dict:
        return {"counts": dict(self.counts), "samples": {k: v.report() for k, v in self.samples.items()},
                "histograms": {k: dict(v) for k, v in self.histograms.items()}}
