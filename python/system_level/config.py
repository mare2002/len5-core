"""Configuration defaults and validation for simulation and sweeps."""

from copy import deepcopy
from dataclasses import dataclass
from math import inf, isfinite
from pathlib import Path
from random import Random
import re
from sys import float_info

import yaml

UNLIMITED = "unlimited"
VARIANT_SEPARATOR = "@"


class Names(tuple):
    """Architecture-name tuple whose membership test ignores an ``@frontend_variant`` suffix."""

    def __contains__(self, name: object) -> bool:
        if isinstance(name, str):
            name = name.partition(VARIANT_SEPARATOR)[0]
        return tuple.__contains__(self, name)


def limit(value: int | str | None) -> float:
    """Numeric capacity or bandwidth; ``unlimited`` becomes infinity (never a large finite constant)."""
    return inf if value == UNLIMITED else value


def head(items: list, count: float) -> list:
    return items if count == inf else items[:count]


def upto(count: float):
    """Iteration budget for a per-cycle bandwidth that may be unlimited."""
    from itertools import count as forever
    return forever() if count == inf else range(count)


DEFAULT_ARCHITECTURES = ("normal_ooo", "len5_ooo_commit", "basic_block_ooo_commit")
IDEAL = "ideal_commit"
IDEAL_OOO = "ideal_commit_ooo"
UNIFIED_SUFFIX = "_unified_rs"
BRANCH_FORWARDING_SUFFIX = "_unified_rs_branch_forwarding"
SEPARATE_ARCHITECTURES = (*DEFAULT_ARCHITECTURES, IDEAL, IDEAL_OOO)
UNIFIED_ARCHITECTURES = tuple(name + UNIFIED_SUFFIX for name in SEPARATE_ARCHITECTURES)
BRANCH_FORWARDING_ARCHITECTURES = tuple(name + BRANCH_FORWARDING_SUFFIX for name in SEPARATE_ARCHITECTURES)
WRAPPER_ARCHITECTURES = (*UNIFIED_ARCHITECTURES, *BRANCH_FORWARDING_ARCHITECTURES)
ARCHITECTURES = Names((*SEPARATE_ARCHITECTURES, *WRAPPER_ARCHITECTURES))
WRAPPER_ARCHITECTURES = Names(WRAPPER_ARCHITECTURES)
BRANCH_FORWARDING_ARCHITECTURES = Names(BRANCH_FORWARDING_ARCHITECTURES)
UNIFIED_ARCHITECTURES = Names(UNIFIED_ARCHITECTURES)


def commit_architecture(name: str) -> str:
    return backend_name(name).removesuffix(BRANCH_FORWARDING_SUFFIX).removesuffix(UNIFIED_SUFFIX)


def backend_name(name: str) -> str:
    return name.partition(VARIANT_SEPARATOR)[0]


def frontend_variant(name: str) -> str | None:
    return name.partition(VARIANT_SEPARATOR)[2] or None


IDEAL_ARCHITECTURES = Names(name for name in ARCHITECTURES
                            if commit_architecture(name) in (IDEAL, IDEAL_OOO))
BLOCK_ARCHITECTURES = Names(name for name in ARCHITECTURES
                            if commit_architecture(name) in (DEFAULT_ARCHITECTURES[2], IDEAL_OOO))
SMT_MODES = ("disabled", "enabled", "both")
KINDS = ("alu", "mul", "div", "branch", "jump", "load", "store", "fp")
INTEGER_UNITS = ("alu", "mul", "div")
UNIFIED_RS = "unified_int"
UNIT_FOR = {**{kind: kind for kind in KINDS[:3]}, "branch": "branch", "jump": "branch",
            "load": "lsu", "store": "lsu", "fp": "fp"}


def fixed(value: int) -> dict:
    return {"type": "fixed", "value": value}


def unit(count: int, latency: int, interval: int, rs: int, width: int) -> dict:
    return {"count": count, "latency": fixed(latency), "initiation_interval": interval,
            "rs_size": rs, "rs_issue_width": width}


PREDICTORS = ("l0_only", "l1_bim", "gshare", "tage", "len5", "ideal")
# BOOM-like TAGE geometry: per-table entries, partial tag width and global history length.
TAGE_TABLES = [{"entries": e, "tag_bits": t, "history_length": h}
               for e, t, h in ((256, 7, 2), (256, 7, 4), (512, 8, 8), (512, 8, 16), (256, 9, 32), (256, 9, 64))]

