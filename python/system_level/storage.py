"""Count modeled state bits under an explicit register and checkpoint layout."""


from .config import (IDEAL_ARCHITECTURES, INTEGER_UNITS, UNLIMITED, WRAPPER_ARCHITECTURES, commit_architecture,
                     variant_config)
from .unified import result_slots, station_capacity


def index_bits(entries: int) -> int:
    return (entries - 1).bit_length()


def unlimited(value) -> bool:
    """Unlimited capacity or bandwidth has no finite storage estimate."""
    if isinstance(value, dict):
        return any(unlimited(item) for item in value.values())
    return value == UNLIMITED


def estimate(config: dict, architecture: str, threads: int | None = None) -> dict:
    if threads is None:
        threads = 2 if config.get("smt", {}).get("mode") == "enabled" else 1
    if threads not in (1, 2):
        raise ValueError("storage estimate requires one or two hardware threads")
    config = variant_config(config, architecture)
    if architecture in IDEAL_ARCHITECTURES or unlimited(
            {key: config[key] for key in ("simulation", "execution", "basic_block", "memory")}):
        return {"rob_bits": None, "total_bits": None, "total_bytes": None}
    unified = architecture in WRAPPER_ARCHITECTURES
    architecture = commit_architecture(architecture)
    tid = index_bits(threads)
    rob_entries = config["simulation"]["rob_size"]
    widths = config["storage"]
    value_bits = max(widths["integer_width"], widths["fp_width"])
    pc = widths["address_width"]
    rob_index = index_bits(rob_entries)
    # Valid/ready, destination write+type, exception valid+code, FP flags,
    # operation class, store status, and branch direction/resolution.
    common = 2 + 2 + 1 + 5 + 5 + 3 + 2 + 2 + 5 + pc
    sizes = {"mapping_bits_per_block": 0, "ownership_bits_per_block": 0, "mapping_bits": 0,
             "ownership_bits": 0, "checkpoint_bits": 0}
    if architecture != "basic_block_ooo_commit":
        len5 = architecture == "len5_ooo_commit"
        commit_width = config["simulation"]["commit_width"] or config["simulation"]["dispatch_width"]
        sizes.update(rob_bits=threads * rob_entries * (common + value_bits + 3 * len5),
                     register_file_bits=threads * (31 * widths["integer_width"] + 32 * widths["fp_width"]),
                     additional_control_bits=threads * (
                         (4 if len5 else 2) * rob_index + index_bits(rob_entries + 1)
                         + 63 * (rob_index + 1) + commit_width * (common + value_bits) + pc + rob_index + 2))
    else:
        block = config["basic_block"]
        pi, pf = (block["registers"][key] for key in ("integer_physical", "fp_physical"))
        p_index = max(index_bits(pi), index_bits(pf))
        count = block["max_active_blocks"]
        b_index = index_bits(count)
        store_entries = config["memory"]["store_buffer_capacity"]
        sb_index = index_bits(store_entries)
        map_bits = 31 * index_bits(pi) + 32 * index_bits(pf)
        ownership = pi + pf
        active_branches = min(count, threads * rob_entries)
        # One extra shadow map per unresolved boundary, including maps awaiting selective flush.
        shadow = 2 * 63 + map_bits + ownership + pc + rob_index + b_index + 2
        sizes.update(rob_bits=threads * rob_entries * (common + p_index + b_index + 2 * rob_index + 1),
                     register_file_bits=threads * (pi * widths["integer_width"] + pf * widths["fp_width"]),
                     mapping_bits_per_block=map_bits, ownership_bits_per_block=ownership,
                     mapping_bits=count * map_bits, ownership_bits=count * ownership,
                     checkpoint_bits=active_branches * shadow,
                     additional_control_bits=(
                         count * (2 * b_index + 2 * index_bits(rob_entries + 1) + 63 + 6 + 2 * sb_index)
                         + count + threads * (map_bits + store_entries * (b_index + sb_index + 1)
                                              + (pi + pf) * (rob_index + 2) + rob_entries + 2 * rob_index
                                              + 3 * b_index + pc + rob_index + 2)))
        if tid:
            sizes["block_thread_tag_bits"] = count * tid

    execution = config["execution"]
    units = {name: unit for name, unit in execution["units"].items() if unit["count"]}
    wrapped = {name: unit for name, unit in units.items() if unified and name in INTEGER_UNITS}
    separate = {name: unit for name, unit in units.items() if name not in wrapped}
    shared = execution["shared_rs"]
    stations = [(shared["size"], 3 if "fp" in separate else 2)] if shared and (separate or not unified) else [
        (unit["rs_size"], 3 if name == "fp" else 2) for name, unit in separate.items()]
    if wrapped:
        stations.append((station_capacity(execution), 2))
    memory = config["memory"]
    load_entries = memory["load_buffer_capacity"]
    store_entries = memory["store_buffer_capacity"]
    # Pending operand slots hold either a value or a local ROB tag. An output latch per lane
    # represents buffered CDB results. Arbitration wires themselves have no storage.
    operand_bits = max(value_bits, rob_index) + 1
    outputs = sum(unit["count"] for unit in separate.values())
    sizes.update(
        reservation_station_bits=sum(count * (operands * operand_bits + pc + rob_index + index_bits(count) + 12)
                                     for count, operands in stations),
        load_buffer_bits=load_entries * (pc + value_bits + rob_index + index_bits(load_entries) + 9),
        store_buffer_bits=threads * store_entries * (pc + value_bits + rob_index + 8)
        + threads * (2 * index_bits(store_entries) + index_bits(store_entries + 1)),
        cdb_result_buffer_bits=outputs * (value_bits + rob_index + 12),
    )
    if tid:
        sizes.update(rs_thread_tag_bits=tid * sum(count for count, _ in stations),
                     load_thread_tag_bits=tid * load_entries, cdb_thread_tag_bits=tid * outputs)
    if wrapped:
        slots = sum(unit["count"] * result_slots(unit) for unit in wrapped.values())
        # Age ranks cover the integer RS and reserved results. Each slot tracks both grants.
        age_bits = index_bits(station_capacity(execution) + slots)
        sizes["unified_completion_buffer_bits"] = slots * (
            widths["integer_width"] + rob_index + tid + age_bits + 5)
        sizes["additional_control_bits"] += 5 if architecture == "basic_block_ooo_commit" else 3
    sizes["total_bits"] = sum(value for key, value in sizes.items() if not key.endswith("_per_block"))
    sizes["total_bytes"] = (sizes["total_bits"] + 7) // 8
    if architecture == "basic_block_ooo_commit":
        sizes["shared_block_mapping_ownership_bits"] = (
            sizes["mapping_bits"] + sizes["ownership_bits"] + sizes.get("block_thread_tag_bits", 0))
    return sizes
