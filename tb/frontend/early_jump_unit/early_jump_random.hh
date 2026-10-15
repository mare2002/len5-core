// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "early_jump_driver.hh"
#include <optional>
#include <random>
namespace len5::early {
struct Weights {
    unsigned ordinary=45,call=15,jump=15,ret=15,branch=10,confirm=35,restore=10,stall=25,reset=2;
    void parse(const std::string&);
    std::string text() const;
};
class RandomScenarios {
    Simulator& sim_;
    RunOptions options_;
    Weights weights_;
    std::mt19937_64 events_,payloads_,latencies_;
    std::optional<Stimulus> response_;
    uint64_t recovery_=0,guided_choices_=0,stall_left_=0,cooldown_=0;
    Campaign campaign_=Campaign::Architectural;
    bool release_=false;
    uint64_t address();
    Stimulus generated(Campaign,bool guided);
    Stimulus architectural();
    Stimulus stress(bool characterization);
public:
    RandomScenarios(Simulator&,const RunOptions&);
    void run();
};
} // namespace len5::early
