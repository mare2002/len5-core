// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Adapted pc_gen comparison, provenance, bounded journal, confidence and report machinery.
#include "early_jump_scoreboard.hh"
#include "tb_macros.hh"
#include <inttypes.h>
#include <sstream>
#include <stdexcept>
namespace len5::early {
static void map_json(std::ostream& s,const std::map<std::string,uint64_t>& m) {
    s<<'{'; bool first=true; for(const auto& p:m) { if(!first) s<<','; first=false; s<<json_quote(p.first)<<':'<<p.second; } s<<'}';
}
static std::string actual_json(const Outputs& o,unsigned lanes) {
    std::ostringstream s; s<<"{\"early\":"<<o.early<<",\"mem_flush\":"<<o.mem_flush<<",\"base\":"<<json_quote(hex64(o.base))
        <<",\"offset\":"<<json_quote(hex64(o.offset))<<",\"mask\":"<<o.mask<<",\"lanes\":[";
    for(unsigned k=0;k<lanes;++k) { if(k) s<<','; const auto& p=o.predictions[k]; s<<"{\"pc\":"<<json_quote(hex64(p.pc))
        <<",\"hit\":"<<p.hit<<",\"taken\":"<<p.taken<<",\"target\":"<<json_quote(hex64(p.target))<<'}'; }
    s<<"]}"; return s.str();
}
std::string sample_json(const Sample& s,unsigned lanes) {
    std::ostringstream o;
    o<<"{\"scenario\":"<<json_quote(s.stimulus.scenario)<<",\"test_name\":"<<json_quote(s.stimulus.title)
        <<",\"campaign\":"<<json_quote(name(s.stimulus.campaign))<<",\"cycle\":"<<s.cycle<<",\"event_time\":"<<s.time
        <<",\"phase\":"<<json_quote(s.phase)<<",\"epoch\":"<<s.epoch<<",\"bundle_id\":"<<s.stimulus.bundle_id
        <<",\"request_pc\":"<<json_quote(hex64(s.stimulus.request_pc))<<",\"requested_cycle\":"<<s.stimulus.requested_cycle
        <<",\"available_cycle\":"<<s.stimulus.available_cycle<<",\"response_delay\":"<<s.stimulus.response_delay
        <<",\"confirmation_id\":"<<s.stimulus.confirmation_id<<",\"recovery_id\":"<<s.stimulus.recovery_id
        <<",\"recovery_reason\":"<<json_quote(s.stimulus.reason)<<",\"malformed\":"<<s.stimulus.malformed
        <<",\"guard_probe\":"<<s.stimulus.guard_probe<<",\"inputs\":"<<inputs_json(s.observed_inputs,lanes)
        <<",\"execution\":[";
    for(unsigned k=0;k<lanes;++k) { if(k) o<<','; o<<"{\"known\":"<<s.stimulus.execution_known[k]
        <<",\"rs1_value\":"<<json_quote(hex64(s.stimulus.rs1_value[k]))<<",\"rs2_value\":"<<json_quote(hex64(s.stimulus.rs2_value[k]))
        <<",\"taken\":"<<s.stimulus.executed_taken[k]<<",\"target\":"<<json_quote(hex64(s.stimulus.executed_target[k]))<<'}'; }
    o<<"],\"selected_lane\":"<<s.expected.selection.lane<<",\"selected_class\":"<<json_quote(name(s.expected.selection.instruction.kind))
        <<",\"accepted\":"<<s.transition.accepted<<",\"speculative_operation\":"<<json_quote(name(s.transition.speculative))
        <<",\"confirmation_operation\":"<<json_quote(name(s.transition.confirmation))
        <<",\"before\":"<<state_json(s.before)<<",\"after\":"<<state_json(s.after)
        <<",\"expected\":"<<expected_json(s.expected,lanes)<<",\"actual\":"<<actual_json(s.actual,lanes)
        <<",\"injected\":"<<s.injected<<'}'; return o.str();
}
uint64_t Coverage::count(const std::string& k) const { const auto p=counters_.find(k); return p==counters_.end()?0:p->second; }
uint64_t Coverage::combination(Campaign c,unsigned op,unsigned confirm,bool f) const { return matrix_[unsigned(c)][op][confirm][f]; }
unsigned Coverage::holes(Campaign c) const {
    unsigned n=0;
    for(unsigned op=0;op<3;++op) for(unsigned confirm=0;confirm<3;++confirm) for(unsigned f=0;f<2;++f) {
        if(c==Campaign::Architectural && f && confirm) continue;
        n+=!combination(c,op,confirm,f);
    }
    return n;
}
static std::string depth_class(const History& h,unsigned depth) {
    return !h.known?"unknown":h.entries.empty()?"empty":h.entries.size()==1?"one":h.entries.size()==depth?"full":"interior";
}
void Coverage::sample(const Sample& s,bool match) {
    const unsigned c=unsigned(s.stimulus.campaign); const std::string p=std::string(name(s.stimulus.campaign))+"/";
    const auto& i=s.observed_inputs;
    ++counters_[p+"EV16/phase/"+s.phase];
    if(s.phase=="probe" || s.phase=="async") ++counters_[p+"EV01/QW"];
    if(s.phase=="post") {
        if(!i.rst_n) restored_[c]=false;
        else if(i.flush) restored_[c]=s.after.predictive.known;
        ++counters_[p+"cycles"]; ++counters_[p+"EV16/P/"+(s.after.predictive.known?"known":"unknown")];
        ++counters_[p+"EV16/C/"+(s.after.confirmed.known?"known":"unknown")];
        return;
    }
    if(s.phase!="pre") return;
    if(previous_cycle_[c]!=UINT64_MAX && previous_cycle_[c]+1!=s.cycle) {
        if(stalls_[c]) ++counters_[p+"EV08/interrupted"];
        stalls_[c]=0; previous_[c].clear(); reset_[c]=false;
    }
    previous_cycle_[c]=s.cycle;
    ++counters_[p+"EV01/"+(!i.rst_n?"reset":i.flush?"recovery":i.valid?(i.ready?"accept":"stall"):"idle")];
    if(reset_[c] && i.rst_n) ++counters_[p+"EV15/release"];
    reset_[c]=!i.rst_n;
    if(!i.rst_n) { ++counters_[p+"EV15/reset-row/"+std::to_string(i.flush*16+i.valid*8+i.ready*4+i.call_confirm*2+i.ret_confirm)]; return; }
    const unsigned op=i.valid?unsigned(s.transition.selection.offered):0;
    const unsigned confirm=i.call_confirm!=i.ret_confirm?unsigned(i.call_confirm?Operation::Push:Operation::Pop):0;
    if(!(i.call_confirm && i.ret_confirm)) ++matrix_[c][op][confirm][i.flush];
    else ++counters_[p+"EV11/both-confirm-illegal"];
    if(i.call_confirm || i.ret_confirm) ++counters_[p+"EV11/"+(i.call_confirm?"call":"return")+"/"+(i.ready?"ready":"stalled")];
    ++counters_[p+"EV10/P/"+depth_class(s.before.predictive,config_.depth)];
    ++counters_[p+"EV10/C/"+depth_class(s.before.confirmed,config_.depth)];
    bool equal=s.before.predictive.known && s.before.confirmed.known && s.before.predictive.entries.size()==s.before.confirmed.entries.size();
    if(equal) for(unsigned k=0;k<s.before.predictive.entries.size();++k) equal=equal && s.before.predictive.entries[k].address==s.before.confirmed.entries[k].address;
    ++counters_[p+"EV10/divergence/"+(equal?"equal":"different_or_unknown")];
    if(i.flush) ++counters_[p+"EV12/"+(s.stimulus.reason.empty()?"unspecified":s.stimulus.reason)+"/confirm="+std::to_string(confirm)];
    const std::string event=i.flush?"restore":!i.valid?"idle":!i.ready?"stall":name(s.transition.speculative);
    if(!previous_[c].empty()) ++counters_[p+"EV17/"+previous_[c]+"->"+event];
    previous_[c]=event;
    if(i.valid && !i.ready && !i.flush) { ++stalls_[c]; ++counters_[p+"EV08/hold"]; }
    else if(stalls_[c]) {
        if(i.flush) ++counters_[p+"EV08/interrupted"];
        else ++counters_[p+"EV08/length/"+(stalls_[c]==1?"1":stalls_[c]==2?"2":stalls_[c]<=config_.lanes?"3..N":stalls_[c]<=32?">N":"long")];
        stalls_[c]=0;
    }
    if(!i.valid) return;
    unsigned hits=0,taken=0,recognized=0,hit_mask=0,taken_mask=0,jump_mask=0;
    for(unsigned k=0;k<config_.lanes;++k) {
        const auto d=decode(i.words[k]); const auto& pred=i.predictions[k];
        hits+=pred.hit; taken+=pred.hit && pred.taken; recognized+=d.recognized();
        if(pred.hit) hit_mask|=1u<<k;
        if(pred.hit && pred.taken) taken_mask|=1u<<k;
        if(d.recognized()) jump_mask|=1u<<k;
        const auto state=std::to_string(unsigned(pred.hit)*2+pred.taken);
        ++counters_[p+"EV03/"+((i.mask&(1u<<k))?"eligible/":"inactive/")+name(d.kind)+"/lane="+std::to_string(k)+"/pred="+state];
        if(d.recognized() && !(i.mask&(1u<<k))) ++counters_[p+"EV02/inactive-jump"];
        if(d.kind==Kind::Jal) ++counters_[p+"EV03/JAL-rd/"+(d.rd==0?"x0":d.rd==5?"x5":"other")];
        if(d.kind==Kind::Jalr) ++counters_[p+"EV03/excluded-JALR/"+(d.rs1==5?"x5":d.rd==1?"indirect-call":"other")];
    }
    ++counters_[p+"EV05/cross/hitmask="+std::to_string(hit_mask)+"/takenmask="+std::to_string(taken_mask)+"/jumpmask="+std::to_string(jump_mask)+"/selected="+std::to_string(s.expected.selection.lane)];
    ++counters_[p+"EV12/cross/P="+depth_class(s.before.predictive,config_.depth)+"/C="+depth_class(s.before.confirmed,config_.depth)+"/F="+std::to_string(i.flush)];
    if(s.expected.selection.lane>=0) {
        const unsigned lane=unsigned(s.expected.selection.lane);
        for(unsigned k=0;k<lane;++k) if(i.mask&(1u<<k)) {
            const auto d=decode(i.words[k]);
            if(d.kind==Kind::Branch && i.predictions[k].hit && !i.predictions[k].taken)
                ++counters_[p+"EV06/PN-branch-before-jump"];
        }
        const auto target=s.expected.selection.target;
        if(target.known) {
            const auto category=[](uint64_t value) {
                return value==0?"zero":value>=UINT64_MAX-31?"top":value>=UINT64_C(0x7fffffffffffffe0) && value<=UINT64_C(0x8000000000000020)?"sign-boundary":value>=UINT64_C(0xffffffe0) && value<=UINT64_C(0x100000020)?"32bit-boundary":value%4?"unaligned":"ordinary";
            };
            ++counters_[p+"EV14/PC-class/"+category(i.predictions[lane].pc)];
            ++counters_[p+"EV14/target-class/"+category(target.value)];
            for(unsigned k=0;k<config_.lanes;++k) if(i.predictions[k].hit)
                ++counters_[p+"EV05/target-cross/"+(target.value==i.predictions[k].target?"equal":"conflicting")];
        }
    }
    const auto cardinality=[](unsigned n) { return n==0?"0":n==1?"1":n==2?"2":"many"; };
    ++counters_[p+"EV05/hits/"+cardinality(hits)]; ++counters_[p+"EV05/taken/"+cardinality(taken)];
    ++counters_[p+"EV06/jump-count/"+cardinality(recognized)];
    ++counters_[p+"EV02/start/"+std::to_string((s.stimulus.request_pc%config_.bundle_bytes())/4)];
    if(s.expected.selection.lane>=0 && match && s.expected.early.known) {
        const auto lane=unsigned(s.expected.selection.lane); const auto& d=s.expected.selection.instruction;
        ++counters_[p+"EV06/matched/"+name(d.kind)+"/lane="+std::to_string(lane)+"/pred="+std::to_string(i.predictions[lane].hit*2+i.predictions[lane].taken)];
        if(d.kind==Kind::Return && s.expected.offset.known && s.actual.offset==s.expected.offset.value) {
            ++counters_[p+"EV13/return-witness"];
            if(restored_[c]) ++counters_[p+"EV13/return-after-restoration"];
            ++counters_[p+"EV13/witness-P-depth/"+depth_class(s.before.predictive,config_.depth)];
        }
        if(d.kind==Kind::Call || d.kind==Kind::Jal) {
            ++counters_[p+"EV14/offset/"+(d.immediate<0?"negative":d.immediate>0?"positive":"zero")];
            if(d.immediate==-1048576) ++counters_[p+"EV14/min"];
            if(d.immediate==1048574 || d.immediate==1048572) ++counters_[p+"EV14/max"];
            const uint64_t pc=i.predictions[lane].pc,target=pc+uint64_t(d.immediate);
            if((pc>>32)!=(target>>32)) ++counters_[p+"EV14/32bit"];
            if((pc>>63)!=(target>>63)) ++counters_[p+"EV14/sign"];
            if((d.immediate>=0 && target<pc) || (d.immediate<0 && target>pc)) ++counters_[p+"EV14/wrap"];
        }
    }
    if(match && s.transition.accepted) ++counters_[p+"EV09/accepted/"+name(s.transition.speculative)];
}
std::string Coverage::json() const {
    std::ostringstream s; s<<"{\"scope\":\"EV01-EV18 observed input and matched outcome coverage; not exhaustive sign-off\",\"LEN5_MULTIPLE_ISSUES\":"
        <<config_.lanes<<",\"RAS_DEPTH\":"<<config_.depth<<",\"counters\":"; map_json(s,counters_);
    s<<",\"campaigns\":{";
    for(unsigned c=0;c<3;++c) { if(c) s<<','; const auto campaign=Campaign(c); const std::string p=std::string(name(campaign))+"/";
        s<<json_quote(name(campaign))<<":{\"matrix\":["; bool first=true;
        for(unsigned op=0;op<3;++op) for(unsigned confirm=0;confirm<3;++confirm) for(unsigned f=0;f<2;++f) {
            if(!first) s<<',';
            first=false;
            s<<"{\"operation\":"<<op<<",\"confirmation\":"<<confirm<<",\"flush\":"<<f<<",\"required\":"
                <<(c==0 && f && confirm?"false":"true")<<",\"count\":"<<matrix_[c][op][confirm][f]<<'}';
        }
        s<<"],\"exclusions\":[\"lanes >= selected N do not exist\",\"no two speculative operations per bundle\",\"both confirmation bits are producer-illegal\"";
        if(c==0) s<<",\"ordinary taken-hit metadata excluded by architectural producer policy; sampled stress crosses remain required\",\"F+confirmation excluded by architectural confirmation-before-recovery scheduler; covered in stress\"";
        if(config_.lanes==1) s<<",\"N=1: no multiple-prediction or ordered lane-pair bins\"";
        s<<"],\"feature_goals\":["; first=true;
        const auto goal=[&](const std::string& key,const char* gate="observed public stimulus / matched outcome") {
            if(!first) s<<',';
            first=false;
            s<<"{\"bin\":"<<json_quote(p+key)<<",\"count\":"<<count(p+key)<<",\"gate\":"<<json_quote(gate)<<'}';
        };
        for(const char* event:{"reset","recovery","accept","stall","idle"}) goal(std::string("EV01/")+event);
        for(unsigned k=0;k<config_.lanes;++k) {
            goal("EV02/start/"+std::to_string(k));
            for(const char* kind:{"call","jal","return"}) for(unsigned pred=0;pred<4;++pred)
                goal("EV06/matched/"+std::string(kind)+"/lane="+std::to_string(k)+"/pred="+std::to_string(pred));
        }
        for(const char* kind:{"arithmetic","immediate","load","store","upper","fence","system","multiply","floating","jalr"})
            for(unsigned k=0;k<config_.lanes;++k) for(unsigned pred=0;pred<4;++pred) {
                if(c==0 && pred==3 && std::string(kind)!="jalr") continue;
                goal("EV03/eligible/"+std::string(kind)+"/lane="+std::to_string(k)+"/pred="+std::to_string(pred),"sampled eligible word; architectural ordinary taken-hit metadata may be excluded by producer policy");
            }
        for(const char* n:{"0","1","2","many"}) {
            if((std::string(n)=="2" && config_.lanes<2) || (std::string(n)=="many" && config_.lanes<3)) continue;
            goal(std::string("EV05/hits/")+n); goal(std::string("EV05/taken/")+n);
        }
        for(const char* depth:{"empty","one","interior","full"}) { goal(std::string("EV10/P/")+depth); goal(std::string("EV10/C/")+depth); }
        for(const char* len:{"1","2","3..N",">N","long"}) {
            if(std::string(len)=="3..N" && config_.lanes<3) continue;
            goal(std::string("EV08/length/")+len);
        }
        goal("EV13/return-witness","known independent top observed on a later return, not inferred internal state");
        if(c!=0) goal("EV13/noop-invariance","approved D no-RAS-effect witness with previously matched independent top");
        s<<"],\"unfinished_stall_length\":"<<stalls_[c]<<'}';
    }
    s<<"}}"; return s.str();
}
Scoreboard::Scoreboard(Config c,Contract contract,uint64_t seed,const std::string& directory,bool full)
    :config_(c),contract_(contract),seed_(seed),directory_(directory),full_(full),journal_(directory+"/samples.jsonl"),coverage(c) {
    if(!journal_) throw std::runtime_error("cannot open sample journal");
}
void Scoreboard::mismatch(const Sample& s,const std::string& field,const Field& e,uint64_t actual) {
    ++field_errors_; ++campaign_errors_[unsigned(s.stimulus.campaign)];
    const char* category=s.injected?"injected_checker_failure":e.assumptions.empty()?"confirmed_dut_mismatch":"provisional_contract_mismatch";
    if(s.injected) ++injected_; else if(e.assumptions.empty()) ++confirmed_; else ++provisional_;
    if(discrepancies_.size()<256) {
        std::ostringstream d; d<<"{\"category\":"<<json_quote(category)<<",\"field\":"<<json_quote(field)
            <<",\"requirement\":"<<json_quote(e.requirement)<<",\"evidence\":"<<json_quote(e.evidence)
            <<",\"assumptions\":"<<json_quote(e.assumptions)<<",\"expected\":"<<json_quote(hex64(e.value))
            <<",\"actual\":"<<json_quote(hex64(actual))<<",\"sample\":"<<sample_json(s,config_.lanes)<<",\"history\":[";
        bool first=true; for(const auto& h:history_) { if(!first) d<<','; first=false; d<<sample_json(h,config_.lanes); }
        d<<"]}"; discrepancies_.push_back(d.str());
    }
    if(field_errors_<=12) {
        TB_ERR("SCB > %s test=%s id=%s req=%s evidence=%s seed=%" PRIu64 " cycle=%" PRIu64 " time=%" PRIu64 " phase=%s epoch=%" PRIu64,
            category,s.stimulus.title.c_str(),s.stimulus.scenario.c_str(),e.requirement.c_str(),e.evidence.c_str(),seed_,s.cycle,s.time,s.phase.c_str(),s.epoch);
        TB_ERR("RSP > field=%s selected_lane=%d --> actual: %s (expected: %s) assumptions=%s",field.c_str(),s.expected.selection.lane,
            hex64(actual).c_str(),hex64(e.value).c_str(),e.assumptions.c_str());
        TB_ERR("REQ > %s",inputs_json(s.observed_inputs,config_.lanes).c_str());
        TB_ERR("SCB > prior independent P/C origins: %s",state_json(s.before).c_str());
        for(const auto& h:history_) TB_ERR("REQ > recent %s",sample_json(h,config_.lanes).c_str());
        if(!replay_.empty()) TB_ERR("SCB > Replay: %s",replay_.c_str());
    }
}
void Scoreboard::compare(const Sample& s,const std::string& field,const Field& e,uint64_t actual,bool& failed) {
    if(!e.known) { if(e.question.rfind("DC:",0)==0) ++dont_cares_[e.question]; else ++unknowns_[e.question]; return; }
    ++checks_; ++campaign_checks_[unsigned(s.stimulus.campaign)]; ++requirements_[e.requirement+"/"+e.evidence];
    ++campaign_requirements_[std::string(name(s.stimulus.campaign))+"/"+e.requirement+"/"+e.evidence];
    if(!e.assumptions.empty()) ++assumptions_[e.assumptions];
    if(e.value!=actual) { failed=true; mismatch(s,field,e,actual); }
}
void Scoreboard::sample(const Sample& s) {
    ++samples_; const auto previous_checks=checks_; bool failed=false;
    const auto& e=s.expected; const auto& a=s.actual; const auto& i=s.observed_inputs;
    // Temporal D invariant uses prior independently expected, matched public evidence,
    // never an observed address to initialize or repair model state.
    if(s.stimulus.guard_probe && s.phase=="probe" && e.early.known) {
        if(guard_ && confidence_ && guard_noops_) {
            Field invariant=known(guard_top_.value,"EJ08","D",guard_independent_?"":"EQ01:masked/younger-jump-exclusion (I)");
            compare(s,"approved_no_RAS_effect_after_ordinary_or_excluded_instructions",invariant,guard_empty_?uint64_t(a.early):a.offset,failed);
            if((guard_empty_?uint64_t(a.early):a.offset)==invariant.value) coverage.increment(std::string(name(s.stimulus.campaign))+"/EV13/noop-invariance");
        } else if(guard_noops_) ++unknowns_["EJ08:prior-RAS-observation-unverified"];
    }
    compare(s,"early_jump_valid_o",e.early,a.early,failed); compare(s,"mem_flush_o",e.mem_flush,a.mem_flush,failed);
    compare(s,"early_jump_base_o",e.base,a.base,failed); compare(s,"early_jump_offs_o",e.offset,a.offset,failed);
    compare(s,"valid_instr_o",e.mask,a.mask,failed);
    for(unsigned k=0;k<config_.lanes;++k) {
        const auto p="issue_pred_o["+std::to_string(k)+"].";
        compare(s,p+"pc",e.predictions[k].pc,a.predictions[k].pc,failed);
        compare(s,p+"hit",e.predictions[k].hit,a.predictions[k].hit,failed);
        compare(s,p+"taken",e.predictions[k].taken,a.predictions[k].taken,failed);
        compare(s,p+"target",e.predictions[k].target,a.predictions[k].target,failed);
    }
    if(e.base.known && e.offset.known && e.selection.instruction.kind!=Kind::Return && e.selection.target.known) {
        auto arithmetic=e.selection.target;
        if(a.base!=e.base.value || !a.early) arithmetic.assumptions="EQ01/EQ05:unverified-selected-instruction-context (I)";
        compare(s,"JAL_architectural_target_sum",arithmetic,a.base+a.offset,failed); // Exact check always retained.
    }
    if(s.phase=="pre") {
        ++pre_records_;
        const uint64_t values[]={s.cycle,s.time,s.epoch,uint64_t(s.stimulus.campaign),i.rst_n,i.flush,i.valid,i.ready,i.call_confirm,i.ret_confirm,
            i.link,i.feedback,i.mask,s.stimulus.bundle_id,s.stimulus.confirmation_id,s.stimulus.recovery_id};
        const auto hash=[&](uint64_t value) { for(unsigned byte=0;byte<8;++byte) { digest_^=(value>>(byte*8))&255; digest_*=UINT64_C(1099511628211); } };
        for(auto value:values) hash(value);
        hash(s.stimulus.request_pc); hash(s.stimulus.requested_cycle); hash(s.stimulus.available_cycle); hash(s.stimulus.response_delay);
        for(char ch:s.stimulus.reason) hash(static_cast<unsigned char>(ch));
        for(unsigned k=0;k<config_.lanes;++k) { hash(i.words[k]); hash(i.predictions[k].pc); hash(i.predictions[k].target); hash(i.predictions[k].hit); hash(i.predictions[k].taken); hash(s.stimulus.execution_known[k]); hash(s.stimulus.rs1_value[k]); hash(s.stimulus.rs2_value[k]); hash(s.stimulus.executed_taken[k]); hash(s.stimulus.executed_target[k]); }
        if(!i.rst_n || i.flush || (s.transition.accepted && s.transition.speculative!=Operation::None)) { guard_=false; guard_noops_=0; }
        else if(guard_ && s.transition.accepted) {
            ++guard_noops_;
            for(unsigned k=0;k<config_.lanes;++k) {
                const auto d=decode(i.words[k]);
                if(d.kind==Kind::Call || d.kind==Kind::Return) guard_independent_=false;
            }
        }
    }
    if(failed) { ++errors_; confidence_=false; }
    if(checks_>previous_checks) ++transactions_;
    if(s.stimulus.guard_probe && s.phase=="probe" && !failed && (e.offset.known || (e.early.known && !e.early.value && s.before.predictive.known))) {
        guard_=true; guard_empty_=!e.offset.known; guard_top_=guard_empty_?e.early:e.offset;
        guard_cycle_=s.cycle; guard_noops_=0; guard_independent_=true; confidence_=true;
    }
    if(s.phase=="async" && !i.rst_n) { guard_=false; guard_noops_=0; confidence_=true; }
    if(s.phase=="post") { ++cycles_; ++campaign_cycles_[unsigned(s.stimulus.campaign)]; }
    if(full_ || failed || logger.getLogLvl()>=LOG_FULL) {
        if(failed && !full_) for(const auto& h:history_) journal_<<sample_json(h,config_.lanes)<<'\n';
        const auto text=sample_json(s,config_.lanes); journal_<<text<<'\n'; TB_LOG(LOG_FULL,"RSP > %s",text.c_str());
    }
    if(!journal_) throw std::runtime_error("sample journal write failed");
    ++scenarios_[s.stimulus.scenario];
    if(s.stimulus.campaign==Campaign::Characterization) {
        const auto key=s.stimulus.scenario+"/"+s.phase+"/"+(e.offset.known?"known":"unknown");
        ++observations_[key];
        if(!characterization_.count(key)) characterization_.emplace(key,s);
    }
    coverage.sample(s,!failed);
    history_.push_back(s); if(history_.size()>8) history_.pop_front();
    if(s.phase=="post" && !failed && logger.getLogLvl()>=(metadata_=="null"?LOG_MEDIUM:LOG_HIGH))
        TB_SUCCESS(metadata_=="null"?LOG_MEDIUM:LOG_HIGH,"RSP > id=%s cycle=%" PRIu64 " phase=post selected_lane=%d --> base: %s offs: %s",
            s.stimulus.scenario.c_str(),s.cycle,e.selection.lane,hex64(a.base).c_str(),hex64(a.offset).c_str());
}
void Scoreboard::problem(const std::string& kind,const std::string& reason) {
    if(kind=="environment_error") ++environment_errors_; else ++framework_errors_;
    discrepancies_.push_back("{\"category\":"+json_quote(kind)+",\"reason\":"+json_quote(reason)+"}"); TB_ERR("SCB > %s: %s",kind.c_str(),reason.c_str());
}
int Scoreboard::finish(const std::string& reason,bool complete_directed,const std::string& selection) {
    journal_.close();
    if(!journal_) throw std::runtime_error("observed-sample journal write failed");
    const bool incomplete=!reason.empty() || !checks_ || (complete_directed && scenarios_.size()!=34);
    const int status=environment_errors_ || framework_errors_?2:field_errors_?1:incomplete?3:0;
    std::ofstream coverage_file(directory_+"/coverage.json"); coverage_file<<coverage.json()<<'\n';
    std::ofstream character(directory_+"/characterization.jsonl");
    for(const auto& p:observations_) character<<"{\"observation\":"<<json_quote(p.first)<<",\"samples\":"<<p.second
        <<",\"representative\":"<<sample_json(characterization_.at(p.first),config_.lanes)<<"}\n";
    std::ofstream f(directory_+"/report.json");
    f<<"{\"status\":"<<json_quote(status==0?"passed":status==1?"failed":status==2?"invalid":"incomplete")
        <<",\"reason\":"<<json_quote(reason)<<",\"exit_status\":"<<status<<",\"full_contract_signoff\":false,\"selection\":"<<json_quote(selection)
        <<",\"seed\":"<<seed_<<",\"config\":{\"LEN5_MULTIPLE_ISSUES\":"<<config_.lanes<<",\"bundle_instructions\":"<<config_.lanes
        <<",\"RAS_DEPTH\":"<<config_.depth<<",\"bundle_bytes\":"<<config_.bundle_bytes()<<",\"xlen\":"<<config_.xlen
        <<",\"source\":"<<json_quote(config_.source)<<",\"fingerprint\":"<<json_quote(config_.fingerprint)<<"},\"contract\":"<<contract_.json()
        <<",\"cycles_executed\":"<<cycles_<<",\"sampled_records\":"<<samples_<<",\"pre_edge_records\":"<<pre_records_<<",\"transactions\":"<<transactions_
        <<",\"errors\":"<<errors_<<",\"field_checks\":"<<checks_<<",\"field_errors\":"<<field_errors_
        <<",\"confirmed_mismatches\":"<<confirmed_<<",\"provisional_mismatches\":"<<provisional_<<",\"injected_failures\":"<<injected_
        <<",\"environment_errors\":"<<environment_errors_<<",\"framework_errors\":"<<framework_errors_
        <<",\"stimulus_digest\":"<<json_quote(hex64(digest_))<<",\"random_configuration\":"<<metadata_<<",\"replay_command\":"<<json_quote(replay_)
        <<",\"timestamp_unit\":\"VerilatedContext tick\",\"cycle_definition\":\"zero-based consuming edge including reset\""
        <<",\"unresolved_questions\":[\"EQ01\",\"EQ02\",\"EQ03-lane-cutoff\",\"EQ04\",\"EQ05\",\"EQ06\",\"EQ08\",\"EQ09\",\"EQ10\",\"EQ11\",\"EQ12\"]"
        <<",\"specification_status\":"<<specification_json()<<",\"requirement_checks\":"; map_json(f,requirements_);
    f<<",\"campaign_requirement_checks\":"; map_json(f,campaign_requirements_);
    f<<",\"assumption_checks\":"; map_json(f,assumptions_); f<<",\"unknown_output_samples\":"; map_json(f,unknowns_);
    f<<",\"dont_care_output_samples\":"; map_json(f,dont_cares_); f<<",\"scenario_samples\":"; map_json(f,scenarios_);
    f<<",\"discrepancies\":["; bool first=true; for(const auto& d:discrepancies_) { if(!first) f<<','; first=false; f<<d; }
    f<<"],\"discrepancy_detail_limit\":256,\"campaigns\":{";
    for(unsigned c=0;c<3;++c) { if(c) f<<','; f<<json_quote(name(Campaign(c)))<<":{\"cycles\":"<<campaign_cycles_[c]
        <<",\"checks\":"<<campaign_checks_[c]<<",\"mismatches\":"<<campaign_errors_[c]<<'}'; }
    f<<"}}\n";
    f.close(); coverage_file.close(); character.close();
    if(!f || !coverage_file || !character) throw std::runtime_error("report write failed");
    if(status) TB_ERR("TEST FAILED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);
    else TB_SUCCESS(LOG_LOW,"TEST SUCCEEDED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);
    TB_LOG(LOG_LOW,"SCB > cycles=%" PRIu64 " checks=%" PRIu64 " confirmed=%" PRIu64 " provisional=%" PRIu64 " report=%s/report.json",
        cycles_,checks_,confirmed_,provisional_,directory_.c_str());
    if(status) TB_ERR("Test failed > early_jump %s exit=%d",selection.c_str(),status);
    else TB_SUCCESS(LOG_LOW,"Test successfully passed > early_jump %s",selection.c_str());
    return status;
}
} // namespace len5::early