FRONTEND = {
    "enabled": False,
    "predictor": "tage",
    # Named configuration overlays selectable as ``<architecture>@<name>`` in architectures.enabled.
    "variants": {},
    "fetch_width": 4,               # RTL LEN5_MULTIPLE_ISSUES: instructions per aligned fetch block
    "instruction_bytes": 4,         # Slot size used to align fetch blocks
    "redirect_delay": 2,            # RTL branch_cu MIS -> MIS_LOAD_PC + issue_cu S_FLUSH
    "wrong_path": "frontend",       # bubble | frontend | full
    "unresolved_indirect": "fallthrough",
    "pipeline": {"predecode_latency": 1, "output_latency": 1, "stage_capacity": 2},
    "memory_fifo": {"depth": 8, "drain_on_flush": True},
    "icache": {"perfect": False, "l1": {"miss_probability": .02, "latency": 1},
               "l2": {"miss_probability": .2, "latency": 8}, "llc": {"miss_probability": .3, "latency": 20},
               "dram_latency": {"type": "uniform", "min": 40, "max": 80}, "queue_delay": fixed(0),
               "max_outstanding": UNLIMITED, "request_width": 1, "response_width": 1},
    "issue_queue": {"capacity": 16, "enqueue_width": UNLIMITED},
    "history": {"update": "per_branch", "stale_policy": "relookup"},
    "l0_btb": {"enabled": True, "entries": 16, "ways": 16, "tag_bits": 12, "offset_bits": 13,
               "counter_bits": 2, "replacement": "lru", "latency": 0, "organization": "per_slot"},
    "l1_btb": {"sets": 128, "ways": 2, "tag_bits": 13, "offset_bits": 13, "extended_entries": 128,
               "replacement": "lru", "latency": 2, "organization": "per_slot",
               "read_ports": 1, "write_ports": 1, "single_port": False},
    "bim": {"entries": 2048, "counter_bits": 2, "read_ports": 1, "write_ports": 1, "single_port": False},
    "gshare": {"entries": 4096, "history_length": 16, "counter_bits": 2, "latency": 1, "start": "response",
               "organization": "per_slot", "history_compression": "xor_fold", "history": "speculative",
               "train_index": "saved", "bypass_entries": 4, "read_ports": 1, "write_ports": 1,
               "single_port": False},
    "tage": {"tables": TAGE_TABLES, "counter_bits": 3, "useful_bits": 2, "useful_reset_period": 4096,
             "use_alt_on_weak": True, "latency": 1, "start": "response", "bypass_entries": 4,
             "read_ports": 1, "write_ports": 1, "single_port": False},
    "ras": {"enabled": True, "depth": 16, "access_stage": "predecode", "organization": "circular",
            "address_format": "full_address", "speculative": True, "perfect": False,
            "recovery": {"mode": "pointer_and_saved_top", "invalidate_corrupted_entries": True,
                         "full_stack_checkpoint": False},
            "target_priority": ["ras", "l1_btb", "l0_btb"]},
    "btq": {"capacity": 32, "training_width": 1, "coalesce": True},
    "smt_predictors": "shared",
}

