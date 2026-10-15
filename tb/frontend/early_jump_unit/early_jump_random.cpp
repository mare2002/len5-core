// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Semantic episodes, split streams and deficit guidance adapted from pc_gen_random.cpp.
#include "early_jump_random.hh"
#include "tb_macros.hh"
#include <algorithm>
#include <inttypes.h>
#include <sstream>
namespace len5::early {
static uint64_t split_seed(uint64_t x) {
    x+=UINT64_C(0x9e3779b97f4a7c15); x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);
    x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb); return x^(x>>31);
}
void Weights::parse(const std::string& text) {
    std::istringstream stream(text); std::string pair;
    while(std::getline(stream,pair,',')) {
        const auto equal=pair.find('='); if(equal==std::string::npos) throw std::invalid_argument("weights require name=integer pairs");
        const auto key=pair.substr(0,equal),value=pair.substr(equal+1);
        if(value.empty() || value.find_first_not_of("0123456789")!=std::string::npos) throw std::invalid_argument("invalid event weight");
        const auto n=std::stoull(value); if(n>10000) throw std::invalid_argument("weight exceeds 10000");
        unsigned* p=key=="ordinary"?&ordinary:key=="call"?&call:key=="jump"?&jump:key=="return"?&ret:key=="branch"?&branch:
            key=="confirm"?&confirm:key=="restore"?&restore:key=="stall"?&stall:key=="reset"?&reset:nullptr;
        if(!p) throw std::invalid_argument("unknown event weight: "+key);
        *p=unsigned(n);
    }
    if(!(ordinary+call+jump+ret+branch) || confirm>100 || restore>100 || stall>100 || reset>100)
        throw std::invalid_argument("positive instruction weights and event percentages 0..100 required");
}
std::string Weights::text() const {
    return "ordinary="+std::to_string(ordinary)+",call="+std::to_string(call)+",jump="+std::to_string(jump)+",return="+std::to_string(ret)
        +",branch="+std::to_string(branch)+",confirm="+std::to_string(confirm)+",restore="+std::to_string(restore)+",stall="+std::to_string(stall)+",reset="+std::to_string(reset);
}
RandomScenarios::RandomScenarios(Simulator& sim,const RunOptions& o):sim_(sim),options_(o),events_(split_seed(o.seed)),
    payloads_(split_seed(o.seed^UINT64_C(0x5041594c4f4144))),latencies_(split_seed(o.seed^UINT64_C(0x4c4154454e4359))) { weights_.parse(o.weights); }
