"""Dynamic state keyed by monotonic allocation identity, independent of ROB slot."""

from dataclasses import dataclass, field

from .instruction import Instruction, Register
from .workload import Timing


@dataclass
class Version:
    uid: int
    ready: bool = False


@dataclass
class Entry:
    uid: int
    index: int
    slot: int
    instruction: Instruction
    timing: Timing
    dispatched: int
    waiting: dict[int, Register]
    operands: dict[Register, int]
    ready_since: int
    version: Version | None = None
    physical: tuple[str, int] | None = None
    checkpoint: dict[Register, Version] | None = None
    valid: bool = True
    done: bool = False
    completed: int = 0
    issued: int = 0
    prepared: int = 0
    faulted: bool = False
    authorized: int = 0
    serviced: bool = False
    launched: bool = False
    conflict_seen: bool = False
    mem_clear: bool = False
    result: int = 0
    thread_id: int = 0
    thread_sequence: int = 0
    iteration: int | None = None

    @property
    def kind(self) -> str:
        return self.instruction.kind
