"""Synthetic workloads and architecture-independent timing samples."""

from dataclasses import dataclass
from random import Random

from .config import Distribution, UNIT_FOR, distribution
from .spike import read_spike
from .instruction import Instruction, Register


@dataclass(frozen=True)
class Timing:
    execution: int
    cache: str
    memory: int
    mispredict: bool
    recovery: int


def synthetic(config: dict, seed: int) -> list[Instruction]:
    kinds, weights = zip(*config["mix"].items())
    mix, registers, control = (Random(f"{seed}:{stream}") for stream in ("mix", "registers", "control"))
    dep = config["dependencies"]
    distance = distribution(dep["distance"])
    latest: dict[Register, int] = {}
    loads: dict[Register, int] = {}
    previous: Register | None = None
    program = []
    pc = 0x10000
    for i, kind in enumerate(mix.choices(kinds, weights, k=config["instructions"])):
        bank = "f" if kind == "fp" else "x"

        def random_reg() -> Register:
            if registers.random() < dep["register_locality"]:
                return bank, registers.randint(1, dep["hot_registers"])
            return bank, registers.randint(int(bank == "x"), 31)

        destination = None if kind in ("branch", "store") else random_reg()
        sources: list[Register] = []
        if dep["max_count"] and registers.random() < dep["probability"]:
            count = registers.randint(1, dep["max_count"])
            if previous is not None and registers.random() < dep["chain_probability"]:
                sources.append(previous)
            if loads and len(sources) < count and registers.random() < dep["load_density"]:
                load = registers.choice(list(loads))
                if load not in sources:
                    sources.append(load)
            while len(sources) < count:
                target = i - distance.sample(registers)
                available = [reg for reg in latest if reg not in sources]
                if not available:
                    break
                sources.append(min(available, key=lambda reg: abs(latest[reg] - target)))
        if destination is not None:
            latest[destination] = i
            loads.pop(destination, None)
            if kind == "load":
                loads[destination] = i
        previous = destination
        address = control.randrange(config["memory_addresses"]) * 8 if kind in ("load", "store") else None
        taken = (kind == "jump" or control.random() < config["branch_taken_probability"]
                 if kind in ("branch", "jump") else None)
        next_pc = pc + (16 if taken else 4)
        program.append(Instruction(kind, tuple(sources), destination, pc, address,
                                   8 if address is not None else 0, taken, next_pc))
        pc = next_pc
    return program


def make_workload(config: dict, seed: int) -> list[Instruction]:
    program = load_program(config["workload"], seed)
    validate_program(program, config["execution"])
    return program


def load_program(w: dict, seed: int) -> list[Instruction]:
    return (synthetic(w, seed) if w["type"] == "random" else
            read_spike(w["trace"], w["trace_hart"], w["trace_skip"], w["instructions"],
                       start_pc=w["trace_start_pc"], stop_at_self_jump=w["trace_stop_at_self_jump"]))


def validate_program(program: list[Instruction], execution: dict) -> None:
    for insn in program:
        unit = UNIT_FOR[insn.kind]
        if not execution["units"][unit]["count"]:
            raise ValueError(f"instruction at PC {insn.pc:#x} requires enabled execution unit {unit}")


def sample_timing(program: list[Instruction], config: dict, seed: int, thread_id: int = 0,
                  *, benchmark: str | None = None, iteration: int = 0) -> list[Timing]:
    if benchmark is not None or iteration:
        seed = Random(f"LEN5 replay {seed} {benchmark!r} {thread_id} {iteration}").getrandbits(128)
    elif thread_id:
        seed = Random(f"LEN5 SMT {seed} {thread_id}").getrandbits(128)
    units = {name: distribution(eu["latency"], minimum=0)
             for name, eu in config["execution"]["units"].items()}
    memory, branch = config["memory"], config["branch"]
    dram = distribution(memory["dram_latency"])
    queue = distribution(memory["queue_delay"], minimum=0)
    store = distribution(memory["store_latency"])
    recovery = distribution(branch["recovery_latency"], minimum=0)
    streams = [Random(f"{seed}:{name}") for name in
               ("execution", "cache", "dram", "queue", "store", "mispredict", "recovery")]

    def draw(spec: Distribution, key: int) -> int:
        return spec.low if spec.low == spec.high else spec.sample(Random(key))

    timings = []
    for insn in program:
        # Advance every stream once so keys remain independent of instruction class.
        eu, cache_key, ram, delay, write, pred, redirect = (rng.getrandbits(64) for rng in streams)
        level, cycles = "", 0
        if insn.kind == "load":
            cache = Random(cache_key)
            for level in ("l1", "l2", "llc"):
                cycles += memory[level]["latency"]
                if cache.random() >= memory[level]["miss_probability"]:
                    break
            else:
                level = "dram"
                cycles += draw(dram, ram)
            cycles += draw(queue, delay)
        elif insn.kind == "store":
            cycles = draw(store, write) + draw(queue, delay)
        timings.append(Timing(draw(units[UNIT_FOR[insn.kind]], eu), level, cycles,
                              insn.control and Random(pred).random() < branch["misprediction_probability"],
                              draw(recovery, redirect) if insn.control else 0))
    return timings