uint64_t RandomScenarios::address() {
    const uint64_t corners[]={0,0x100,0xfffffffc,0x100000000,UINT64_C(0x7ffffffffffffffc),UINT64_C(0x8000000000000000),UINT64_MAX-3};
    const auto choice=payloads_()%16; return choice<7?corners[choice]:(payloads_()&UINT64_C(0x0000fffffffffffc));
}
Stimulus RandomScenarios::generated(Campaign campaign,bool guided) {
    const auto cfg=sim_.config(); const auto pc=address(); auto s=bundle(cfg,pc,sim_.environment().allocate_bundle());
    s.campaign=campaign; s.scenario=campaign==Campaign::Architectural?"RA-bundle":campaign==Campaign::Stress?"RS-bundle":"RC-bundle";
    s.title="constrained-random encoded bundle early-jump-v1";
    for(unsigned k=0;k<cfg.lanes;++k) {
        const unsigned w[]={weights_.ordinary,weights_.call,weights_.jump,weights_.ret,weights_.branch};
        auto pick=events_()%(weights_.ordinary+weights_.call+weights_.jump+weights_.ret+weights_.branch);
        unsigned kind=0; for(;kind<4 && pick>=w[kind];++kind) pick-=w[kind];
        const int64_t offsets[]={-1048576,-4096,-4,0,4,2048,1048572};
        const int64_t off=payloads_()%2?offsets[payloads_()%7]:int64_t(payloads_()%524288)*4-1048576;
        switch(kind) {
        case 0:
            s.inputs.words[k]=payloads_()%5?ordinary(payloads_,payloads_()%11):jalr(unsigned(payloads_()%32),unsigned(payloads_()%32),int64_t(payloads_()%1024)*4-2048); break;
        case 1: s.inputs.words[k]=jal(1,off); break;
        case 2: s.inputs.words[k]=jal(payloads_()%2?5:0,off); break;
        case 3: s.inputs.words[k]=jalr(0,1,0); break;
        default: { const unsigned f[]={0,1,4,5,6,7}; s.inputs.words[k]=branch(f[payloads_()%6],payloads_()%32,payloads_()%32,int64_t(payloads_()%2048)*4-4096); }
        }
        auto& p=s.inputs.predictions[k]; const unsigned pred=payloads_()%4; p.hit=pred&2; p.taken=pred&1;
        const auto d=decode(s.inputs.words[k]);
        // No normal branch producer corrects ordinary taken-hit metadata in this abstract architecture policy.
        if(campaign==Campaign::Architectural && !d.control() && p.hit && p.taken) p.taken=false;
        p.target=d.kind==Kind::Call || d.kind==Kind::Jal?(payloads_()%3?p.pc+uint64_t(d.immediate):address()):address();
        s.rs1_value[k]=d.kind==Kind::Return && sim_.state().predictive.top().known && payloads_()%4?
            sim_.state().predictive.top().value:address();
        s.rs2_value[k]=payloads_()%3?payloads_():s.rs1_value[k];
        s.execution_known[k]=true;
    }
    if(guided && events_()%3==0) {
        const auto lane=unsigned((pc%cfg.bundle_bytes())/4);
        const std::string prefix=std::string(name(campaign))+"/EV06/matched/";
        unsigned selected_kind=0,selected_pred=0; uint64_t least=UINT64_MAX;
        const char* names[]={"call","jal","return"};
        for(unsigned kind=0;kind<3;++kind) for(unsigned pred=0;pred<4;++pred) {
            const auto hits=sim_.scoreboard().coverage.count(prefix+names[kind]+"/lane="+std::to_string(lane)+"/pred="+std::to_string(pred));
            if(hits<least) { least=hits; selected_kind=kind; selected_pred=pred; }
        }
        if(least<5) {
            s.inputs.words[lane]=selected_kind==0?jal(1,8):selected_kind==1?jal(5,-4):jalr(0,1,0);
            s.inputs.predictions[lane].hit=selected_pred&2; s.inputs.predictions[lane].taken=selected_pred&1; ++guided_choices_;
        }
    }
    s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg);
    for(unsigned k=0;k<cfg.lanes;++k) {
        const auto executed=outcome(s.inputs.words[k],s.inputs.predictions[k].pc,s.rs1_value[k],s.rs2_value[k]);
        s.executed_taken[k]=executed.taken; s.executed_target[k]=executed.target;
    }
    s.response_delay=2+latencies_()%11;
    return s;
}
Stimulus RandomScenarios::architectural() {
    Stimulus s; s.campaign=Campaign::Architectural; s.scenario="RA-idle";
    s.title="causal response/confirmation/recovery epoch";
    if(recovery_) {
        if(response_ && sim_.cycles()>=response_->available_cycle) s=*response_;
        s.inputs.flush=true; s.inputs.ready=false; s.inputs.call_confirm=s.inputs.ret_confirm=false;
        s.reason="misprediction"; s.recovery_id=recovery_; s.scenario="RA-recovery";
        response_.reset(); recovery_=0; stall_left_=0; cooldown_=2+latencies_()%11; return s;
    }
    if(!response_ && events_()%5!=0) {
        response_=generated(Campaign::Architectural,options_.guided);
        response_->requested_cycle=sim_.cycles(); response_->available_cycle=sim_.cycles()+response_->response_delay;
        sim_.environment().request(*response_);
    }
    if(response_ && sim_.cycles()>=response_->available_cycle) {
        s=*response_;
        if(!stall_left_ && events_()%100<weights_.stall) {
            const unsigned lengths[]={1,2,sim_.config().lanes,sim_.config().lanes+1,40};
            stall_left_=latencies_()%3?1+latencies_()%12:lengths[latencies_()%5];
        }
        s.inputs.ready=!stall_left_;
        if(stall_left_) --stall_left_;
    }
    if(cooldown_) --cooldown_;
    else if(events_()%100<weights_.confirm) {
        const auto sources=sim_.environment().pending(sim_.cycles());
        if(!sources.empty()) {
            const auto& r=sources[0]; const auto d=decode(r.word);
            const bool prediction=r.prediction.hit && r.prediction.taken;
            const bool wrong=prediction!=r.actual_taken || (prediction && r.prediction.target!=r.actual_target);
            if(d.kind==Kind::Call || d.kind==Kind::Return) {
                s.confirmation_id=r.id; s.inputs.call_confirm=d.kind==Kind::Call; s.inputs.ret_confirm=d.kind==Kind::Return;
                s.inputs.link=r.pc+4; s.reason=wrong?"confirmed-mispredicted":"confirmed-correct";
            } else sim_.environment().resolve_correct(r.id);
            if(wrong) recovery_=r.id;
        }
    }
    if(s.inputs.valid && s.inputs.ready) response_.reset();
    return s;
}
Stimulus RandomScenarios::stress(bool characterization) {
    const auto campaign=characterization?Campaign::Characterization:Campaign::Stress;
    if(response_) {
        auto s=*response_; s.inputs.ready=stall_left_==0;
        if(characterization && events_()%11==0) {
            const unsigned lane=payloads_()%sim_.config().lanes;
            s.inputs.predictions[lane].target=address(); s.inputs.predictions[lane].hit=events_()%2;
            s.inputs.predictions[lane].taken=events_()%2; s.malformed=true; s.scenario="RC-held-metadata-change";
            response_=s;
        }
        if(stall_left_) --stall_left_; else response_.reset();
        s.inputs.call_confirm=s.inputs.ret_confirm=false;
        if(events_()%100<weights_.confirm) { s.inputs.call_confirm=events_()%2; s.inputs.ret_confirm=!s.inputs.call_confirm; s.inputs.link=address(); }
        return s;
    }
    auto s=generated(campaign,options_.guided);
    s.inputs.valid=events_()%8!=0; s.inputs.ready=events_()%100>=weights_.stall;
    s.inputs.flush=events_()%100<weights_.restore; s.reason=events_()%4?"misprediction":"exception";
    if(events_()%100<weights_.confirm) { s.inputs.call_confirm=events_()%2; s.inputs.ret_confirm=!s.inputs.call_confirm; s.inputs.link=address(); }
    if(options_.guided && events_()%2==0) {
        unsigned candidates[18],n=0;
        for(unsigned op=0;op<3;++op) for(unsigned c=0;c<3;++c) for(unsigned f=0;f<2;++f)
            if(sim_.scoreboard().coverage.combination(campaign,op,c,f)<5) candidates[n++]=op*6+c*2+f;
        if(n) {
            const unsigned chosen=candidates[events_()%n],op=chosen/6,c=(chosen/2)%3;
            s.inputs.valid=true; s.inputs.mask=sim_.config().all_lanes();
            for(unsigned k=0;k<sim_.config().lanes;++k) s.inputs.words[k]=ordinary(payloads_,payloads_()%11);
            s.inputs.words[0]=op==1?jal(1,8):op==2?jalr(0,1,0):s.inputs.words[0];
            s.inputs.call_confirm=c==1; s.inputs.ret_confirm=c==2; s.inputs.flush=chosen%2; s.inputs.link=address(); ++guided_choices_;
        }
    }
    if(characterization) {
        switch(events_()%9) {
        case 0: s.inputs.call_confirm=s.inputs.ret_confirm=true; s.scenario="RC-both-confirms"; break;
        case 1: s.inputs.words[payloads_()%sim_.config().lanes]=uint32_t(payloads_()); s.scenario="RC-raw-word"; break;
        case 2: s.inputs.mask=payloads_()&sim_.config().all_lanes(); s.scenario="RC-holey-mask"; break;
        case 3: s.inputs.feedback=payloads_(); s.feedback_explicit=true; s.scenario="RC-feedback"; break;
        case 4: s.inputs.predictions[0].pc|=payloads_()%4; s.scenario="RC-raw-address"; break;
        case 5: s.inputs.words[payloads_()%sim_.config().lanes]=near_miss(payloads_); s.scenario="RC-near-miss"; break;
        case 6: s.inputs.words[payloads_()%sim_.config().lanes]=0xffffffff; s.scenario="RC-unsupported-word"; break;
        default: break;
        }
    }
    if(!s.inputs.ready && s.inputs.valid && !s.inputs.flush) { response_=s; stall_left_=1+latencies_()%40; }
    return s;
}
void RandomScenarios::run() {
    const auto start=sim_.cycles();
    const auto metadata=[&]{ return "{\"policy\":\"early-jump-v1\",\"campaign\":"+json_quote(options_.campaign)
        +",\"weights\":"+json_quote(weights_.text())+",\"guided\":"+(options_.guided?"true":"false")+",\"guided_choices\":"+std::to_string(guided_choices_)
        +",\"streams\":\"splitmix64 seeded mt19937_64: events,payloads,latencies\"}"; };
    std::string executable="'"; for(char ch:options_.executable) executable+=ch=='\''?"'\\''":std::string(1,ch); executable+='\'';
    const auto& contract=options_.contract;
    const auto replay=executable+" --random --seed="+std::to_string(options_.seed)+" --cycles="+std::to_string(options_.cycles)
        +" --max_cycles="+std::to_string(options_.max_cycles)+" --campaign="+options_.campaign+" --contract="+contract.profile
        +" --order="+contract.order+" --exception="+contract.exception+" --boundaries="+contract.boundaries+" --lifecycle="+contract.lifecycle
        +" --weights="+weights_.text()+" --guided="+(options_.guided?"true":"false")+" --expect_issues="+std::to_string(sim_.config().lanes)
        +" --expect_ras_depth="+std::to_string(sim_.config().depth)+(options_.inject.empty()?"":" --inject_failure="+options_.inject)
        +" --journal=full --log_level=LOG_HIGH --dump_waves=true --run_dir=NEW_REPLAY_DIRECTORY";
    sim_.scoreboard().random_run(metadata(),replay);
    TB_CONFIG("Random policy=early-jump-v1 seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " guided=%u weights=%s",options_.seed,options_.campaign.c_str(),options_.cycles,options_.guided,weights_.text().c_str());
    while(sim_.cycles()-start<options_.cycles) {
        const uint64_t index=sim_.cycles()-start;
        const auto desired=options_.campaign=="all"?Campaign((index/256)%3):options_.campaign=="architectural"?Campaign::Architectural:
            options_.campaign=="stress"?Campaign::Stress:Campaign::Characterization;
        const bool reset=index==0 || desired!=campaign_ || events_()%100<weights_.reset;
        if(reset) {
            campaign_=desired; response_.reset(); recovery_=stall_left_=cooldown_=0;
            Stimulus s; s.campaign=campaign_; s.scenario="R-reset"; s.inputs.rst_n=false;
            sim_.probe(s); sim_.step(s); release_=true; continue;
        }
        if(release_) { Stimulus s; s.campaign=campaign_; s.scenario="R-release"; sim_.step(s); release_=false; continue; }
        auto s=campaign_==Campaign::Architectural?architectural():stress(campaign_==Campaign::Characterization);
        sim_.step(s);
        if(!response_ && !s.inputs.flush && sim_.cycles()%17==0) sim_.guard("R-temporal-noop-witness",campaign_==Campaign::Characterization?Campaign::Characterization:Campaign::Stress);
    }
    sim_.scoreboard().random_run(metadata(),replay);
    TB_LOG(LOG_LOW,"SCB > Random completed seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " comparisons=%" PRIu64 " guided_choices=%" PRIu64,
        options_.seed,options_.campaign.c_str(),sim_.cycles()-start,sim_.scoreboard().field_checks(),guided_choices_);
}
} // namespace len5::early
