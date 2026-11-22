"""Decode the instruction and commit lines from LEN5's make spike-trace target."""

from dataclasses import replace
from pathlib import Path
import re
from typing import Iterator

from .instruction import Instruction


PREFIX = r"^\s*core\s+(\d+):\s+"
FETCH = re.compile(PREFIX + r"(0x[0-9a-f]+)\s+\((0x[0-9a-f]+)\)\s*(\S+)?", re.I)
COMMIT = re.compile(PREFIX + r"\d+\s+(0x[0-9a-f]+)\s+\((0x[0-9a-f]+)\)(.*)", re.I)
MEM = re.compile(r"\bmem\s+(0x[0-9a-f]+)", re.I)


def x(index: int) -> tuple[str, int]:
    return "x", index


def f(index: int) -> tuple[str, int]:
    return "f", index


def integer_register_op(op: int, funct: int, funct7: int) -> bool:
    if funct7 == 0:
        return op == 0x33 or funct in (0, 1, 5)
    if funct7 == 1:
        return op == 0x33 or funct in (0, 4, 5, 6, 7)
    return funct7 == 32 and funct in (0, 5)


def integer_immediate_op(op: int, funct: int, word: int) -> bool:
    if funct not in (1, 5):
        return op == 0x13 or funct == 0
    high = word >> (25 if op == 0x1b else 26)
    return high == 0 or (funct == 5 and high == (32 if op == 0x1b else 16))


def decode(pc: int, word: int, mnemonic: str) -> Instruction:
    if word > 0xffffffff or word & 31 == 31:
        raise unsupported(pc, word, mnemonic)
    if word & 3 != 3:
        if word > 0xffff:
            raise unsupported(pc, word, mnemonic)
        return compressed(pc, word, mnemonic)
    op, rd, funct = word & 127, (word >> 7) & 31, (word >> 12) & 7
    a, b, c = (word >> 15) & 31, (word >> 20) & 31, (word >> 27) & 31
    funct7 = word >> 25
    kind, sources, destination, size = "alu", (), None, 0
    if op in (0x33, 0x3b) and integer_register_op(op, funct, funct7):
        if funct7 == 1:
            kind = "mul" if funct < 4 else "div"
        sources, destination = (x(a), x(b)), x(rd)
    elif op in (0x13, 0x1b) and integer_immediate_op(op, funct, word):
        sources, destination = (x(a),), x(rd)
    elif op in (0x17, 0x37):
        destination = x(rd)
    elif op in (0x6f, 0x67) and (op == 0x6f or funct == 0):
        kind, sources, destination = "jump", ((x(a),) if op == 0x67 else ()), x(rd)
    elif op == 0x63 and funct in (0, 1, 4, 5, 6, 7):
        kind, sources = "branch", (x(a), x(b))
    elif (op == 0x03 and funct < 7) or (op == 0x07 and funct in (2, 3)):
        kind, sources, destination, size = "load", (x(a),), (f(rd) if op == 7 else x(rd)), 1 << (funct & 3)
    elif (op == 0x23 and funct < 4) or (op == 0x27 and funct in (2, 3)):
        kind, sources, size = "store", (x(a), f(b) if op == 0x27 else x(b)), 1 << funct
    elif op in (0x43, 0x47, 0x4b, 0x4f) and (funct7 & 3) in (0, 1):
        kind, sources, destination = "fp", (f(a), f(b), f(c)), f(rd)
    elif op == 0x53 and (funct7 & 3) in (0, 1):
        kind = "fp"
        operation = funct7 >> 2
        if (operation in (0, 1, 2, 3) or (operation in (4, 20) and funct <= 2)
                or (operation == 5 and funct <= 1)):
            sources, destination = (f(a), f(b)), (x(rd) if operation == 20 else f(rd))
        elif ((operation == 8 and b == 1 - (funct7 & 3)) or (operation == 11 and b == 0)
              or (operation == 24 and b <= 3) or (operation == 28 and b == 0 and funct <= 1)):
            sources, destination = (f(a),), (x(rd) if operation in (24, 28) else f(rd))
        elif (operation == 26 and b <= 3) or (operation == 30 and b == funct == 0):
            sources, destination = (x(a),), f(rd)
        else:
            raise unsupported(pc, word, mnemonic)
    else:
        raise unsupported(pc, word, mnemonic)
    return Instruction(kind, sources, destination, pc, size=size, encoding=word, mnemonic=mnemonic)


def unsupported(pc: int, word: int, mnemonic: str) -> ValueError:
    return ValueError(f"unsupported Spike instruction at PC {pc:#x}: {word:#x} {mnemonic}")


