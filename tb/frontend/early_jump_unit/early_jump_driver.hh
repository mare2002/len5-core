// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "early_jump_environment.hh"
#include "early_jump_scoreboard.hh"
#include <memory>
class VerilatedContext;
class VerilatedFstC;
class Vearly_jump_tb;
namespace len5::early {
struct RunOptions {
    uint64_t seed=1,max_cycles=100000,cycles=10000;
    bool waves=false,random=false,guided=true;
    unsigned expect_issues=0,expect_depth=0;
    Contract contract;
    std::string selection="all",campaign="all",weights,journal="auto",inject,run_dir,executable;
};
struct Timeout : std::runtime_error { using std::runtime_error::runtime_error; };
class Simulator {
    RunOptions options_;
    std::unique_ptr<VerilatedContext> context_;
    std::unique_ptr<Vearly_jump_tb> dut_;
    std::unique_ptr<VerilatedFstC> trace_;
    Config config_;
    std::unique_ptr<ReferenceModel> model_;
    std::unique_ptr<Environment> environment_;
    std::unique_ptr<Scoreboard> scoreboard_;
    uint64_t cycles_=0;
    bool fault_=false;
    void drive(const Inputs&);
    Inputs read_inputs() const;
    Outputs read_outputs() const;
    void sample(const Stimulus&,const State&,const Transition&,const char* phase);
    void dump();
public:
    Simulator(const RunOptions&,int argc,char** argv);
    ~Simulator();
    void step(Stimulus);
    void probe(Stimulus);
    void reset();
    uint64_t cycles() const { return cycles_; }
    const Config& config() const { return config_; }
    const State& state() const { return model_->state(); }
    Environment& environment() { return *environment_; }
    Scoreboard& scoreboard() { return *scoreboard_; }
    uint64_t feedback(const Inputs& i) const { return model_->feedback(i); }
    void guard(const char* scenario,Campaign campaign=Campaign::Stress);
};
} // namespace len5::early
