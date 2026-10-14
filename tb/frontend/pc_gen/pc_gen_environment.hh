// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_model.hh"
#include <map>
#include <stdexcept>

namespace len5::pcgen {
struct EnvironmentError : std::runtime_error { using std::runtime_error::runtime_error; };
enum class InstructionKind { Ordinary, Branch, DirectJump, Return };
struct Instruction {
    uint64_t id = 0, epoch = 0, pc = 0, fetched_cycle = 0, available_cycle = 0;
    bool live = true, resolved = false, early_applied = false, committed = false;
    InstructionKind kind = InstructionKind::Ordinary;
    bool actual_taken = false, predicted_taken = false;
    uint64_t actual_target = 0, offset = 0, predicted_target = 0, return_prediction = 0;
};
class Environment {
    Config config_;
    uint64_t next_id_ = 1, epoch_ = 0;
    bool in_reset_ = false, branch_blocked_ = false;
    uint64_t held_early_ = 0;
    std::map<uint64_t, Instruction> instructions_;
    std::map<uint64_t, uint64_t> commits_;
public:
    explicit Environment(Config c): config_(c) {}
    uint64_t epoch() const { return epoch_; }
    void input_change(const Inputs&);
    void accept_bundle(uint64_t cursor, const Stimulus&, uint64_t cycle);
    uint64_t instruction_at(uint64_t pc) const;
    void describe(uint64_t id, InstructionKind, bool taken, uint64_t target, uint64_t offset = 0);
    void correct_return_execution(uint64_t id, uint64_t actual_target);
    void request_commit(uint64_t id, uint64_t target);
    const Instruction& instruction(uint64_t id) const;
    void validate(const Stimulus&, Field cursor, uint64_t cycle) const;
    void consume(const Stimulus&, const Transition&);
    // Generator-only queries operate on independently generated live records.
    std::vector<uint64_t> live_records() const;
    void set_availability(uint64_t id, uint64_t cycle);
    void complete_correct_resolution(uint64_t id);
    void prune(uint64_t cycle, uint64_t retention = 128);
    bool branch_blocked() const { return branch_blocked_; }
    void resume_after_backend_flush() { branch_blocked_ = false; }
};
} // namespace len5::pcgen
