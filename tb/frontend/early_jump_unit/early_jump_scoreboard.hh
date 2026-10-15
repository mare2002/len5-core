// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "early_jump_model.hh"
#include <deque>
#include <fstream>
#include <map>
namespace len5::early {
struct Outputs {
    bool early=false,mem_flush=false;
    uint64_t base=0,offset=0;
    unsigned mask=0;
    std::array<Prediction,MaxLanes> predictions;
};
struct Sample {
    uint64_t cycle=0,time=0,epoch=0;
    std::string phase;
    Stimulus stimulus;
    State before,after;
    Transition transition;
    Inputs observed_inputs;
    Outputs actual;
    Expected expected;
    bool injected=false;
};
std::string sample_json(const Sample&,unsigned lanes);
class Coverage {
    Config config_;
    std::map<std::string,uint64_t> counters_;
    uint64_t matrix_[3][3][3][2]={};
    uint64_t previous_cycle_[3]={UINT64_MAX,UINT64_MAX,UINT64_MAX};
    unsigned stalls_[3]={};
    std::string previous_[3];
    bool reset_[3]={};
    bool restored_[3]={};
public:
    explicit Coverage(Config c):config_(c) {}
    void sample(const Sample&,bool matched);
    void increment(const std::string& k) { ++counters_[k]; }
    uint64_t count(const std::string& k) const;
    uint64_t combination(Campaign,unsigned operation,unsigned confirmation,bool flush) const;
    std::string json() const;
    unsigned holes(Campaign) const;
};
class Scoreboard {
    Config config_;
    Contract contract_;
    uint64_t seed_;
    std::string directory_,replay_,metadata_="null";
    bool full_,confidence_=true,guard_=false,guard_empty_=false;
    Field guard_top_;
    uint64_t guard_cycle_=0,guard_noops_=0;
    bool guard_independent_=true;
    std::ofstream journal_;
    std::deque<Sample> history_;
    std::vector<std::string> discrepancies_;
    std::map<std::string,uint64_t> requirements_,campaign_requirements_,assumptions_,unknowns_,dont_cares_,scenarios_,observations_;
    std::map<std::string,Sample> characterization_;
    uint64_t cycles_=0,samples_=0,pre_records_=0,transactions_=0,errors_=0,checks_=0,field_errors_=0;
    uint64_t confirmed_=0,provisional_=0,injected_=0,environment_errors_=0,framework_errors_=0;
    uint64_t digest_=UINT64_C(14695981039346656037);
    uint64_t campaign_cycles_[3]={},campaign_checks_[3]={},campaign_errors_[3]={};
    void mismatch(const Sample&,const std::string&,const Field&,uint64_t actual);
    void compare(const Sample&,const std::string&,const Field&,uint64_t actual,bool& failed);
public:
    Coverage coverage;
    Scoreboard(Config,Contract,uint64_t,const std::string&,bool full);
    void sample(const Sample&);
    void problem(const std::string&,const std::string&);
    void random_run(const std::string& metadata,const std::string& replay) { metadata_=metadata; replay_=replay; }
    int finish(const std::string& reason,bool complete_directed,const std::string& selection);
    uint64_t field_checks() const { return checks_; }
    uint64_t field_errors() const { return field_errors_; }
};
} // namespace len5::early
