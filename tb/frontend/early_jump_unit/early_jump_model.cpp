// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "early_jump_model.hh"
#include <sstream>
#include <stdexcept>
#include <tuple>

namespace len5::early {
const char* name(Operation op) { return op==Operation::Push?"push":op==Operation::Pop?"pop":"none"; }
Field known(uint64_t v,const char* r,const char* e,std::string a) { return {v,true,r,e,a,{}}; }
Field unknown(const char* q) { return {0,false,{},"Q",{},q}; }
Field dont_care(const char* q) { return {0,false,{},"D",{},std::string("DC:")+q}; }
void Config::validate() const {
    if((lanes!=1 && lanes!=2 && lanes!=4 && lanes!=8) || depth!=4 || xlen!=64 || alen!=64 || instruction_bytes!=4)
        throw std::invalid_argument("EJ01/EQ09: require N=1,2,4,8; depth=4; XLEN=ALEN=64; ILEN=32");
}
Contract Contract::established() {
    Contract c; c.profile="established"; c.exception="unknown"; c.boundaries="unknown"; c.lifecycle="unknown"; return c;
}
void Contract::validate() const {
    if(order!="updated") throw std::invalid_argument("EQ07 is approved: qualified confirmation precedes restoration; require order=updated");
    if((profile!="len5_minimal" && profile!="established")
        || (exception!="restore" && exception!="unknown") || (boundaries!="recent" && boundaries!="unknown")
        || (lifecycle!="held" && lifecycle!="unknown")) throw std::invalid_argument("invalid named EJU contract policy");
}
std::string Contract::json() const {
    return "{\"profile\":"+json_quote(profile)+",\"EQ05_lifecycle\":"+json_quote(lifecycle)
        +",\"EQ07_order\":"+json_quote(order)+",\"EQ08_exception\":"+json_quote(exception)
        +",\"EQ09_boundaries\":"+json_quote(boundaries)+",\"recognition\":\"approved-x1-only-D\""
        +",\"taken_JAL\":\"approved-target-independent-suppression-D\""
        +",\"taken_RET\":\"approved-matching-RAS-suppression-D\""
        +",\"confirmation_restore\":\"approved-confirm-then-restore-D\"}";
}
bool Inputs::same_bundle(const Inputs& b) const { return words==b.words && predictions==b.predictions && mask==b.mask; }
bool Inputs::operator==(const Inputs& b) const {
    return same_bundle(b) && std::tie(rst_n,flush,valid,ready,call_confirm,ret_confirm,link,feedback)
        == std::tie(b.rst_n,b.flush,b.valid,b.ready,b.call_confirm,b.ret_confirm,b.link,b.feedback);
}
Field History::top() const {
    if(entries.empty()) return known?dont_care("empty-RAS-top"):unknown(uncertainty.c_str());
    const auto& e=entries.back();
    return len5::early::known(e.address,"RA03","D",dependency+(e.dependency.empty()?"":";"+e.dependency));
}
void History::reset() { entries.clear(); known=true; uncertainty.clear(); dependency="EQ02:empty-reset (I)"; }
void History::apply(Operation op,const Entry& entry,const Config& cfg,const Contract& contract) {
    if(op==Operation::None) return;
    if(op==Operation::Pop) {
        if(!entries.empty()) entries.pop_back();
        else if(known && contract.boundaries=="unknown") { known=false; uncertainty="EQ09:empty-pop"; }
        else if(known) dependency+=";EQ09:empty-pop-no-op (I)";
        return;
    }
    if(!known && contract.boundaries=="unknown") {
        // Unknown occupancy may already be full. Without an overflow contract,
        // a push cannot establish even the top (e.g. retain-old versus drop-oldest).
        entries.clear(); uncertainty="EQ09:push-with-unknown-occupancy"; return;
    }
    if(known && entries.size()==cfg.depth && contract.boundaries=="unknown") {
        entries.clear(); known=false; uncertainty="EQ09:overflow"; return;
    }
    if(entries.size()==cfg.depth) { entries.erase(entries.begin()); dependency+=";EQ09:drop-oldest (I)"; }
    entries.push_back(entry);
    if(!known && contract.boundaries=="recent" && entries.size()==cfg.depth) {
        known=true; uncertainty.clear(); dependency="EQ09:independent-full-known-suffix (I)";
    }
    // Keep provenance bounded: state dependencies are policy names, not an ever-growing event log.
    if(dependency.size()>300) dependency="EQ02/EQ05/EQ09:declared-reset-acceptance-boundary-contracts (I)";
}
ReferenceModel::ReferenceModel(Config cfg,Contract c):config_(cfg),contract_(c) { cfg.validate(); c.validate(); }
void ReferenceModel::input_change(const Inputs& i) {
    if(!i.rst_n) {
        state_.predictive.reset(); state_.confirmed.reset(); state_.initialized=true;
        state_.startup=true; state_.pending=false; state_.pending_known=true; state_.control_uncertainty.clear();
    }
}
Selection ReferenceModel::select(const Inputs& i) const {
    Selection s; s.retained=i.mask&config_.all_lanes();
    // Semantic oldest eligible instruction; no DUT mux, default lane, or internal pointer is mirrored.
    for(unsigned lane=0;lane<config_.lanes;++lane) if(i.mask&(1u<<lane)) {
        const auto d=decode(i.words[lane]);
        if(d.recognized()) { s.lane=int(lane); s.instruction=d; break; }
    }
    s.correction=known(0,"EJ05","I","EQ04:qualified-JAL-and-RAS-return-policy (I)");
    s.target=s.base=s.offset=dont_care("no-applicable-early-correction");
    if(s.lane<0) return s;
    const unsigned lane=unsigned(s.lane);
    s.retained&=(1u<<(lane+1))-1;
    const auto& pred=i.predictions[lane];
    if(s.instruction.kind==Kind::Call) s.offered=Operation::Push;
    if(s.instruction.kind==Kind::Return) s.offered=Operation::Pop;
    if(s.instruction.kind==Kind::Return) {
        if(!state_.predictive.entries.empty()) {
            s.target=state_.predictive.top(); s.offset=s.target;
            s.base=known(0,"EJ04","I","EQ03:canonical-return-operand-decomposition (I)");
            s.correction=known(!(pred.hit && pred.taken && pred.target==s.target.value),"EJ05","D",
                               s.target.assumptions);
        } else if(!state_.predictive.known) {
            s.correction=unknown(state_.predictive.uncertainty.c_str());
            s.target=s.base=s.offset=unknown("RA03:unknown-predictive-history");
        }
    } else if(pred.hit && pred.taken) {
        // Approved EQ04 policy: a taken BTB hit need not match the decoded target.
        // Lane selection and correction lifetime keep their separate I dependencies.
        s.correction=known(0,"EJ05","D");
    } else {
        s.correction=known(1,"EJ05","I","EQ04:JAL-correction-qualification (I)");
        s.base=known(pred.pc,"EJ04","I","EQ01:oldest-eligible-lane (I)");
        s.offset=known(uint64_t(s.instruction.immediate),"EJ04","I","EQ03:direct-JAL-operand-decomposition (I)");
        s.target=known(pred.pc+uint64_t(s.instruction.immediate),"EJ03","A");
    }
    return s;
}
Expected ReferenceModel::outputs(const Stimulus& stimulus) const {
    const auto& i=stimulus.inputs; Expected e; e.selection=select(i); const auto& s=e.selection;
    e.early=unknown("EQ05:uninitialized-or-malformed-lifecycle"); e.mem_flush=e.early;
    e.mask=dont_care("inactive-or-canceled-bundle"); e.base=e.offset=dont_care("unqualified-operands");
    if(!i.rst_n) { e.early=e.mem_flush=known(0,"EJ09","I","EQ02:reset-suppresses-control (I)"); }
    else if(!state_.startup && state_.initialized && state_.pending_known && !stimulus.malformed) {
        if(state_.pending) {
            if(contract_.lifecycle=="held") {
                e.early=known(1,"EJ06","I","EQ05:held-live-correction (I)");
                e.mem_flush=known(i.ready,"EJ06","I","EQ05:flush-on-completion (I)");
            } else e.early=e.mem_flush=unknown("EQ05:pending-correction-lifetime");
        } else if(!i.valid || (s.correction.known && !s.correction.value)) {
            e.early=e.mem_flush=known(0,"EJ06","I","EQ05:qualified-live-offer (I)");
        } else if(s.correction.known) {
            e.early=known(1,"EJ06","I","EQ05:live-correction-offer (I)");
            e.mem_flush=known(i.ready,"EJ06","I","EQ05:flush-on-completion (I)");
        }
    } else if(i.rst_n && state_.startup) e.early=e.mem_flush=unknown("EQ02:immediate-reset-release");
    if(i.rst_n && i.valid && !i.flush && !stimulus.canceled) {
        e.mask=known(s.retained,"EJ02","I","EQ01:oldest-eligible-cutoff (I)");
        if(e.early.known && e.early.value && s.correction.known && s.correction.value) { e.base=s.base; e.offset=s.offset; }
        for(unsigned k=0;k<config_.lanes;++k) if(s.retained&(1u<<k)) {
            auto& p=e.predictions[k]; const auto& in=i.predictions[k];
            p.pc=known(in.pc,"EJ07","I","saved-lane-PC-propagation (I)");
            if(int(k)==s.lane && !s.correction.known) p.hit=p.taken=p.target=unknown("EQ04:unknown-return-applicability");
            else {
                const bool correct=int(k)==s.lane && s.correction.known && s.correction.value;
                p.hit=known(correct || in.hit,"EJ07","I","selected-prediction-rewrite (I)");
                p.taken=known(correct || in.taken,"EJ07","I","selected-prediction-rewrite (I)");
                p.target=stimulus.feedback_unused && correct?unknown("EQ10:overridden-target-consumer-window"):
                    known(correct?i.feedback:in.target,"EJ07","I","target-feedback-propagation (I)");
            }
        }
    }
    for(unsigned k=0;k<config_.lanes;++k) if(!e.predictions[k].pc.known && e.predictions[k].pc.question.empty())
        e.predictions[k].pc=e.predictions[k].hit=e.predictions[k].taken=e.predictions[k].target=dont_care("unretained-lane");
    return e;
}
Transition ReferenceModel::plan(const Stimulus& s,uint64_t cycle) const {
    Transition t; t.next=state_; t.selection=select(s.inputs); const auto& i=s.inputs;
    if(!i.rst_n) { t.next.predictive.reset(); t.next.confirmed.reset(); return t; }
    t.confirmation=i.call_confirm!=i.ret_confirm?(i.call_confirm?Operation::Push:Operation::Pop):Operation::None;
    if(i.call_confirm && i.ret_confirm) {
        t.next.confirmed.entries.clear(); t.next.confirmed.known=false; t.next.confirmed.uncertainty="EQ12:both-confirmation-bits";
    } else {
        Entry entry{i.link,s.confirmation_id,cycle,i.link-4,0,"ENV02:qualified-confirmation (I)"};
        t.next.confirmed.apply(t.confirmation,entry,config_,contract_);
    }
    if(i.flush) {
        if(s.reason=="exception" && contract_.exception=="unknown") {
            t.next.predictive.entries.clear(); t.next.predictive.known=false; t.next.predictive.uncertainty="EQ08:exception-RAS-survival";
            t.next.confirmed.entries.clear(); t.next.confirmed.known=false; t.next.confirmed.uncertainty="EQ08:exception-RAS-survival";
        } else {
            // A qualified confirmation survives this recovery, so restore its resulting history.
            t.next.predictive=t.next.confirmed;
            if(s.reason=="exception") t.next.predictive.dependency+=";EQ08:exception-restoration (I)";
        }
        t.next.pending=false; t.next.pending_known=true; t.next.startup=false; return t;
    }
    t.accepted=i.valid && i.ready && !s.canceled;
    if(state_.startup && i.valid) {
        t.next.predictive.entries.clear(); t.next.predictive.known=false; t.next.predictive.uncertainty="EQ02:release-with-live-bundle";
    } else if(t.accepted) {
        t.speculative=t.selection.offered;
        if(t.speculative!=Operation::None) {
            const auto lane=unsigned(t.selection.lane);
            Entry entry{i.predictions[lane].pc+4,s.bundle_id,cycle,i.predictions[lane].pc,i.words[lane],"EQ05:accepted-selected-instruction (I)"};
            t.next.predictive.apply(t.speculative,entry,config_,contract_);
        }
    }
    t.next.startup=false;
    if(s.malformed) { t.next.pending_known=false; t.next.control_uncertainty="EQ05:malformed-held-request"; }
    else if(i.ready) { t.next.pending=false; t.next.pending_known=true; }
    else if(i.valid && t.selection.correction.known && t.selection.correction.value) { t.next.pending=true; t.next.pending_known=true; }
    else if(i.valid && !t.selection.correction.known) { t.next.pending_known=false; }
    return t;
}
uint64_t ReferenceModel::feedback(const Inputs& i) const { const auto s=select(i); return s.target.known?s.target.value:i.feedback; }
unsigned request_mask(uint64_t pc,const std::array<Prediction,MaxLanes>& predictions,const Config& cfg) {
    if(pc%4) throw std::invalid_argument("ENV01: architectural instruction PC is not four-byte aligned");
    const unsigned start=(pc%cfg.bundle_bytes())/4;
    unsigned end=cfg.lanes-1;
    for(unsigned k=start;k<cfg.lanes;++k) if(predictions[k].hit && predictions[k].taken) { end=k; break; }
    return ((1u<<(end+1))-1) & ~((1u<<start)-1);
}
std::string inputs_json(const Inputs& i,unsigned lanes) {
    std::ostringstream s;
    s<<"{\"rst_n\":"<<i.rst_n<<",\"F\":"<<i.flush<<",\"V\":"<<i.valid<<",\"R\":"<<i.ready
        <<",\"C+\":"<<i.call_confirm<<",\"C-\":"<<i.ret_confirm<<",\"link\":"<<json_quote(hex64(i.link))
        <<",\"feedback\":"<<json_quote(hex64(i.feedback))<<",\"mask\":"<<i.mask<<",\"lanes\":[";
    for(unsigned k=0;k<lanes;++k) { if(k) s<<','; const auto& p=i.predictions[k];
        s<<"{\"word\":"<<i.words[k]<<",\"class\":"<<json_quote(name(decode(i.words[k]).kind))
            <<",\"pc\":"<<json_quote(hex64(p.pc))<<",\"hit\":"<<p.hit<<",\"taken\":"<<p.taken
            <<",\"target\":"<<json_quote(hex64(p.target))<<'}'; }
    s<<"]}"; return s.str();
}
static std::string history_json(const History& h) {
    std::ostringstream s; s<<"{\"known\":"<<h.known<<",\"uncertainty\":"<<json_quote(h.uncertainty)
        <<",\"assumptions\":"<<json_quote(h.dependency)<<",\"entries\":[";
    for(unsigned k=0;k<h.entries.size();++k) { const auto& e=h.entries[k]; if(k) s<<',';
        s<<"{\"address\":"<<json_quote(hex64(e.address))<<",\"source_id\":"<<e.source_id<<",\"cycle\":"<<e.cycle
            <<",\"pc\":"<<json_quote(hex64(e.pc))<<",\"word\":"<<e.word<<",\"assumptions\":"<<json_quote(e.dependency)<<'}'; }
    s<<"]}"; return s.str();
}
std::string state_json(const State& s) {
    return "{\"P\":"+history_json(s.predictive)+",\"C\":"+history_json(s.confirmed)
        +",\"pending\":"+std::to_string(s.pending)+",\"pending_known\":"+std::to_string(s.pending_known)
        +",\"startup\":"+std::to_string(s.startup)+"}";
}
std::string expected_json(const Expected& e,unsigned lanes) {
    std::ostringstream s; s<<"{\"early\":"<<field_json(e.early)<<",\"mem_flush\":"<<field_json(e.mem_flush)
        <<",\"base\":"<<field_json(e.base)<<",\"offset\":"<<field_json(e.offset)<<",\"mask\":"<<field_json(e.mask)<<",\"lanes\":[";
    for(unsigned k=0;k<lanes;++k) { if(k) s<<','; const auto& p=e.predictions[k]; s<<"{\"pc\":"<<field_json(p.pc)
        <<",\"hit\":"<<field_json(p.hit)<<",\"taken\":"<<field_json(p.taken)<<",\"target\":"<<field_json(p.target)<<'}'; }
    s<<"]}"; return s.str();
}
std::string specification_json() {
    return R"SPEC({"recognition":"approved-x1-only-D","EQ01":{"status":"unresolved","detail":"oldest valid jump and mask contract"},"EQ02":{"status":"unresolved","detail":"reset release, initial contents and qualification"},"EQ03":{"status":"partial","resolved":"JAL x1 push; other JAL no push; exact 0x00008067 pop; other JALR no RAS action","remaining":"generic JALR lane cutoff"},"EQ04":{"status":"partial","resolved":"D: hit-and-taken JAL suppression is permitted independently of target equality","resolved_RET":"D: suppress only hit-and-taken BTB target equal to known RAS top; accepted RET still pops","remaining":"stale RAS overriding correct BTB"},"EQ05":{"status":"unresolved","detail":"held-correction acceptance and completion"},"EQ06":{"status":"unresolved","detail":"flush qualification window"},"EQ07":{"status":"approved","detail":"D: apply qualified surviving confirmation before restoring predictive history"},"EQ08":{"status":"unresolved","detail":"exception survival of execution-confirmed history"},"EQ09":{"status":"unresolved","detail":"stack boundaries and other depths"},"EQ10":{"status":"unresolved","detail":"sideband feedback consumption"},"EQ11":{"status":"unresolved","detail":"faulting speculative instruction treatment"},"EQ12":{"status":"unresolved","detail":"producer lifecycle and cancellation"}})SPEC";
}
} // namespace len5::early
