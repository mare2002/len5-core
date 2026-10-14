// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_environment.hh"
#include "pc_gen_scoreboard.hh"
#include <memory>

class VerilatedContext;
class VerilatedFstC;
class Vpc_gen_tb;
namespace len5::pcgen {
struct RunOptions {
    uint64_t seed = 1, max_cycles = 50000;
    bool dump_waves = false, random = false, guided = true;
    uint64_t random_cycles = 10000;
    unsigned expect_issues = 0; // Replay compatibility assertion, never a width selector.
    std::string campaign = "all", weights, journal = "auto", executable;
    Contract contract;
    std::string contract_name = "proposed", selection = "all", inject_failure, run_dir;
};
struct Timeout : std::runtime_error { using std::runtime_error::runtime_error; };
class Simulator {
    RunOptions options_;
    std::unique_ptr<VerilatedContext> context_;
    std::unique_ptr<Vpc_gen_tb> dut_;
    std::unique_ptr<VerilatedFstC> trace_;
    Config config_;
    std::unique_ptr<ReferenceModel> model_;
    std::unique_ptr<Environment> environment_;
    std::unique_ptr<Scoreboard> scoreboard_;
    uint64_t cycles_ = 0;
    bool fault_injected_ = false;
    void drive(const Inputs&);
    Inputs read_inputs() const;
    Outputs read_outputs() const;
    void dump();
    void sample(const Stimulus&, const Field&, const Transition&, const std::string& phase);
public:
    Simulator(const RunOptions&, int argc, char** argv);
    ~Simulator();
    Simulator(const Simulator&) = delete;
    void step(const Stimulus&);
    void probe(const Stimulus&); // Settled inputs with clock stopped; no model transition.
    Field cursor() const { return model_->cursor(); }
    const Config& config() const { return config_; }
    uint64_t cycles() const { return cycles_; }
    Environment& environment() { return *environment_; }
    Scoreboard& scoreboard() { return *scoreboard_; }
};
} // namespace len5::pcgen
