// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_environment.hh"

namespace len5::pcgen {
void Environment::input_change(const Inputs& i) {
    if (!i.rst_n && !in_reset_) {
        ++epoch_;
        for (auto& entry : instructions_) entry.second.live = false;
        commits_.clear(); held_early_ = 0; branch_blocked_ = false;
    }
    in_reset_ = !i.rst_n;
    if (!i.early) held_early_ = 0;
}
void Environment::accept_bundle(uint64_t cursor, const Stimulus& s, uint64_t cycle) {
    if (cursor % config_.instruction_bytes) throw EnvironmentError("misaligned architectural bundle");
    const uint64_t first_lane = (cursor % config_.bundle_bytes()) / config_.instruction_bytes;
    const uint64_t base = (cursor / config_.bundle_bytes()) * config_.bundle_bytes();
    const unsigned last_lane = s.inputs.prediction
        ? unsigned(s.prediction_lane < 0 ? first_lane : s.prediction_lane) : config_.bundle_instructions - 1;
    for (unsigned lane = unsigned(first_lane); lane <= last_lane; ++lane) {
        Instruction r;
        r.id = next_id_++; r.epoch = epoch_; r.pc = base + lane * config_.instruction_bytes;
        r.fetched_cycle = cycle; r.available_cycle = cycle + 2;
        r.predicted_taken = s.inputs.prediction && lane == last_lane;
        r.predicted_target = s.inputs.prediction_target;
        instructions_.emplace(r.id, r);
    }
}
uint64_t Environment::instruction_at(uint64_t pc) const {
    for (auto r = instructions_.rbegin(); r != instructions_.rend(); ++r)
        if (r->second.live && r->second.epoch == epoch_ && r->second.pc == pc) return r->first;
    throw EnvironmentError("instruction was never fetched in the live epoch: " + hex64(pc));
}
const Instruction& Environment::instruction(uint64_t id) const {
    const auto r = instructions_.find(id);
    if (r == instructions_.end() || !r->second.live || r->second.epoch != epoch_)
        throw EnvironmentError("absent or squashed instruction id=" + std::to_string(id));
    return r->second;
}
void Environment::describe(uint64_t id, InstructionKind kind, bool taken, uint64_t target, uint64_t offset) {
    instruction(id);
    auto& r = instructions_.at(id);
    r.kind = kind; r.actual_taken = taken; r.actual_target = target; r.offset = offset;
    if (kind == InstructionKind::Return) r.return_prediction = target;
}
void Environment::correct_return_execution(uint64_t id, uint64_t target) {
    if (instruction(id).kind != InstructionKind::Return) throw EnvironmentError("execution correction is not a return");
    instructions_.at(id).actual_target = target;
}
void Environment::request_commit(uint64_t id, uint64_t target) {
    if (instruction(id).committed) throw EnvironmentError("duplicate commit control event");
    commits_[id] = target;
}
void Environment::validate(const Stimulus& s, Field cursor, uint64_t cycle) const {
    if (s.campaign != Campaign::Architectural || !s.inputs.rst_n) return;
    const auto& i = s.inputs;
    auto aligned = [&](uint64_t p) {
        if (p % config_.instruction_bytes) throw EnvironmentError("architectural address is misaligned: " + hex64(p));
    };
    if (i.prediction) {
        aligned(i.prediction_target);
        if (s.prediction_lane < 0 || unsigned(s.prediction_lane) >= config_.bundle_instructions)
            throw EnvironmentError("prediction needs an eligible offered-bundle lane");
        if (cursor.known && unsigned(s.prediction_lane) < (cursor.value % config_.bundle_bytes()) / config_.instruction_bytes)
            throw EnvironmentError("prediction precedes the starting instruction");
    }
    if (i.branch_valid) {
        if (!i.mispredict) throw EnvironmentError("current producer sends correct resolutions on the BPU path, not pc_gen");
        const auto& r = instruction(s.branch_id);
        if (r.kind == InstructionKind::Ordinary || r.resolved || r.committed || cycle < r.available_cycle || branch_blocked_)
            throw EnvironmentError("branch producer cannot resolve this record yet");
        if (i.branch_pc != r.pc || i.taken != r.actual_taken || i.branch_target != r.actual_target)
            throw EnvironmentError("resolution payload disagrees with the generated instruction");
        const bool mispredicted = r.predicted_taken != r.actual_taken
            || (r.predicted_taken && r.predicted_target != r.actual_target);
        if (i.mispredict != mispredicted) throw EnvironmentError("mispredict qualifier contradicts the generated prediction history");
        aligned(r.pc); if (r.actual_taken) aligned(r.actual_target);
    }
    if (i.early) {
        const auto& r = instruction(s.early_id);
        if (r.committed || cycle < r.available_cycle || (r.early_applied && held_early_ != r.id))
            throw EnvironmentError("early request is absent, premature or reused after release");
        if (r.kind == InstructionKind::DirectJump) {
            if(r.predicted_taken && !r.early_applied)
                throw EnvironmentError("current early producer does not correct an already-taken JAL prediction");
            const int64_t displacement = static_cast<int64_t>(r.offset);
            if (displacement < -1048576 || displacement > 1048574 || displacement % 2
                || i.early_base != r.pc || i.early_offset != r.offset || r.actual_target != r.pc + r.offset)
                throw EnvironmentError("early JAL payload is not a decoded instruction displacement");
        } else if (r.kind == InstructionKind::Return) {
            if (i.early_base != 0 || i.early_offset != r.return_prediction)
                throw EnvironmentError("return prediction disagrees with the generated saved address");
        } else throw EnvironmentError("early request does not name a fetched JAL/return");
        aligned(r.kind == InstructionKind::Return ? r.return_prediction : r.actual_target);
    }
    if (i.commit) {
        const auto& r = instruction(s.commit_id);
        const auto request = commits_.find(r.id);
        if (r.committed || cycle < r.available_cycle || request == commits_.end() || request->second != i.commit_pc)
            throw EnvironmentError("commit redirect lacks a live commit control event");
        aligned(i.commit_pc);
    }
}
void Environment::consume(const Stimulus& s, const Transition& t) {
    if (s.campaign != Campaign::Architectural || !s.inputs.rst_n || !t.next_pc.known || !t.control_accepted) return;
    uint64_t older = 0;
    if (t.event == Event::Commit) {
        older = s.commit_id; commits_.erase(older);
        instructions_.at(older).committed = true;
    } else if (t.event == Event::TakenRecovery || t.event == Event::FallthroughRecovery) {
        older = s.branch_id; instructions_.at(older).resolved = true; branch_blocked_ = true;
    } else if (t.event == Event::Early) {
        older = s.early_id; instructions_.at(older).early_applied = true; held_early_ = older;
        auto& record = instructions_.at(older);
        record.predicted_taken = true;
        record.predicted_target = record.kind == InstructionKind::Return ? record.return_prediction : record.pc + record.offset;
    }
    if (older) for (auto& r : instructions_) if (r.first > older) r.second.live = false;
}
std::vector<uint64_t> Environment::live_records() const {
    std::vector<uint64_t> result;
    for (const auto& p : instructions_) if (p.second.live && p.second.epoch == epoch_) result.push_back(p.first);
    return result;
}
void Environment::set_availability(uint64_t id, uint64_t cycle) {
    const auto& r = instruction(id);
    if (cycle < r.fetched_cycle + 2) throw EnvironmentError("instruction latency below causal minimum");
    instructions_.at(id).available_cycle = cycle;
}
void Environment::complete_correct_resolution(uint64_t id) {
    const auto& r = instruction(id);
    if (r.resolved || r.predicted_taken != r.actual_taken
        || (r.actual_taken && r.predicted_target != r.actual_target))
        throw EnvironmentError("BPU-only correct resolution contradicts history");
    instructions_.at(id).resolved = true;
}
void Environment::prune(uint64_t cycle, uint64_t retention) {
    // Abstract completed execution window, not a hardware queue-depth claim.
    // A held producer request and an outstanding commit token must survive.
    for (auto p = instructions_.begin(); p != instructions_.end();) {
        const auto& r = p->second;
        if (r.id != held_early_ && !commits_.count(r.id)
            && (!r.live || (cycle > r.fetched_cycle && cycle-r.fetched_cycle > retention
                && (r.kind==InstructionKind::Ordinary || r.resolved || r.committed))))
            p = instructions_.erase(p);
        else ++p;
    }
}
} // namespace len5::pcgen