# Default dispatch, CDB, commit and per-station issue width: the fetch width (RTL has no total issue limit).
WIDTH = FRONTEND["fetch_width"]
DEFAULTS = {
    "architectures": {"enabled": list(DEFAULT_ARCHITECTURES)},
    "simulation": {"mode": "event_driven", "seed": 42, "dispatch_width": WIDTH,
                   "cdb_width": None, "commit_width": None, "rob_size": 32,
                   "max_cycles": 1_000_000, "cdb_policy": "oldest_completed", "record_events": False,
                   "warmup_instructions": 0,
                   "parallel": {"workers": "auto"}},
    "smt": {"mode": "disabled", "threads": 2, "initial_priority": 0,
            "dispatch_policy": "majority_feedback", "tie_policy": "retain_priority",
            "workloads": {"thread_0": None, "thread_1": None}, "benchmark_pairs": [],
            "measurement": {"policy": "reference_completion", "reference_thread": "auto"}},
    "execution": {"units": {"alu": unit(2, 1, 1, 12, WIDTH), "mul": unit(1, 3, 1, 6, WIDTH),
                            "div": {**unit(1, 8, 8, 4, WIDTH),
                                    "latency": {"type": "uniform", "min": 6, "max": 14}},
                            "branch": unit(1, 1, 1, 8, WIDTH), "lsu": unit(2, 1, 1, 12, WIDTH),
                            "fp": unit(1, 4, 1, 8, WIDTH)},
                  "shared_rs": None, "unified_issue_width": None},
    "basic_block": {
        "max_active_blocks": 16, "max_stores_per_new_block": 1, "max_instructions": 32,
        "registers": {"integer_physical": 64, "fp_physical": 64,
                      "reuse_destination_within_block": True},
        "merging": {"width": 1, "require_younger_complete": True, "require_older_complete": False,
                    "reject_store_conflicts": True, "selection_policy": "oldest_eligible"},
        "flushing": {"width": 2, "direction": "youngest_first",
                     "immediate_logical_invalidation": True,
                     "incremental_resource_reclamation": True, "allow_unaffected_merges": True}},
    "branch": {"misprediction_probability": .05,
               "recovery_latency": {"type": "uniform", "min": 5, "max": 12}},
    "memory": {"l1": {"miss_probability": .12, "latency": 2},
               "l2": {"miss_probability": .3, "latency": 7},
               "llc": {"miss_probability": .35, "latency": 16},
               "dram_latency": {"type": "uniform", "min": 40, "max": 80},
               "queue_delay": fixed(0), "store_latency": fixed(4),
               "max_outstanding_loads": 10, "mshr_capacity": 5, "response_width": 2,
               "load_buffer_capacity": 16, "store_buffer_capacity": 12, "store_drain_width": 1},
    "workload": {"type": "random", "instructions": 3000, "trace": None, "trace_hart": 0,
                 "trace_skip": 0, "trace_start_pc": None, "trace_stop_at_self_jump": False, "elf": None,
                 "mix": dict(zip(KINDS, [52, 8, 4, 10, 3, 12, 8, 3])),
                 "dependencies": {"probability": .65, "max_count": 3,
                                  "distance": {"type": "uniform", "min": 1, "max": 24},
                                  "chain_probability": .25, "load_density": .25,
                                  "register_locality": .65, "hot_registers": 8},
                 "memory_addresses": 128, "branch_taken_probability": .6},
    "frontend": FRONTEND,
    "storage": {"integer_width": 64, "fp_width": 64, "address_width": 64},
    "analysis": {"seeds": [42, 43, 44], "confidence": .95},
    "plotting": {"preset": "essential"},
}

DISTRIBUTIONS = {"latency", "recovery_latency", "dram_latency", "queue_delay", "store_latency", "distance"}


@dataclass(frozen=True)
class Distribution:
    low: int
    high: int
    values: tuple[int, ...] = ()
    weights: tuple[float, ...] = ()

    def sample(self, rng: Random) -> int:
        if self.values:
            return rng.choices(self.values, self.weights)[0]
        return self.low if self.low == self.high else rng.randint(self.low, self.high)


def integer(value: object, path: str, minimum: int = 1, maximum: int | None = None,
            *, unlimited: bool = False) -> None:
    if unlimited and value == UNLIMITED:
        return
    if type(value) is not int or value < minimum or (maximum is not None and value > maximum):
        limit = f"..{maximum}" if maximum is not None else " or greater"
        raise ValueError(f"{path} must be an integer in {minimum}{limit}")


def number(value: object, path: str, maximum: float = float("inf")) -> None:
    if type(value) not in (int, float) or not 0 <= value <= min(maximum, float_info.max):
        raise ValueError(f"{path} must be a finite number between 0 and {maximum}")


def choice(value: object, options: tuple, path: str) -> None:
    if value not in options:
        raise ValueError(f"{path} must be one of {options}")


def distribution(spec: dict, path: str = "distribution", minimum: int = 1) -> Distribution:
    if not isinstance(spec, dict):
        raise ValueError(f"{path} must be a distribution mapping")
    kind = spec.get("type")
    choice(kind, ("fixed", "uniform", "weighted"), f"{path}.type")
    fields = {"fixed": {"value"}, "uniform": {"min", "max"}, "weighted": {"values", "weights"}}[kind]
    if set(spec) != fields | {"type"}:
        raise ValueError(f"{path} ({kind}) requires exactly these fields: {', '.join(sorted(fields))}")
    if kind == "fixed":
        integer(spec["value"], path, minimum)
        return Distribution(spec["value"], spec["value"])
    if kind == "uniform":
        integer(spec["min"], f"{path}.min", minimum)
        integer(spec["max"], f"{path}.max", spec["min"])
        return Distribution(spec["min"], spec["max"])
    values, weights = spec["values"], spec["weights"]
    if not isinstance(values, list) or not isinstance(weights, list) or not values or len(values) != len(weights):
        raise ValueError(f"{path}.values and weights must be nonempty lists of equal length")
    for value, weight in zip(values, weights):
        integer(value, f"{path}.values", minimum)
        number(weight, f"{path}.weights")
    if not isfinite(sum(weights)) or not sum(weights):
        raise ValueError(f"{path}.weights must have a finite positive sum")
    return Distribution(min(values), max(values), tuple(values), tuple(weights))


