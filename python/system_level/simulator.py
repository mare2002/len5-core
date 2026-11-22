"""Deterministic simulation pipeline shared by all three commit architectures."""

from collections import Counter, defaultdict
from heapq import heappop, heappush
from itertools import islice

from .blocks import Blocks, Group
from .config import ARCHITECTURES, UNIT_FOR
from .instruction import Instruction, Register
from .memory import Memory
from .metrics import Metrics
from .rob import ROB
from .state import Entry, Version
from .workload import Timing


class Simulator:
    def __init__(self, architecture: str, config: dict, program: list[Instruction], timings: list[Timing],
                 *, core: "Simulator | None" = None, stats: Metrics | None = None,
                 memory: Memory | None = None, block_pool: list[Group | None] | None = None):
        if architecture not in ARCHITECTURES or not program or len(program) != len(timings):
            raise ValueError("simulation requires a known architecture and matching nonempty program and timings")
        self.architecture = architecture
        self.config = config
        self.program = program
        self.timings = timings
        self.options = config["simulation"]
        self.cdb_width = self.options["cdb_width"] or self.options["dispatch_width"]
        self.commit_width = self.options["commit_width"] or self.options["dispatch_width"]
        self.statistical = self.options["mode"] == "statistical"
        self.core = self if core is None else core
        self.threads = (self,)
        self.stats = stats if stats is not None else Metrics(self.options["record_events"])
        self.thread_id = self.stats.thread_id or 0
        self.memory = memory if memory is not None else Memory(config["memory"], self.stats)
        self.rob = ROB(self.options["rob_size"], architecture,
                       protect_unresolved_head=config.get("smt", {}).get("mode", "disabled") != "disabled")
        self.blocks = (Blocks(config["basic_block"], self.memory, self.stats, block_pool, self.thread_id)
                       if self.rob.individual else None)
        self.enabled = {name: unit for name, unit in config["execution"]["units"].items() if unit["count"]}
        self.lanes = ({name: [(0, 0, 0)] * unit["count"] for name, unit in self.enabled.items()}
                      if core is None else core.lanes)
        shared = config["execution"]["shared_rs"]
        self.rs_for = {name: "shared" if shared else name for name in self.enabled}
        self.rs_limits = ({"shared": (shared["size"], shared["issue_width"])} if shared else
                          {name: (unit["rs_size"], unit["rs_issue_width"]) for name, unit in self.enabled.items()})
        self.rs: dict[int, Entry] = {} if core is None else core.rs
        self.rs_occupancy = dict.fromkeys(self.rs_limits, 0) if core is None else core.rs_occupancy
        self.executing: list[tuple[int, int, Entry]] = [] if core is None else core.executing
        self.cdb: dict[int, tuple[int, Entry]] = {} if core is None else core.cdb
        self.cdb_batch: set[str] = set()
        self.readers: defaultdict[int, dict[int, Entry]] = defaultdict(dict)
        self.latest: dict[Register, Version] = {}
        self.rf = None if self.blocks else {("x", i): 0 for i in range(1, 32)} | {
            ("f", i): 0 for i in range(32)}
        self.cycle = 0
        self.cursor = 0
        self.uid = 0
        self.redirect_until = 0
        self.redirect_started: int | None = None
        self.pending_recovery: Entry | None = None
        self.commit_stage: list[Entry] = []
        self.committed = 0
        self.sequence = 0
        self.iteration: int | None = None
        self.dispatch_stall = ""
        for instruction in program:
            if UNIT_FOR[instruction.kind] not in self.enabled:
                raise ValueError(f"instruction {instruction.kind} has no enabled execution unit")

    def log(self, name: str, entry: Entry, **fields: int | str) -> None:
        if self.stats.events is None:
            return
        if entry.iteration is not None:
            fields["iteration"] = entry.iteration
        self.owner(entry).stats.event(self.cycle, name, index=entry.index, uid=entry.uid, slot=entry.slot, **fields)

    def owner(self, entry: Entry) -> "Simulator":
        return self.core.threads[entry.thread_id]

    def remove_rs(self, entry: Entry) -> None:
        del self.rs[entry.uid]
        self.rs_occupancy[self.rs_for[UNIT_FOR[entry.kind]]] -= 1

    def ready_operand(self, reg: Register, version: Version) -> int:
        if self.blocks:
            value = self.blocks.read(reg)
        elif (producer := self.rob.entries.get(version.uid)) is not None:
            value = producer.result
        else:
            value = next((entry.result for entry in self.commit_stage if entry.uid == version.uid), self.rf[reg])
        assert value == version.uid
        return value

    def dispatch(self, backend_flushing: bool = False, width: int | None = None) -> int:
        if width is None:
            width = self.options["dispatch_width"]
        self.dispatch_stall = ""
        count = 0
        while count < width and self.cursor < len(self.program):
            instruction = self.program[self.cursor]
            station = self.rs_for[UNIT_FOR[instruction.kind]]
            dest = instruction.destination
            if self.cycle < self.redirect_until:
                stall = "frontend_redirect"
            elif self.pending_recovery is not None or backend_flushing:
                stall = "recovery_backend_pending"
            elif self.rob.full:
                stall = "rob_full"
                if self.rob.reuse_delayed:
                    self.stats.counts["rob_reuse_delayed_cycles"] += 1
            elif self.rs_occupancy[station] >= self.rs_limits[station][0]:
                stall = "rs_full:" + station
            else:
                stall = self.memory.dispatch_stall(instruction.kind, self.thread_id)
                if not stall and self.blocks:
                    stall = self.blocks.can_allocate(instruction.kind, dest)
            if stall:
                self.dispatch_stall = stall
                self.stats.counts["dispatch_stall:" + stall] += 1
                if (self.blocks and self.blocks.reclaim and
                        stall in ("block_capacity", "integer_prf", "fp_prf", "store_buffer_full")):
                    self.stats.counts["dispatch_stall_with_reclaim_backlog"] += 1
                    if self.blocks.reclaim_blocks_dispatch(stall, dest):
                        self.stats.counts["dispatch_stall_reclamation"] += 1
                break

            self.core.uid += 1
            sources = {reg: self.latest[reg] for reg in instruction.sources if reg in self.latest}
            waiting = {version.uid: reg for reg, version in sources.items() if not version.ready}
            operands = {reg: self.ready_operand(reg, version) for reg, version in sources.items() if version.ready}
            operands.update((reg, 0) for reg in instruction.sources if reg not in sources)
            entry = Entry(self.core.uid, self.cursor, -1, instruction, self.timings[self.cursor],
                          self.cycle, waiting, operands, self.cycle + 1, thread_id=self.thread_id)
            if self.stats.thread_id is not None:
                self.sequence += 1
                entry.thread_sequence = self.sequence
            entry.iteration = self.iteration
            if dest is not None:
                entry.version = self.latest[dest] = Version(entry.uid)
            if instruction.control:
                entry.checkpoint = self.latest.copy()
            self.rob.add(entry)
            if self.blocks:
                self.blocks.insert(entry, self.cycle)
            self.memory.allocate(entry)
            self.rs[entry.uid] = entry
            self.rs_occupancy[station] += 1
            for producer in waiting:
                self.readers[producer][entry.uid] = entry
            self.log("dispatch", entry)
            if self.redirect_started is not None:
                self.stats.samples["recovery_to_first_dispatch"].add(self.cycle - self.redirect_started)
                if self.blocks is None:
                    self.stats.samples["recovery_dispatch_extra_delay"].add(self.cycle - self.redirect_until)
                self.redirect_started = None
            self.cursor += 1
            count += 1
        if self.blocks and self.cursor == len(self.program):
            self.blocks.seal()
        if count == self.options["dispatch_width"]:
            self.stats.counts["dispatch_width_saturated_cycles"] += 1
        self.stats.counts["dispatched"] += count
        return count

    def select(self) -> int:
        issued: list[Entry] = []
        local: Counter[str] = Counter()
        units: Counter[str] = Counter()
        for entry in self.rs.values():
            if entry.waiting or entry.ready_since > self.cycle:
                continue
            name = UNIT_FOR[entry.kind]
            station = self.rs_for[name]
            stats = self.owner(entry).stats
            if local[station] == self.rs_limits[station][1]:
                stats.counts["issue_blocked:rs_width:" + station] += 1
                continue
            lanes = self.lanes[name]
            if self.statistical:
                available = units[name] < len(lanes)
                lane = 0
            else:
                lane = min(range(len(lanes)), key=lambda i: lanes[i][0])
                available = lanes[lane][0] <= self.cycle
            if not available:
                stats.counts["issue_blocked:execution_unit:" + name] += 1
                continue
            if entry.kind == "load":
                if reason := self.memory.load_blocked(entry):
                    stats.counts["issue_blocked:" + reason] += 1
                    continue
                self.memory.start_load(entry)
            if not self.statistical:
                lanes[lane] = (self.cycle + self.enabled[name]["initiation_interval"], entry.uid, entry.thread_id)
            entry.issued = self.cycle
            due = self.cycle + entry.timing.execution
            heappush(self.executing, (due, entry.uid, entry))
            stats.samples["rs_wait:" + station].add(self.cycle - entry.dispatched)
            stats.samples["dependency_wait"].add(entry.ready_since - entry.dispatched - 1)
            stats.counts["issues:" + name] += 1
            self.log("issue", entry)
            local[station] += 1
            units[name] += 1
            issued.append(entry)
        for entry in issued:
            self.remove_rs(entry)
        return len(issued)

    def finish_execution(self) -> None:
        while self.executing and self.executing[0][0] <= self.cycle:
            _, _, entry = heappop(self.executing)
            if not entry.valid:
                continue
            self.log("execution_complete", entry)
            if entry.kind == "load":
                self.memory.request_load(entry, self.cycle)
            else:
                if entry.kind == "store":
                    entry.prepared = self.cycle
                    self.log("store_prepare", entry)
                self.cdb[entry.uid] = (self.cycle, entry)

    def finish_memory(self) -> None:
        for entry in self.memory.complete(self.cycle):
            self.cdb[entry.uid] = (self.cycle, entry)
            self.owner(entry).stats.samples["load_service_latency"].add(self.cycle - entry.issued)
            self.log("load_response", entry)

    def select_broadcasts(self) -> list[tuple[int, Entry]]:
        pending = sorted(self.cdb.values(), key=lambda item: (item[0], item[1].uid))
        if self.options["cdb_policy"] == "oldest_completed":
            return pending[:self.cdb_width]
        priority = ("load", "branch", "alu", "mul", "div", "fp")
        stores = [item for item in pending if item[1].kind == "store"]
        selected = stores[:self.cdb_width]
        low = [item for item in pending if item[1].kind != "store"]
        while low and len(selected) < self.cdb_width:
            sources = {"branch" if entry.kind == "jump" else entry.kind for _, entry in low}
            self.cdb_batch &= sources
            if not self.cdb_batch:
                self.cdb_batch = sources
            name = next(source for source in priority if source in self.cdb_batch)
            index = next(i for i, (_, entry) in enumerate(low)
                         if entry.kind == name or (name == "branch" and entry.kind == "jump"))
            selected.append(low.pop(index))
            self.cdb_batch.remove(name)
        return selected

    def broadcast(self, shared_stats: Metrics | None = None) -> int:
        cdb_stats = self.stats if shared_stats is None else shared_stats
        if len(self.cdb) > self.cdb_width:
            cdb_stats.counts["cdb_contention_cycles"] += 1
            cdb_stats.counts["cdb_deferred_requests"] += len(self.cdb) - self.cdb_width
        selected = self.select_broadcasts()
        if self.blocks:
            for thread in self.threads:
                miss = min((entry for _, entry in selected
                            if entry.thread_id == thread.thread_id and entry.timing.mispredict),
                           key=lambda entry: entry.uid, default=None)
                if miss is not None:
                    thread.recover(miss)
        count = 0
        for finished, entry in selected:
            if not entry.valid:
                continue
            owner = self.owner(entry)
            assert owner.rob.slots[entry.slot] is entry
            del self.cdb[entry.uid]
            entry.done = True
            entry.completed = self.cycle
            if entry.version is not None:
                entry.version.ready = True
                if owner.blocks:
                    owner.blocks.write(entry)
                else:
                    entry.result = entry.uid
            if entry.instruction.control:
                if owner.blocks:
                    owner.blocks.resolve(entry)
                if owner.blocks is None and entry.timing.mispredict and not entry.faulted:
                    owner.detect_misprediction(entry)
                else:
                    entry.checkpoint = None
            for consumer in owner.readers.pop(entry.uid, {}).values():
                assert consumer.valid and consumer.thread_id == entry.thread_id
                reg = consumer.waiting.pop(entry.uid)
                consumer.operands[reg] = entry.uid
                if not consumer.waiting:
                    consumer.ready_since = self.cycle + 1
                    self.log("wakeup", consumer, producer=entry.uid)
            if entry.kind == "load":
                del self.memory.loads[entry.uid]
                owner.stats.samples["load_result_latency"].add(self.cycle - entry.issued)
            owner.stats.samples["cdb_wait"].add(self.cycle - finished - 1)
            owner.stats.counts["broadcasts"] += 1
            self.log("broadcast", entry)
            count += 1
        self.stats.counts.setdefault("broadcasts", 0)
        return count

    def detect_misprediction(self, branch: Entry) -> None:
        redirect = self.pending_recovery is None or branch.uid < self.pending_recovery.uid
        self.stats.counts["mispredictions"] += 1
        if redirect:
            self.redirect_until = self.cycle + branch.timing.recovery
            self.redirect_started = self.cycle
            self.stats.samples["frontend_recovery_latency"].add(branch.timing.recovery)
        if self.blocks:
            self.log("mispredict", branch, frontend_ready=self.redirect_until)
        else:
            if redirect:
                self.pending_recovery = branch
            self.log("mispredict", branch, frontend_ready=self.redirect_until, redirected=int(redirect))

    def recover(self, branch: Entry) -> None:
        assert branch.checkpoint is not None
        self.latest = branch.checkpoint.copy()
        self.stats.counts["squashed_instructions"] += self.cursor - branch.index - 1
        self.cursor = branch.index + 1
        if self.blocks:
            self.detect_misprediction(branch)
        else:
            assert branch is self.pending_recovery and branch.done and branch.uid not in self.rob.entries
            self.pending_recovery = None
            self.stats.counts["recovery_backend_flushes"] += 1
            self.stats.samples["recovery_detection_to_flush"].add(self.cycle - branch.completed)
            self.log("backend_flush", branch, detected_cycle=branch.completed)
        removed = [entry for entry in self.rob.entries.values() if entry.uid > branch.uid]
        for entry in removed:
            entry.valid = False
            if entry.uid in self.rs:
                self.remove_rs(entry)
            self.cdb.pop(entry.uid, None)
            for producer in entry.waiting:
                self.readers[producer].pop(entry.uid, None)
                if not self.readers[producer]:
                    del self.readers[producer]
            self.memory.squash(entry, defer_store=self.blocks is not None)
            if self.blocks:
                self.blocks.squash(entry)
            self.log("squash", entry)
        self.rob.squash(removed)
        if self.blocks:
            self.blocks.invalidate(branch, self.cycle)
        for name, lanes in self.lanes.items():
            self.lanes[name] = [(self.cycle, 0, tid) if tid == self.thread_id and uid > branch.uid
                                else (due, uid, tid) for due, uid, tid in lanes]

    def authorize_head_store(self) -> None:
        head = self.rob.head
        if head and head.kind == "store" and head.prepared and not (head.authorized or head.faulted):
            self.memory.authorize(head, self.cycle, ready_cycle=head.prepared)

    def accept_one(self) -> Entry | None:
        entry = self.rob.retirement_candidate()
        if entry is None:
            return None
        head = self.rob.head
        if entry is not head:
            assert self.pending_recovery is None or entry.uid < self.pending_recovery.uid
            self.stats.counts["out_of_order_commits"] += 1
        if entry.timing.mispredict:
            assert entry is head
        self.rob.remove(entry)
        self.commit_stage.append(entry)
        self.log("commit_accept", entry)
        return entry

    def accept_commit(self) -> int:
        self.authorize_head_store()
        for _ in range(self.commit_width):
            entry = self.accept_one()
            if entry is None or entry.timing.mispredict:
                break
        return len(self.commit_stage)

    def local_retire(self, entry: Entry) -> None:
        self.blocks.retire(entry)
        self.rob.remove(entry)
        self.log("local_retire", entry)

    def retire(self) -> int:
        if self.blocks:
            retire = list(islice((entry for entry in self.rob.entries.values() if entry.done), self.commit_width))
            for entry in retire:
                self.local_retire(entry)
            count = len(retire)
        else:
            count = len(self.commit_stage)
            for entry in self.commit_stage:
                if entry.timing.mispredict:
                    self.recover(entry)
                    entry.checkpoint = None
                if entry.instruction.destination is not None:
                    self.rf[entry.instruction.destination] = entry.result
                self.log("commit", entry)
            self.commit_stage.clear()
            self.committed += count
        self.record_retirement(count)
        return count

    def record_retirement(self, count: int) -> None:
        if self.rob.entries and not count:
            self.stats.counts["retire_blocked_cycles"] += 1
        if count == self.commit_width:
            self.stats.counts["retirement_width_saturated_cycles"] += 1
        self.stats.counts["rob_retirements"] += count

    def observe(self, issued: int, broadcasts: int, merged: int, flushed: int, cycles: int = 1) -> None:
        sample = self.stats.samples
        for name, value in (("rob_occupancy", len(self.rob.entries)), ("issue_throughput", issued),
                            ("cdb_throughput", broadcasts), ("cdb_backlog", len(self.cdb)),
                            ("speculative_window", self.cursor - self.committed)):
            sample[name].add(value, cycles)
        for name, value in self.rs_occupancy.items():
            sample["rs_occupancy:" + name].add(value, cycles)
        self.observe_recovery(cycles)
        for name, lanes in self.lanes.items():
            # Statistical mode omits lane reservation. Issue utilization remains available.
            sample["execution_lane_busy:" + name].add(sum(due > self.cycle for due, _, _ in lanes), cycles)
        self.memory.observe(cycles)
        self.observe_blocks(merged, flushed, cycles)

    def observe_recovery(self, cycles: int = 1) -> None:
        if self.pending_recovery is not None:
            self.stats.counts["recovery_pending_cycles"] += cycles
            if self.pending_recovery.uid in self.rob.entries and self.pending_recovery is not self.rob.head:
                self.stats.counts["recovery_wait_for_rob_head_cycles"] += cycles
            self.stats.samples["recovery_pending_rob_occupancy"].add(len(self.rob.entries), cycles)

    def observe_blocks(self, merged: int, flushed: int, cycles: int = 1) -> None:
        if self.blocks:
            self.blocks.observe(cycles)
            sample = self.stats.samples
            sample["merge_operations_per_cycle"].add(merged, cycles)
            sample["flush_operations_per_cycle"].add(flushed, cycles)
            self.stats.histograms["merges_per_cycle"][merged] += cycles
            self.stats.histograms["flushes_per_cycle"][flushed] += cycles

    def step(self) -> int:
        self.cycle += 1
        backend_flushing = bool(self.commit_stage and self.commit_stage[-1].timing.mispredict)
        retired = self.retire()
        accepted = 0
        merged, flushed = 0, 0
        published = 0
        if self.blocks:
            recovering = bool(self.blocks.reclaim) or self.cycle < self.redirect_until
            flushed = self.blocks.flush(self.cycle)
            if not recovering or self.blocks.config["flushing"]["allow_unaffected_merges"]:
                merged = self.blocks.merge(self.cycle)
            else:
                self.stats.samples["merge_candidates"].add(0)
            published = self.blocks.publish(self.cycle)
            self.committed += published
        else:
            if not backend_flushing:
                accepted = self.accept_commit()
            self.stats.samples["commit_stage_occupancy"].add(accepted)
        self.memory.drain(self.cycle)
        broadcasts = self.broadcast()
        if self.rob.len5 and not backend_flushing:
            if metric := self.rob.advance_clear(self.cycle):
                self.stats.counts[metric] += 1
        old_stores = self.stats.counts["stores_serviced"]
        self.finish_execution()
        self.finish_memory()
        issued = self.select()
        # Zero-cycle starts finish now, after this cycle's CDB arbitration.
        self.finish_execution()
        dispatched = self.dispatch(backend_flushing)
        self.observe(issued, broadcasts, merged, flushed)
        self.rob.released.clear()
        return (retired + accepted + merged + flushed + issued + dispatched + broadcasts + published
                + self.stats.counts["stores_serviced"] - old_stores)

    def skip_idle(self) -> None:
        # A quiescent statistical core can advance directly to the next timed event.
        if (self.cdb or self.commit_stage or self.rob.clear_entry is not None or
                any(not entry.waiting for entry in self.rs.values())
                or (self.blocks and self.blocks.reclaim)):
            return
        if any(store.valid and store.authorized and not store.launched for store in self.memory.stores.values()):
            return
        if self.blocks and self.blocks.groups and self.blocks.groups[0].complete:
            return
        due = [queue[0][0] for queue in (self.executing, self.memory.responses) if queue]
        if self.cycle < self.redirect_until:
            due.append(self.redirect_until)
        if not due:
            return
        cycles = min(min(due) - 1, self.options["max_cycles"]) - self.cycle
        if cycles <= 0:
            return
        if self.dispatch_stall:
            self.stats.counts["dispatch_stall:" + self.dispatch_stall] += cycles
        if self.rob.entries:
            self.stats.counts["retire_blocked_cycles"] += cycles
        if self.blocks is None:
            self.stats.samples["commit_stage_occupancy"].add(0, cycles)
        if self.blocks:
            self.stats.samples["merge_candidates"].add(0, cycles)
        self.observe(0, 0, 0, 0, cycles)
        self.cycle += cycles
        self.stats.counts["statistical_cycles_skipped"] += cycles

    def run(self) -> dict:
        while self.committed < len(self.program) or self.memory.stores or (self.blocks and self.blocks.reclaim):
            if self.cycle >= self.options["max_cycles"]:
                raise RuntimeError(f"{self.architecture}: hit max_cycles at instruction {self.cursor}, "
                                   f"committed {self.committed}/{len(self.program)}, "
                                   f"last dispatch stall {self.dispatch_stall or 'none'}")
            progress = self.step()
            if self.statistical and not progress:
                self.skip_idle()
        self.verify_done()
        return self.report()

    def verify_done(self) -> None:
        assert self.cursor == self.committed == len(self.program)
        assert not self.rob.entries and not self.readers
        assert not self.memory.loads and not self.cdb
        assert not self.memory.store_buffers[self.thread_id]
        assert self.pending_recovery is None and not self.commit_stage
        assert self.stats.counts["dispatched"] == self.committed + self.stats.counts["squashed_instructions"]
        self.verify_registers()

    def verify_registers(self) -> None:
        if self.blocks:
            assert not self.blocks.owners and not self.blocks.reserved and len(self.blocks.prf.refs) == 63
            final = {reg: self.blocks.prf.values[p] for reg, p in self.blocks.prf.architectural.items()}
        else:
            final = self.rf
        assert all(final[reg] == (self.latest[reg].uid if reg in self.latest else 0) for reg in final)

    def restart(self, timings: list[Timing]) -> None:
        assert self.committed == len(self.program) and not self.rob.entries and not self.commit_stage
        assert not self.readers and self.pending_recovery is None
        self.timings = timings
        self.cursor = self.committed = 0
        self.latest.clear()
        self.redirect_until = 0
        self.redirect_started = None
        self.rob.tail = self.rob.clear_index = 0
        if self.blocks:
            assert not self.blocks.reserved and not self.blocks.owners and not self.blocks.reclaim
            self.blocks.reset_registers()
        else:
            self.rf = dict.fromkeys(self.rf, 0)

    def cancel_remaining(self) -> None:
        for entry in (*self.rob.entries.values(), *self.commit_stage):
            entry.valid = False
            entry.checkpoint = None
        self.rob = ROB(self.rob.size, self.architecture, protect_unresolved_head=self.rob.protect_unresolved_head)
        self.commit_stage.clear()
        self.readers.clear()
        self.latest.clear()
        self.pending_recovery = None
        if self.blocks:
            self.blocks.discard_speculation()

    def report(self, stats: Metrics | None = None, committed: int | None = None) -> dict:
        stats = self.stats if stats is None else stats
        committed = self.committed if committed is None else committed
        elapsed = self.cycle
        counts = stats.counts
        for name in ("mispredictions", "squashed_instructions", "load_requests", "stores_authorized",
                     "stores_serviced", "store_load_conflicts", "cdb_contention_cycles"):
            counts.setdefault(name, 0)
        if self.blocks:
            for name in ("merges", "merges_delayed_by_bandwidth", "flush_operations",
                         "merged_groups_restored", "dispatch_stall_reclamation",
                         "dispatch_stall:block_capacity", "merge_store_conflict_pair_cycles"):
                counts.setdefault(name, 0)
        lanes_per_station: Counter[str] = Counter()
        for unit, lanes in self.lanes.items():
            lanes_per_station[self.rs_for[unit]] += len(lanes)
        issue_capacity = sum(min(size, width, lanes_per_station[station])
                             for station, (size, width) in self.rs_limits.items())
        report = stats.report()
        report.update(architecture=self.architecture, cycles=self.cycle, committed=committed,
                      ipc=committed / elapsed, mode=self.options["mode"],
                      cdb_utilization=counts["broadcasts"] / (elapsed * self.cdb_width),
                      issue_utilization=stats.samples["issue_throughput"].total /
                      (elapsed * issue_capacity),
                      retirement_utilization=counts["rob_retirements"] / (elapsed * self.commit_width),
                      execution_units={eu: {
                          "issues": counts["issues:" + eu],
                          "issue_utilization": counts["issues:" + eu] / (elapsed * unit["count"]),
                          "lane_utilization": (stats.samples["execution_lane_busy:" + eu].total /
                                               (elapsed * unit["count"]) if not self.statistical else None),
                      } for eu, unit in self.enabled.items()})
        if self.blocks:
            for name, section, metric in (("merge", "merging", "merges"),
                                          ("flush", "flushing", "flush_operations")):
                report[name + "_utilization"] = counts[metric] / (
                    elapsed * self.blocks.config[section]["width"])
        if stats.events is not None:
            report["events"] = stats.events
        return report
