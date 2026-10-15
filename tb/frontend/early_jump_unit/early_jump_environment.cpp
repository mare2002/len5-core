// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Causal ledger adapted from pc_gen_environment; no BPU, queue or branch RTL replica.
#include "early_jump_environment.hh"
namespace len5::early {
Stimulus bundle(Config cfg,uint64_t pc,uint64_t id) {
    Stimulus s; s.request_pc=pc; s.bundle_id=id; s.inputs.valid=s.inputs.ready=true;
    const uint64_t base=(pc/cfg.bundle_bytes())*cfg.bundle_bytes();
    for(unsigned k=0;k<cfg.lanes;++k) { s.inputs.words[k]=0x13; s.inputs.predictions[k].pc=base+k*4; }
    s.inputs.mask=request_mask(pc,s.inputs.predictions,cfg); return s;
}
void Environment::input_change(const Inputs& i) {
    if(!i.rst_n && !in_reset_) {
        ++epoch_; held_.reset(); requests_.clear(); for(auto& p:records_) p.second.live=false;
    }
    in_reset_=!i.rst_n;
}
void Environment::request(const Stimulus& s) {
    if(!s.bundle_id || !requests_.emplace(s.bundle_id,s).second) throw EnvironmentError("duplicate/absent fetch request identity");
}
const Instruction& Environment::instruction(uint64_t id) const {
    const auto p=records_.find(id);
    if(p==records_.end() || !p->second.live) throw EnvironmentError("absent/canceled instruction id="+std::to_string(id));
    return p->second;
}
void Environment::validate(const Stimulus& s,uint64_t cycle) const {
    if(s.campaign!=Campaign::Architectural || !s.inputs.rst_n) return;
    const auto& i=s.inputs;
    if(s.malformed) throw EnvironmentError("architectural transaction marked malformed");
    if(i.call_confirm && i.ret_confirm) throw EnvironmentError("simultaneous confirmation types forbidden by producer");
    if(i.flush && i.ready) throw EnvironmentError("output spill withdraws ready on frontend flush");
    if(held_ && !i.flush) {
        if(!i.valid || s.bundle_id!=held_->bundle_id || !i.same_bundle(held_->inputs))
            throw EnvironmentError("buffered response changed/withdrawn while stalled");
    }
    if(i.valid && !i.flush) {
        const auto request=requests_.find(s.bundle_id);
        if(request==requests_.end() || !i.same_bundle(request->second.inputs) || s.request_pc!=request->second.request_pc
            || s.requested_cycle!=request->second.requested_cycle || s.available_cycle!=request->second.available_cycle)
            throw EnvironmentError("response is not associated with its saved request metadata");
        if(!s.bundle_id || cycle<s.available_cycle || s.available_cycle<s.requested_cycle+s.response_delay)
            throw EnvironmentError("response lacks identity or precedes independently scheduled request availability");
        if(i.mask!=request_mask(s.request_pc,i.predictions,config_)) throw EnvironmentError("mask disagrees with start/first hit-and-taken interval");
        const uint64_t base=(s.request_pc/config_.bundle_bytes())*config_.bundle_bytes();
        for(unsigned k=0;k<config_.lanes;++k) {
            if(i.predictions[k].pc!=base+k*4) throw EnvironmentError("saved lane PCs incoherent with request bundle");
            if(i.predictions[k].hit && i.predictions[k].target%4) throw EnvironmentError("architectural BPU target misaligned");
            if(!decode(i.words[k]).valid) throw EnvironmentError("architectural bundle contains unsupported encoding");
            if(s.execution_known[k]) {
                const auto result=outcome(i.words[k],i.predictions[k].pc,s.rs1_value[k],s.rs2_value[k]);
                if(result.taken!=s.executed_taken[k] || result.target!=s.executed_target[k])
                    throw EnvironmentError("execution context disagrees with encoded instruction or x0 semantics");
            }
        }
    }
    if(i.call_confirm || i.ret_confirm) {
        const auto& r=instruction(s.confirmation_id); const auto d=decode(r.word);
        if(r.resolved || r.confirmed || r.fault || cycle<r.available_cycle)
            throw EnvironmentError("confirmation is duplicate, faulting or premature");
        if(i.call_confirm ? d.kind!=Kind::Call || i.link!=r.pc+4 : d.kind!=Kind::Return)
            throw EnvironmentError("confirmation type/link is not a supported accepted operation");
        for(const auto& p:records_) if(p.first<r.id && p.second.live && !p.second.resolved)
            throw EnvironmentError("younger confirmation passed an unresolved older control instruction");
    }
    if(i.flush && s.reason=="misprediction") {
        const auto& r=instruction(s.recovery_id);
        if(!decode(r.word).control() || cycle<r.available_cycle) throw EnvironmentError("recovery lacks mature control source");
        const bool wrong=r.prediction.hit && r.prediction.taken ? !r.actual_taken || r.prediction.target!=r.actual_target : r.actual_taken;
        if(!wrong) throw EnvironmentError("misprediction recovery disagrees with independent execution/prediction history");
    }
}
void Environment::consume(const Stimulus& s,const Transition& t,uint64_t cycle) {
    if(s.campaign!=Campaign::Architectural || !s.inputs.rst_n) return;
    const auto& i=s.inputs;
    if(i.call_confirm || i.ret_confirm) { auto& r=records_.at(s.confirmation_id); r.confirmed=r.resolved=true; }
    if(i.flush) {
        held_.reset(); requests_.clear(); ++epoch_;
        const uint64_t source=s.reason=="misprediction"?s.recovery_id:0;
        for(auto& p:records_) {
            if(!source || p.first>source) p.second.live=false;
            if(p.first==source) p.second.resolved=true;
        }
        return;
    }
    if(i.valid && !i.ready) held_=s;
    if(t.accepted) {
        held_.reset(); requests_.erase(s.bundle_id);
        for(unsigned k=0;k<config_.lanes;++k) if(t.selection.retained&(1u<<k)) {
            const auto d=decode(i.words[k]); const uint64_t id=next_id_++;
            if(!d.control()) continue;
            Instruction r; r.id=id; r.bundle_id=s.bundle_id; r.epoch=epoch_; r.pc=i.predictions[k].pc; r.word=i.words[k];
            r.accepted_cycle=cycle; r.available_cycle=cycle+s.response_delay; r.prediction=i.predictions[k];
            r.actual_taken=d.kind!=Kind::Branch || s.executed_taken[k];
            r.actual_target=d.kind==Kind::Call || d.kind==Kind::Jal?r.pc+uint64_t(d.immediate):s.executed_target[k];
            if(!s.execution_known[k] && d.kind==Kind::Return && !t.selection.target.known && !r.actual_target) r.actual_target=r.pc+4;
            if(int(k)==t.selection.lane && t.selection.correction.known && t.selection.correction.value) {
                r.prediction.hit=r.prediction.taken=true; r.prediction.target=i.feedback;
                if(!s.execution_known[k] && d.kind==Kind::Return && !r.actual_target) r.actual_target=i.feedback;
            }
            r.fault=r.actual_taken && r.actual_target%4;
            records_.emplace(r.id,r);
        }
    }
}
std::vector<Instruction> Environment::pending(uint64_t cycle) const {
    std::vector<Instruction> result;
    for(const auto& p:records_) if(p.second.live && !p.second.resolved && !p.second.confirmed) {
        if(cycle>=p.second.available_cycle) result.push_back(p.second);
        break; // Scalar ordered branch producer, never skip a younger instruction past this one.
    }
    return result;
}
void Environment::resolve_correct(uint64_t id) { instruction(id); records_.at(id).resolved=true; }
void Environment::prune(uint64_t cycle) {
    for(auto p=records_.begin();p!=records_.end();) {
        if(!p->second.live || (p->second.resolved && cycle>p->second.accepted_cycle+64)) p=records_.erase(p); else ++p;
    }
}
} // namespace len5::early