def overlay(base: dict, changes: dict, path: str = "") -> dict:
    if not isinstance(changes, dict):
        raise ValueError(f"{path or 'configuration'} must be a mapping")
    result = deepcopy(base)
    for key, value in changes.items():
        name = f"{path}.{key}" if path else str(key)
        if key not in base:
            raise ValueError(f"unknown parameter {name}")
        if isinstance(base[key], dict) and key != "variants" and not (
            key in DISTRIBUTIONS and "type" in base[key]
        ):
            value = overlay(base[key], value, name)
        result[key] = deepcopy(value)
    return result


def configure(changes: dict | None = None) -> dict:
    c = overlay(DEFAULTS, {} if changes is None else changes)
    enabled = c["architectures"]["enabled"]
    if (not isinstance(enabled, list) or not enabled or any(not isinstance(name, str) for name in enabled) or
            any(backend_name(name) not in ARCHITECTURES for name in enabled) or len(set(enabled)) != len(enabled)):
        raise ValueError(f"architectures.enabled must contain unique names from {tuple(ARCHITECTURES)}, "
                         f"optionally suffixed with @<frontend variant>")
    validate_frontend(c["frontend"], "frontend")
    for name in enabled:
        if frontend_variant(name) is not None:
            # Each variant must produce a valid complete configuration.
            configure(variant_config(c, name, validate=False))

    s = c["simulation"]
    choice(s["mode"], ("event_driven", "statistical"), "simulation.mode")
    choice(s["cdb_policy"], ("oldest_completed", "len5_priority"), "simulation.cdb_policy")
    for key in ("dispatch_width", "rob_size", "max_cycles"):
        integer(s[key], "simulation." + key, unlimited=key != "max_cycles")
    for key in ("cdb_width", "commit_width"):
        if s[key] is not None:
            integer(s[key], "simulation." + key, unlimited=True)
    integer(s["seed"], "simulation.seed", 0)
    integer(s["warmup_instructions"], "simulation.warmup_instructions", 0)
    boolean(s["record_events"], "simulation.record_events")
    if s["parallel"]["workers"] != "auto":
        integer(s["parallel"]["workers"], "simulation.parallel.workers")
    smt = c["smt"]
    choice(smt["mode"], SMT_MODES, "smt.mode")
    integer(smt["threads"], "smt.threads", 2, 2)
    integer(smt["initial_priority"], "smt.initial_priority", 0, 1)
    choice(smt["dispatch_policy"], ("majority_feedback",), "smt.dispatch_policy")
    choice(smt["tie_policy"], ("retain_priority",), "smt.tie_policy")
    measurement = smt["measurement"]
    choice(measurement["policy"], ("reference_completion",), "smt.measurement.policy")
    reference = measurement["reference_thread"]
    if reference != "auto":
        integer(reference, "smt.measurement.reference_thread", 0, 1)
    for thread, workload in smt["workloads"].items():
        path = "smt.workloads." + thread
        if isinstance(workload, dict):
            settings = workload.copy()
            if "name" in settings:
                workload_name(settings.pop("name"), path + ".name")
            configure({"execution": c["execution"], "workload": overlay(c["workload"], settings, path)})
        elif workload is not None:
            workload_name(workload, path)
    pairs = smt["benchmark_pairs"]
    if not isinstance(pairs, list) or any(not isinstance(pair, list) or len(pair) != 2 for pair in pairs):
        raise ValueError("smt.benchmark_pairs must be a list of two-name lists")
    for pair in pairs:
        for name in pair:
            workload_name(name, "smt.benchmark_pairs")

    execution = c["execution"]
    if execution["unified_issue_width"] is not None:
        integer(execution["unified_issue_width"], "execution.unified_issue_width", unlimited=True)
    if execution["shared_rs"] is not None:
        shared = execution["shared_rs"]
        if not isinstance(shared, dict) or set(shared) != {"size", "issue_width"}:
            raise ValueError("execution.shared_rs must provide size and issue_width")
        for key, value in shared.items():
            integer(value, "execution.shared_rs." + key, unlimited=True)
    for name, eu in execution["units"].items():
        path = f"execution.units.{name}"
        integer(eu["count"], path + ".count", 0, unlimited=True)
        integer(eu["initiation_interval"], path + ".initiation_interval")
        for key in ("rs_size", "rs_issue_width"):
            integer(eu[key], path + "." + key, unlimited=True)
        distribution(eu["latency"], path + ".latency", minimum=0)

    b = c["basic_block"]
    for key in ("max_active_blocks", "max_stores_per_new_block"):
        integer(b[key], "basic_block." + key, unlimited=key == "max_active_blocks")
    if b["max_instructions"] is not None:
        integer(b["max_instructions"], "basic_block.max_instructions")
    registers = b["registers"]
    integer(registers["integer_physical"], "basic_block.registers.integer_physical", 32, unlimited=True)
    integer(registers["fp_physical"], "basic_block.registers.fp_physical", 33, unlimited=True)
    required(registers["reuse_destination_within_block"], "basic_block.registers.reuse_destination_within_block")
    merge, flush = b["merging"], b["flushing"]
    for name, policy in (("merging", merge), ("flushing", flush)):
        integer(policy["width"], f"basic_block.{name}.width", unlimited=True)
    for key in ("require_younger_complete", "reject_store_conflicts"):
        required(merge[key], "basic_block.merging." + key)
    boolean(merge["require_older_complete"], "basic_block.merging.require_older_complete")
    choice(merge["selection_policy"], ("oldest_eligible",), "basic_block.merging.selection_policy")
    choice(flush["direction"], ("youngest_first",), "basic_block.flushing.direction")
    for key in ("immediate_logical_invalidation", "incremental_resource_reclamation"):
        required(flush[key], "basic_block.flushing." + key)
    boolean(flush["allow_unaffected_merges"], "basic_block.flushing.allow_unaffected_merges")

    branch, memory = c["branch"], c["memory"]
    number(branch["misprediction_probability"], "branch.misprediction_probability", 1)
    distribution(branch["recovery_latency"], "branch.recovery_latency", 0)
    for level in ("l1", "l2", "llc"):
        number(memory[level]["miss_probability"], f"memory.{level}.miss_probability", 1)
        integer(memory[level]["latency"], f"memory.{level}.latency")
    for key in ("dram_latency", "queue_delay", "store_latency"):
        distribution(memory[key], "memory." + key, int(key != "queue_delay"))
    for key in ("max_outstanding_loads", "mshr_capacity", "response_width", "load_buffer_capacity",
                "store_buffer_capacity", "store_drain_width"):
        integer(memory[key], "memory." + key, unlimited=True)

    w = c["workload"]
    choice(w["type"], ("random", "spike"), "workload.type")
    if w["instructions"] is not None:
        integer(w["instructions"], "workload.instructions")
    elif w["type"] == "random":
        raise ValueError("workload.instructions is required for random generation")
    if (w["type"] == "spike" or w["trace"] is not None) and (
        not isinstance(w["trace"], str) or not w["trace"].strip()
    ):
        raise ValueError("workload.trace must be a Spike log path")
    for key in ("trace_hart", "trace_skip"):
        integer(w[key], "workload." + key, 0)
    if w["trace_start_pc"] is not None:
        integer(w["trace_start_pc"], "workload.trace_start_pc", 0)
    boolean(w["trace_stop_at_self_jump"], "workload.trace_stop_at_self_jump")
    if w["elf"] is not None and (not isinstance(w["elf"], str) or not w["elf"].strip()):
        raise ValueError("workload.elf must be an ELF path or null")
    integer(w["memory_addresses"], "workload.memory_addresses")
    number(w["branch_taken_probability"], "workload.branch_taken_probability", 1)
    for kind, weight in w["mix"].items():
        number(weight, "workload.mix." + kind)
        if w["type"] == "random" and weight and not execution["units"][UNIT_FOR[kind]]["count"]:
            raise ValueError(f"workload.mix.{kind} requires execution.units.{UNIT_FOR[kind]}.count > 0")
    if not isfinite(sum(w["mix"].values())) or not sum(w["mix"].values()):
        raise ValueError("workload.mix must have a finite positive sum")
    dep = w["dependencies"]
    for key in ("probability", "chain_probability", "load_density", "register_locality"):
        number(dep[key], "workload.dependencies." + key, 1)
    integer(dep["max_count"], "workload.dependencies.max_count", 0, 3)
    integer(dep["hot_registers"], "workload.dependencies.hot_registers", 1, 31)
    distribution(dep["distance"], "workload.dependencies.distance")
    for key, value in c["storage"].items():
        integer(value, "storage." + key)
    choice(c["plotting"]["preset"], ("essential", "detailed", "none"), "plotting.preset")
    a = c["analysis"]
    if not isinstance(a["seeds"], list) or not a["seeds"]:
        raise ValueError("analysis.seeds must be a nonempty list of unique seeds")
    for seed in a["seeds"]:
        integer(seed, "analysis.seeds", 0)
    if len(set(a["seeds"])) != len(a["seeds"]):
        raise ValueError("analysis.seeds must be unique")
    number(a["confidence"], "analysis.confidence", 1)
    if not 0 < a["confidence"] < 1:
        raise ValueError("analysis.confidence must be strictly between 0 and 1")
    return c


