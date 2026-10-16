// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fetch_stage_driver.hh"
#include "tb_macros.hh"
#include <filesystem>
#include <iostream>
#include <unistd.h>
TbLogger logger;
using namespace len5::frontend;
namespace len5::frontend {
std::vector<Scenario> scenarios(const Config &c) {
    const char *titles[] = {"reset and sequential boot",
                            "partial bundle lanes",
                            "memory association",
                            "output backpressure",
                            "saved prediction across updates",
                            "access fault tuple",
                            "cause-zero misalignment",
                            "cold WT plus BTB miss",
                            "mostly-taken training",
                            "mostly-not-taken training",
                            "phase adaptation",
                            "alternating outcomes",
                            "interacting histories",
                            "BTB replacement",
                            "gshare interference",
                            "long trained execution",
                            "cold JAL lane",
                            "warm JAL suppression",
                            "JAL hit/not-taken reachability",
                            "poisoned JAL target stress",
                            "x1/x0/x5 calls",
                            "oldest jump cutoff",
                            "taken branch excludes jump",
                            "not-taken branch permits call",
                            "held early correction",
                            "concurrent training and correction",
                            "empty RAS return",
                            "repeated call and return",
                            "redundant return correction",
                            "two-caller stale BTB return",
                            "three callers",
                            "nested call unwind",
                            "wrong-path call",
                            "wrong-path return",
                            "indirect call no push",
                            "good BTB stale RAS reachability",
                            "latency ordering",
                            "all latency distributions",
                            "confirmation during frontend stall",
                            "split recovery feedback",
                            "EQ07 alternatives",
                            "normal recovery retains predictor",
                            "exception predictor reset",
                            "commit versus branch priority",
                            "fault epoch cancellation",
                            "early flush preserves older output",
                            "reset populated histories",
                            "EQ08 delayed data-fault context",
                            "delayed exception redirect",
                            "faulting encoded jump",
                            "alternate memory protocols",
                            "predictor-only flush",
                            "invalid backend histories",
                            "confidence and replay"};
    const char *families[] = {
        "sequential",    "lanes",        "sequential",  "sequential",   "loop-a",      "lanes",
        "lanes",         "loop-a",       "loop-a",      "loop-b",       "phase",       "alternating",
        "interacting",   "conflict",     "interacting", "long",         "lanes",       "jal-loop",
        "interacting",   "jal-loop",     "call",        "lanes",        "interacting", "wrong-call",
        "call",          "multi-caller", "empty-ret",   "call",         "call",        "multi-caller",
        "three-callers", "nested",       "wrong-call",  "wrong-return", "indirect",    "multi-caller",
        "interacting",   "loop-a",       "call",        "empty-ret",    "call",        "loop-a",
        "loop-a",        "sequential",   "sequential",  "call",         "nested",      "call",
        "sequential",    "lanes",        "sequential",  "loop-a",       "sequential",  "sequential"};
    std::vector<Scenario> all;
    for (unsigned k = 0; k < 54; ++k) {
        Scenario s;
        s.id = std::string("FE-T") + (k < 9 ? "0" : "") + std::to_string(k + 1);
        s.title = titles[k];
        s.family = families[k];
        s.variant = k % c.lanes;
        s.repetitions = 32;
        s.budget = 6000;
        s.witnesses = {"FEV01/request", "FEV01/dispatch"};
        if (k >= 7 && k <= 15) {
            s.witnesses.push_back("update");
            s.witnesses.push_back("branch-execution");
            s.witnesses.push_back("conditional-trained");
        }
        if (k == 7 || k == 8)
            s.witnesses.insert(s.witnesses.end(),
                               {"raw-miss", "recovery", "conditional-taken", "conditional-not-taken"});
        if (k == 9 || k == 10 || k == 11)
            s.witnesses.insert(s.witnesses.end(), {"conditional-taken", "conditional-not-taken"});
        if (k == 13) {
            s.witnesses.push_back("btb-conflict-replacement");
            s.witnesses.push_back("btb-conflict-miss");
        }
        if (k == 17)
            s.witnesses.push_back("jal-cold-to-warm");
        if (k == 26)
            s.witnesses.insert(s.witnesses.end(), {"return-empty", "recovery"});
        if (k >= 27 && k <= 31)
            s.witnesses.insert(s.witnesses.end(), {"return-witness", "confirmation", "update"});
        if (k == 28)
            s.witnesses.push_back("return-bpu-correct");
        if (k == 29 || k == 30)
            s.witnesses.insert(s.witnesses.end(), {"return-bpu-stale", "multiple-return-targets"});
        if (k == 30)
            s.family = "caller-order";
        if (k == 31)
            s.witnesses.push_back("nested-full-unwind");
        if (k == 3 || k == 24)
            s.witnesses.push_back("EJU-stalled");
        if (k == 5 || k == 6 || k == 44 || k == 49)
            s.witnesses.push_back("fault-delivery");
        if (k == 18) {
            s.family = "jal-nt";
            s.witnesses.push_back("jal-hit-not-taken");
        }
        if (k == 19) {
            s.classification = "interface_stress";
            s.witnesses.push_back("poisoned-update");
            s.witnesses.push_back("wrong-target-jal-suppressed");
            s.witnesses.push_back("poisoned-recovery");
        }
        if (k == 20) {
            s.family = "call-kind";
            s.witnesses.push_back("return");
        }
        if (k == 21) {
            s.family = "multiple-jumps";
            s.witnesses.push_back("return-empty");
        }
        if (k == 22) {
            s.family = "mask-cutoff";
            s.witnesses.push_back("conditional-trained");
        }
        if (k == 14) {
            s.witnesses.push_back("gshare-opposing-update");
            s.witnesses.push_back("gshare-interference-witness");
            s.witnesses.push_back("gshare-public-threshold-up");
            s.witnesses.push_back("gshare-public-threshold-down");
        }
        if (k == 23 || k == 32) {
            s.family = "nt-call";
            s.witnesses.push_back("return-empty");
            s.witnesses.push_back("recovery");
        }
        if (k == 33) {
            s.family = "wrong-return-deep";
            s.witnesses.push_back("return-witness");
            s.witnesses.push_back("recovery");
            s.witnesses.push_back("RAS-multiple-entry-restoration");
        }
        if (k == 35) {
            s.family = "stale-ras";
            s.witnesses.push_back("correct-btb-stale-ras");
        }
        if (k == 36) {
            s.family = "ordered-pair";
            s.witnesses.push_back("latency64-before1");
        }
        if (k == 37) {
            s.witnesses.push_back("update");
        }
        if (k == 40) {
            s.classification = "interface_stress";
            s.witnesses.push_back("simultaneous-confirm-restore");
            s.witnesses.push_back("return-witness");
        }
        if (k == 42 || k == 43 || k == 47 || k == 48 || k == 49 || k == 50) {
            s.classification = k == 43 ? "interface_stress" : "characterization";
            if (k != 43)
                s.limitation = k == 47 ? "EQ08 requires separately tagged delayed "
                                         "data-fault context; no fake fetch-fault "
                                         "reproduction"
                                       : "characterization observation does not close "
                                         "all specified temporal obligations";
        }
        if (k == 45)
            s.witnesses.push_back("early-flush");
        if (k == 46)
            s.witnesses.push_back("populated-history-reset");
        if (k == 46)
            s.family = "reset-loaded";
        if (k == 43) {
            s.family = "call";
            s.witnesses.insert(s.witnesses.end(),
                               {"priority-triple", "triple-redirect-refetch", "triple-target-delivered"});
        }
        if (k == 25)
            s.witnesses.push_back("training-and-early-correction");
        if (k == 38)
            s.witnesses.push_back("confirmation-during-stall");
        if (k == 39)
            s.witnesses.push_back("held-redirect-rejected");
        if (k == 52)
            s.witnesses.push_back("backend-negative-rejections");
        if (k == 53)
            s.limitation = "independent negative/confidence validators own these "
                           "obligations; directed "
                           "placeholder alone is not completion";
        all.push_back(s);
    }
    return all;
}
} // namespace len5::frontend
static uint64_t number(const std::string &v) {
    size_t n = 0;
    auto x = std::stoull(v, &n, 0);
    if (n != v.size() || v.empty() || v[0] == '-')
        throw std::invalid_argument("invalid unsigned number");
    return x;
}
static unsigned small(const std::string &text) {
    auto x = number(text);
    if (x > UINT32_MAX)
        throw std::invalid_argument("32-bit option out of range");
    return unsigned(x);
}
static bool boolean(const std::string &v) {
    if (v != "true" && v != "false")
        throw std::invalid_argument("boolean options require true or false");
    return v == "true";
}
int main(int argc, char **argv) {
    try {
        Options o;
        o.executable = std::filesystem::canonical(argv[0]);
        o.max_cycles = 1000000;
        o.run_dir = "build/fetch-stage/run/native-" + std::to_string(getpid());
        for (int k = 1; k < argc; ++k) {
            std::string a = argv[k];
            auto pos = a.find('=');
            std::string key = a.substr(0, pos), v = pos == std::string::npos ? "true" : a.substr(pos + 1);
            if (key == "--seed")
                o.seed = number(v);
            else if (key == "--scenario")
                o.scenario = v;
            else if (key == "--program")
                o.program = v;
            else if (key == "--cycles")
                o.cycles = number(v);
            else if (key == "--max_cycles")
                o.max_cycles = number(v);
            else if (key == "--run_dir")
                o.run_dir = v;
            else if (key == "--profile")
                o.profile = v;
            else if (key == "--ras_order")
                o.ras_order = v;
            else if (key == "--campaign")
                o.campaign = v;
            else if (key == "--weights")
                o.weights = v;
            else if (key == "--journal")
                o.journal = v;
            else if (key == "--random")
                o.random = boolean(v);
            else if (key == "--guided")
                o.guided = boolean(v);
            else if (key == "--dump_waves")
                o.waves = boolean(v);
            else if (key == "--inject_failure")
                o.inject = v;
            else if (key == "--expect_fingerprint")
                o.expect_fingerprint = v;
            else if (key == "--expect_issues")
                o.expect_issues = small(v);
            else if (key == "--repetitions")
                o.repetitions = small(v);
            else if (key == "--directed_repetitions")
                o.directed_repetitions = small(v);
            else if (key == "--directed_cycles")
                o.directed_cycles = number(v);
            else if (key == "--variant")
                o.variant = small(v);
            else if (key == "--exec_latency_min")
                o.latency.minimum = number(v);
            else if (key == "--exec_latency_max")
                o.latency.maximum = number(v);
            else if (key == "--exec_latency_dist")
                o.latency.distribution = v;
            else if (key == "--exec_latency_fixed")
                o.latency.fixed = number(v);
            else if (key == "--exec_latency_mode")
                o.latency.mode = number(v);
            else if (key == "--exec_geo_u")
                o.latency.geo_u = small(v);
            else if (key == "--exec_geo_v")
                o.latency.geo_v = small(v);
            else if (key == "--exec_short_u")
                o.latency.short_u = small(v);
            else if (key == "--exec_short_v")
                o.latency.short_v = small(v);
            else if (key == "--exec_short_min")
                o.latency.short_min = number(v);
            else if (key == "--exec_short_max")
                o.latency.short_max = number(v);
            else if (key == "--exec_long_min")
                o.latency.long_min = number(v);
            else if (key == "--exec_long_max")
                o.latency.long_max = number(v);
            else if (key == "--log_level") {
                const std::map<std::string, int> levels = {{"LOG_NONE", 0},   {"LOG_LOW", 1},
                                                           {"LOG_MEDIUM", 2}, {"LOG_HIGH", 3},
                                                           {"LOG_FULL", 4},   {"LOG_DEBUG", 5}};
                logger.setLogLvl(levels.at(v));
            } else
                throw std::invalid_argument("unknown option " + key);
        }
        o.latency.validate();
        if (o.campaign != "all" && o.campaign != "architectural" && o.campaign != "stress" &&
            o.campaign != "characterization")
            throw std::invalid_argument("unknown campaign");
        if (o.journal != "auto" && o.journal != "full" && o.journal != "failures")
            throw std::invalid_argument("journal must be auto, full, or failures");
        if (o.profile != "exact-I" && o.profile != "predictor-agnostic")
            throw std::invalid_argument("profile must be exact-I or predictor-agnostic");
        Simulator sim(o, argc, argv);
        auto all = scenarios(sim.config());
        if (o.random) {
            std::mt19937_64 program_rng(split_seed(o.seed ^ UINT64_C(0x50524f47)));
            const std::vector<std::string> families = {"loop-a",        "loop-b",   "phase", "alternating",
                                                       "interacting",   "jal-loop", "call",  "multi-caller",
                                                       "three-callers", "nested"};
            unsigned episode = 0;
            do {
                Scenario s;
                s.id = "random-" + std::to_string(episode);
                s.title = "persistent executable training episode";
                s.family = o.program.empty() ? families[bounded(program_rng, families.size())] : o.program;
                s.variant = unsigned(bounded(program_rng, sim.config().lanes));
                s.repetitions = o.repetitions;
                if (o.guided && o.program.empty()) {
                    if (!sim.observed("/conditional-trained"))
                        s.family = "loop-a";
                    else if (!sim.observed("/jal-cold-to-warm"))
                        s.family = "jal-loop";
                    else if (!sim.observed("/return-bpu-stale"))
                        s.family = "multi-caller";
                }
                unsigned category = o.campaign == "stress"             ? 1
                                    : o.campaign == "characterization" ? 2
                                    : o.campaign == "all"              ? episode % 3
                                                                       : 0;
                s.classification = category == 0   ? "architectural"
                                   : category == 1 ? "interface_stress"
                                                   : "characterization";
                s.witnesses = category == 2 ? std::vector<std::string>{"fault-delivery", "frontend-flush",
                                                                       "new-epoch-clean"}
                                            : std::vector<std::string>{"update", "branch-execution"};
                if (category == 2)
                    s.family = "sequential";
                const auto before = sim.cycles();
                sim.run(s, o.cycles > before ? o.cycles - before : 1);
                ++episode;
                if (sim.cycles() <= before)
                    throw std::logic_error("random episode made no progress");
            } while (sim.cycles() < o.cycles);
        } else {
            bool found = false;
            for (auto s : all)
                if (o.scenario == "all" || o.scenario == s.id) {
                    if (o.directed_cycles)
                        s.budget = o.directed_cycles;
                    if (o.directed_repetitions)
                        s.repetitions = o.directed_repetitions;
                    found = true;
                    if (o.variant != UINT32_MAX) {
                        s.variant = o.variant;
                        sim.run(s);
                    } else if (s.id == "FE-T02" || s.id == "FE-T17" || s.id == "FE-T22") {
                        for (unsigned lane = 0; lane < sim.config().lanes; ++lane) {
                            auto x = s;
                            x.variant = lane;
                            sim.run(x);
                        }
                    } else if (s.id == "FE-T21") {
                        for (unsigned rd : {0u, 1u, 5u}) {
                            auto x = s;
                            x.variant = rd;
                            sim.run(x);
                        }
                    } else if (s.id == "FE-T32") {
                        for (unsigned depth = 1; depth <= sim.config().ras_depth + 1; ++depth) {
                            auto x = s;
                            x.variant = depth - 1;
                            sim.run(x);
                        }
                    } else if (s.id == "FE-T38") {
                        for (unsigned dist = 0; dist < 7; ++dist) {
                            auto x = s;
                            x.variant = dist;
                            sim.run(x);
                        }
                    } else
                        sim.run(s);
                }
            if (!found && o.scenario != "empty")
                throw std::invalid_argument("unknown scenario " + o.scenario);
        }
        return sim.finish();
    } catch (const std::exception &e) {
        TB_ERR("SCB > configuration/framework failure: %s", e.what());
        std::cerr << "Test failed: fetch_stage startup/framework\n";
        return 2;
    }
}
