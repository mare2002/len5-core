// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "early_jump_model.hh"
#include <map>
#include <optional>
#include <stdexcept>
namespace len5::early {
struct EnvironmentError : std::runtime_error { using std::runtime_error::runtime_error; };
struct Instruction {
    uint64_t id=0,bundle_id=0,epoch=0,pc=0,accepted_cycle=0,available_cycle=0;
    uint32_t word=0;
    Prediction prediction;
    bool live=true,resolved=false,confirmed=false,fault=false,actual_taken=false;
    uint64_t actual_target=0;
};
class Environment {
    Config config_;
    uint64_t next_id_=1,next_bundle_=1,epoch_=0;
    bool in_reset_=false;
    std::optional<Stimulus> held_;
    std::map<uint64_t,Stimulus> requests_;
    std::map<uint64_t,Instruction> records_;
public:
    explicit Environment(Config c):config_(c) {}
    uint64_t epoch() const { return epoch_; }
    uint64_t allocate_bundle() { return next_bundle_++; }
    void request(const Stimulus&);
    void input_change(const Inputs&);
    void validate(const Stimulus&,uint64_t cycle) const;
    void consume(const Stimulus&,const Transition&,uint64_t cycle);
    std::vector<Instruction> pending(uint64_t cycle) const;
    void resolve_correct(uint64_t id);
    const Instruction& instruction(uint64_t id) const;
    void prune(uint64_t cycle);
};
Stimulus bundle(Config,uint64_t pc,uint64_t id=0);
} // namespace len5::early
