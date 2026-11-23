"""Statistical memory service with finite queues and ordered store visibility."""

from heapq import heappop, heappush

from .instruction import Instruction
from .metrics import Metrics
from .state import Entry


def overlaps(x: Instruction, y: Instruction) -> bool:
    if x.address is None or y.address is None:
        return True
    return x.address < y.address + max(1, y.size) and y.address < x.address + max(1, x.size)


class Memory:
    def __init__(self, config: dict, stats: Metrics, thread_stats: tuple[Metrics, ...] = ()):
        self.config = config
        self.stats = stats
        self.thread_stats = thread_stats or (stats,)
        self.loads: dict[int, Entry] = {}
        self.outstanding: dict[int, Entry] = {}
        self.misses = 0
        self.store_buffers: tuple[dict[int, Entry], ...] = tuple({} for _ in self.thread_stats)
        self.responses: list[tuple[int, int, Entry]] = []
        self.store_tails = [0] * len(self.store_buffers)
        self.drain_priority = 0

    @property
    def stores(self) -> dict[int, Entry]:
        return self.store_buffers[0]

    def dispatch_stall(self, kind: str, thread_id: int = 0) -> str:
        if kind == "load" and len(self.loads) >= self.config["load_buffer_capacity"]:
            return "load_buffer_full"
        if kind == "store" and len(self.store_buffers[thread_id]) >= self.config["store_buffer_capacity"]:
            return "store_buffer_full"
        return ""

    def allocate(self, entry: Entry) -> None:
        if entry.kind == "load":
            self.loads[entry.uid] = entry
        elif entry.kind == "store":
            self.store_buffers[entry.thread_id][entry.uid] = entry

    def load_blocked(self, entry: Entry) -> str:
        for store in self.store_buffers[entry.thread_id].values():
            if store.valid and store.index < entry.index and overlaps(store.instruction, entry.instruction):
                if not entry.conflict_seen:
                    self.thread_stats[entry.thread_id].counts["store_load_conflicts"] += 1
                    entry.conflict_seen = True
                return "store_conflict"
        if len(self.outstanding) >= self.config["max_outstanding_loads"]:
            return "outstanding_loads_full"
        if entry.timing.cache != "l1" and self.misses >= self.config["mshr_capacity"]:
            return "mshr_full"
        return ""

    def start_load(self, entry: Entry) -> None:
        self.outstanding[entry.uid] = entry
        self.misses += entry.timing.cache != "l1"
        stats = self.thread_stats[entry.thread_id]
        stats.counts["load_requests"] += 1
        stats.histograms["cache_outcomes"][entry.timing.cache] += 1

    def request_load(self, entry: Entry, cycle: int) -> None:
        heappush(self.responses, (cycle + entry.timing.memory, entry.uid, entry))

    def release_outstanding(self, entry: Entry) -> None:
        if self.outstanding.pop(entry.uid, None) is not None:
            self.misses -= entry.timing.cache != "l1"

    def authorize(self, entry: Entry, cycle: int, *, ready_cycle: int | None = None) -> None:
        assert entry.valid and entry.prepared and not entry.faulted and not entry.authorized
        if ready_cycle is None:
            assert entry.done
            ready_cycle = entry.completed
        entry.authorized = cycle
        stats = self.thread_stats[entry.thread_id]
        stats.counts["stores_authorized"] += 1
        stats.samples["store_authorization_wait"].add(cycle - ready_cycle)
        stats.event(cycle, "store_authorize", index=entry.index, uid=entry.uid)

    def drain(self, cycle: int) -> int:
        queues = [iter(store for store in buffer.values() if store.valid and not store.launched)
                  for buffer in self.store_buffers]
        heads = [next(queue, None) for queue in queues]
        drained = 0
        for _ in range(self.config["store_drain_width"]):
            for offset in range(len(heads)):
                thread = (self.drain_priority + offset) % len(heads)
                entry = heads[thread]
                if entry is not None and entry.authorized:
                    break
            else:
                break
            entry.launched = True
            # Each address space preserves its own store order.
            due = max(self.store_tails[thread], cycle + entry.timing.memory)
            self.store_tails[thread] = due
            heappush(self.responses, (due, entry.uid, entry))
            self.thread_stats[thread].event(cycle, "store_drain", index=entry.index, uid=entry.uid)
            self.drain_priority = (thread + 1) % len(heads)
            heads[thread] = next(queues[thread], None)
            drained += 1
        return drained

    def complete(self, cycle: int) -> list[Entry]:
        loads = []
        remaining = self.config["response_width"]
        while self.responses and self.responses[0][0] <= cycle:
            due, _, entry = self.responses[0]
            if not entry.valid:
                heappop(self.responses)
                continue
            if not remaining:
                self.stats.counts["memory_response_contention_cycles"] += 1
                break
            heappop(self.responses)
            remaining -= 1
            stats = self.thread_stats[entry.thread_id]
            stats.samples["memory_response_queue_wait"].add(cycle - due)
            if entry.kind == "load":
                self.release_outstanding(entry)
                loads.append(entry)
            else:
                entry.serviced = True
                del self.store_buffers[entry.thread_id][entry.uid]
                stats.counts["stores_serviced"] += 1
                stats.samples["store_latency"].add(cycle - entry.authorized)
                stats.event(cycle, "store_complete", index=entry.index, uid=entry.uid)
        if len(self.thread_stats) > 1:
            self.stats.samples["memory_response_throughput"].add(self.config["response_width"] - remaining)
        return loads

    def squash(self, entry: Entry, defer_store: bool = False) -> None:
        if entry.kind == "load":
            self.loads.pop(entry.uid, None)
            self.release_outstanding(entry)
        elif entry.kind == "store":
            assert not entry.authorized
            if not defer_store:
                del self.store_buffers[entry.thread_id][entry.uid]

    def observe(self, cycles: int = 1) -> None:
        for name, value in (
            ("load_buffer_occupancy", len(self.loads)), ("store_buffer_occupancy", sum(map(len, self.store_buffers))),
            ("outstanding_loads", len(self.outstanding)), ("mshr_occupancy", self.misses),
        ):
            self.stats.samples[name].add(value, cycles)
