"""Configuration defaults and validation for simulation and sweeps."""

from copy import deepcopy
from dataclasses import dataclass
from math import isfinite
from pathlib import Path
from random import Random
from sys import float_info

import yaml

DEFAULT_ARCHITECTURES = ("normal_ooo", "len5_ooo_commit", "basic_block_ooo_commit")
IDEAL = "ideal_commit"
IDEAL_OOO = "ideal_commit_ooo"
UNIFIED_SUFFIX = "_unified_rs"
BRANCH_FORWARDING_SUFFIX = "_unified_rs_branch_forwarding"
SEPARATE_ARCHITECTURES = (*DEFAULT_ARCHITECTURES, IDEAL, IDEAL_OOO)
UNIFIED_ARCHITECTURES = tuple(name + UNIFIED_SUFFIX for name in SEPARATE_ARCHITECTURES)
BRANCH_FORWARDING_ARCHITECTURES = tuple(name + BRANCH_FORWARDING_SUFFIX for name in SEPARATE_ARCHITECTURES)
WRAPPER_ARCHITECTURES = (*UNIFIED_ARCHITECTURES, *BRANCH_FORWARDING_ARCHITECTURES)
ARCHITECTURES = (*SEPARATE_ARCHITECTURES, *WRAPPER_ARCHITECTURES)


def commit_architecture(name: str) -> str:
    return name.removesuffix(BRANCH_FORWARDING_SUFFIX).removesuffix(UNIFIED_SUFFIX)


IDEAL_ARCHITECTURES = tuple(name for name in ARCHITECTURES
                            if commit_architecture(name) in (IDEAL, IDEAL_OOO))
BLOCK_ARCHITECTURES = tuple(name for name in ARCHITECTURES
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


DEFAULTS = {
    "architectures": {"enabled": list(DEFAULT_ARCHITECTURES)},
    "simulation": {"mode": "event_driven", "seed": 42, "dispatch_width": 4,
                   "cdb_width": None, "commit_width": None, "rob_size": 32,
                   "max_cycles": 1_000_000, "cdb_policy": "oldest_completed", "record_events": False,
                   "parallel": {"workers": "auto"}},
    "smt": {"mode": "disabled", "threads": 2, "initial_priority": 0,
            "dispatch_policy": "majority_feedback", "tie_policy": "retain_priority",
            "workloads": {"thread_0": None, "thread_1": None}, "benchmark_pairs": [],
            "measurement": {"policy": "reference_completion", "reference_thread": "auto"}},
    "execution": {"units": {"alu": unit(2, 1, 1, 12, 2), "mul": unit(1, 3, 1, 6, 1),
                            "div": {**unit(1, 8, 8, 4, 1),
                                    "latency": {"type": "uniform", "min": 6, "max": 14}},
                            "branch": unit(1, 1, 1, 8, 1), "lsu": unit(2, 1, 1, 12, 2),
                            "fp": unit(1, 4, 1, 8, 1)},
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
                 "trace_skip": 0, "trace_start_pc": None, "trace_stop_at_self_jump": False,
                 "mix": dict(zip(KINDS, [52, 8, 4, 10, 3, 12, 8, 3])),
                 "dependencies": {"probability": .65, "max_count": 3,
                                  "distance": {"type": "uniform", "min": 1, "max": 24},
                                  "chain_probability": .25, "load_density": .25,
                                  "register_locality": .65, "hot_registers": 8},
                 "memory_addresses": 128, "branch_taken_probability": .6},
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


def integer(value: object, path: str, minimum: int = 1, maximum: int | None = None) -> None:
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
        if isinstance(base[key], dict) and not (
            key in DISTRIBUTIONS and "type" in base[key]
        ):
            value = overlay(base[key], value, name)
        result[key] = deepcopy(value)
    return result


def configure(changes: dict | None = None) -> dict:
    c = overlay(DEFAULTS, {} if changes is None else changes)
    enabled = c["architectures"]["enabled"]
    if (not isinstance(enabled, list) or not enabled or
            any(name not in ARCHITECTURES for name in enabled) or len(set(enabled)) != len(enabled)):
        raise ValueError(f"architectures.enabled must contain unique names from {ARCHITECTURES}")

    s = c["simulation"]
    choice(s["mode"], ("event_driven", "statistical"), "simulation.mode")
    choice(s["cdb_policy"], ("oldest_completed", "len5_priority"), "simulation.cdb_policy")
    for key in ("dispatch_width", "rob_size", "max_cycles"):
        integer(s[key], "simulation." + key)
    for key in ("cdb_width", "commit_width"):
        if s[key] is not None:
            integer(s[key], "simulation." + key)
    integer(s["seed"], "simulation.seed", 0)
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
        integer(execution["unified_issue_width"], "execution.unified_issue_width")
    if execution["shared_rs"] is not None:
        shared = execution["shared_rs"]
        if not isinstance(shared, dict) or set(shared) != {"size", "issue_width"}:
            raise ValueError("execution.shared_rs must provide size and issue_width")
        for key, value in shared.items():
            integer(value, "execution.shared_rs." + key)
    for name, eu in execution["units"].items():
        path = f"execution.units.{name}"
        integer(eu["count"], path + ".count", 0)
        for key in ("initiation_interval", "rs_size", "rs_issue_width"):
            integer(eu[key], path + "." + key)
        distribution(eu["latency"], path + ".latency", minimum=0)

    b = c["basic_block"]
    for key in ("max_active_blocks", "max_stores_per_new_block"):
        integer(b[key], "basic_block." + key)
    if b["max_instructions"] is not None:
        integer(b["max_instructions"], "basic_block.max_instructions")
    registers = b["registers"]
    integer(registers["integer_physical"], "basic_block.registers.integer_physical", 32)
    integer(registers["fp_physical"], "basic_block.registers.fp_physical", 33)
    required(registers["reuse_destination_within_block"], "basic_block.registers.reuse_destination_within_block")
    merge, flush = b["merging"], b["flushing"]
    for name, policy in (("merging", merge), ("flushing", flush)):
        integer(policy["width"], f"basic_block.{name}.width")
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
        integer(memory[key], "memory." + key)

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
    trace = config["workload"]["trace"]
    if trace is not None:
        config["workload"]["trace"] = str((path.parent / trace).resolve())
    for workload in config["smt"]["workloads"].values():
        if isinstance(workload, dict) and workload.get("trace") is not None:
            workload["trace"] = str((path.parent / workload["trace"]).resolve())
    return config
