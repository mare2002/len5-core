"""Iteration boundaries and measurement accounting for one hardware context."""

from .simulator import Simulator
from .workload import sample_timing


class Replay:
    def __init__(self, thread: Simulator, name: str, sample_name: str | None, seed: int):
        self.thread = thread
        self.name = name
        self.sample_name = sample_name
        self.seed = seed
        self.iteration = 0
        self.completed = 0
        self.completion_cycle = 0
        self.set_iteration()

    def set_iteration(self) -> None:
        self.thread.iteration = self.thread.stats.iteration = self.iteration

    def observe(self) -> bool:
        thread = self.thread
        if (self.completion_cycle or thread.committed != len(thread.program)
                or thread.memory.store_buffers[thread.thread_id] or (thread.blocks and thread.blocks.reclaim)):
            return False
        assert not (thread.rob.entries or thread.commit_stage or thread.readers or thread.pending_recovery)
        assert not thread.blocks or not thread.blocks.reserved
        assert all(entry.thread_id != thread.thread_id for entry in thread.memory.loads.values())
        thread.verify_registers()
        self.completed += 1
        self.completion_cycle = thread.cycle
        thread.stats.event(thread.cycle, "iteration_complete", benchmark=self.name)
        return True

    def restart(self) -> None:
        thread = self.thread
        self.iteration += 1
        self.set_iteration()
        thread.restart(sample_timing(thread.program, thread.config, self.seed,
                                     thread.thread_id,
                                     benchmark=self.sample_name, iteration=self.iteration))
        self.completion_cycle = 0

    def progress(self) -> dict:
        partial = 0 if self.completion_cycle else self.thread.committed
        committed = self.completed * len(self.thread.program) + partial
        return {"benchmark": self.name, "iteration": self.iteration, "completed_iterations": self.completed,
                "measured_completed_iterations": self.completed, "partial_iteration_committed": partial,
                "instructions_per_iteration": len(self.thread.program), "total_committed": committed,
                "measured_committed": committed}