PREDICTOR_PRESETS = {name: {"predictor": name} for name in PREDICTORS}
# RTL defaults (len5_config_pkg): BPU_BTB_BITS=4 direct-mapped full-tag BTB, BPU_HLEN=4 gshare with history
# updated at resolution and the training index recomputed from it (R08 Policy A), RAS_DEPTH=4.
PREDICTOR_PRESETS["len5"] = {
    "predictor": "len5",
    "l0_btb": {"entries": 16, "ways": 1, "tag_bits": 58, "offset_bits": 64, "latency": 0,
               "organization": "per_slot", "replacement": "lru"},
    "gshare": {"entries": 16, "history_length": 4, "history": "committed", "train_index": "recompute",
               "history_compression": "truncate", "latency": 0, "start": "pc", "bypass_entries": 0,
               "organization": "per_slot"},
    "ras": {"depth": 4},
}
IDEAL_FRONTEND = {"predictor": "ideal", "icache": {"perfect": True, "max_outstanding": UNLIMITED,
                                                  "request_width": UNLIMITED, "response_width": UNLIMITED},
                  "memory_fifo": {"depth": UNLIMITED}, "issue_queue": {"capacity": UNLIMITED},
                  "ras": {"perfect": True, "depth": UNLIMITED},
                  "btq": {"capacity": UNLIMITED, "training_width": UNLIMITED}}
