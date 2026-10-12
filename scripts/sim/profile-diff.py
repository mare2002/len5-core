#!/usr/bin/env python3
"""Build a separate, instrumented simulator from an existing differential build.

Copy four C++ sources, add inclusive steady-clock timers, and reuse the generated
RTL and Spike objects. The source tree and normal executable are not modified.
Run the resulting Vtb_bare normally; PROFILE lines are printed on stderr at exit.
Use benchmark-diff.py with uninstrumented binaries for performance comparisons.
"""
import argparse
import os
import shlex
import subprocess
from pathlib import Path


TIMING_HEADER = r'''#pragma once
#include <chrono>
#include <cstdio>
namespace timing {
struct Counter { const char *name; unsigned long long calls = 0, ns = 0; };
inline Counter counters[] = {{"rise"}, {"fall"}, {"after"}, {"spike"}, {"checker"},
                            {"eval"}, {"waves"}, {"finish"}, {"init"}, {"signal_get"}};
struct Report {
    ~Report() {
        for (auto &c : counters)
            std::fprintf(stderr, "PROFILE %s %llu %.9f\n", c.name, c.calls, c.ns * 1e-9);
    }
};
inline Report report;
struct Scope {
    int index;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    explicit Scope(int i) : index(i) {}
    ~Scope() {
        auto &c = counters[index];
        ++c.calls;
        c.ns += std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - start).count();
    }
};
}
#define TIMER(i) timing::Scope timer(i)
'''


def scope(source, marker, index):
    start = source.index("{", source.index(marker)) + 1
    return source[:start] + f"\n TIMER({index});" + source[start:]


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--model-dir", type=Path, default=root / "build/debug/sim-diff-verilator")
    args = parser.parse_args()
    model, out = args.model_dir.resolve(), args.output.resolve()
    if model == out:
        parser.error("output must differ from the model directory")
    out.mkdir(parents=True, exist_ok=True)
    (out / "timing.hh").write_text(TIMING_HEADER)
    # Match the optimization settings used by the Edalize build driver.
    options = []
    for line in (model / "config.mk").read_text().splitlines():
        if line.startswith("MAKE_OPTIONS"):
            options += [s for s in shlex.split(line.split("=", 1)[1])
                        if s.startswith(("OPT_FAST=", "OPT_GLOBAL="))]
    env = dict(os.environ, CCACHE_DISABLE="1")

    def dry_run(prerequisite):
        return subprocess.check_output(
            ["make", "-s", "-f", "Vtb_bare.mk", "-n", "-W", prerequisite, "OBJCACHE="] + options,
            cwd=model, env=env, text=True)

    objects, commands = {}, []
    for name in ["monitor", "checker", "spike_adapter", "len5_tb"]:
        path = root / "tb/verilator" / (f"{name}.cpp" if name == "len5_tb" else f"diff/{name}.cpp")
        source = path.read_text()
        if name == "monitor":
            for marker, index in [("void Monitor::before_rising", 0),
                                  ("void Monitor::before_falling", 1),
                                  ("void Monitor::after_rising", 2), ("int Monitor::finish", 7),
                                  ("uint64_t get(std::string_view signal", 9)]:
                source = scope(source, marker, index)
        elif name == "spike_adapter":
            source = scope(source, "ReferenceRecord SpikeReference::step()", 3)
        elif name == "checker":
            for method in ["fetch", "dispatch", "allocate", "execute", "memory", "authorize",
                           "external_store", "store_response", "load_request", "load_response",
                           "load_capture", "commit", "checkpoint", "source_at_dispatch",
                           "flush_frontend", "flush_backend", "resolve_branch", "tick"]:
                source = scope(source, "Checker::" + method + "(", 4)
        else:
            source = source.replace("dut->eval();", "{ TIMER(5); dut->eval(); }")
            source = source.replace("if (dump_waves) m_trace->dump(cntx->time());",
                                    "if (dump_waves) { TIMER(6); m_trace->dump(cntx->time()); }")
            source = source.replace("differential = std::make_unique<len5::diff::Monitor>",
                                    "TIMER(8); differential = std::make_unique<len5::diff::Monitor>")
        dest = out / f"{name}.cpp"
        dest.write_text('#include "timing.hh"\n' + source)
        command = next(shlex.split(line) for line in dry_run(os.path.relpath(path, model)).splitlines()
                       if " -c " in line and f"{name}.o" in line)
        command[-1] = str(dest)
        command[command.index("-o") + 1] = str(out / f"{name}.o")
        subprocess.run(command, cwd=model, env=env, check=True)
        commands.append(shlex.join(command))
        objects[f"{name}.o"] = str(out / f"{name}.o")
    command = shlex.split(next(line for line in dry_run("Vtb_bare__ALL.a").splitlines()
                              if " -o Vtb_bare" in line))
    command = [objects.get(arg, arg) for arg in command]
    command[-1] = str(out / "Vtb_bare")
    subprocess.run(command, cwd=model, env=env, check=True)
    commands.append(shlex.join(command))
    (out / "commands.txt").write_text("\n".join(commands) + "\n")
    print(out / "Vtb_bare")


if __name__ == "__main__":
    main()
