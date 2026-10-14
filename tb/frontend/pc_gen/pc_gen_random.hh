// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_driver.hh"
#include <array>
#include <random>

namespace len5::pcgen {
// Policy v3 permits prediction revisions during stalls and uses source-configured bundle widths and raw deterministic engine draws.
struct RandomWeights {
    unsigned normal=40, stall=20, branch=15, early=10, commit=5, overlap=5, reset=5;
    unsigned prediction=25, ready=65;
    void parse(const std::string&);
    std::string text() const;
};
class RandomScenarios {
    Simulator& sim_;
    RunOptions options_;
    RandomWeights weights_;
    std::mt19937_64 events_, payloads_, latencies_;
    Campaign campaign_=Campaign::Architectural;
    uint64_t described_=0, held_early_=0, backend_wait_=0, burst_=0, last_recovery_=0;
    bool memory_ready_=true, prior_reset_=false;
    uint64_t held_prediction_pc_=0, held_prediction_target_=0;
    int held_prediction_lane_=0;
    bool have_prediction_=false, held_prediction_=false;
    uint64_t last_return_cycle_=0, last_fetch_cycle_=UINT64_MAX;
    uint64_t guided_choices_=0, hold_remaining_=0, normal_remaining_=0;
    Stimulus held_controls_;
    uint64_t address(uint64_t old=0);
    uint64_t displacement();
    bool ready();
    unsigned action();
    Stimulus base(Campaign, const char*);
    Stimulus architectural();
    Stimulus stress(bool characterization);
    void describe_fetched();
public:
    RandomScenarios(Simulator&, const RunOptions&);
    void run();
};
} // namespace len5::pcgen