IDEAL_BACKEND = {
    "simulation": {"rob_size": UNLIMITED, "cdb_width": UNLIMITED, "commit_width": UNLIMITED},
    "execution": {"units": {name: {"count": UNLIMITED, "rs_size": UNLIMITED, "rs_issue_width": UNLIMITED}
                            for name in ("alu", "mul", "div", "branch", "lsu", "fp")}},
    "basic_block": {"max_active_blocks": UNLIMITED,
                    "registers": {"integer_physical": UNLIMITED, "fp_physical": UNLIMITED},
                    "merging": {"width": UNLIMITED}, "flushing": {"width": UNLIMITED}},
    "memory": {key: UNLIMITED for key in ("max_outstanding_loads", "mshr_capacity", "response_width",
                                          "load_buffer_capacity", "store_buffer_capacity", "store_drain_width")},
}
# Built-in variants. Unlimited capacity, unlimited bandwidth and perfect prediction remain separate keys.
BUILTIN_VARIANTS = {
    **{name: {"frontend": overrides} for name, overrides in PREDICTOR_PRESETS.items()},
    "ideal_frontend": {"frontend": IDEAL_FRONTEND},
    "ideal_backend": {"frontend": {"predictor": "tage"}, **IDEAL_BACKEND},
    "ideal_both": {"frontend": IDEAL_FRONTEND, **IDEAL_BACKEND},
    "unlimited_tage": {"frontend": {"predictor": "tage", "tage": {"tables": [
        dict(table, entries=UNLIMITED) for table in TAGE_TABLES]}, "bim": {"entries": UNLIMITED},
        "l1_btb": {"sets": UNLIMITED}, "l0_btb": {"entries": UNLIMITED}}},
    "unlimited_ras": {"frontend": {"ras": {"depth": UNLIMITED}}},
    "perfect_ras": {"frontend": {"ras": {"perfect": True}}},
    "no_ras": {"frontend": {"ras": {"enabled": False}}},
    "ideal_icache": {"frontend": {"icache": {"perfect": True}}},
    "unlimited_btq": {"frontend": {"btq": {"capacity": UNLIMITED, "training_width": UNLIMITED}}},
}


def variant_config(config: dict, architecture: str, *, validate: bool = True) -> dict:
    """Configuration for one ``architecture[@variant]`` run; a variant always enables the frontend."""
    variant = frontend_variant(architecture)
    if variant is None:
        return config
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", variant):
        raise ValueError(f"invalid frontend variant name {variant!r}")
    variants = config["frontend"]["variants"]
    if variant not in variants and variant not in BUILTIN_VARIANTS:
        raise ValueError(f"unknown frontend variant {variant!r}; define it in frontend.variants "
                         f"or use one of {tuple(BUILTIN_VARIANTS)}")
    changes = deepcopy(variants.get(variant, BUILTIN_VARIANTS.get(variant)))
    if not isinstance(changes, dict):
        raise ValueError(f"frontend.variants.{variant} must be a configuration mapping")
    if set(changes) - {"frontend", "simulation", "execution", "basic_block", "memory", "branch"}:
        raise ValueError(f"frontend.variants.{variant} may override only hardware sections")
    changes.setdefault("frontend", {})["enabled"] = True
    result = overlay(config, changes, f"frontend.variants.{variant}")
    result["architectures"]["enabled"] = [backend_name(architecture)]
    return configure(result) if validate else result