def compressed(pc: int, word: int, mnemonic: str) -> Instruction:
    quadrant, funct = word & 3, word >> 13
    rd, rs2 = (word >> 7) & 31, (word >> 2) & 31
    a, b = x(8 + (rd & 7)), 8 + (rs2 & 7)
    kind, sources, destination, size = "alu", (), None, 0
    if quadrant == 0 and funct == 0 and word & 0x1fe0:
        sources, destination = (x(2),), x(b)
    elif quadrant in (0, 2) and funct in (1, 2, 3, 5, 6, 7):
        base = x(2) if quadrant == 2 else a
        fp = funct in (1, 5)
        size = 4 if funct in (2, 6) else 8
        if funct < 4:
            target = rd if quadrant == 2 else b
            if not fp and target == 0:
                raise unsupported(pc, word, mnemonic)
            kind, sources, destination = "load", (base,), (f(target) if fp else x(target))
        else:
            value = rs2 if quadrant == 2 else b
            kind, sources = "store", (base, f(value) if fp else x(value))
    elif quadrant == 1 and funct in (0, 1):
        sources, destination = (x(rd),), x(rd)
    elif quadrant == 1 and funct in (2, 3):
        sources, destination = ((x(2),) if funct == 3 and rd == 2 else ()), x(rd)
    elif quadrant == 1 and funct == 4:
        sources = (a, x(b)) if (word >> 10) & 3 == 3 else (a,)
        destination = a
    elif quadrant == 1 and funct == 5:
        kind = "jump"
    elif quadrant == 1 and funct in (6, 7):
        kind, sources = "branch", (a,)
    elif quadrant == 2 and funct == 0:
        sources, destination = (x(rd),), x(rd)
    elif quadrant == 2 and funct == 4:
        upper = bool(word & (1 << 12))
        if rs2:
            sources, destination = ((x(rd), x(rs2)) if upper else (x(rs2),)), x(rd)
        elif rd:
            kind, sources, destination = "jump", (x(rd),), (x(1) if upper else None)
        else:
            raise unsupported(pc, word, mnemonic)
    else:
        raise unsupported(pc, word, mnemonic)
    return Instruction(kind, sources, destination, pc, size=size, encoding=word, mnemonic=mnemonic)


def records(path: str | Path, hart: int) -> Iterator[tuple[int, int, str, int | None, bool]]:
    pending: tuple[int, int, str] | None = None
    with Path(path).open() as stream:
        for line in stream:
            match = FETCH.match(line)
            if match and int(match[1]) == hart:
                if pending:
                    yield *pending, None, False
                pending = (int(match[2], 16), int(match[3], 16), match[4] or "")
                continue
            match = COMMIT.match(line)
            if match and int(match[1]) == hart:
                pc, word = int(match[2], 16), int(match[3], 16)
                if pending and pending[:2] != (pc, word):
                    yield *pending, None, False
                    pending = None
                mem = MEM.search(match[4])
                yield pc, word, pending[2] if pending else "", int(mem[1], 16) if mem else None, True
                pending = None
    if pending:
        yield *pending, None, False


def read_spike(path: str | Path, hart: int = 0, skip: int = 0, limit: int | None = None,
               *, start_pc: int | None = None, stop_at_self_jump: bool = False) -> list[Instruction]:
    """Pair disassembly/commit lines and retain the selected dynamic instruction region."""
    started = start_pc is None
    saw_commits = False
    uncommitted: Instruction | None = None
    program = []
    previous = None
    for pc, word, mnemonic, address, confirmed in records(path, hart):
        saw_commits |= confirmed
        if skip:
            skip -= 1
            continue
        if not started:
            if pc != start_pc:
                continue
            started = True
        if previous is not None:
            length = 2 if previous.encoding & 3 != 3 else 4
            taken = pc != previous.pc + length if previous.kind == "branch" else previous.taken
            program[-1] = replace(previous, next_pc=pc, taken=taken)
        if (stop_at_self_jump and word == 0x0000006f) or len(program) == limit:
            break
        insn = decode(pc, word, mnemonic)
        previous = replace(insn, address=address, taken=True if insn.kind == "jump" else None)
        if not confirmed and uncommitted is None:
            uncommitted = previous
        program.append(previous)
    if saw_commits and uncommitted is not None:
        raise ValueError(f"{path}: no commit record at PC {uncommitted.pc:#x}; check for traps or a truncated trace")
    if not program:
        start = f" at or after PC {start_pc:#x}" if start_pc is not None else " in selected region"
        raise ValueError(f"{path}: no Spike instructions for hart {hart}{start}")
    return program
