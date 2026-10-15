// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_mem_environment.hh"
#include "fetch_mem_scoreboard.hh"
#include <memory>
class VerilatedContext;class VerilatedFstC;class Vfetch_mem_tb;
namespace len5::fetchmem {
struct RunOptions {
    uint64_t seed=1,cycles=10000,max_cycles=100000;
    bool random=false,guided=true,waves=false;
    unsigned expect_issues=0,expect_depth=0;
    Contract contract;
    std::string selection="all",campaign="all",weights,journal="auto",inject,run_dir,executable;
};
struct Timeout : std::runtime_error {using std::runtime_error::runtime_error;};
struct StopOnMismatch : std::runtime_error {using std::runtime_error::runtime_error;};
class Simulator {
    RunOptions options_;Config cfg_;
    std::unique_ptr<VerilatedContext> context_;
    std::unique_ptr<Vfetch_mem_tb> dut_;
    std::unique_ptr<VerilatedFstC> trace_;
    std::unique_ptr<ReferenceModel> model_;
    std::unique_ptr<Environment> environment_;
    std::unique_ptr<Scoreboard> scoreboard_;
    uint64_t cycle_=0;
    bool injected_=false;
    std::string scenario_="unspecified",title_="transport";
    Campaign campaign_=Campaign::Architectural;
    Transition last_;
    void drive(const Inputs&);
    Inputs read_inputs() const;
    Outputs read_outputs() const;
    void dump();
    bool sample(const Stimulus&,const State&,const Transition&,const char*);
public:
    Simulator(const RunOptions&,int,char**);
    ~Simulator();
    void begin(const std::string&,const std::string&,Campaign=Campaign::Architectural);
    void step(Stimulus);
    void probe(Stimulus);
    void tick(const Offer* =nullptr,bool respond=true,bool ready=true,bool grant=true,const std::string& reason={});
    void reset();
    void drain(unsigned limit=128);
    Offer offer(uint64_t pc,unsigned variant=0,unsigned errors=0,unsigned cause=1);
    uint64_t cycles() const {return cycle_;}
    const Config& config() const {return cfg_;}
    const State& state() const {return model_->state();}
    const Transition& last() const {return last_;}
    Environment& environment() {return *environment_;}
    Scoreboard& scoreboard() {return *scoreboard_;}
    Campaign campaign() const {return campaign_;}
    int finish(const std::string& reason={},bool all=false,const std::string& selection="all");
};
} // namespace len5::fetchmem
