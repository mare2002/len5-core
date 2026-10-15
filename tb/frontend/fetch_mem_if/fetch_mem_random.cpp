// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Split streams, weighted semantic episodes and bounded guidance adapted from EJU/pc_gen.
#include "fetch_mem_random.hh"
#include "early_jump_instructions.hh"
#include "tb_macros.hh"
#include <inttypes.h>
#include <sstream>
namespace len5::fetchmem {
static uint64_t split(uint64_t x){x+=UINT64_C(0x9e3779b97f4a7c15);x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb);return x^(x>>31);}
void Weights::parse(const std::string& text){std::istringstream in(text);std::string pair;
    while(std::getline(in,pair,',')){auto e=pair.find('=');if(e==std::string::npos)throw std::invalid_argument("weights require name=percentage");const auto key=pair.substr(0,e),v=pair.substr(e+1);if(v.empty()||v.find_first_not_of("0123456789")!=std::string::npos)throw std::invalid_argument("invalid weight");auto n=std::stoull(v);if(n>100)throw std::invalid_argument("weight must be 0..100");
        unsigned* p=key=="request"?&request:key=="response"?&response:key=="grant"?&grant:key=="ready"?&ready:key=="error"?&error:key=="flush"?&flush:key=="reset"?&reset:nullptr;if(!p)throw std::invalid_argument("unknown weight: "+key);*p=unsigned(n);}
}
std::string Weights::text() const{return "request="+std::to_string(request)+",response="+std::to_string(response)+",grant="+std::to_string(grant)+",ready="+std::to_string(ready)+",error="+std::to_string(error)+",flush="+std::to_string(flush)+",reset="+std::to_string(reset);}
void run_random(Simulator& sim,const RunOptions& o){
    const auto cfg=sim.config();Weights w;w.parse(o.weights);std::mt19937_64 events(split(o.seed)),payloads(split(o.seed^UINT64_C(0x5041594c4f4144))),latencies(split(o.seed^UINT64_C(0x4c4154454e4359)));
    Campaign campaign=o.campaign=="stress"?Campaign::Stress:o.campaign=="characterization"?Campaign::Characterization:Campaign::Architectural;
    auto context=[&](){sim.begin("random-"+std::string(name(campaign)),"fetch-mem-if-v1 semantic memory episode",campaign);};context();
    uint64_t guided=0,episodes=0;unsigned phase=8;bool fill=false;
    unsigned request_stall=0,consumer_stall=0,response_gap=0;
    std::optional<Offer> pending;
    auto address=[&](){const uint64_t corners[]={0,0x100,0xfffffffc,0x100000000,0x7ffffffffffffffc,0x8000000000000000,UINT64_MAX-3};return payloads()%3?payloads()&UINT64_C(0x0000fffffffffffc):corners[payloads()%7];};
    auto generated=[&](bool force_error=false,bool force_clean=false){
        uint64_t pc=address();unsigned lane=(pc%cfg.bytes())/4;
        if(o.guided){const auto p=std::string(name(campaign))+"/FV07/start/";uint64_t least=UINT64_MAX;for(unsigned k=0;k<cfg.lanes;++k){auto n=sim.scoreboard().coverage.count(p+std::to_string(k));if(n<least){least=n;lane=k;}}pc=(pc/cfg.bytes())*cfg.bytes()+lane*4;}
        auto a=sim.offer(pc);const unsigned delays[]={1,2,3,8,16,40};a.latency=latencies()%3?1+latencies()%16:delays[latencies()%6];
        a.memory_data.errors=force_clean?0:(force_error||events()%100<w.error?unsigned(payloads())&cfg.mask():0);
        if(force_error)a.memory_data.errors=cfg.mask();
        for(unsigned k=0;k<cfg.lanes;++k){auto& p=a.predictions[k];const auto pred=payloads()%4;p.hit=pred&2;p.taken=pred&1;p.target=address();
            a.memory_data.causes[k]=unsigned(payloads()%2);const unsigned family=payloads()%16;
            a.memory_data.words[k]=family<11?early::ordinary(payloads,family):family==11?early::jal(unsigned(payloads()%32),int64_t(payloads()%4096)*4-8192):family==12?early::jalr(0,1,0):family==13?early::branch(0,unsigned(payloads()%32),unsigned(payloads()%32),16):family==14?uint32_t(payloads()):early::near_miss(payloads);
        }
        if(force_error){for(auto& p:a.predictions)p.hit=false;}
        a.mask=request_mask(a.start,a.predictions,cfg);
        if(campaign==Campaign::Stress && !force_error && !force_clean && payloads()%3==0) {
            a.mask=unsigned(payloads())&cfg.mask();
            for(unsigned k=0;k<cfg.lanes;++k){a.predictions[k].pc=payloads();a.predictions[k].target=payloads();a.memory_data.causes[k]=unsigned(payloads()%32);}
        }
        return a;
    };
    const auto metadata=[&](){std::ostringstream m;m<<"{\"policy\":\"fetch-mem-if-v1\",\"campaign\":"<<json_quote(o.campaign)<<",\"cycles\":"<<o.cycles<<",\"guided\":"<<o.guided<<",\"guided_choices\":"<<guided<<",\"weights\":"<<json_quote(w.text())<<'}';sim.scoreboard().random_metadata(m.str());};
    metadata();TB_CONFIG("Random policy=fetch-mem-if-v1 seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " guided=%u weights=%s",o.seed,o.campaign.c_str(),o.cycles,o.guided,w.text().c_str());
    sim.reset();
    while(sim.cycles()<o.cycles){
        const auto remaining=o.cycles-sim.cycles();
        if(remaining<=128){if(pending){sim.tick(&*pending);if(sim.last().k)pending.reset();}else if(sim.environment().empty()&&sim.state().outstanding.empty()&&sim.state().answers.empty())sim.tick(nullptr,false);else sim.tick();continue;}
        const Campaign wanted=o.campaign=="all"?Campaign((sim.cycles()/512)%3):campaign;
        if(wanted!=campaign){sim.reset();campaign=wanted;context();pending.reset();phase=8;request_stall=consumer_stall=response_gap=0;continue;}
        if(phase<8){
            if(fill){
                if(phase<=2){auto a=generated(phase!=0,phase==0);a.latency=1;
                    if(phase==0){for(auto& p:a.predictions)p.hit=false;const unsigned start=(a.start%cfg.bytes())/4;for(unsigned k=0;k<cfg.lanes;++k)a.memory_data.words[k]=0x13;a.memory_data.words[start]=early::jal(1,64);a.mask=request_mask(a.start,a.predictions,cfg);}
                    sim.tick(&a,phase!=0,false);
                }else if(phase==3)sim.tick(nullptr,true,false);
                else if(phase==4)sim.tick(nullptr,true,true,false,"early");
                else if(phase==5){auto a=generated(false,true);a.latency=1;sim.tick(&a,false);}
                else sim.tick();
            }else{
                if(phase==0||phase==2||phase==3||phase==4){auto a=generated(episodes%2==0,false);a.latency=1;sim.tick(&a,phase>=3,phase==2||phase==4);}
                else sim.tick(nullptr,phase==1||phase==5,phase!=1);
            }
            ++phase;continue;
        }
        if(!pending && sim.environment().empty() && o.guided && (events()%4==0 || sim.scoreboard().coverage.holes(campaign))){
            phase=0;fill=sim.scoreboard().coverage.count(std::string(name(campaign))+"/FV04/a/2")==0||episodes%3==0;++episodes;++guided;continue;
        }
        if(campaign==Campaign::Characterization&&!pending&&sim.environment().empty()&&events()%9==0){
            const unsigned kind=payloads()%3;Stimulus x;x.malformed=true;x.inputs.consumer_ready=false;
            auto a=generated(true);a.latency=1;
            if(kind==0){x.question="FQ03";x.request_id=a.id;x.start=a.start;x.inputs.fetch_valid=x.inputs.grant=x.inputs.response_valid=true;x.inputs.predictions=a.predictions;x.inputs.mask=a.mask;x.inputs.response=a.memory_data;}
            else if(kind==1){sim.tick(&a,false);sim.tick(nullptr,false,false,false,"branch");x.question="FQ04";x.response_id=a.id;x.inputs.response_valid=true;x.inputs.response=a.memory_data;}
            else{x.question="FQ02";x.reason="raw-flush";x.request_id=a.id;x.start=a.start;x.inputs.fetch_valid=x.inputs.grant=x.inputs.flush=true;x.inputs.predictions=a.predictions;x.inputs.mask=a.mask;}
            sim.step(x);x.inputs.fetch_valid=x.inputs.grant=x.inputs.response_valid=x.inputs.flush=false;x.reason.clear();sim.step(x);sim.reset();continue;
        }
        if(events()%100<w.reset){pending.reset();sim.reset();continue;}
        if(events()%100<w.flush){std::string reason;
            if(sim.environment().early_context() || (campaign==Campaign::Stress&&!sim.state().answers.empty()))reason="early";
            else if(sim.environment().exception_context())reason="exception";
            else if(sim.environment().branch_context())reason="branch";
            if(!reason.empty()){pending.reset();sim.tick(nullptr,true,reason=="early",false,reason);continue;}
        }
        if(!pending&&events()%100<w.request)pending=generated();
        if(!request_stall&&events()%100>=w.grant)request_stall=1+latencies()%16;
        if(!consumer_stall&&events()%100>=w.ready)consumer_stall=1+latencies()%40;
        if(!response_gap&&events()%100>=w.response)response_gap=1+latencies()%12;
        if(pending&&request_stall&&payloads()%5==0){for(unsigned k=0;k<cfg.lanes;++k){auto& p=pending->predictions[k];p.hit=payloads()%2;p.taken=payloads()%2;p.target=address();}pending->mask=request_mask(pending->start,pending->predictions,cfg);}
        auto stimulus=sim.environment().compose(pending?&*pending:nullptr,sim.cycles(),!response_gap,!consumer_stall,!request_stall,{},campaign);
        if(campaign==Campaign::Stress&&pending&&!request_stall&&sim.environment().outstanding()==cfg.depth&&stimulus.inputs.response_valid&&sim.state().answers.size()<2) {
            stimulus.turnover=true;stimulus.inputs.grant=true;
        }
        sim.step(stimulus);
        if(sim.last().k)pending.reset();
        if(request_stall)--request_stall;if(consumer_stall)--consumer_stall;if(response_gap)--response_gap;
    }
    metadata();TB_LOG(LOG_LOW,"SCB > Random completed seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " comparisons=%" PRIu64 " guided_choices=%" PRIu64,o.seed,o.campaign.c_str(),sim.cycles(),sim.scoreboard().checks(),guided);
}
} // namespace len5::fetchmem
