// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Field comparison, bounded journal, confidence provenance and reports adapted from EJU/pc_gen.
#include "fetch_mem_scoreboard.hh"
#include "tb_macros.hh"
#include "early_jump_instructions.hh"
#include <inttypes.h>
#include <sstream>
namespace len5::fetchmem {
static void map_json(std::ostream& o,const std::map<std::string,uint64_t>& m) {
    o<<'{';bool first=true;for(const auto& p:m){if(!first)o<<',';first=false;o<<json_quote(p.first)<<':'<<p.second;}o<<'}';
}
std::string sample_json(const Sample& s,unsigned n) {
    std::ostringstream o;o<<"{\"scenario\":"<<json_quote(s.stimulus.scenario)<<",\"campaign\":"<<json_quote(name(s.stimulus.campaign))
        <<",\"cycle\":"<<s.cycle<<",\"event_time\":"<<s.time<<",\"phase\":"<<json_quote(s.phase)<<",\"epoch\":"<<s.before.epoch
        <<",\"request_id\":"<<s.stimulus.request_id<<",\"response_id\":"<<s.stimulus.response_id<<",\"start\":"<<json_quote(hex64(s.stimulus.start))
        <<",\"latency\":"<<s.stimulus.latency<<",\"reason\":"<<json_quote(s.stimulus.reason)<<",\"question\":"<<json_quote(s.stimulus.question)
        <<",\"malformed\":"<<s.stimulus.malformed<<",\"inputs\":"<<inputs_json(s.observed,n)
        <<",\"before\":"<<state_json(s.before)<<",\"after\":"<<state_json(s.after)<<",\"events\":{\"K\":"<<s.transition.k<<",\"R\":"<<s.transition.r<<",\"D\":"<<s.transition.d
        <<",\"delivered_id\":"<<s.transition.delivered_id<<",\"response_id\":"<<s.transition.response_id<<"},\"expected\":{\"fetch_ready\":"<<field_json(s.expected.fetch_ready)
        <<",\"request_valid\":"<<field_json(s.expected.request_valid)<<",\"request_address\":"<<field_json(s.expected.request_address)
        <<",\"response_ready\":"<<field_json(s.expected.response_ready)<<",\"valid\":"<<field_json(s.expected.valid)<<",\"mask\":"<<field_json(s.expected.mask)<<",\"lanes\":[";
    for(unsigned k=0;k<n;++k){if(k)o<<',';const auto& p=s.expected.lanes[k];o<<"{\"word\":"<<field_json(p.word)<<",\"pc\":"<<field_json(p.pc)<<",\"hit\":"<<field_json(p.hit)
        <<",\"taken\":"<<field_json(p.taken)<<",\"target\":"<<field_json(p.target)<<",\"error\":"<<field_json(p.error)<<",\"cause\":"<<field_json(p.cause)<<'}';}
    const auto& a=s.actual;o<<"]},\"actual\":{\"fetch_ready\":"<<a.fetch_ready<<",\"request_valid\":"<<a.request_valid<<",\"request_address\":"<<json_quote(hex64(a.address))
        <<",\"write\":"<<a.write<<",\"response_ready\":"<<a.response_ready<<",\"valid\":"<<a.valid<<",\"mask\":"<<a.mask<<",\"errors\":"<<a.payload.errors<<",\"lanes\":[";
    for(unsigned k=0;k<n;++k){if(k)o<<',';const auto& p=a.predictions[k];o<<"{\"word\":"<<a.payload.words[k]<<",\"pc\":"<<json_quote(hex64(p.pc))
        <<",\"target\":"<<json_quote(hex64(p.target))<<",\"hit\":"<<p.hit<<",\"taken\":"<<p.taken<<",\"cause\":"<<a.payload.causes[k]<<'}';}
    o<<"]},\"injected\":"<<s.injected<<'}';return o.str();
}
uint64_t Coverage::count(const std::string& k) const {auto p=counts_.find(k);return p==counts_.end()?0:p->second;}
unsigned Coverage::holes(Campaign c) const {unsigned holes=0;for(auto n:matrix_[unsigned(c)])holes+=!n;return holes;}
void Coverage::sample(const Sample& s,bool matched) {
    const std::string prefix=std::string(name(s.stimulus.campaign))+"/";
    if(s.phase=="async" && !s.observed.rst_n) {
        ++counts_[prefix+"FV17/async-reset/q="+std::to_string(s.before.outstanding.size())+"/a="+std::to_string(s.before.answers.size())];
    }
    if(s.phase=="post" && !s.stimulus.question.empty()) {
        ++counts_[prefix+"FV16/cross/"+s.stimulus.question+"/epoch="+std::to_string(s.before.epoch%2)+"/valid="+std::to_string(s.actual.valid)+"/error="+std::to_string(bool(s.actual.payload.errors))];
    }
    if(matched && s.phase=="async" && !s.observed.rst_n &&
       !s.before.outstanding.empty() && !s.before.completed.empty())
        ++counts_[prefix+"FV23/reset-mixed"];
    if(s.phase!="pre")return;
    const auto& i=s.observed;const auto& a=s.actual;const auto& t=s.transition;
    const unsigned c=unsigned(s.stimulus.campaign);const std::string p=std::string(name(s.stimulus.campaign))+"/";
    const bool k=a.request_valid&&i.grant,r=i.response_valid&&a.response_ready,d=a.valid&&i.consumer_ready;
    if(last_cycle_[c]+1!=s.cycle || !i.rst_n || i.flush) {for(auto& n:stalls_[c])if(n){++counts_[p+"FV06/interrupted"];n=0;}previous_[c].clear();delivered_before_[c]=false;}
    last_cycle_[c]=s.cycle;
    ++counts_[p+"FV20/sampled"];
    if(i.fetch_valid)++counts_[p+"FV01/request-offer"];
    if(i.response_valid)++counts_[p+"FV01/response-offer"];
    if(a.valid)++counts_[p+"FV01/output-offer"];
    if(i.fetch_valid&&!i.grant)++counts_[p+"FV01/request-stall"];
    if(i.response_valid&&!a.response_ready)++counts_[p+"FV01/response-stall"];
    if(a.valid&&!i.consumer_ready)++counts_[p+"FV01/output-stall"];
    if(matched && i.rst_n && !s.stimulus.malformed) {
        const auto pending=s.before.outstanding.size(),completed=s.before.completed.size();
        if(!i.flush) {
            if(pending+completed==cfg_.depth)++counts_[p+"FV23/reserved-full"];
            if(completed==cfg_.depth)++counts_[p+"FV23/completed-full"];
            if(r && !completed && s.before.answers.size()<2)++counts_[p+"FV23/arriving-head-bypass"];
            if(r && completed)++counts_[p+"FV23/older-result-with-return"];
            if(completed==cfg_.depth && d && !k)++counts_[p+"FV23/full-release-bubble"];
        } else if(pending && completed && i.response_valid)
            ++counts_[p+"FV23/flush-mixed-with-return"];
    }
    if(!i.rst_n){++counts_[p+"FV17/reset/q="+std::to_string(s.before.outstanding.size())+"/a="+std::to_string(s.before.answers.size())];return;}
    if(i.flush){++counts_[p+"FV14/"+s.stimulus.reason+"/q="+std::to_string(s.before.outstanding.size())+"/a="+std::to_string(s.before.answers.size())];
        if(i.response_valid&&i.response.errors)++counts_[p+"FV14/fault-offered-on-flush"];
        if(t.d)++counts_[p+"FV15/early-head-delivered"];
    } else if(!s.stimulus.malformed){++matrix_[c][unsigned(k)*4+unsigned(r)*2+unsigned(d)];}
    if(!s.stimulus.question.empty())++counts_[p+"FV16/"+s.stimulus.question];
    ++counts_[p+"FV03/q/"+std::to_string(s.before.outstanding.size())];++counts_[p+"FV04/a/"+std::to_string(s.before.answers.size())];
    if(!s.stimulus.malformed){
        ++counts_[p+"FV04/cross/a="+std::to_string(s.before.answers.size())+"/K="+std::to_string(k)+"/R="+std::to_string(r)];
        const unsigned error_role=(i.response_valid&&i.response.errors?1u:0u)|(a.valid&&(a.payload.errors&a.mask)?2u:0u);
        ++counts_[p+"FV14/cross/error="+std::to_string(error_role)+"/flush="+std::to_string(i.flush)+"/q="+std::to_string(s.before.outstanding.size())];
    }
    const bool stalled[]={i.fetch_valid&&!i.grant,i.response_valid&&!a.response_ready,a.valid&&!i.consumer_ready};
    for(unsigned n=0;n<3;++n){if(stalled[n])++stalls_[c][n];else if(stalls_[c][n]){const auto len=stalls_[c][n];++counts_[p+"FV06/"+std::to_string(n)+"/length/"+(len==1?"1":len==2?"2":len<=cfg_.lanes?"3..N":len<=32?">N":"long")];stalls_[c][n]=0;}}
    const std::string event=i.flush?"flush":std::to_string(unsigned(k)*4+unsigned(r)*2+unsigned(d));
    if(!previous_[c].empty())++counts_[p+"FV02/sequence/"+previous_[c]+"->"+event];
    previous_[c]=event;
    ++counts_[p+"FV02/cross/q="+std::to_string(s.before.outstanding.size())+"/response="+std::to_string(r)+"/ready="+std::to_string(i.consumer_ready)];
    if(k){++counts_[p+"FV01/request-accepted"];++counts_[p+"FV07/start/"+std::to_string((s.stimulus.start%cfg_.bytes())/4)];
        unsigned hits=0,taken=0;for(unsigned lane=0;lane<cfg_.lanes;++lane){const auto& pr=i.predictions[lane];hits+=pr.hit;taken+=pr.hit&&pr.taken;
            ++counts_[p+"FV08/lane="+std::to_string(lane)+"/pred="+std::to_string(unsigned(pr.hit)*2+pr.taken)];}
        ++counts_[p+"FV08/hits/"+(hits==0?"0":hits==1?"1":hits==2?"2":"many")];++counts_[p+"FV08/taken-count/"+std::to_string(taken)];
        unsigned length=0;for(unsigned lane=0;lane<cfg_.lanes;++lane)length+=(i.mask>>lane)&1;
        ++counts_[p+"FV07/valid-length/"+std::to_string(length)];
        const auto pc=i.predictions[0].pc;
        ++counts_[p+"FV19/address/"+(pc==0?"zero":pc>UINT64_MAX-64?"wrap":pc&(UINT64_C(1)<<63)?"high-bit":pc>=UINT64_C(0xffffffe0)&&pc<=UINT64_C(0x100000020)?"32bit-boundary":"ordinary")];
        if(!s.before.outstanding.empty())++counts_[p+"FV09/newer-request-with-older-outstanding"];
    }
    if(r){++counts_[p+"FV01/response-accepted"];++counts_[p+(i.response.errors?"FV10/error-response":"FV10/clean-response")];
        uint64_t latency=0;if(!s.before.outstanding.empty())latency=s.cycle-s.before.outstanding.front().accepted;
        ++counts_[p+"FV05/latency/"+(latency==1?"1":latency<=4?"2..4":latency<=16?"5..16":"long")];
        if(s.before.outstanding.size() && i.response.errors)++counts_[p+"FV12/fault/q="+std::to_string(s.before.outstanding.size())+"/K="+std::to_string(k)+"/D="+std::to_string(d)];
    }
    if(matched && t.d && !s.before.answers.empty() && s.before.answers.front().request.metadata_known) {
        const auto& old=s.before.answers.front();++counts_[p+"FV21/fulfilled"];
        const uint64_t age=s.cycle-old.request.accepted,buffer_age=s.cycle-old.arrived;
        const uint64_t memory_latency=old.arrived-old.request.accepted;
        ++counts_[p+"FV05/delivery-age/"+(age<=4?"short":age<=16?"medium":"long")];
        ++counts_[p+"FV05/buffer-age/"+(buffer_age<=1?"1":buffer_age<=8?"2..8":"long")];
        unsigned hitmask=0;for(unsigned lane=0;lane<cfg_.lanes;++lane)if(old.request.predictions[lane].hit)hitmask|=1u<<lane;
        ++counts_[p+"FV09/cross/hitmask="+std::to_string(hitmask)+"/latency="+(memory_latency<=4?"short":"delayed")+"/metadata=matched"];
        if(delivered_before_[c])++counts_[p+"FV13/"+(last_error_[c]?std::string("error"):std::string("clean"))+"->"+(old.payload.errors?"error":"clean")];
        if(old.request.epoch!=delivered_epoch_[c])++counts_[p+"FV15/new-epoch-delivery/"+(old.payload.errors?"fault":"clean")];
        delivered_before_[c]=true;last_error_[c]=old.payload.errors!=0;delivered_epoch_[c]=old.request.epoch;
        for(unsigned lane=0;lane<cfg_.lanes;++lane)if(old.request.mask&(1u<<lane)){
            ++counts_[p+"FV09/matched-lane/"+std::to_string(lane)];
            if(s.expected.lanes[lane].word.known && s.expected.lanes[lane].word.value==a.payload.words[lane])
                ++counts_[p+"FV18/matched-word/"+early::name(early::decode(a.payload.words[lane]).kind)+"/lane="+std::to_string(lane)];
            if(old.payload.errors&(1u<<lane))++counts_[p+"FV11/matched-error/lane="+std::to_string(lane)+"/cause="+std::to_string(old.payload.causes[lane])];
        }
        ++counts_[p+(old.payload.errors?"FV13/delivered-error":"FV13/delivered-clean")];
    }
    if(matched)++counts_[p+"FV20/matched-pre"];
    counts_[p+"FV21/canceled"]+=t.canceled_ids.size();
}
std::string Coverage::json() const {
    std::ostringstream o;o<<"{\"scope\":\"FV01-FV23 sampled/accepted/matched/obligation evidence; not exhaustive signoff\",\"LEN5_MULTIPLE_ISSUES\":"<<cfg_.lanes<<",\"counters\":";map_json(o,counts_);o<<",\"campaigns\":{";
    for(unsigned c=0;c<3;++c){if(c)o<<',';const auto p=std::string(name(Campaign(c)))+"/";o<<json_quote(name(Campaign(c)))<<":{\"matrix\":[";
        for(unsigned row=0;row<8;++row){if(row)o<<',';o<<"{\"row\":"<<row<<",\"required\":true,\"count\":"<<matrix_[c][row]<<'}';}o<<"],\"feature_goals\":[";
        std::vector<std::string> goals={p+"FV01/request-accepted",p+"FV01/response-accepted",p+"FV10/error-response",p+"FV10/clean-response",p+"FV21/fulfilled",p+"FV03/q/2",p+"FV04/a/2"};
        for(unsigned k=0;k<cfg_.lanes;++k){goals.push_back(p+"FV07/start/"+std::to_string(k));goals.push_back(p+"FV09/matched-lane/"+std::to_string(k));for(unsigned pred=0;pred<4;++pred)goals.push_back(p+"FV08/lane="+std::to_string(k)+"/pred="+std::to_string(pred));
            for(unsigned cause=0;cause<2;++cause)goals.push_back(p+"FV11/matched-error/lane="+std::to_string(k)+"/cause="+std::to_string(cause));}
        for(unsigned k=0;k<goals.size();++k){if(k)o<<',';o<<"{\"bin\":"<<json_quote(goals[k])<<",\"count\":"<<count(goals[k])<<'}';}o<<"]}";
    }
    o<<"},\"configuration_exclusions\":[\"lanes >= source N do not exist; multi-prediction cardinality limited by N\",\"architectural zero-latency, grant-on-flush, overcapacity, unordered/stale responses excluded by active protocol\",\"answer spill retains no-lookahead consumption; reserved queue accepts responses even at a=2\"],\"coverage_limits\":[\"matrix closure enforces only eight normal handshake rows per selected campaign\",\"feature and temporal gaps remain separate; pending obligations fail completion\",\"fault address means saved prediction PC; mtval/full-core recovery outside scope\"]}";return o.str();
}
Scoreboard::Scoreboard(Config c,Contract p,uint64_t seed,const std::string& dir,bool full):cfg_(c),contract_(p),seed_(seed),directory_(dir),full_(full),journal_(dir+"/samples.jsonl"),coverage(c) {
    if(!journal_)throw std::runtime_error("cannot create sample journal");
    ++requirements_["FM19/D"];
}
void Scoreboard::mismatch(const Sample& s,const std::string& field,const Field& e,uint64_t actual) {
    ++field_errors_;++campaign_errors_[unsigned(s.stimulus.campaign)];
    const char* category=s.injected?"injected_checker_failure":e.assumptions.empty()?"confirmed_dut_mismatch":"provisional_contract_mismatch";
    if(s.injected)++injected_;else if(e.assumptions.empty())++confirmed_;else ++provisional_;
    if(discrepancies_.size()<256){std::ostringstream o;o<<"{\"category\":"<<json_quote(category)<<",\"field\":"<<json_quote(field)<<",\"requirement\":"<<json_quote(e.requirement)<<",\"evidence\":"<<json_quote(e.evidence)
        <<",\"assumptions\":"<<json_quote(e.assumptions)<<",\"expected\":"<<json_quote(hex64(e.value))<<",\"actual\":"<<json_quote(hex64(actual))<<",\"sample\":"<<sample_json(s,cfg_.lanes)<<",\"history\":[";
        bool first=true;for(const auto& h:history_){if(!first)o<<',';first=false;o<<sample_json(h,cfg_.lanes);}o<<"]}";discrepancies_.push_back(o.str());}
    if(field_errors_<=8){TB_ERR("SCB > %s test=%s req=%s evidence=%s seed=%" PRIu64 " cycle=%" PRIu64 " time=%" PRIu64 " phase=%s epoch=%" PRIu64,
        category,s.stimulus.scenario.c_str(),e.requirement.c_str(),e.evidence.c_str(),seed_,s.cycle,s.time,s.phase.c_str(),s.before.epoch);
        TB_ERR("RSP > field=%s --> actual: %s (expected: %s) assumptions=%s",field.c_str(),hex64(actual).c_str(),hex64(e.value).c_str(),e.assumptions.c_str());
        TB_ERR("REQ > %s",inputs_json(s.observed,cfg_.lanes).c_str());TB_ERR("SCB > prior independent transaction history: %s",state_json(s.before).c_str());
        for(const auto& h:history_)TB_ERR("REQ > recent %s",sample_json(h,cfg_.lanes).c_str());
        if(!replay_.empty())TB_ERR("SCB > Replay: %s",replay_.c_str());}
}
void Scoreboard::compare(const Sample& s,const std::string& field,const Field& e,uint64_t actual,bool& failed) {
    if(!e.known){if(e.question.rfind("DC:",0)==0)++dont_cares_[e.question];else ++unknowns_[e.question];return;}
    ++checks_;++campaign_checks_[unsigned(s.stimulus.campaign)];++requirements_[e.requirement+"/"+e.evidence];
    ++campaign_requirements_[std::string(name(s.stimulus.campaign))+"/"+e.requirement+"/"+e.evidence];if(!e.assumptions.empty())++assumptions_[e.assumptions];
    if(e.value!=actual){failed=true;mismatch(s,field,e,actual);}
}
bool Scoreboard::sample(const Sample& s) {
    ++samples_;const uint64_t before_checks=checks_;bool failed=false;
    const auto& e=s.expected;const auto& a=s.actual;
    compare(s,"fetch_ready_o",e.fetch_ready,a.fetch_ready,failed);compare(s,"instr_valid_o",e.request_valid,a.request_valid,failed);
    compare(s,"instr_addr_o",e.request_address,a.address,failed);compare(s,"instr_ready_o",e.response_ready,a.response_ready,failed);
    compare(s,"issue_valid_o",e.valid,a.valid,failed);compare(s,"instr_we_o",e.write,a.write,failed);
    const bool output_verified=e.valid.known&&e.valid.value&&a.valid;
    const auto qualified=[&](Field f,bool context,const char* dependency){
        // Keep every exact expected value/check. Only secondary diagnostic confidence
        // changes when output/lane/error qualification has not been established.
        if(f.known&&!context){if(!f.assumptions.empty())f.assumptions+=";";f.assumptions+=dependency;}
        return f;
    };
    compare(s,"valid_instr_o",qualified(e.mask,output_verified,"FM20:unverified-output-valid-context (I)"),a.mask,failed);
    const bool unqualified_unknown=!e.valid.known&&!a.valid;
    for(unsigned k=0;k<cfg_.lanes;++k){if(unqualified_unknown){unknowns_["FQ03/FQ04:unconsumed-ambiguous-payload"]+=7;continue;}const auto prefix="lane["+std::to_string(k)+"].";const auto& p=e.lanes[k];const auto& v=a.predictions[k];
        const bool relevant=e.mask.known&&((e.mask.value>>k)&1);
        const bool lane_verified=output_verified&&(!relevant||((a.mask>>k)&1));
        const bool actual_error=(a.payload.errors>>k)&1;
        const auto lane_field=[&](const Field& f){return qualified(f,lane_verified,"FM20:unverified-output/lane-context (I)");};
        const bool word_verified=lane_verified&&(!relevant||!p.error.known||p.error.value||!actual_error);
        const bool cause_verified=lane_verified&&(!relevant||!p.error.known||!p.error.value||actual_error);
        compare(s,prefix+"word",qualified(p.word,word_verified,"FM20:unverified-word-qualification (I)"),a.payload.words[k],failed);
        compare(s,prefix+"pc",lane_field(p.pc),v.pc,failed);compare(s,prefix+"hit",lane_field(p.hit),v.hit,failed);
        compare(s,prefix+"taken",lane_field(p.taken),v.taken,failed);compare(s,prefix+"target",lane_field(p.target),v.target,failed);
        compare(s,prefix+"exception_raised",lane_field(p.error),actual_error,failed);
        compare(s,prefix+"exception_code",qualified(p.cause,cause_verified,"FM20:unverified-cause-qualification (I)"),a.payload.causes[k],failed);}
    if(failed)++errors_;
    if(checks_>before_checks)++transactions_;
    if(s.phase=="pre") {
        ++pre_;const auto& i=s.observed;
        if(i.rst_n&&!s.stimulus.malformed)++requirements_["FM18/I"];
        const auto hash=[&](uint64_t v){for(unsigned b=0;b<8;++b){digest_^=(v>>(b*8))&255;digest_*=UINT64_C(1099511628211);}};
        for(auto v:{s.cycle,s.before.epoch,s.stimulus.request_id,s.stimulus.response_id,s.stimulus.start,s.stimulus.latency,uint64_t(s.stimulus.campaign),uint64_t(i.rst_n),uint64_t(i.flush),uint64_t(i.fetch_valid),uint64_t(i.grant),uint64_t(i.response_valid),uint64_t(i.consumer_ready),uint64_t(i.mask),uint64_t(i.response.errors)})hash(v);
        for(unsigned k=0;k<cfg_.lanes;++k){hash(i.predictions[k].pc);hash(i.predictions[k].target);hash(i.predictions[k].hit);hash(i.predictions[k].taken);hash(i.response.words[k]);hash(i.response.causes[k]);hash(s.stimulus.memory_data.words[k]);hash(s.stimulus.memory_data.causes[k]);}hash(s.stimulus.memory_data.errors);
        for(char ch:s.stimulus.reason)hash(static_cast<unsigned char>(ch));
        for(char ch:s.stimulus.question)hash(static_cast<unsigned char>(ch));
    }
    if(s.phase=="post"){++cycles_;++campaign_cycles_[unsigned(s.stimulus.campaign)];}
    if(full_ || failed || logger.getLogLvl()>=LOG_FULL){if(failed&&!full_)for(const auto& h:history_)journal_<<sample_json(h,cfg_.lanes)<<'\n';const auto json=sample_json(s,cfg_.lanes);journal_<<json<<'\n';TB_LOG(LOG_FULL,"RSP > %s",json.c_str());}
    if(!journal_)throw std::runtime_error("journal write failed");
    ++scenarios_[s.stimulus.scenario];
    if(s.stimulus.campaign==Campaign::Characterization){const auto key=(s.stimulus.question.empty()?s.stimulus.scenario:s.stimulus.question)+"/"+s.phase;++observations_[key];if(!characterization_.count(key))characterization_[key]=sample_json(s,cfg_.lanes);}
    // A pre-edge observation alone does not consume a transaction: the driver
    // can stop on a control mismatch before clocking this offered handshake.
    if(s.phase=="pre"){coverage_pre_=s;coverage_pre_matched_=!failed;}
    else {
        if(s.phase=="post"&&coverage_pre_&&coverage_pre_->cycle==s.cycle){
            coverage.sample(*coverage_pre_,coverage_pre_matched_);coverage_pre_.reset();
        }
        coverage.sample(s,!failed);
    }
    history_.push_back(s);if(history_.size()>8)history_.pop_front();
    const auto mismatch=[](const Field& f,uint64_t v){return f.known&&f.value!=v;};
    return !(mismatch(e.fetch_ready,a.fetch_ready)||mismatch(e.request_valid,a.request_valid)||mismatch(e.request_address,a.address)||mismatch(e.response_ready,a.response_ready)||mismatch(e.valid,a.valid));
}
void Scoreboard::problem(const std::string& kind,const std::string& why) {
    if(kind=="environment_error")++environment_;else ++framework_;discrepancies_.push_back("{\"category\":"+json_quote(kind)+",\"reason\":"+json_quote(why)+"}");TB_ERR("SCB > %s: %s",kind.c_str(),why.c_str());
}
int Scoreboard::finish(const std::string& reason,bool all,const std::string& selection) {
    uint64_t pending=0;for(const auto& q:final_.outstanding)pending+=q.id!=0;for(const auto& a:final_.completed)pending+=a.request.id!=0;for(const auto& a:final_.answers)pending+=a.request.id!=0;
    const bool conserved=final_.totals.accepted==final_.totals.delivered+final_.totals.canceled+pending;
    if(!conserved)problem("framework_error","FM07/FV21: independent temporal obligations do not conserve");
    const bool incomplete=!reason.empty()||!checks_||pending||(selection=="random"&&!final_.totals.accepted)||(all&&scenarios_.size()!=44);
    const int status=environment_||framework_?2:field_errors_?1:incomplete?3:0;
    std::ofstream cov(directory_+"/coverage.json");cov<<coverage.json()<<'\n';
    std::ofstream chr(directory_+"/characterization.jsonl");for(const auto& p:observations_)chr<<"{\"observation\":"<<json_quote(p.first)<<",\"samples\":"<<p.second<<",\"representative\":"<<characterization_.at(p.first)<<"}\n";
    journal_.close();
    if(!journal_)throw std::runtime_error("observed-sample journal write failed");
    std::ofstream o(directory_+"/report.json");
    o<<"{\"status\":"<<json_quote(status==0?"passed":status==1?"failed":status==2?"invalid":"incomplete")<<",\"reason\":"<<json_quote(reason.empty()&&pending?"unfulfilled temporal obligations":reason)
        <<",\"exit_status\":"<<status<<",\"full_contract_signoff\":false,\"selection\":"<<json_quote(selection)<<",\"seed\":"<<seed_<<",\"config\":"<<config_json(cfg_)<<",\"contract\":"<<contract_.json()
        <<",\"cycles_executed\":"<<cycles_<<",\"sampled_records\":"<<samples_<<",\"pre_edge_records\":"<<pre_<<",\"transactions\":"<<transactions_<<",\"errors\":"<<errors_<<",\"field_checks\":"<<checks_<<",\"field_errors\":"<<field_errors_
        <<",\"confirmed_mismatches\":"<<confirmed_<<",\"provisional_mismatches\":"<<provisional_<<",\"injected_failures\":"<<injected_<<",\"environment_errors\":"<<environment_<<",\"framework_errors\":"<<framework_
        <<",\"obligations\":"<<counters_json(final_.totals,pending)<<",\"obligations_conserved\":"<<conserved<<",\"stimulus_digest\":"<<json_quote(hex64(digest_))<<",\"replay_command\":"<<json_quote(replay_)
        <<",\"random_configuration\":"<<metadata_<<",\"timestamp_unit\":\"VerilatedContext tick\",\"specification_status\":"<<specification_json()<<",\"unresolved_questions\":[";
    for(unsigned q=1;q<=13;++q){if(q>1)o<<',';o<<json_quote(std::string("FQ")+(q<10?"0":"")+std::to_string(q));}o<<"],\"requirement_checks\":";map_json(o,requirements_);o<<",\"campaign_requirement_checks\":";map_json(o,campaign_requirements_);
    o<<",\"assumption_checks\":";map_json(o,assumptions_);o<<",\"unknown_output_samples\":";map_json(o,unknowns_);o<<",\"dont_care_output_samples\":";map_json(o,dont_cares_);o<<",\"scenario_samples\":";map_json(o,scenarios_);
    o<<",\"discrepancies\":[";for(unsigned k=0;k<discrepancies_.size();++k){if(k)o<<',';o<<discrepancies_[k];}o<<"],\"campaigns\":{";
    for(unsigned c=0;c<3;++c){if(c)o<<',';o<<json_quote(name(Campaign(c)))<<":{\"cycles\":"<<campaign_cycles_[c]<<",\"checks\":"<<campaign_checks_[c]<<",\"mismatches\":"<<campaign_errors_[c]<<",\"obligations\":"<<counters_json(final_.campaigns[c],[&](){uint64_t count=0;for(const auto& q:final_.outstanding)count+=q.id&&unsigned(q.campaign)==c;for(const auto& a:final_.completed)count+=a.request.id&&unsigned(a.request.campaign)==c;for(const auto& a:final_.answers)count+=a.request.id&&unsigned(a.request.campaign)==c;return count;}())<<'}';}o<<"}}\n";
    o.close();cov.close();chr.close();
    if(!o||!cov||!chr)throw std::runtime_error("report write failed");
    if(status)TB_ERR("TEST FAILED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);else TB_SUCCESS(LOG_LOW,"TEST SUCCEEDED > errors: %" PRIu64 "/%" PRIu64,errors_,transactions_);
    TB_LOG(LOG_LOW,"SCB > cycles=%" PRIu64 " comparisons=%" PRIu64 " mismatches=%" PRIu64 " delivered=%" PRIu64 " canceled=%" PRIu64 " pending=%" PRIu64 " report=%s/report.json",cycles_,checks_,field_errors_,final_.totals.delivered,final_.totals.canceled,pending,directory_.c_str());
    if(status)TB_ERR("Test failed > fetch_mem_if %s exit=%d",selection.c_str(),status);else TB_SUCCESS(LOG_LOW,"Test successfully passed > fetch_mem_if %s",selection.c_str());return status;
}
} // namespace len5::fetchmem
