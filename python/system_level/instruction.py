"""Decoded instruction metadata shared by both workload sources."""

from dataclasses import dataclass


Register = tuple[str, int]


@dataclass(frozen=True)
class Instruction:
    kind: str
    sources: tuple[Register, ...] = ()
    destination: Register | None = None
    pc: int = 0
    address: int | None = None
    size: int = 0
    taken: bool | None = None
    next_pc: int | None = None
    encoding: int | None = None
    mnemonic: str = ""

    def __post_init__(self):
        object.__setattr__(self, "sources", tuple(reg for reg in self.sources if reg != ("x", 0)))
        if self.destination == ("x", 0):
            object.__setattr__(self, "destination", None)

    @property
    def control(self) -> bool:
        return self.kind in ("branch", "jump")

    @property
    def raw_rd(self) -> int:
        if self.encoding is not None and self.encoding & 3 == 3:
            return (self.encoding >> 7) & 31
        return self.destination[1] if self.destination is not None else 0
