"""Speculative circular-buffer return address stack with pointer-and-saved-top recovery.

Each entry holds a full return address, a valid bit and a write generation. A checkpoint is only
the stack pointer, the live-entry count, the logical depth, the push generation counter and the
saved top entry. Recovery restores the pointer and top entry, then invalidates live entries that
younger (squashed) pushes overwrote; those cannot be reconstructed and fall back to the BTBs.
Hardware would keep the generation as a short wrapping tag compared against the checkpoint.
"""

from collections import Counter
from dataclasses import dataclass

from .config import UNLIMITED

LINK = (1, 5)


@dataclass(frozen=True, slots=True)
class Checkpoint:
    sp: int
    count: int
    logical: int
    generation: int
    top_address: int
    top_valid: bool
    top_generation: int


def ras_action(kind: str, rd: int | None, rs1: int | None) -> str:
    """RISC-V hint table (Unprivileged ISA, JAL/JALR): push, pop, pop_push or none."""
    if kind == "jal":
        return "push" if rd in LINK else "none"
    if kind != "jalr":
        return "none"
    rd_link, rs1_link = rd in LINK, rs1 in LINK
    if not rd_link:
        return "pop" if rs1_link else "none"
    if not rs1_link or rd == rs1:
        return "push"
    return "pop_push"


class RAS:
    def __init__(self, depth: int | str, stats: Counter):
        self.unbounded = depth == UNLIMITED
        self.depth = None if self.unbounded else depth
        self.address: dict[int, int] = {}
        self.valid: dict[int, bool] = {}
        self.written: dict[int, int] = {}
        self.sp = -1 if self.unbounded else self.depth - 1
        self.count = 0          # Live entries inside the circular buffer (bounded by depth).
        self.logical = 0        # Architectural call depth along this speculative path.
        self.generation = 0     # Monotonic push counter; each written entry keeps its value.
        self.stats = stats

    def _wrap(self, index: int) -> int:
        return index if self.unbounded else index % self.depth

    def checkpoint(self) -> Checkpoint:
        return Checkpoint(self.sp, self.count, self.logical, self.generation,
                          self.address.get(self.sp, 0), self.valid.get(self.sp, False),
                          self.written.get(self.sp, 0))

    def physically_valid(self) -> int:
        return sum(self.valid.values())

    def top(self) -> tuple[int | None, str]:
        """Prediction for a return: (address, "") when usable, else (None, fallback reason)."""
        if not self.count:
            return None, "overflow_loss" if self.logical else "underflow"
        if not self.valid.get(self.sp, False):
            return None, "corruption"
        return self.address[self.sp], ""

    def push(self, address: int) -> None:
        self.stats["ras_pushes"] += 1
        sp = self._wrap(self.sp + 1)
        if not self.unbounded and sp == 0 and self.sp == self.depth - 1:
            self.stats["ras_wraparounds"] += 1
        if self.depth is not None and self.count == self.depth:
            self.stats["ras_overflows"] += 1
            if self.valid.get(sp, False):
                self.stats["ras_overwritten_addresses"] += 1
        else:
            self.count += 1
        self.generation += 1
        self.sp = sp
        self.address[sp], self.valid[sp], self.written[sp] = address, True, self.generation
        self.logical += 1

    def pop(self) -> None:
        self.stats["ras_pops"] += 1
        if not self.count:
            self.stats["ras_underflows" if not self.logical else "ras_overflow_losses"] += 1
        else:
            # The entry is left intact so recovery of an older checkpoint can still read it.
            self.sp = self._wrap(self.sp - 1)
            self.count -= 1
        self.logical = max(0, self.logical - 1)

    def apply(self, action: str, link: int) -> None:
        if action in ("pop", "pop_push"):
            self.pop()
        if action in ("push", "pop_push"):
            self.push(link)

    def restore(self, saved: Checkpoint, invalidate: bool = True) -> int:
        """Restore a checkpoint and return how many corrupted live entries were invalidated."""
        self.stats["ras_recoveries"] += 1
        top_lost = self.written.get(saved.sp, 0) != saved.top_generation
        invalidated = 0
        if invalidate:
            for offset in range(1, saved.count):
                index = self._wrap(saved.sp - offset)
                # Younger pushes overwrote this older live entry; its address cannot be recovered.
                if self.written.get(index, 0) > saved.generation and self.valid.get(index, False):
                    self.valid[index] = False
                    invalidated += 1
        self.sp, self.count, self.logical = saved.sp, saved.count, saved.logical
        self.address[saved.sp], self.valid[saved.sp] = saved.top_address, saved.top_valid
        self.written[saved.sp] = saved.top_generation
        if top_lost and saved.top_valid:
            self.stats["ras_saved_top_restored"] += 1
        self.stats["ras_entries_invalidated"] += invalidated
        return invalidated
