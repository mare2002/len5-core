// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Causal identity/epoch/held-response concepts adapted from EJU environment.
#include "fetch_mem_environment.hh"
#include "early_jump_instructions.hh"
namespace len5::fetchmem {
Offer make_offer(const Config& c,uint64_t id,uint64_t start,unsigned variant,unsigned errors,unsigned cause) {
    Offer o;o.id=id;o.start=start;
    const uint64_t base=(start/c.bytes())*c.bytes();
    for(unsigned k=0;k<c.lanes;++k) {
        auto& p=o.predictions[k];p.pc=base+4*k;p.target=UINT64_C(0x80000000)+id*256+k*4;
        const unsigned kind=(variant+k)%4;p.hit=kind&2;p.taken=kind&1;
        // Distinguishable valid ADDI words. The oracle never decodes these payloads.
        o.memory_data.words[k]=((unsigned(id*17+k*13)&4095)<<20)|((k%31+1)<<7)|0x13;
        o.memory_data.causes[k]=cause;
    }
    o.mask=request_mask(start,o.predictions,c);o.memory_data.errors=errors&c.mask();return o;
}
void Environment::input_change(const Inputs& i) {
    if(!i.rst_n && !in_reset_) {pending_.clear();answered_.clear();held_response_.reset();held_address_.reset();++epoch_;branch_context_=exception_context_=false;}
    in_reset_=!i.rst_n;
}
bool Environment::early_context() const {
    if(answered_.empty())return false;
    const auto& o=answered_.front().offer;
    for(unsigned k=0;k<cfg_.lanes;++k) if(o.mask&(1u<<k)) {
        const auto d=early::decode(o.memory_data.words[k]);
        if(d.kind==early::Kind::Jal || d.kind==early::Kind::Call) return !(o.predictions[k].hit&&o.predictions[k].taken);
        if(d.kind==early::Kind::Return)return false; // No RAS oracle at this boundary.
    }
    return false;
}
Stimulus Environment::compose(const Offer* offer,uint64_t cycle,bool respond,bool ready,bool grant,const std::string& reason,Campaign c) const {
    Stimulus s;s.campaign=c;s.reason=reason;s.inputs.flush=!reason.empty();s.inputs.consumer_ready=ready;
    s.inputs.grant=grant && pending_.size()<cfg_.depth && !s.inputs.flush;
    if(offer) {s.request_id=offer->id;s.start=offer->start;s.latency=offer->latency;s.memory_data=offer->memory_data;
        s.inputs.fetch_valid=true;s.inputs.predictions=offer->predictions;s.inputs.mask=offer->mask;}
    if(!pending_.empty() && (held_response_ || (respond && cycle>=pending_.front().accepted+pending_.front().offer.latency))) {
        s.response_id=pending_.front().offer.id;s.inputs.response_valid=true;s.inputs.response=pending_.front().offer.memory_data;
    }
    return s;
}
void Environment::validate(const Stimulus& s,const Transition& t,uint64_t cycle) const {
    const auto& i=s.inputs;if(!i.rst_n)return;
    if(s.malformed) {if(s.campaign==Campaign::Architectural)throw EnvironmentError("FM18: malformed architectural transaction");return;}
    if(i.flush) {
        if(i.grant && i.fetch_valid)throw EnvironmentError("FQ02: active protocol withdraws grant on flush");
        if(s.campaign==Campaign::Architectural && i.consumer_ready && s.reason!="early")throw EnvironmentError("FM14: recovery withdraws downstream ready");
        if(s.campaign==Campaign::Architectural && s.reason=="early" && !early_context())throw EnvironmentError("FM15: early flush lacks eligible current answer");
        return;
    }
    if(held_address_ && (!i.fetch_valid || i.predictions[0].pc!=*held_address_))throw EnvironmentError("FQ01: ordinary stalled request address withdrawn/changed");
    if(held_response_ && (!i.response_valid || s.response_id!=held_response_->first || !(i.response==held_response_->second)))throw EnvironmentError("FM18: held response changed/withdrawn");
    if(i.fetch_valid) {
        if(!s.request_id)throw EnvironmentError("FM18: missing request identity");
        if(accepted_ids_.count(s.request_id))throw EnvironmentError("FM18: accepted/canceled identity reused");
        for(const auto& q:pending_)if(q.offer.id==s.request_id)throw EnvironmentError("FM18: duplicate accepted request identity");
        for(const auto& q:answered_)if(q.offer.id==s.request_id)throw EnvironmentError("FM18: duplicate answered request identity");
        if(s.campaign==Campaign::Architectural) {
            if(i.mask!=request_mask(s.start,i.predictions,cfg_))throw EnvironmentError("FM18: incoherent validity mask");
            const uint64_t base=(s.start/cfg_.bytes())*cfg_.bytes();
            for(unsigned k=0;k<cfg_.lanes;++k)if(i.predictions[k].pc!=base+4*k)throw EnvironmentError("FM18: incoherent lane PCs");
        }
    }
    if(t.k && pending_.size()>=cfg_.depth && !(s.turnover && t.r))throw EnvironmentError("FM18: memory overcapacity grant");
    if(i.response_valid) {
        if(pending_.empty()) {
            if(!t.k || s.latency!=0 || s.response_id!=s.request_id)
                throw EnvironmentError("FM18: response without an accepted request");
            if(!(i.response==s.memory_data))throw EnvironmentError("FM18: same-edge response assigned to wrong request");
        } else {
            const auto& q=pending_.front();
            if(q.offer.id!=s.response_id)throw EnvironmentError("FM18: out-of-order/duplicate response identity");
            if(cycle<q.accepted+q.offer.latency || cycle<=q.accepted)throw EnvironmentError("FM18: response violates declared latency");
            if(!(i.response==q.offer.memory_data))throw EnvironmentError("FM18: response data/error assigned to wrong request");
        }
    }
}
void Environment::consume(const Stimulus& s,const Transition& t,uint64_t cycle) {
    const auto& i=s.inputs;if(!i.rst_n)return;
    if(s.malformed) {if(i.flush){pending_.clear();answered_.clear();held_response_.reset();held_address_.reset();++epoch_;}return;}
    if(t.d) {
        if(answered_.empty() || answered_.front().offer.id!=t.delivered_id)throw std::logic_error("model/environment delivery identity disagreement");
        const auto& o=answered_.front().offer;
        for(unsigned k=0;k<cfg_.lanes;++k)if(o.mask&(1u<<k)) {
            if(early::decode(o.memory_data.words[k]).control())branch_context_=true;
            if(o.memory_data.errors&(1u<<k))exception_context_=true;
        }
        answered_.pop_front();
    }
    if(i.flush){pending_.clear();answered_.clear();held_response_.reset();held_address_.reset();branch_context_=exception_context_=false;++epoch_;return;}
    if(t.k) {
        Offer o;o.id=s.request_id;o.start=s.start;o.latency=s.latency;o.predictions=i.predictions;o.mask=i.mask;o.memory_data=s.memory_data;
        accepted_ids_.insert(o.id);pending_.push_back({o,cycle,epoch_});held_address_.reset();
    } else if(i.fetch_valid)held_address_=i.predictions[0].pc;
    if(t.r){if(pending_.empty())throw std::logic_error("model/environment response identity disagreement");answered_.push_back(pending_.front());pending_.pop_front();held_response_.reset();}
    else if(i.response_valid)held_response_=std::make_pair(s.response_id,i.response);
}
} // namespace len5::fetchmem
