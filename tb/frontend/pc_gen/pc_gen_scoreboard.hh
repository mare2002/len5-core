// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_model.hh"
#include <deque>
#include <fstream>
#include <map>

namespace len5::pcgen {
struct Outputs { uint64_t pc = 0, early_target = 0; bool valid = false, branch_ready = false; };
struct Sample {
    uint64_t cycle = 0, time = 0, epoch = 0;
    std::string phase;
    Stimulus stimulus;
    Field previous_pc;
    Inputs observed_inputs;
    Outputs actual;
    Expected expected;
    Transition transition;
    bool injected = false;
};
class Coverage {
    Config config_;
    uint64_t combinations_[16][2][2] = {};
    uint64_t resets_[16][2] = {};
    uint64_t campaign_combinations_[3][16][2][2] = {};
    uint64_t campaign_resets_[3][16][2] = {};
    bool previous_reset_[3] = {};
    uint64_t previous_cycle_[3] = {UINT64_MAX,UINT64_MAX,UINT64_MAX};
    unsigned campaign_stalls_[3] = {};
    std::string campaign_previous_[3];
    uint64_t previous_epoch_[3] = {};
    Inputs previous_inputs_[3];
    bool have_previous_[3] = {};
    std::string previous_event_;
    std::map<std::string, uint64_t> counters_;
    unsigned stall_length_ = 0;
public:
    explicit Coverage(Config cfg): config_(cfg) {}
    void sample(const Sample&, bool match);
    uint64_t combination_count(Campaign c, unsigned row, bool ready, bool taken) const;
    uint64_t reset_count(Campaign c, unsigned row, bool ready) const;
    static bool architectural_row(unsigned row);
    unsigned campaign_holes(Campaign c) const;
    unsigned matrix_holes() const;
    unsigned reset_holes() const;
    void write(const std::string&, const std::map<std::string,uint64_t>& requirements,
               const std::map<std::string,uint64_t>& assumptions,
               const std::map<std::string,uint64_t>& unknowns,
               const std::map<std::string,uint64_t>& dont_cares = {}) const;
    std::pair<unsigned,unsigned> feature_goals(std::ostream&, Campaign) const;
    void configuration_exclusions(std::ostream&) const;
};
class Scoreboard {
    Config config_;
    Contract contract_;
    uint64_t seed_;
    std::string directory_;
    std::ofstream journal_;
    bool full_journal_, pre_pc_matches_ = false;
    uint64_t pre_cycle_ = UINT64_MAX;
    std::deque<Sample> history_;
    uint64_t stimulus_digest_ = UINT64_C(14695981039346656037), cycles_ = 0;
    std::map<std::string,Sample> observations_;
    std::map<std::string,uint64_t> campaign_requirement_checks_;
    std::string random_metadata_ = "null", replay_command_;
    std::string config_source_, config_fingerprint_;
    unsigned issue_bits_ = 0;
    std::vector<std::string> discrepancies_;
    std::map<std::string, uint64_t> requirement_checks_, assumption_checks_, unknowns_, dont_cares_, scenarios_, campaigns_;
    uint64_t campaign_cycles_[3]={}, campaign_checks_[3]={}, campaign_errors_[3]={};
    uint64_t transactions_ = 0, errors_ = 0, field_checks_ = 0, field_errors_ = 0;
    uint64_t sampled_records_ = 0, pre_edge_records_ = 0;
    uint64_t confirmed_ = 0, provisional_ = 0, injected_ = 0, environment_errors_ = 0, framework_errors_ = 0;
    void compare(const Sample&, const char*, const Field&, uint64_t actual, bool& failed);
    void mismatch(const Sample&, const char*, const Field&, uint64_t actual);
public:
    Coverage coverage;
    Scoreboard(Config, Contract, uint64_t seed, const std::string& directory, bool full_journal = true);
    void random_run(const std::string& metadata, const std::string& replay_command);
    void build_configuration(const std::string& source, const std::string& fingerprint, unsigned bits) {
        config_source_=source; config_fingerprint_=fingerprint; issue_bits_=bits;
    }
    void sample(const Sample&);
    void problem(const std::string& kind, const std::string& reason);
    int finish(const std::string& reason, bool complete_suite, const std::string& selection);
    uint64_t field_checks() const { return field_checks_; }
};
std::string sample_json(const Sample&);
} // namespace len5::pcgen
