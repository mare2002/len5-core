// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Semantic queues and lifecycle accounting; no Verilator or observed output dependency.
#include "fetch_mem_model.hh"
#include <sstream>
#include <tuple>
namespace len5::fetchmem {
void Config::validate() const {
    if((lanes!=1 && lanes!=2 && lanes!=4 && lanes!=8) || depth!=2 || xlen!=64 || ilen!=32 || cause_bits!=5 || req_skip!=1 || ans_skip!=0)
        throw std::invalid_argument("FM19/FQ08: support N=1/2/4/8, XLEN=64, ILEN=32, depth=2, request bypass and registered answer; source configuration is not overridden");
}
void Contract::validate() const { if(profile!="integrated" && profile!="established") throw std::invalid_argument("unknown fetch memory contract"); }
std::string Contract::json() const {
    return "{\"profile\":"+json_quote(profile)+",\"memory\":\"ordered-nonnegative-latency-capacity-2\",\"cancellation\":\"atomic-coordinated\",\"timing\":\"I:registered-answer-no-lookahead;release-one-empty-edge\",\"raw_record\":"+(raw_transport?"true":"false")+"}";
}
Field known(uint64_t v,const char* r,const char* e,std::string a) { return {v,true,r,e,a,{}}; }
Field unknown(const std::string& q) { return {0,false,{},"Q",{},q}; }
Field dont_care(const std::string& q) { return {0,false,{},"",{},"DC:"+q}; }
bool Inputs::operator==(const Inputs& i) const {
    return std::tie(rst_n,flush,fetch_valid,grant,response_valid,consumer_ready,mask)==std::tie(i.rst_n,i.flush,i.fetch_valid,i.grant,i.response_valid,i.consumer_ready,i.mask)
        && predictions==i.predictions && response==i.response;
}
unsigned request_mask(uint64_t pc,const std::array<Prediction,MaxLanes>& p,const Config& c) {
    if(pc%4) throw std::invalid_argument("FM18: architectural start is not instruction aligned");
    const unsigned start=(pc%c.bytes())/4;
    unsigned end=c.lanes-1;
    for(unsigned k=start;k<c.lanes;++k) if(p[k].hit && p[k].taken) { end=k; break; }
    return ((1u<<(end+1))-1)&~((1u<<start)-1);
}
ReferenceModel::ReferenceModel(Config c,Contract p):cfg_(c),contract_(p) { c.validate(); p.validate(); }
void ReferenceModel::cancel(State& n,Campaign) const {
    for(const auto& q:n.outstanding) if(q.id) {++n.totals.canceled;++n.campaigns[unsigned(q.campaign)].canceled;}
    for(const auto& a:n.completed) if(a.request.id) {
        auto& c=n.campaigns[unsigned(a.request.campaign)];++n.totals.canceled;++c.canceled;
        ++n.totals.canceled_buffered;++c.canceled_buffered;
        if(a.payload.errors&a.request.mask){++n.totals.fault_cancellations;++c.fault_cancellations;}
    }
    for(const auto& a:n.answers) if(a.request.id) {
        auto& c=n.campaigns[unsigned(a.request.campaign)];++n.totals.canceled;++c.canceled;
        ++n.totals.canceled_buffered;++c.canceled_buffered;
        if(a.payload.errors&a.request.mask){++n.totals.fault_cancellations;++c.fault_cancellations;}
    }
    n.outstanding.clear(); n.completed.clear(); n.answers.clear();
}
void ReferenceModel::input_change(const Stimulus& s) {
    if(!s.inputs.rst_n) {
        if(!state_.in_reset) { cancel(state_,s.campaign); ++state_.epoch; }
        state_.initialized=true; state_.released=false; state_.association_known=true; state_.in_reset=true;
    } else state_.in_reset=false;
}
Expected ReferenceModel::outputs(const Stimulus& s) const {
    const auto& i=s.inputs; Expected e;
    const bool credit=i.rst_n && !i.flush && state_.outstanding.size()+state_.completed.size()<cfg_.depth;
    e.fetch_ready=known(i.grant && credit,"FM02","I","reserved request slot (I)");
    e.request_valid=known(i.fetch_valid && credit,"FM02","I","reserved request slot (I)");
    e.request_address=i.fetch_valid?known(i.predictions[0].pc,"FM02","I","request-lane0-address (I)"):dont_care("inactive-request-address");
    e.write=known(0,"FM01");
    e.response_ready=e.valid=unknown("FQ05:before-reset"); e.mask=dont_care("inactive-output");
    for(auto& p:e.lanes) p.word=p.pc=p.hit=p.taken=p.target=p.error=p.cause=dont_care("inactive-output");
    if(!state_.initialized) return e;
    const bool active=i.rst_n && state_.released;
    e.response_ready=known(i.rst_n && !i.flush && (!state_.outstanding.empty() || (i.fetch_valid && i.grant && credit)),
                           "FM09","I","response fills an allocated entry (I)");
    e.valid=known(active && !state_.answers.empty(),"FM09","I","registered-answer (I)");
    if(!active || state_.answers.empty()) return e;
    if(i.flush && s.reason!="early") { e.mask=dont_care("canceled-output"); return e; }
    const auto& a=state_.answers.front();
    const bool meta=a.request.metadata_known;
    if(!meta)e.valid=unknown("FQ03/FQ04:ambiguous-response-output-qualification");
    e.mask=meta?known(a.request.mask,"FM05"):unknown("FQ03/FQ04:unknown-response-association");
    for(unsigned k=0;k<cfg_.lanes;++k) {
        const bool relevant=meta && (a.request.mask&(1u<<k));
        auto& p=e.lanes[k]; const auto& pred=a.request.predictions[k];
        const auto unused=[&](uint64_t v,const char* req) { return contract_.raw_transport?known(v,req,"I","FQ07:raw-record-preservation (I)"):dont_care("unused-lane-field"); };
        p.word=(relevant && !(a.payload.errors&(1u<<k)))?known(a.payload.words[k],"FM06"):unused(a.payload.words[k],"FM06");
        p.error=relevant?known((a.payload.errors>>k)&1,"FM11"):unused((a.payload.errors>>k)&1,"FM11");
        p.cause=(relevant && (a.payload.errors&(1u<<k)))?known(a.payload.causes[k],"FM11"):unused(a.payload.causes[k],"FM11");
        if(meta) {
            p.pc=relevant?known(pred.pc,"FM05"):unused(pred.pc,"FM05");
            p.hit=relevant?known(pred.hit,"FM05"):unused(pred.hit,"FM05");
            p.taken=relevant?known(pred.taken,"FM05"):unused(pred.taken,"FM05");
            p.target=relevant?known(pred.target,"FM05"):unused(pred.target,"FM05");
        } else p.pc=p.hit=p.taken=p.target=unknown("FQ03/FQ04:unknown-response-association");
    }
    return e;
}
Transition ReferenceModel::plan(const Stimulus& s,uint64_t cycle) const {
    Transition t; t.next=state_; auto& n=t.next; const auto& i=s.inputs;
    if(!i.rst_n) return t;
    const auto e=outputs(s);
    t.k=e.request_valid.known && e.request_valid.value && i.grant;
    t.r=i.response_valid && e.response_ready.known && e.response_ready.value;
    t.d=e.valid.known && e.valid.value && i.consumer_ready && (!i.flush || s.reason=="early");
    if(t.d) {
        const auto a=n.answers.front(); t.delivered_id=a.request.id;
        if(a.request.id) { ++n.totals.delivered; ++n.campaigns[unsigned(a.request.campaign)].delivered; }
        if(a.payload.errors&a.request.mask) { ++n.totals.fault_deliveries; ++n.campaigns[unsigned(a.request.campaign)].fault_deliveries; }
        n.answers.pop_front();
    }
    if(i.flush) {
        for(const auto& q:n.outstanding) t.canceled_ids.push_back(q.id);
        for(const auto& a:n.completed) t.canceled_ids.push_back(a.request.id);
        for(const auto& a:n.answers) t.canceled_ids.push_back(a.request.id);
        cancel(n,s.campaign); ++n.epoch; n.initialized=n.released=true; n.association_known=true;
        return t;
    }
    if(t.k) {
        Request q; q.campaign=s.campaign; q.id=s.request_id; q.epoch=n.epoch; q.start=s.start; q.accepted=cycle;
        q.mask=i.mask; q.predictions=i.predictions; q.metadata_known=n.association_known;
        n.outstanding.push_back(q); ++n.totals.accepted; ++n.campaigns[unsigned(q.campaign)].accepted;
    }
    if(t.r) {
        Answer a; a.payload=i.response; a.arrived=cycle;
        a.request=n.outstanding.front(); n.outstanding.pop_front();
        if(!s.question.empty()) { a.request.metadata_known=false; n.association_known=false; t.ambiguous=true;
            ++n.totals.ambiguous; ++n.campaigns[unsigned(s.campaign)].ambiguous; }
        t.response_id=a.request.id;
        if(a.request.id) { ++n.totals.responded; ++n.campaigns[unsigned(a.request.campaign)].responded; }
        if(i.response.errors) { ++n.totals.fault_responses; ++n.campaigns[unsigned(s.campaign)].fault_responses; }
        n.completed.push_back(a);
    }
    // Independent semantic queue: the answer spill has registered, non-lookahead capacity two.
    // A newly returned head may transfer directly on the same edge.
    if(state_.released && state_.answers.size()<2 && !n.completed.empty()) {
        n.answers.push_back(n.completed.front()); n.completed.pop_front();
    }
    n.released=n.initialized;
    return t;
}
std::string counters_json(const Counters& c,uint64_t pending) {
    std::ostringstream o; o<<"{\"accepted\":"<<c.accepted<<",\"responded\":"<<c.responded<<",\"delivered\":"<<c.delivered
        <<",\"canceled\":"<<c.canceled<<",\"canceled_buffered\":"<<c.canceled_buffered<<",\"pending\":"<<pending
        <<",\"fault_responses\":"<<c.fault_responses<<",\"fault_deliveries\":"<<c.fault_deliveries<<",\"fault_cancellations\":"<<c.fault_cancellations
        <<",\"ambiguous_completions\":"<<c.ambiguous<<'}'; return o.str();
}
std::string config_json(const Config& c) {
    std::ostringstream o; o<<"{\"LEN5_MULTIPLE_ISSUES\":"<<c.lanes<<",\"bundle_instructions\":"<<c.lanes<<",\"bundle_bytes\":"<<c.bytes()
        <<",\"metadata_depth\":"<<c.depth<<",\"request_skip\":"<<c.req_skip<<",\"answer_skip\":"<<c.ans_skip<<",\"xlen\":"<<c.xlen
        <<",\"source\":"<<json_quote(c.source)<<",\"fingerprint\":"<<json_quote(c.fingerprint)<<'}'; return o.str();
}
std::string inputs_json(const Inputs& i,unsigned lanes) {
    std::ostringstream o; o<<"{\"rst_n\":"<<i.rst_n<<",\"flush\":"<<i.flush<<",\"fetch_valid\":"<<i.fetch_valid<<",\"grant\":"<<i.grant
        <<",\"response_valid\":"<<i.response_valid<<",\"consumer_ready\":"<<i.consumer_ready<<",\"mask\":"<<i.mask<<",\"errors\":"<<i.response.errors<<",\"lanes\":[";
    for(unsigned k=0;k<lanes;++k) { if(k)o<<','; const auto& p=i.predictions[k]; o<<"{\"pc\":"<<json_quote(hex64(p.pc))<<",\"target\":"<<json_quote(hex64(p.target))
        <<",\"hit\":"<<p.hit<<",\"taken\":"<<p.taken<<",\"word\":"<<i.response.words[k]<<",\"cause\":"<<i.response.causes[k]<<'}'; }
    o<<"]}"; return o.str();
}
std::string state_json(const State& s) {
    std::ostringstream o; o<<"{\"epoch\":"<<s.epoch<<",\"initialized\":"<<s.initialized<<",\"released\":"<<s.released<<",\"association_known\":"<<s.association_known<<",\"outstanding\":[";
    bool first=true; for(const auto& q:s.outstanding) { if(!first)o<<',';first=false;o<<"{\"id\":"<<q.id<<",\"accepted\":"<<q.accepted<<",\"start\":"<<json_quote(hex64(q.start))<<'}'; }
    o<<"],\"completed\":[";first=true;for(const auto& a:s.completed){if(!first)o<<',';first=false;o<<"{\"id\":"<<a.request.id<<",\"arrived\":"<<a.arrived<<'}';}
    o<<"],\"answers\":[";first=true;for(const auto& a:s.answers){if(!first)o<<',';first=false;o<<"{\"id\":"<<a.request.id<<",\"arrived\":"<<a.arrived<<",\"metadata_known\":"<<a.request.metadata_known<<'}';}
    o<<"],\"obligations\":"<<counters_json(s.totals,s.outstanding.size()+s.completed.size()+s.answers.size())<<'}';return o.str();
}
std::string specification_json() {
    std::ostringstream o;o<<'{';
    for(unsigned k=1;k<=13;++k) {
        if(k>1)o<<',';
        o<<json_quote(std::string("FQ")+(k<10?"0":"")+std::to_string(k))<<':';
        if(k==3)
            o<<R"({"status":"supported","detail":"accepted allocation and its ordered response may coincide; FM-T34 checks exact association"})";
        else if(k==2 || k==4 || k==8)
            o<<R"({"status":"partial","detail":"reserved completion credit and separate cancel/drain contracts; broader integration remains scoped"})";
        else o<<R"({"status":"unresolved"})";
    }
    o<<'}';return o.str();
}
} // namespace len5::fetchmem