def unlimited_or(value: object, path: str, minimum: int = 1) -> None:
    integer(value, path, minimum, unlimited=True)


def ports(spec: dict, path: str) -> None:
    for key in ("read_ports", "write_ports"):
        unlimited_or(spec[key], f"{path}.{key}")
    boolean(spec["single_port"], path + ".single_port")


def validate_frontend(f: dict, path: str) -> None:
    boolean(f["enabled"], path + ".enabled")
    choice(f["predictor"], PREDICTORS, path + ".predictor")
    if not isinstance(f["variants"], dict) or any(not isinstance(k, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", k)
                                                  for k in f["variants"]):
        raise ValueError(f"{path}.variants must map names (letters, digits, '_', '.', '-') to configuration overlays")
    integer(f["fetch_width"], path + ".fetch_width", 1, 64)
    choice(f["instruction_bytes"], (2, 4), path + ".instruction_bytes")
    integer(f["redirect_delay"], path + ".redirect_delay", 0)
    choice(f["wrong_path"], ("bubble", "frontend", "full"), path + ".wrong_path")
    choice(f["unresolved_indirect"], ("fallthrough",), path + ".unresolved_indirect")
    pipe = f["pipeline"]
    integer(pipe["predecode_latency"], path + ".pipeline.predecode_latency", 0)
    integer(pipe["output_latency"], path + ".pipeline.output_latency", 0)
    unlimited_or(pipe["stage_capacity"], path + ".pipeline.stage_capacity")
    unlimited_or(f["memory_fifo"]["depth"], path + ".memory_fifo.depth")
    boolean(f["memory_fifo"]["drain_on_flush"], path + ".memory_fifo.drain_on_flush")
    ic = f["icache"]
    boolean(ic["perfect"], path + ".icache.perfect")
    for level in ("l1", "l2", "llc"):
        number(ic[level]["miss_probability"], f"{path}.icache.{level}.miss_probability", 1)
        integer(ic[level]["latency"], f"{path}.icache.{level}.latency", 0)
    distribution(ic["dram_latency"], path + ".icache.dram_latency")
    distribution(ic["queue_delay"], path + ".icache.queue_delay", 0)
    for key in ("max_outstanding", "request_width", "response_width"):
        unlimited_or(ic[key], f"{path}.icache.{key}")
    unlimited_or(f["issue_queue"]["capacity"], path + ".issue_queue.capacity")
    unlimited_or(f["issue_queue"]["enqueue_width"], path + ".issue_queue.enqueue_width")
    choice(f["history"]["update"], ("per_branch", "per_bundle"), path + ".history.update")
    choice(f["history"]["stale_policy"], ("relookup", "use_stale"), path + ".history.stale_policy")
    replacement = ("lru", "plru", "random", "fifo")
    l0 = f["l0_btb"]
    boolean(l0["enabled"], path + ".l0_btb.enabled")
    unlimited_or(l0["entries"], path + ".l0_btb.entries")
    unlimited_or(l0["ways"], path + ".l0_btb.ways")
    if l0["entries"] != UNLIMITED and (l0["ways"] == UNLIMITED or l0["entries"] % l0["ways"]):
        raise ValueError(f"{path}.l0_btb.entries must be a multiple of l0_btb.ways")
    l1 = f["l1_btb"]
    unlimited_or(l1["sets"], path + ".l1_btb.sets")
    integer(l1["ways"], path + ".l1_btb.ways")
    unlimited_or(l1["extended_entries"], path + ".l1_btb.extended_entries", 0)
    ports(l1, path + ".l1_btb")
    for name, spec in (("l0_btb", l0), ("l1_btb", l1)):
        integer(spec["tag_bits"], f"{path}.{name}.tag_bits", 1, 64)
        integer(spec["offset_bits"], f"{path}.{name}.offset_bits", 2, 64)
        integer(spec["latency"], f"{path}.{name}.latency", 0)
        choice(spec["replacement"], replacement, f"{path}.{name}.replacement")
        choice(spec["organization"], ("per_slot", "per_bundle"), f"{path}.{name}.organization")
    integer(l0["counter_bits"], path + ".l0_btb.counter_bits", 1, 8)
    bim = f["bim"]
    unlimited_or(bim["entries"], path + ".bim.entries")
    integer(bim["counter_bits"], path + ".bim.counter_bits", 1, 8)
    ports(bim, path + ".bim")
    g = f["gshare"]
    unlimited_or(g["entries"], path + ".gshare.entries")
    integer(g["history_length"], path + ".gshare.history_length", 0, 1024)
    integer(g["counter_bits"], path + ".gshare.counter_bits", 1, 8)
    integer(g["latency"], path + ".gshare.latency", 0)
    choice(g["start"], ("response", "pc"), path + ".gshare.start")
    choice(g["organization"], ("per_slot", "per_bundle"), path + ".gshare.organization")
    choice(g["history_compression"], ("xor_fold", "truncate"), path + ".gshare.history_compression")
    choice(g["history"], ("speculative", "committed"), path + ".gshare.history")
    choice(g["train_index"], ("saved", "recompute"), path + ".gshare.train_index")
    unlimited_or(g["bypass_entries"], path + ".gshare.bypass_entries", 0)
    ports(g, path + ".gshare")
    t = f["tage"]
    if not isinstance(t["tables"], list) or not t["tables"]:
        raise ValueError(f"{path}.tage.tables must be a nonempty list")
    for i, table in enumerate(t["tables"]):
        table_path = f"{path}.tage.tables[{i}]"
        if not isinstance(table, dict) or set(table) != {"entries", "tag_bits", "history_length"}:
            raise ValueError(f"{table_path} requires entries, tag_bits and history_length")
        unlimited_or(table["entries"], table_path + ".entries")
        integer(table["tag_bits"], table_path + ".tag_bits", 1, 32)
        integer(table["history_length"], table_path + ".history_length", 1, 1024)
    lengths = [table["history_length"] for table in t["tables"]]
    if lengths != sorted(set(lengths)):
        raise ValueError(f"{path}.tage.tables must have strictly increasing history lengths")
    integer(t["counter_bits"], path + ".tage.counter_bits", 2, 8)
    integer(t["useful_bits"], path + ".tage.useful_bits", 1, 8)
    unlimited_or(t["useful_reset_period"], path + ".tage.useful_reset_period")
    boolean(t["use_alt_on_weak"], path + ".tage.use_alt_on_weak")
    integer(t["latency"], path + ".tage.latency", 0)
    choice(t["start"], ("response", "pc"), path + ".tage.start")
    unlimited_or(t["bypass_entries"], path + ".tage.bypass_entries", 0)
    ports(t, path + ".tage")
    r = f["ras"]
    for key in ("enabled", "speculative", "perfect"):
        boolean(r[key], f"{path}.ras.{key}")
    unlimited_or(r["depth"], path + ".ras.depth")
    choice(r["access_stage"], ("predecode", "pcgen"), path + ".ras.access_stage")
    choice(r["organization"], ("circular",), path + ".ras.organization")
    choice(r["address_format"], ("full_address",), path + ".ras.address_format")
    required(r["speculative"], path + ".ras.speculative")
    rec = r["recovery"]
    choice(rec["mode"], ("pointer_and_saved_top",), path + ".ras.recovery.mode")
    boolean(rec["invalidate_corrupted_entries"], path + ".ras.recovery.invalidate_corrupted_entries")
    choice(rec["full_stack_checkpoint"], (False,), path + ".ras.recovery.full_stack_checkpoint")
    if r["target_priority"] != ["ras", "l1_btb", "l0_btb"]:
        raise ValueError(f"{path}.ras.target_priority supports only [ras, l1_btb, l0_btb]")
    unlimited_or(f["btq"]["capacity"], path + ".btq.capacity", 0)
    unlimited_or(f["btq"]["training_width"], path + ".btq.training_width")
    boolean(f["btq"]["coalesce"], path + ".btq.coalesce")
    choice(f["smt_predictors"], ("shared", "partitioned"), path + ".smt_predictors")


def workload_name(value: object, path: str) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{path} must be a nonempty workload name")


def boolean(value: object, path: str) -> None:
    if type(value) is not bool:
        raise ValueError(f"{path} must be a boolean")


def required(value: object, path: str) -> None:
    if value is not True:
        raise ValueError(f"{path} must be true; disabling it is unsupported")


class UniqueLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        result = {}
        for key_node, value_node in node.value:
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in result:
                raise ValueError(f"invalid or duplicate YAML key {key!r} on line {key_node.start_mark.line + 1}")
            result[key] = self.construct_object(value_node, deep=deep)
        return result


def load_config(path: Path) -> dict:
    with path.open() as stream:
        raw = yaml.load(stream, Loader=UniqueLoader)
    if not isinstance(raw, dict):
        raise ValueError("configuration file must contain a YAML mapping")
    config = configure(raw)
    for workload in (config["workload"], *config["smt"]["workloads"].values()):
        for key in ("trace", "elf"):
            if isinstance(workload, dict) and workload.get(key) is not None:
                workload[key] = str((path.parent / workload[key]).resolve())
    return config
