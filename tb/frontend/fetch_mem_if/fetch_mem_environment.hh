// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_mem_model.hh"
#include <optional>
#include <unordered_set>
namespace len5::fetchmem {
struct EnvironmentError : std::runtime_error { using std::runtime_error::runtime_error; };
struct PhysicalRequest { Offer offer; uint64_t accepted=0,epoch=0; };
class Environment {
    Config cfg_;
    uint64_t next_id_=1,epoch_=0;
    bool in_reset_=false;
    std::unordered_set<uint64_t> accepted_ids_;
    std::deque<PhysicalRequest> pending_;
    std::deque<PhysicalRequest> answered_;
    std::optional<std::pair<uint64_t,Payload>> held_response_;
    std::optional<uint64_t> held_address_;
    bool branch_context_=false,exception_context_=false;
public:
    explicit Environment(Config c):cfg_(c) {}
    uint64_t allocate() { return next_id_++; }
    uint64_t epoch() const { return epoch_; }
    unsigned outstanding() const { return pending_.size(); }
    bool empty() const { return pending_.empty() && answered_.empty(); }
    bool branch_context() const { return branch_context_; }
    bool exception_context() const { return exception_context_; }
    bool early_context() const;
    void input_change(const Inputs&);
    Stimulus compose(const Offer*,uint64_t cycle,bool respond=true,bool ready=true,bool grant=true,
                     const std::string& reason={},Campaign=Campaign::Architectural) const;
    void validate(const Stimulus&,const Transition&,uint64_t) const;
    void consume(const Stimulus&,const Transition&,uint64_t);
};
Offer make_offer(const Config&,uint64_t id,uint64_t start,unsigned variant=0,unsigned errors=0,unsigned cause=1);
} // namespace len5::fetchmem
