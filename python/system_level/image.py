"""Static instruction image for fetch: ELF bytes when available, otherwise the trace's own PCs.

Wrong-path fetch needs instructions that the correct-path trace never executed. The ELF supplies
their encodings. Without an ELF (synthetic workloads), an unknown PC decodes as a 4-byte
non-control filler instruction with no register operands; this is a documented approximation.
"""

from dataclasses import dataclass, replace
from pathlib import Path
import struct

from .instruction import Instruction
from .ras import ras_action
from .spike import decode


def sign(value: int, bits: int) -> int:
    return value - (1 << bits) if value >> (bits - 1) & 1 else value


@dataclass(frozen=True, slots=True)
class Static:
    instruction: Instruction
    size: int
    cfi: str | None          # branch | jal | jalr
    target: int | None       # Direct target from the encoding
    action: str              # RAS hint action
    known: bool              # False for synthesized filler

    @property
    def pc(self) -> int:
        return self.instruction.pc


def control(insn: Instruction) -> tuple[str | None, int | None, int | None, int | None]:
    """Control-flow class, direct target, rd and rs1 from the encoding (synthetic: +16 targets)."""
    pc, word = insn.pc, insn.encoding
    if insn.kind not in ("branch", "jump"):
        return None, None, None, None
    if word is None:
        rd = insn.destination[1] if insn.destination else 0
        return ("branch", pc + 16, None, None) if insn.kind == "branch" else ("jal", pc + 16, rd, None)
    if word & 3 == 3:
        op, rd, rs1 = word & 127, (word >> 7) & 31, (word >> 15) & 31
        if op == 0x63:
            imm = ((word >> 31) & 1) << 12 | ((word >> 25) & 0x3f) << 5 | ((word >> 8) & 0xf) << 1 | ((word >> 7) & 1) << 11
            return "branch", pc + sign(imm, 13), None, None
        if op == 0x6f:
            imm = ((word >> 31) & 1) << 20 | ((word >> 21) & 0x3ff) << 1 | ((word >> 20) & 1) << 11 | ((word >> 12) & 0xff) << 12
            return "jal", pc + sign(imm, 21), rd, None
        return "jalr", None, rd, rs1
    quadrant, funct = word & 3, word >> 13
    if quadrant == 1 and funct == 5:
        e = word
        imm = (((e >> 12) & 1) << 11 | ((e >> 11) & 1) << 4 | ((e >> 9) & 3) << 8 | ((e >> 8) & 1) << 10
               | ((e >> 7) & 1) << 6 | ((e >> 6) & 1) << 7 | ((e >> 3) & 7) << 1 | ((e >> 2) & 1) << 5)
        return "jal", pc + sign(imm, 12), 0, None
    if quadrant == 1 and funct in (6, 7):
        e = word
        imm = ((e >> 12) & 1) << 8 | ((e >> 10) & 3) << 3 | ((e >> 5) & 3) << 6 | ((e >> 3) & 3) << 1 | ((e >> 2) & 1) << 5
        return "branch", pc + sign(imm, 9), None, None
    # c.jr / c.jalr
    return "jalr", None, 1 if word & (1 << 12) else 0, (word >> 7) & 31


def static(insn: Instruction, known: bool = True) -> Static:
    size = 2 if insn.encoding is not None and insn.encoding & 3 != 3 else 4
    cfi, target, rd, rs1 = control(insn)
    return Static(insn, size, cfi, target, ras_action(cfi or "", rd, rs1), known)


def load_elf(path: str | Path) -> dict[int, bytes]:
    """Loadable segments of a little-endian ELF64 file, keyed by virtual address."""
    data = Path(path).read_bytes()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError(f"{path}: expected a little-endian ELF64 executable")
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    segments = {}
    for i in range(phnum):
        kind, _, offset, vaddr, _, filesz = struct.unpack_from("<IIQQQQ", data, phoff + i * phentsize)
        if kind == 1 and filesz:
            segments[vaddr] = data[offset:offset + filesz]
    return segments


class Image:
    def __init__(self, program: list[Instruction], elf: str | None = None):
        self.cache: dict[int, Static] = {}
        self.addresses: dict[int, int] = {}
        for insn in program:
            if insn.pc not in self.cache:
                self.cache[insn.pc] = static(replace(insn, address=None, taken=None, next_pc=None))
            if insn.address is not None:
                self.addresses[insn.pc] = insn.address
        self.segments = load_elf(elf) if elf else {}

    def _word(self, pc: int) -> int | None:
        for base, blob in self.segments.items():
            if base <= pc and pc + 2 <= base + len(blob):
                low = int.from_bytes(blob[pc - base:pc - base + 2], "little")
                if low & 3 != 3:
                    return low
                if pc + 4 <= base + len(blob):
                    return int.from_bytes(blob[pc - base:pc - base + 4], "little")
        return None

    def at(self, pc: int) -> Static:
        item = self.cache.get(pc)
        if item is None:
            word = self._word(pc)
            insn = None
            if word is not None:
                try:
                    insn = decode(pc, word, "")
                except ValueError:
                    # Unsupported encodings (CSR, fences, data) cannot redirect fetch; treat as ALU filler.
                    insn = Instruction("alu", pc=pc, encoding=word)
            item = static(insn, True) if insn is not None else static(Instruction("alu", pc=pc), False)
            self.cache[pc] = item
        return item
