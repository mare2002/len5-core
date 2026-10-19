// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Pure independent fixtures: no Verilator, DUT output or internal RTL state.
#include "fetch_mem_environment.hh"
#include <iostream>
#include <random>
using namespace len5::fetchmem;
static unsigned checks=0;
static void check(bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);}
static Transition edge(ReferenceModel& m,Stimulus s,unsigned cycle){m.input_change(s);auto t=m.plan(s,cycle);m.rising_edge(t);return t;}
static void reset(ReferenceModel& m){Stimulus s;s.inputs.rst_n=false;edge(m,s,0);s.inputs.rst_n=true;edge(m,s,1);}
int main(){try{
    for(unsigned n:{1u,2u,4u,8u}){
        Config c;c.lanes=n;ReferenceModel m(c);reset(m);check(m.outputs(Stimulus{}).response_ready.value==0,"no response without an allocated request");
        std::array<Prediction,8> pred{};for(unsigned k=0;k<n;++k)pred[k].pc=0x100+4*k;
        for(unsigned start=0;start<n;++start)for(unsigned taken=0;taken<n;++taken){auto p=pred;p[taken].hit=p[taken].taken=true;unsigned mask=request_mask(0x100+start*4,p,c);unsigned expected=0;for(unsigned lane=start;lane<n;++lane){expected|=1u<<lane;if(lane==taken)break;}check(mask==expected,"mathematical start/first-taken mask");p[taken].hit=false;check(request_mask(0x100+start*4,p,c)==(c.mask()&~((1u<<start)-1)),"miss-taken does not cut mask");}
        Stimulus s;s.request_id=11;s.start=0x100;s.inputs.fetch_valid=s.inputs.grant=true;s.inputs.predictions=pred;s.inputs.mask=c.mask();edge(m,s,2);
        s.request_id=12;s.start=0x200;for(auto& p:s.inputs.predictions)p.pc+=0x100;s.inputs.mask=1;
        s.inputs.response_valid=true;s.inputs.response.words[0]=0x12345678;s.inputs.response.errors=1;s.inputs.response.causes[0]=0;auto t=edge(m,s,3);
        check(t.k&&t.r&&!t.d,"same-edge accepted different request and old response");auto e=m.outputs(Stimulus{});check(e.lanes[0].pc.value==0x100,"old request PC retained");check(e.lanes[0].error.value==1&&e.lanes[0].cause.known&&e.lanes[0].cause.value==0,"raised cause-zero is meaningful");
        check(e.lanes[0].word.value==0x12345678,"actual supplied response word transported");check(m.state().outstanding.front().id==12,"new request remains outstanding");
        Stimulus r;r.inputs.response_valid=true;r.inputs.response.words[0]=0xabcdef13;r.inputs.consumer_ready=false;edge(m,r,4);check(m.state().answers.size()==2,"two buffered records");check(m.outputs(r).response_ready.value==0,"full buffer no lookahead ready");
        Stimulus d;edge(m,d,5);check(m.state().answers.size()==1,"consume exactly once");check(m.outputs(d).lanes[0].pc.value==0x200,"next request association");check(m.outputs(d).lanes[0].error.value==0,"clean response does not inherit old fault");edge(m,d,6);check(m.state().totals.delivered==2,"two completed obligations");
        // Completed reservations survive a full answer spill and retain their original metadata.
        ReferenceModel buffered(c); reset(buffered);
        for (unsigned id=1; id<=4; ++id) {
            Stimulus request; request.request_id=id; request.inputs.fetch_valid=request.inputs.grant=true;
            request.inputs.consumer_ready=false; request.inputs.mask=c.mask(); request.inputs.predictions=pred;
            for (auto& p:request.inputs.predictions) p.pc+=id*0x100;
            edge(buffered,request,id*2);
            Stimulus result; result.inputs.response_valid=true; result.inputs.consumer_ready=false;
            result.inputs.response.words[0]=id;
            check(buffered.outputs(result).response_ready.value==1,"reserved result accepted behind full answer spill");
            edge(buffered,result,id*2+1);
        }
        check(buffered.state().answers.size()==2 && buffered.state().completed.size()==2,"both completed storage regions full");
        Stimulus blocked; blocked.inputs.fetch_valid=blocked.inputs.grant=true;
        check(!buffered.outputs(blocked).request_valid.value && !buffered.outputs(blocked).fetch_ready.value,"completed entries retain reservation credit");
        for (unsigned id=1; id<=4; ++id) {
            while (!buffered.outputs(Stimulus{}).valid.value) edge(buffered,Stimulus{},20+id);
            auto result=buffered.outputs(Stimulus{});
            check(result.lanes[0].word.value==id && result.lanes[0].pc.value==0x100+id*0x100,"completed queue preserves payload/metadata order");
            edge(buffered,Stimulus{},30+id);
        }
        check(buffered.state().totals.delivered==4 && buffered.state().completed.empty(),"all completed entries drain once");
        // Independent randomized queue fixture with manually supplied known predictions and words.
        std::mt19937_64 rng(19+n);Environment env(c);ReferenceModel q(c);reset(q);Inputs z;z.rst_n=false;env.input_change(z);z.rst_n=true;env.input_change(z);
        uint64_t id=1;std::optional<Offer> offer;
        for(unsigned cycle=2;cycle<1002;++cycle){if(!offer&&rng()%2)offer=make_offer(c,id++,0x100+(rng()%16)*4,rng()%4,rng()%c.mask(),rng()%2);
            auto v=env.compose(offer?&*offer:nullptr,cycle,true,rng()%3!=0);q.input_change(v);auto plan=q.plan(v,cycle);env.validate(v,plan,cycle);env.consume(v,plan,cycle);q.rising_edge(plan);if(plan.k)offer.reset();
            check(q.state().outstanding.size()+q.state().completed.size()<=2&&q.state().answers.size()<=2,"capacity invariant");check(q.state().totals.accepted==q.state().totals.delivered+q.state().totals.canceled+q.state().outstanding.size()+q.state().completed.size()+q.state().answers.size(),"obligations conserved at every edge");}
        // Flush and reset are independent establishing events, never observed-state repair.
        Stimulus f;f.inputs.flush=true;f.inputs.consumer_ready=false;f.reason="branch";edge(q,f,1002);check(q.state().outstanding.empty()&&q.state().completed.empty()&&q.state().answers.empty(),"flush empties pending logical queues");
        check(q.state().totals.accepted==q.state().totals.delivered+q.state().totals.canceled,"canceled obligations fully accounted");
        ReferenceModel unknown(c);reset(unknown);Stimulus bad;bad.malformed=true;bad.question="FQ04";bad.inputs.response_valid=true;bad.inputs.consumer_ready=false;bad.inputs.response.words[0]=0x13;edge(unknown,bad,2);auto u=unknown.outputs(bad);
        check(!u.response_ready.value && !u.valid.value,"unsolicited response cannot create an entry");check(unknown.state().association_known,"rejected unsolicited response leaves allocated associations intact");reset(unknown);check(unknown.state().association_known,"coordinated reset establishes association knowledge");
        // Hand-calculated early-flush accounting: consume old head, cancel younger work.
        ReferenceModel em(c); reset(em);
        Stimulus ea; ea.request_id=1; ea.start=0x100; ea.inputs.fetch_valid=ea.inputs.grant=true; ea.inputs.mask=c.mask(); ea.inputs.predictions=pred; ea.inputs.consumer_ready=false;
        edge(em,ea,2);
        ea.request_id=2; ea.inputs.response_valid=true; ea.inputs.response.errors=c.mask(); edge(em,ea,3);
        Stimulus ef; ef.inputs.flush=true; ef.reason="early"; ef.inputs.consumer_ready=true;
        auto et=edge(em,ef,4);
        check(et.d && et.delivered_id==1 && et.canceled_ids.size()==1,"early flush distinguishes consumed head from younger cancellation");
        check(em.state().totals.accepted==2 && em.state().totals.delivered==1 && em.state().totals.canceled==1,"early completion conservation");
        check(em.state().outstanding.empty() && em.state().completed.empty() && em.state().answers.empty(),"no stale association survives atomic flush");
        // Duplicate reset assertion cannot cancel the same obligation twice.
        edge(em,ea,5); Stimulus rz; rz.inputs.rst_n=false; em.input_change(rz);
        auto canceled=em.state().totals.canceled; em.input_change(rz);
        check(em.state().totals.canceled==canceled,"held asynchronous reset cancels once");
        check(!em.outputs(rz).valid.value,"reset invalidates registered output immediately");
        // Negative memory histories are rejected independently of scoreboard comparisons.
        Environment neg(c);ReferenceModel nm(c);reset(nm);Stimulus invalid;invalid.inputs.response_valid=true;invalid.response_id=999;bool rejected=false;try{neg.validate(invalid,nm.plan(invalid,3),3);}catch(const EnvironmentError&){rejected=true;}check(rejected,"unsolicited response rejected");
        auto a=make_offer(c,1,0x100);auto k=neg.compose(&a,4,false);auto kt=nm.plan(k,4);neg.validate(k,kt,4);neg.consume(k,kt,4);nm.rising_edge(kt);
        invalid=neg.compose(nullptr,5);invalid.response_id=999;rejected=false;try{neg.validate(invalid,nm.plan(invalid,5),5);}catch(const EnvironmentError&){rejected=true;}check(rejected,"out-of-order response identity rejected");
        invalid=neg.compose(nullptr,5);invalid.inputs.response.words[0]^=4;rejected=false;try{neg.validate(invalid,nm.plan(invalid,5),5);}catch(const EnvironmentError&){rejected=true;}check(rejected,"response error/data must belong to correct request");
        auto reject=[&](Stimulus v,unsigned cycle,const char* message){bool caught=false;try{neg.validate(v,nm.plan(v,cycle),cycle);}catch(const EnvironmentError&){caught=true;}check(caught,message);};
        invalid=neg.compose(nullptr,4); invalid.inputs.response_valid=true; invalid.response_id=1; invalid.inputs.response=a.memory_data;
        reject(invalid,4,"zero-latency response rejected by positive-latency profile");
        invalid=neg.compose(&a,5,false);reject(invalid,5,"duplicate accepted identity rejected");
        auto b=make_offer(c,2,0x200);auto kb=neg.compose(&b,5,false);auto bt=nm.plan(kb,5);neg.validate(kb,bt,5);neg.consume(kb,bt,5);nm.rising_edge(bt);
        auto third=make_offer(c,3,0x300);invalid=neg.compose(&third,6,false);invalid.inputs.grant=true;
        auto blocked_full=nm.plan(invalid,6);
        check(!blocked_full.k,"full reservation queue suppresses a new request despite grant");
        auto illegal_full=blocked_full; illegal_full.k=true;
        rejected=false;try{neg.validate(invalid,illegal_full,6);}catch(const EnvironmentError&){rejected=true;}
        check(rejected,"environment rejects an actual overcapacity acceptance");
        invalid=neg.compose(nullptr,6);invalid.inputs.flush=true;invalid.inputs.consumer_ready=false;invalid.inputs.fetch_valid=invalid.inputs.grant=true;
        reject(invalid,6,"grant on flush rejected by active protocol");
        Inputs canceled_reset; canceled_reset.rst_n=false;neg.input_change(canceled_reset);canceled_reset.rst_n=true;neg.input_change(canceled_reset);reset(nm);
        invalid=neg.compose(&a,9,false);reject(invalid,9,"canceled request identity cannot be reused as a new live request");
        // Fill answer capacity before offering a held third response; changing it is invalid.
        Environment held(c);ReferenceModel hm(c);reset(hm);
        for(unsigned cycle=2;cycle<5;++cycle){auto next=make_offer(c,cycle,0x100+cycle*c.bytes());auto v=held.compose(&next,cycle,cycle>2,false);auto ht=hm.plan(v,cycle);held.validate(v,ht,cycle);held.consume(v,ht,cycle);hm.rising_edge(ht);}
        auto v=held.compose(nullptr,5,true,false);auto ht=hm.plan(v,5);
        check(ht.r && v.inputs.response_valid,"reserved response accepted while answer spill is full");
        // Exercise the environment's held-response guards independently of this always-accepting consumer.
        ht.r=false; ht.next=hm.state(); held.validate(v,ht,5); held.consume(v,ht,5);
        auto changed=v;changed.inputs.response.errors^=1;rejected=false;try{held.validate(changed,hm.plan(changed,6),6);}catch(const EnvironmentError&){rejected=true;}check(rejected,"held fault payload change rejected");
        changed=v;changed.inputs.response_valid=false;rejected=false;try{held.validate(changed,hm.plan(changed,6),6);}catch(const EnvironmentError&){rejected=true;}check(rejected,"held response withdrawal rejected");
        Environment rq(c);ReferenceModel rm(c);reset(rm);auto held_offer=make_offer(c,100,0x100);auto offer_step=rq.compose(&held_offer,2,false,true,false);auto ot=rm.plan(offer_step,2);rq.validate(offer_step,ot,2);rq.consume(offer_step,ot,2);rm.rising_edge(ot);
        offer_step.inputs.predictions[0].target^=64;offer_step.inputs.predictions[0].taken=!offer_step.inputs.predictions[0].taken;offer_step.inputs.mask=request_mask(offer_step.start,offer_step.inputs.predictions,c);
        rq.validate(offer_step,rm.plan(offer_step,3),3);check(true,"unaccepted BPU metadata may update during grant stall");
        offer_step.inputs.predictions[0].pc+=c.bytes();rejected=false;try{rq.validate(offer_step,rm.plan(offer_step,3),3);}catch(const EnvironmentError&){rejected=true;}check(rejected,"ordinary held request address change rejected");
    }
    std::cout<<"PASS: fetch_mem independent model/environment, "<<checks<<" checks\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<" after "<<checks<<" checks\n";return 1;}}
