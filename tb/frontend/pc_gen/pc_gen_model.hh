// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace len5::pcgen {
enum class Campaign { Architectural, Stress, Characterization };
enum class Event { Reset, Commit, TakenRecovery, FallthroughRecovery, Early, Prediction,
                   Sequential, Hold, Unknown };
const char* name(Event);
const char* name(Campaign);

struct Config {
    uint64_t boot_pc = 0;
    unsigned xlen = 64, instruction_bytes = 4, bundle_instructions = 8;
    uint64_t bundle_bytes() const { return uint64_t(instruction_bytes) * bundle_instructions; }
    void validate() const;
};

// Approved PC rules are invariant across profiles. Only residual output
// qualification/acknowledgment assumptions are configurable.
struct Contract {
    bool valid_on_recovery = true; // I/Q5: suppress ordinary offers on E/R, keep J valid
    bool always_ready = true;      // I/Q5: sole active E/R producer sees ready
    static Contract strict();
    std::vector<std::string> assumptions() const;
};

struct Inputs {
    bool rst_n = true, commit = false, branch_valid = false, mispredict = false, taken = false;
    bool prediction = false, ready = false, early = false;
    uint64_t commit_pc = 0, branch_pc = 0, branch_target = 0, prediction_target = 0;
    uint64_t early_base = 0, early_offset = 0;
    bool recovery() const { return branch_valid && mispredict; }
    unsigned combination() const { return (commit ? 8 : 0) + (recovery() ? 4 : 0)
                                         + (early ? 2 : 0) + (prediction ? 1 : 0); }
    bool operator==(const Inputs&) const;
};

struct Field {
    uint64_t value = 0;
    bool known = false;
    std::string requirement, evidence, assumptions, question;
};
struct Expected {
    Field pc, valid, branch_ready, early_target;
};
struct Transition {
    Event event = Event::Unknown;
    Field next_pc;
    bool ordinary_acceptance = false;
    bool acceptance_known = false;
    bool control_acceptance_known = false, control_accepted = false;
};
struct Stimulus {
    Inputs inputs;
    Campaign campaign = Campaign::Stress;
    std::string scenario, test_name, requirements;
    uint64_t branch_id = 0, early_id = 0, commit_id = 0;
    int prediction_lane = -1;
    std::string branch_cause, early_source;
    uint64_t record_age = 0;
    bool malformed = false;
};

// Pure behavioral model: no Verilator headers, DUT handles or observed values.
class ReferenceModel {
    Config config_;
    Contract contract_;
    Field cursor_;
    Field address(uint64_t, const char*, const char*, const std::string&) const;
public:
    ReferenceModel(Config, Contract);
    const Config& config() const { return config_; }
    const Contract& contract() const { return contract_; }
    Field cursor() const { return cursor_; }
    void input_change(const Inputs&);
    Expected outputs(const Inputs&, bool malformed = false) const;
    Transition plan(const Inputs&, bool malformed = false) const;
    void rising_edge(const Transition& transition) { cursor_ = transition.next_pc; }
    uint64_t sequential(uint64_t cursor) const;
};

std::string hex64(uint64_t);
std::string json_quote(const std::string&);
std::string inputs_json(const Inputs&);
std::string field_json(const Field&);
std::string expected_json(const Expected&);
// Historical Q IDs remain tracked; this describes their current resolution.
std::string specification_status_json();
} // namespace len5::pcgen
