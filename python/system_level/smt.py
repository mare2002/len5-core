"""Two thread contexts driven by one shared backend cycle scheduler."""

from collections import Counter

from .config import UNIT_FOR
from .instruction import Instruction
from .memory import Memory
from .metrics import Metrics
from .replay import Replay
from .simulator import Simulator
from .workload import Timing


def next_dispatch_priority(priority: int, dispatches: list[int]) -> int:
    other = 1 - priority
    return other if dispatches[priority] > dispatches[other] else priority


def paired_performance(report: dict, isolated: list[dict]) -> None:
    threads = report["threads"]
    for thread, reference in zip(threads, isolated, strict=True):
        thread.update(isolated_cycles=reference["cycles"], isolated_ipc=reference["ipc"],
                      isolated_measured_cycles=reference["cycles"],
                      slowdown=reference["ipc"] / thread["ipc"] if thread["ipc"] else None)
    report["sequential_cycles"] = sum(ref["cycles"] for ref in isolated)
    weighted = sum(t["ipc"] / t["isolated_ipc"] for t in threads)
    report.update(smt_throughput_improvement=100 * (weighted - 1), weighted_speedup=weighted)


class SMT:
    def __init__(self, architecture: str, config: dict, program: list[Instruction],
                 timings: tuple[list[Timing], list[Timing]], *, other_program: list[Instruction] | None = None,
                 names: tuple[str, str] | None = None, sample_names: tuple[str | None, str | None] = (None, None),
                 seed: int = 42, reference_thread: int | None = None):
        self.config = config
        record = config["simulation"]["record_events"]
        self.stats = Metrics(record)
        per_thread = tuple(Metrics(False, tid) for tid in range(2))
        for stats in per_thread:
            stats.events = self.stats.events
            stats.counts.update(smt_priority_cycles=0, smt_no_dispatch_grant_cycles=0)
        self.memory = Memory(config["memory"], self.stats, per_thread)
        self.pool = ([None] * config["basic_block"]["max_active_blocks"]
                     if architecture == "basic_block_ooo_commit" else None)
        self.core = Simulator(architecture, config, program, timings[0], stats=per_thread[0],
                              memory=self.memory, block_pool=self.pool)
        other = Simulator(architecture, config, program if other_program is None else other_program,
                          timings[1], core=self.core, stats=per_thread[1],
                          memory=self.memory, block_pool=self.pool)
        self.threads = self.core.threads = (self.core, other)
        self.dispatch_priority = config["smt"]["initial_priority"]
        self.commit_priority = self.merge_priority = self.flush_priority = 0
        self.completion = [0, 0]
        if reference_thread is None:
            reference_thread = config["smt"]["measurement"]["reference_thread"]
        if reference_thread not in (0, 1):
            raise ValueError("automatic SMT reference selection requires a paired experiment")
        self.reference_thread = reference_thread
        self.replays = [Replay(thread, name, sample, seed) for thread, name, sample in
                        zip(self.threads, names or ("thread_0", "thread_1"), sample_names)]
        self.finished = False

    def dispatch(self, flushing: list[bool]) -> None:
        width = self.config["simulation"]["dispatch_width"]
        priority = self.dispatch_priority
        other = 1 - priority
        counts = [0, 0]
        counts[priority] = self.threads[priority].dispatch(flushing[priority], width)
        counts[other] = self.threads[other].dispatch(flushing[other], width - counts[priority])
        self.dispatch_priority = next_dispatch_priority(priority, counts)
        total = sum(counts)
        for thread, count in zip(self.threads, counts):
            thread.stats.samples["dispatch_throughput"].add(count)
        fallback = self.threads[other]
        if counts[priority] == width and fallback.cursor < len(fallback.program):
            fallback.stats.counts["smt_no_dispatch_grant_cycles"] += 1
        self.threads[priority].stats.counts["smt_priority_cycles"] += 1
        stats = self.stats
        stats.counts["smt_priority_switches"] += self.dispatch_priority != priority
        stats.counts["smt_priority_dispatches"] += counts[priority]
        stats.counts["smt_fallback_dispatches"] += counts[other]
        stats.counts["smt_both_thread_dispatch_cycles"] += all(counts)
        stats.counts["smt_single_thread_dispatch_cycles"] += bool(total) and not all(counts)
        stats.counts["smt_unused_dispatch_slots"] += width - total
        stats.counts["dispatch_width_saturated_cycles"] += total == width
        stats.samples["dispatch_throughput"].add(total)
        stats.event(self.core.cycle, "dispatch_arbitration", priority=priority,
                    thread_0=counts[0], thread_1=counts[1], next_priority=self.dispatch_priority)

    def commit(self, flushing: list[bool]) -> list[int]:
        # Conventional CUs consume last cycle's grants before the next acceptance phase.
        local = self.pool is not None
        retired = [0, 0] if local else [thread.retire() for thread in self.threads]
        accepted = [0, 0]
        eligible = [not flush for flush in flushing]
        if not local:
            for thread, ready in zip(self.threads, eligible):
                if ready:
                    thread.authorize_head_store()
        for _ in range(self.core.commit_width):
            for tid in (self.commit_priority, 1 - self.commit_priority):
                if not eligible[tid]:
                    continue
                thread = self.threads[tid]
                if local:
                    entry = next((entry for entry in thread.rob.entries.values() if entry.done), None)
                    if entry is not None:
                        thread.local_retire(entry)
                        retired[tid] += 1
                else:
                    entry = thread.accept_one()
                    if entry is not None:
                        accepted[tid] += 1
                        eligible[tid] = not entry.timing.mispredict
                if entry is not None:
                    self.commit_priority = 1 - tid
                    break
                eligible[tid] = False
            else:
                break
        for tid, thread in enumerate(self.threads):
            if local:
                thread.record_retirement(retired[tid])
            else:
                thread.stats.samples["commit_stage_occupancy"].add(accepted[tid])
        if not local:
            self.stats.samples["commit_stage_occupancy"].add(sum(accepted))
        total = sum(retired)
        self.stats.counts["retirement_width_saturated_cycles"] += total == self.core.commit_width
        self.stats.counts["retire_blocked_cycles"] += not total and any(t.rob.entries for t in self.threads)
        return retired

    def block_phase(self, cycle: int) -> tuple[list[int], list[int]]:
        config = self.config["basic_block"]
        blocks = [t.blocks for t in self.threads]
        recovering = [bool(b.reclaim) or cycle < t.redirect_until for t, b in zip(self.threads, blocks)]
        flushed, merged = [0, 0], [0, 0]
        for tid in (self.flush_priority, 1 - self.flush_priority):
            flushed[tid] = blocks[tid].flush(cycle, config["flushing"]["width"] - sum(flushed))
        if flushed[self.flush_priority]:
            self.flush_priority = 1 - self.flush_priority
        before = sum(t.stats.samples["merge_candidates"].total for t in self.threads)
        for tid in (self.merge_priority, 1 - self.merge_priority):
            if not recovering[tid] or config["flushing"]["allow_unaffected_merges"]:
                merged[tid] = blocks[tid].merge(cycle, config["merging"]["width"] - sum(merged))
            else:
                blocks[tid].stats.samples["merge_candidates"].add(0)
        if merged[self.merge_priority]:
            self.merge_priority = 1 - self.merge_priority
        self.stats.samples["merge_candidates"].add(sum(t.stats.samples["merge_candidates"].total
                                                      for t in self.threads) - before)
        for tid, thread in enumerate(self.threads):
            thread.committed += blocks[tid].publish(cycle)
        for name, histogram, count in (("merge", "merges_per_cycle", sum(merged)),
                                       ("flush", "flushes_per_cycle", sum(flushed))):
            self.stats.samples[name + "_operations_per_cycle"].add(count)
            self.stats.histograms[histogram][count] += 1
        return merged, flushed

    def observe(self, retired: list[int], broadcasts: list[int], issued: list[int]) -> None:
        memory = self.memory
        core = self.core
        rs = Counter((e.thread_id, core.rs_for[UNIT_FOR[e.kind]]) for e in core.rs.values())
        loads = Counter(e.thread_id for e in memory.loads.values())
        outstanding = Counter(e.thread_id for e in memory.outstanding.values())
        shared = self.stats.samples
        for tid, thread in enumerate(self.threads):
            sample = thread.stats.samples
            for name, count in (("rob_occupancy", len(thread.rob.entries)),
                                ("speculative_window", thread.cursor - thread.committed),
                                ("issue_throughput", issued[tid]), ("cdb_throughput", broadcasts[tid]),
                                ("retirement_throughput", retired[tid]), ("load_buffer_occupancy", loads[tid]),
                                ("outstanding_loads", outstanding[tid]),
                                ("store_buffer_occupancy", len(memory.store_buffers[tid]))):
                sample[name].add(count)
            for station in core.rs_occupancy:
                sample["rs_occupancy:" + station].add(rs[tid, station])
            thread.observe_recovery()
        memory.observe()
        for name, count in (("rob_occupancy", sum(len(t.rob.entries) for t in self.threads)),
                            ("speculative_window", sum(t.cursor - t.committed for t in self.threads)),
                            ("issue_throughput", sum(issued)), ("cdb_throughput", sum(broadcasts)),
                            ("cdb_backlog", len(core.cdb)), ("retirement_throughput", sum(retired))):
            shared[name].add(count)
        for name, count in core.rs_occupancy.items():
            shared["rs_occupancy:" + name].add(count)
        for name, lanes in core.lanes.items():
            busy = [0, 0]
            for due, _, owner in lanes:
                if due > core.cycle:
                    busy[owner] += 1
            key = "execution_lane_busy:" + name
            for thread, count in zip(self.threads, busy):
                thread.stats.samples[key].add(count)
            shared[key].add(sum(busy))
        if self.pool is not None:
            shared["block_occupancy"].add(sum(group is not None for group in self.pool))
            shared["flush_backlog"].add(sum(len(t.blocks.reclaim) for t in self.threads))
            for bank, name in (("x", "integer"), ("f", "fp")):
                shared[name + "_prf_occupancy"].add(sum(t.blocks.prf.occupancy(bank) for t in self.threads))

    def step(self) -> None:
        core = self.core
        if self.finished:
            raise RuntimeError("SMT measurement has already ended")
        core.cycle += 1
        self.threads[1].cycle = core.cycle
        flushing = [bool(t.commit_stage and t.commit_stage[-1].timing.mispredict) for t in self.threads]
        retired = self.commit(flushing)
        if self.pool is not None:
            merged, flushed = self.block_phase(core.cycle)
        self.stats.samples["store_drain_throughput"].add(self.memory.drain(core.cycle))
        prior = [t.stats.counts["broadcasts"] for t in self.threads]
        core.broadcast(self.stats)
        broadcasts = [t.stats.counts["broadcasts"] - n for t, n in zip(self.threads, prior)]
        for thread, flush in zip(self.threads, flushing):
            if thread.rob.len5 and not flush:
                if metric := thread.rob.advance_clear(core.cycle):
                    thread.stats.counts[metric] += 1
        core.finish_execution()
        core.finish_memory()
        prior = [sum(t.stats.counts["issues:" + unit] for unit in core.enabled) for t in self.threads]
        core.select()
        issued = [sum(t.stats.counts["issues:" + unit] for unit in core.enabled) - n
                  for t, n in zip(self.threads, prior)]
        core.finish_execution()
        self.dispatch(flushing)
        self.observe(retired, broadcasts, issued)
        for tid, thread in enumerate(self.threads):
            if self.pool is not None:
                thread.observe_blocks(merged[tid], flushed[tid])
            thread.rob.released.clear()
        self.finish_cycle()

    def finish_cycle(self) -> None:
        for tid, replay in enumerate(self.replays):
            if replay.observe():
                self.completion[tid] = self.core.cycle
        self.finished = bool(self.completion[self.reference_thread])
        repeated = self.replays[1 - self.reference_thread]
        if not self.finished and repeated.completion_cycle:
            repeated.restart()

    def run(self) -> dict:
        while not self.finished:
            if self.core.cycle >= self.core.options["max_cycles"]:
                state = [(t.cursor, t.committed, t.dispatch_stall) for t in self.threads]
                raise RuntimeError(f"{self.core.architecture} SMT hit max_cycles with thread states {state}")
            self.step()
        report = self.report()
        for entry in (*self.core.rs.values(), *(e for _, e in self.core.cdb.values()),
                      *(e for _, _, e in self.core.executing), *(e for _, _, e in self.memory.responses),
                      *(e for buffer in self.memory.store_buffers for e in buffer.values())):
            entry.valid = False
        for thread in self.threads:
            thread.cancel_remaining()
        self.core.rs.clear()
        self.core.rs_occupancy.update(dict.fromkeys(self.core.rs_limits, 0))
        self.core.cdb.clear()
        self.core.executing.clear()
        self.memory.responses.clear()
        self.memory.loads.clear()
        self.memory.outstanding.clear()
        self.memory.misses = 0
        for buffer in self.memory.store_buffers:
            buffer.clear()
        if self.pool is not None:
            self.pool[:] = [None] * len(self.pool)
        return report

    def report(self) -> dict:
        # Instantaneous shared occupancies were sampled at the core. Pool only instruction-level samples.
        combined = Metrics(False)
        combined.events = self.stats.events
        combined.counts.update(self.stats.counts)
        combined.samples.update(self.stats.samples)
        combined.histograms.update(self.stats.histograms)
        shared_samples = set(self.stats.samples)
        shared_counts = set(self.stats.counts)
        shared_histograms = set(self.stats.histograms)
        per_thread = []
        dispatched = sum(t.stats.counts["dispatched"] for t in self.threads)
        elapsed = self.core.cycle
        for tid, thread in enumerate(self.threads):
            progress = self.replays[tid].progress()
            row = thread.report(committed=progress["total_committed"])
            row.update(progress, total_cycles=elapsed, measured_cycles=elapsed)
            row.pop("events", None)
            for key in ("cdb_contention_cycles", "cdb_deferred_requests"):
                row["counts"].pop(key, None)
            if thread.blocks:
                row["counts"]["physical_registers_reclaimed"] = thread.blocks.prf.freed
                combined.counts["physical_registers_reclaimed"] += thread.blocks.prf.freed
            row.update(thread_id=tid, smt_mode="enabled", completion_cycle=self.completion[tid],
                       dispatch_share=thread.stats.counts["dispatched"] / dispatched if dispatched else 0)
            per_thread.append(row)
            for name, count in thread.stats.counts.items():
                if name not in shared_counts and name != "smt_priority_cycles":
                    combined.counts[name] += count
            for name, sample in thread.stats.samples.items():
                if name not in shared_samples:
                    total = combined.samples[name]
                    total.count += sample.count
                    total.total += sample.total
                    total.peak = max(total.peak, sample.peak)
            for name, histogram in thread.stats.histograms.items():
                if name not in shared_histograms:
                    combined.histograms[name].update(histogram)
        report = self.core.report(combined, sum(t["committed"] for t in per_thread))
        ref = self.reference_thread
        repeated = 1 - ref
        report.update(smt_mode="enabled", threads=per_thread, measurement_policy="reference_completion",
                      reference_thread=ref, reference_benchmark=self.replays[ref].name,
                      repeated_thread=repeated, repeated_benchmark=self.replays[repeated].name,
                      measured_cycles=elapsed, total_cycles=elapsed, workloads=[r.name for r in self.replays],
                      total_committed=report["committed"], measured_committed=report["committed"],
                      completed_iterations=sum(t["completed_iterations"] for t in per_thread),
                      measured_completed_iterations=sum(t["completed_iterations"] for t in per_thread))
        return report
