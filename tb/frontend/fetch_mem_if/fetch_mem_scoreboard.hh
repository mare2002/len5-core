// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_mem_model.hh"
#include <fstream>
#include <optional>
namespace len5::fetchmem {
struct Outputs {
    bool fetch_ready=false,request_valid=false,write=false,response_ready=false,valid=false;
    uint64_t address=0;unsigned mask=0;
    std::array<Prediction,MaxLanes> predictions{};
    Payload payload;
};
struct Sample {
    uint64_t cycle=0,time=0;
    std::string phase;
    Stimulus stimulus; Inputs observed;
    State before,after; Transition transition;
    Expected expected;Outputs actual;bool injected=false;
};
std::string sample_json(const Sample&,unsigned);
class Coverage {
    Config cfg_;
    std::map<std::string,uint64_t> counts_;
    uint64_t matrix_[3][8]={};
    uint64_t last_cycle_[3]={UINT64_MAX,UINT64_MAX,UINT64_MAX};
    unsigned stalls_[3][3]={};
    std::string previous_[3];
    bool delivered_before_[3]={},last_error_[3]={};
    uint64_t delivered_epoch_[3]={};
public:
    explicit Coverage(Config c):cfg_(c) {}
    void sample(const Sample&,bool);
    uint64_t count(const std::string& k) const;
    unsigned holes(Campaign) const;
    std::string json() const;
};
class Scoreboard {
    Config cfg_;Contract contract_;uint64_t seed_;
    std::string directory_,replay_,metadata_="null";
    bool full_;
    std::ofstream journal_;
    std::deque<Sample> history_;
    std::optional<Sample> coverage_pre_;
    bool coverage_pre_matched_=false;
    std::vector<std::string> discrepancies_;
    std::map<std::string,uint64_t> requirements_,assumptions_,unknowns_,dont_cares_,scenarios_,observations_,campaign_requirements_;
    std::map<std::string,std::string> characterization_;
    uint64_t checks_=0,field_errors_=0,transactions_=0,errors_=0,cycles_=0,samples_=0,pre_=0;
    uint64_t confirmed_=0,provisional_=0,injected_=0,environment_=0,framework_=0;
    uint64_t campaign_checks_[3]={},campaign_cycles_[3]={},campaign_errors_[3]={};
    uint64_t digest_=UINT64_C(14695981039346656037);
    State final_;
    void mismatch(const Sample&,const std::string&,const Field&,uint64_t);
    void compare(const Sample&,const std::string&,const Field&,uint64_t,bool&);
public:
    Coverage coverage;
    Scoreboard(Config,Contract,uint64_t,const std::string&,bool);
    bool sample(const Sample&); // False means physical protocol controls diverged: stop, never repair oracle.
    void problem(const std::string&,const std::string&);
    void metadata(const std::string& m,const std::string& r) {metadata_=m;replay_=r;}
    void random_metadata(const std::string& m) {metadata_=m;}
    void final_state(const State& s) {final_=s;}
    uint64_t checks() const {return checks_;}
    uint64_t errors() const {return field_errors_;}
    int finish(const std::string&,bool,const std::string&);
};
} // namespace len5::fetchmem
