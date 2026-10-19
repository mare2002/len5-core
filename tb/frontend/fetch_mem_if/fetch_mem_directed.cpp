// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// FM-T01..FM-T44 from VERIFICATION.md; scenario dispatch/verdict pattern adapted from EJU.
#include "fetch_mem_directed.hh"
#include "early_jump_instructions.hh"
#include "tb_macros.hh"
#include <random>
namespace len5::fetchmem {
static const char* titles[]={
    "asynchronous reset hold release and first fetch","idle and inactive payload noise","single request response all fields",
    "held request with changing current predictions","every starting lane and partial bundle","four hit/taken prediction pairs",
    "multiple predictions and first-taken masks","two outstanding immutable snapshots","simultaneous request and old response",
    "simultaneous K R D and repeated queue wrap","long downstream stall and full buffers","full-buffer release and ordered drain",
    "independent request and response channel progress","old metadata survives newer BPU updates","per-lane access faults",
    "raised misalignment with cause zero","mixed and masked lane errors","error clean error and consecutive faults",
    "fault held in memory and downstream","fault response with new request and old delivery","unqualified codes and payload poison",
    "branch flush at occupancy boundaries","early flush consumes head and cancels younger fault","exception recovery and later address change",
    "flush with offered memory fault","flush with buffered held fault","request offer on flush and repeated cancellation",
    "reset with live and faulting transactions","same address distinct recovery epochs","long distinct clean and fault bursts",
    "encoded and raw instruction payload families","address and bundle boundaries","clock-stopped combinational and async probes",
    "FQ03 zero-latency alternative characterization","FQ04 late canceled response characterization","FQ02 grant-on-flush characterization",
    "malformed response and capacity characterization","raw masks and unused metadata","known state restored by coordinated reset",
    "temporal conservation and consecutive recovery",
    "all completion slots filled and full-credit recovery",
    "flush with a buffered result and a returning younger request",
    "reset with completed-full and mixed pending/completed requests",
    "repeated full-ring reuse with distinct metadata and faults"};
static void live(Offer& o,const Config& c){for(unsigned k=0;k<c.lanes;++k)o.predictions[k].hit=false;o.mask=request_mask(o.start,o.predictions,c);}
static void single(Simulator& s,const Offer& o){s.tick(&o,false);s.tick();s.drain();}
static Offer full(Simulator& s,bool first_error=false,bool early_head=false){
    const auto c=s.config();auto a=s.offer(0x100,0,first_error?c.mask():0,0);live(a,c);
    if(early_head)a.memory_data.words[0]=early::jal(1,64);
    auto b=s.offer(0x240,2,c.mask(),1);live(b,c);auto d=s.offer(0x380,1,c.mask(),0);live(d,c);
    s.tick(&a,false,false);s.tick(&b,true,false);s.tick(&d,true,false);s.tick(nullptr,true,false);return d;
}
// Two answer-spill entries plus every reserved slot, observed through handshakes.
static void completed_full(Simulator& s,uint64_t base) {
    const auto c=s.config();
    for(unsigned k=0;k<c.depth+2;++k) {
        auto o=s.offer(base+k*c.bytes(),k%4,k%2?c.mask():0,k%2);
        live(o,c);
        s.tick(&o,true,false);
        if(!s.last().k)throw std::logic_error("FM07: saturation request was not accepted");
    }
    for(unsigned k=0;k<c.depth+2;++k)s.tick(nullptr,true,false);
}
static void release_full(Simulator& s,uint64_t pc) {
    auto held=s.offer(pc);
    for(unsigned k=0;k<8;++k) {
        s.tick(&held,true,k!=0);
        if(s.last().k){s.drain();return;}
    }
    throw std::logic_error("FM09: full queue failed to recover credit");
}
static void pipe(Simulator& s,unsigned n){for(unsigned k=0;k<n;++k){auto o=s.offer(0x1000+uint64_t(k)*s.config().bytes(),k%4,k%3==1?s.config().mask():0,k%2);live(o,s.config());s.tick(&o);}s.drain();}
static void late(Simulator& s){auto a=s.offer(0x400,0,s.config().mask(),1);s.tick(&a,false);s.tick(nullptr,false,false,false,"branch");
    Stimulus x;x.malformed=true;x.question="FQ04";x.inputs.response_valid=true;x.inputs.response=a.memory_data;x.response_id=a.id;x.inputs.consumer_ready=false;s.step(x);
    x.inputs.response_valid=false;s.step(x);s.reset();}
static void scenario(Simulator& s,unsigned n){const auto c=s.config();
    switch(n){
    case 1:{s.tick();auto a=s.offer(0);single(s,a);s.reset();single(s,s.offer(0x100));break;}
    case 2:{for(unsigned k=0;k<12;++k){Stimulus x;x.inputs.consumer_ready=k%2;x.inputs.grant=k%3;x.inputs.mask=c.mask();x.inputs.response.errors=c.mask();for(unsigned j=0;j<c.lanes;++j){x.inputs.predictions[j]={UINT64_MAX-j,0x1234567800000000+k,true,true};x.inputs.response.words[j]=0xffffffff;x.inputs.response.causes[j]=31;}s.step(x);}break;}
    case 3:single(s,s.offer(0x100,2));break;
    case 4:{auto a=s.offer(0x100);for(unsigned k=0;k<24;++k){a.predictions[0].target=0x800+k*4;a.predictions[0].hit=k&1;a.predictions[0].taken=k&2;a.mask=request_mask(a.start,a.predictions,c);s.tick(&a,false,true,false);}single(s,a);break;}
    case 5:for(unsigned k=0;k<c.lanes;++k){auto a=s.offer(0x400+k*4);live(a,c);single(s,a);}break;
    case 6:for(unsigned lane=0;lane<c.lanes;++lane)for(unsigned pred=0;pred<4;++pred){auto a=s.offer(0x800);live(a,c);a.predictions[lane].hit=pred&2;a.predictions[lane].taken=pred&1;a.mask=request_mask(a.start,a.predictions,c);single(s,a);}break;
    case 7:for(unsigned start=0;start<c.lanes;++start)for(unsigned variant=0;variant<5;++variant){auto a=s.offer(0x1000+start*4);for(unsigned k=0;k<c.lanes;++k){a.predictions[k].hit=true;a.predictions[k].taken=variant==0?false:variant==1?true:k%2==0;a.predictions[k].target=variant==4?0x2000:0x3000+k*16;}a.mask=request_mask(a.start,a.predictions,c);single(s,a);}break;
    case 8:{auto a=s.offer(0x100),b=s.offer(0x208,2);a.latency=7;b.latency=3;s.tick(&a,false);s.tick(&b,false);for(unsigned k=0;k<5;++k)s.tick(nullptr,false);s.drain();break;}
    case 9:pipe(s,12);break;
    case 10:pipe(s,80);break;
    case 11:full(s);for(unsigned k=0;k<45;++k)s.tick(nullptr,true,false);s.drain();break;
    case 12:{full(s);auto d=s.offer(0x480);s.tick(&d,true,true);s.drain();break;}
    case 13:{auto a=s.offer(0x100);s.tick(&a,false);auto b=s.offer(0x200);s.tick(&b,true,true,false);s.tick(&b,true,true,false);s.tick(&b,true,true,true);s.drain();break;}
    case 14:{auto a=s.offer(0x100,1),b=s.offer(0x200,3);a.latency=4;s.tick(&a,false);s.tick(&b,false);for(unsigned k=0;k<12;++k){Stimulus x=s.environment().compose(nullptr,s.cycles(),true,false);for(unsigned j=0;j<c.lanes;++j)x.inputs.predictions[j]={0xffff0000+k*64+j*4,UINT64_MAX-k-j,bool(k&1),bool(k&2)};s.step(x);}s.drain();break;}
    case 15:for(unsigned k=0;k<c.lanes;++k){auto a=s.offer(0x100,0,1u<<k,1);live(a,c);single(s,a);}break;
    case 16:for(unsigned k=0;k<c.lanes;++k){auto a=s.offer(0x200,0,1u<<k,0);live(a,c);single(s,a);}break;
    case 17:for(unsigned start=0;start<c.lanes;++start){auto a=s.offer(0x400+start*4,0,c.mask(),0);for(unsigned k=0;k<c.lanes;++k){a.memory_data.causes[k]=k&1;a.predictions[k].hit=false;}a.mask=request_mask(a.start,a.predictions,c);single(s,a);}break;
    case 18:for(unsigned k=0;k<12;++k){auto a=s.offer(0x100+k*c.bytes(),0,k%3?c.mask():0,k&1);live(a,c);single(s,a);}break;
    case 19:full(s,true);for(unsigned k=0;k<36;++k)s.tick(nullptr,true,false);s.drain();break;
    case 20:{auto a=s.offer(0x100,0,c.mask(),0);live(a,c);s.tick(&a,false);auto b=s.offer(0x200);s.tick(&b);auto d=s.offer(0x300,0,c.mask(),1);live(d,c);s.tick(&d);s.drain();break;}
    case 21:{auto a=s.offer(0x100,0,0,31);live(a,c);single(s,a);Stimulus x;x.inputs.response.errors=c.mask();for(unsigned k=0;k<c.lanes;++k)x.inputs.response.causes[k]=31;s.step(x);if(c.lanes>1){auto b=s.offer(0x200+4,0,1,0);live(b,c);single(s,b);}break;}
    case 22:for(unsigned k=0;k<3;++k){if(k==1){auto a=s.offer(0x100);s.tick(&a,false);}if(k==2)full(s);s.tick(nullptr,false,false,false,"branch");single(s,s.offer(0x800+k*c.bytes()));}break;
    case 23:full(s,false,true);s.tick(nullptr,true,true,false,"early");single(s,s.offer(0x800));break;
    case 24:{auto a=s.offer(0x100,0,c.mask(),1);s.tick(&a,false);s.tick(nullptr,false,false,false,"exception");single(s,s.offer(0x240));single(s,s.offer(0x1200));break;}
    case 25:{auto a=s.offer(0x400,0,c.mask(),0);s.tick(&a,false);s.tick(nullptr,true,false,false,"branch");single(s,s.offer(0x800));break;}
    case 26:{auto a=s.offer(0x100,0,c.mask(),1);live(a,c);s.tick(&a,false,false);s.tick(nullptr,true,false);for(unsigned k=0;k<12;++k)s.tick(nullptr,true,false);s.tick(nullptr,false,false,false,"exception");single(s,s.offer(0x800));break;}
    case 27:{auto a=s.offer(0x200);s.tick(&a,false,false,false,"branch");s.tick(nullptr,false,false,false,"branch");s.tick(nullptr,false,false,false,"exception");s.reset();single(s,s.offer(0x800));break;}
    case 28:{for(unsigned k=0;k<3;++k){if(k==0){auto a=s.offer(0x100);s.tick(&a,false);}else full(s,true);s.reset();single(s,s.offer(0x800));}break;}
    case 29:for(unsigned k=0;k<6;++k){auto a=s.offer(0x100,k,k%2?c.mask():0,k&1);s.tick(&a,false);if(k%3==0)s.tick(nullptr,false,false,false,"branch");else s.drain();}break;
    case 30:pipe(s,256);break;
    case 31:{std::mt19937_64 rng(17);for(unsigned family=0;family<16;++family){auto a=s.offer(0x400);live(a,c);for(unsigned k=0;k<c.lanes;++k)a.memory_data.words[k]=family<11?early::ordinary(rng,family):family==11?early::jal(k%2?1:5,-16):family==12?early::jalr(0,1,0):family==13?early::branch(0,1,2,16):family==14?uint32_t(rng()):early::near_miss(rng);single(s,a);}break;}
    case 32:{const uint64_t addresses[]={0,4,0xfffffffc,0x100000000,0x7ffffffffffffffc,0x8000000000000000,UINT64_MAX-3};for(auto pc:addresses)single(s,s.offer(pc));break;}
    case 33:{auto a=s.offer(0x100);s.tick(&a,false,false);s.tick(nullptr,true,false);Stimulus p=s.environment().compose(nullptr,s.cycles(),false,false);s.probe(p);p.inputs.predictions[0].target=UINT64_MAX;s.probe(p);p.inputs.flush=true;p.reason="branch";s.probe(p);p.inputs.flush=false;s.probe(p);s.drain();break;}
    case 34:{auto a=s.offer(0x100,0,c.mask(),0);Stimulus x;x.malformed=true;x.question="FQ03";x.request_id=a.id;x.start=a.start;x.inputs.fetch_valid=x.inputs.grant=x.inputs.response_valid=true;x.inputs.consumer_ready=false;x.inputs.predictions=a.predictions;x.inputs.mask=a.mask;x.inputs.response=a.memory_data;x.memory_data=a.memory_data;s.step(x);x.inputs.fetch_valid=x.inputs.grant=x.inputs.response_valid=false;s.step(x);s.reset();single(s,s.offer(0x800));break;}
    case 35:late(s);single(s,s.offer(0x800));break;
    case 36:{auto a=s.offer(0x100);Stimulus x;x.malformed=true;x.question="FQ02";x.reason="raw-flush";x.request_id=a.id;x.start=a.start;x.inputs.flush=x.inputs.fetch_valid=x.inputs.grant=true;x.inputs.predictions=a.predictions;x.inputs.mask=a.mask;x.inputs.consumer_ready=false;s.step(x);s.reset();single(s,s.offer(0x800));break;}
    case 37:{Stimulus x;x.malformed=true;x.question="FM18:unsolicited";x.inputs.response_valid=true;x.inputs.response.errors=c.mask();s.step(x);s.reset();auto a=s.offer(0x100),b=s.offer(0x200);s.tick(&a,false,false);s.tick(&b,false,false);auto d=s.offer(0x300);x=Stimulus{};x.malformed=true;x.question="FM18:overcapacity";x.inputs.fetch_valid=x.inputs.grant=true;x.request_id=d.id;x.start=d.start;x.inputs.predictions=d.predictions;x.inputs.mask=d.mask;x.inputs.consumer_ready=false;s.step(x);s.reset();single(s,s.offer(0x800));break;}
    case 38:{for(unsigned mask=0;mask<=c.mask();++mask){auto a=s.offer(0x100,mask,c.mask(),31);a.mask=mask;for(unsigned k=0;k<c.lanes;++k){a.predictions[k].pc=0x1234567800000001+37*k;a.predictions[k].target=UINT64_MAX-k;}single(s,a);}break;}
    case 39:late(s);s.tick(nullptr,false,false,false,"branch");single(s,s.offer(0x800));break;
    case 40:{pipe(s,16);s.tick(nullptr,false,false,false,"branch");s.tick(nullptr,false,false,false,"exception");pipe(s,16);const auto& n=s.state();if(n.totals.accepted!=n.totals.delivered+n.totals.canceled)throw std::logic_error("FM07: completed directed obligations do not conserve");break;}
    case 41:completed_full(s,0x2000);release_full(s,0x3000);break;
    case 42:{full(s);auto a=s.offer(0x500,0,c.mask(),0);live(a,c);
        s.tick(&a,false,false);s.tick(nullptr,true,false,false,"branch");
        single(s,s.offer(0x800));break;}
    case 43:{completed_full(s,0x2000);s.reset();single(s,s.offer(0x800));
        full(s);auto a=s.offer(0x500);s.tick(&a,false,false);s.reset();
        single(s,s.offer(0x800));break;}
    case 44:for(unsigned k=0;k<8;++k){completed_full(s,0x4000+k*0x100);release_full(s,0x8000+k*c.bytes());}break;
    default:throw std::invalid_argument("unknown FM scenario");
    }
}
void run_directed(Simulator& s,const RunOptions& o){
    unsigned selected=0;if(o.selection!="all"){if(o.selection.size()!=6||o.selection.rfind("FM-T",0)!=0)throw std::invalid_argument("scenario must be all or FM-T01..FM-T44");selected=std::stoul(o.selection.substr(4));if(!selected||selected>44)throw std::invalid_argument("unknown FM scenario");}
    for(unsigned n=1;n<=44;++n){if(selected&&selected!=n)continue;const auto id=std::string("FM-T")+(n<10?"0":"")+std::to_string(n);
        const auto campaign=n>=34&&n<=39?Campaign::Characterization:n==38?Campaign::Stress:Campaign::Architectural;
        s.begin(id,titles[n-1],campaign);const auto before=s.scoreboard().errors();const auto checks=s.scoreboard().checks();TB_LOG(LOG_LOW,"Starting %s > %s",id.c_str(),titles[n-1]);s.reset();scenario(s,n);s.drain();
        if(s.scoreboard().checks()==checks)throw std::logic_error("FM20: scenario performed no comparisons");
        if(s.scoreboard().errors()==before)TB_SUCCESS(LOG_LOW,"Test successfully passed > %s comparisons=%llu",id.c_str(),static_cast<unsigned long long>(s.scoreboard().checks()-checks));else TB_ERR("Test failed > %s",id.c_str());
    }
}
} // namespace len5::fetchmem
