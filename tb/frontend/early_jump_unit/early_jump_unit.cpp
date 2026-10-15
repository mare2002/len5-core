// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Independent encoder, abstract model and causal environment confidence fixtures.
#include "early_jump_environment.hh"
#include <iostream>
#include <stdexcept>
#include <functional>
using namespace len5::early;
static uint64_t checks=0;
static void require(bool v,const char* why) { ++checks; if(!v) throw std::runtime_error(why); }
static void rejects(const std::function<void()>& f) {
    bool caught=false; try { f(); } catch(const std::exception&) { caught=true; } require(caught,"invalid fixture was not rejected");
}
static void edge(ReferenceModel& m,Stimulus s,uint64_t c=0) { m.input_change(s.inputs); m.rising_edge(m.plan(s,c)); }
int main() {
    try {
        require(jal(1,8)==0x008000ef,"independently specified JAL x1,+8 word");
        require(jal(0,-4)==0xffdff06f,"independently specified JAL x0,-4 word");
        require(decode(0xffdff06f).immediate==-4,"fixed negative immediate word");
        require(decode(0x800000ef).immediate==-1048576,"fixed JAL minimum word, independent of encoder");
        require(decode(0x7ffff0ef).immediate==1048574,"fixed JAL maximum word, independent of encoder");
        require(decode(0x000010ef).immediate==4096,"fixed JAL upper immediate word, independent of encoder");
        require(jalr(0,1,0)==0x00008067 && decode(0x00008067).kind==Kind::Return,"canonical return");
        require(decode(0x00028067).kind==Kind::Jalr,"x5 return is excluded from RAS");
        require(decode(0x00000093).kind==Kind::Immediate,"ordinary x1 destination is not call");
        require(outcome(branch(0,0,0,8),0x100,1,2).taken,"BEQ x0,x0 always taken regardless of poisoned operand values");
        require(!outcome(branch(1,0,0,8),0x100,1,2).taken,"BNE x0,x0 never taken");
        require(outcome(jalr(0,0,-4),0x100,0x800,0).target==UINT64_MAX-3,"JALR x0 source uses hardwired zero");
        require(outcome(jalr(0,1,1),0x100,0x800,0).target==0x800,"JALR clears target bit zero");
        std::mt19937_64 rng(17);
        for(unsigned rd=0;rd<32;++rd) for(int64_t off:{-1048576,-4096,-4,0,2,4,2048,524288,1048574}) {
            const auto d=decode(jal(rd,off)); require(d.immediate==off && d.rd==rd,"JAL architectural bit positions/sign");
            require(d.kind==(rd==1?Kind::Call:Kind::Jal),"D exact linking register policy");
        }
        for(unsigned rd=0;rd<32;++rd) for(unsigned rs1=0;rs1<32;++rs1) for(int64_t off:{-2048,0,2047}) {
            const auto d=decode(jalr(rd,rs1,off)); require(d.rd==rd && d.rs1==rs1 && d.immediate==off,"I-format register/immediate layout");
            require(d.kind==(rd==0 && rs1==1 && off==0?Kind::Return:Kind::Jalr),"D no coroutine/x5 hint expansion");
        }
        for(unsigned n=0;n<10000;++n) {
            const auto d=decode(ordinary(rng,n)); require(d.valid && !d.control(),"valid randomized ordinary word falsely classified as jump");
        }
        rejects([&]{jal(1,3);}); rejects([&]{jal(32,0);}); rejects([&]{jalr(0,0,2048);});
        for(unsigned width:{1u,2u,4u,8u}) {
            Config cfg; cfg.lanes=width; ReferenceModel m(cfg,Contract{});
            require(!m.state().predictive.known,"no observed-state initialization");
            Stimulus reset; reset.inputs.rst_n=false; edge(m,reset);
            edge(m,Stimulus{});
            for(unsigned lane=0;lane<width;++lane) {
                auto predicted=bundle(cfg,0x100+4*lane);
                predicted.inputs.words[lane]=jal(1,8);
                auto& p=predicted.inputs.predictions[lane]; p.hit=p.taken=true;
                for(uint64_t target:{p.pc+8,p.pc+0x100}) {
                    p.target=target; const auto selection=m.select(predicted.inputs);
                    require(selection.correction.known && selection.correction.value==0
                        && selection.correction.evidence=="D","EQ04 approved suppression ignores taken JAL target equality");
                    require(selection.offered==Operation::Push,"EQ04 suppression does not remove approved call operation");
                }
                p.taken=false;
                require(m.select(predicted.inputs).correction.value==1,"not-taken JAL hit still needs correction under existing contract");
                p.hit=false; p.taken=true;
                require(m.select(predicted.inputs).correction.value==1,"raw taken on a miss is not approved suppression");
            }
            for(unsigned lane=0;lane<width;++lane) {
                auto s=bundle(cfg,0x100+4*lane); s.inputs.words[lane]=jal(1,8); edge(m,s,1);
                require(m.state().predictive.top().value==0x104+4*lane,"call own PC+4, no bundle-relative error");
                auto excluded=bundle(cfg,0x200); excluded.inputs.words[0]=jalr(0,5,0); edge(m,excluded,2);
                require(m.state().predictive.top().value==0x104+4*lane,"D excluded JALR leaves P intact");
                auto ret=bundle(cfg,0x300); ret.inputs.words[0]=jalr(0,1,0); const auto s0=m.select(ret.inputs);
                require(s0.target.known && s0.target.value==0x104+4*lane,"return uses pre-acceptance top"); edge(m,ret,3);
            }
            edge(m,reset); edge(m,Stimulus{});
            auto a=bundle(cfg,0x104); a.inputs.words[1%width]=jal(1,8); if(width==1) a.request_pc=0x104;
            a.inputs.mask=request_mask(a.request_pc,a.inputs.predictions,cfg); edge(m,a,4);
            auto confirm=Stimulus{}; confirm.inputs.call_confirm=true; confirm.inputs.link=0xabc; edge(m,confirm,5);
            require(m.state().confirmed.top().value==0xabc && m.state().predictive.top().value!=0xabc,"confirmed does not duplicate into predictive");
            auto f=Stimulus{}; f.inputs.flush=true; f.reason="misprediction"; edge(m,f,6);
            require(m.state().predictive.top().value==0xabc,"D restore from independently known C");
            f.inputs.call_confirm=true; f.inputs.link=0xdef; edge(m,f,7);
            require(m.state().predictive.top().value==0xdef,"named provisional confirm-then-restore hypothesis");
            for(unsigned lane=0;lane<width;++lane) {
                auto b=bundle(cfg,0x400+4*lane);
                for(auto& p:b.inputs.predictions) p.hit=p.taken=true;
                require(request_mask(b.request_pc,b.inputs.predictions,cfg)==(1u<<lane),"inclusive first taken and start exclusion");
                for(auto& p:b.inputs.predictions) { p.hit=true; p.taken=false; }
                require(request_mask(b.request_pc,b.inputs.predictions,cfg)==(cfg.all_lanes() & ~((1u<<lane)-1)),"NT is not prediction absence or cutoff");
            }
        }
        Config cfg; cfg.lanes=2; Environment env(cfg);
        auto s=bundle(cfg,0x100,env.allocate_bundle()); s.campaign=Campaign::Architectural;
        s.requested_cycle=0; s.available_cycle=2; s.inputs.words[0]=jal(1,8);
        env.request(s);
        rejects([&]{env.validate(s,1);}); env.validate(s,2);
        ReferenceModel m(cfg,Contract{}); Stimulus reset; reset.inputs.rst_n=false; edge(m,reset); edge(m,Stimulus{});
        auto t=m.plan(s,2); env.consume(s,t,2); auto candidates=env.pending(4); require(candidates.size()==1,"causal supported accepted call record");
        auto confirm=Stimulus{}; confirm.campaign=Campaign::Architectural; confirm.inputs.call_confirm=true;
        confirm.inputs.link=0x104; confirm.confirmation_id=candidates[0].id;
        rejects([&]{env.validate(confirm,3);}); env.validate(confirm,4);
        env.consume(confirm,m.plan(confirm,4),4); rejects([&]{env.validate(confirm,5);});
        Contract c=Contract::established(); ReferenceModel unknown_model(cfg,c); edge(unknown_model,reset); edge(unknown_model,Stimulus{});
        Stimulus f; f.inputs.flush=f.inputs.call_confirm=true; f.inputs.link=0x800; f.reason="misprediction"; edge(unknown_model,f);
        require(!unknown_model.state().predictive.known,"EQ07 unknown state is not promoted to golden");
        auto nop=bundle(cfg,0x100); edge(unknown_model,nop); require(!unknown_model.state().predictive.known,"ordinary word cannot repair unknown history");
        edge(unknown_model,reset); require(unknown_model.state().predictive.known,"independent reset restores knowledge");
        // EQ08 has not decided whether exception recovery preserves or clears C.
        // A subsequent ordinary restoration cannot manufacture knowledge of C.
        edge(unknown_model,Stimulus{});
        Stimulus confirmed; confirmed.inputs.call_confirm=true; confirmed.inputs.link=0xabc;
        edge(unknown_model,confirmed);
        Stimulus exception; exception.inputs.flush=true; exception.reason="exception";
        edge(unknown_model,exception);
        require(!unknown_model.state().confirmed.known,"EQ08 unknown exception policy must invalidate C as well as P");
        exception.reason="misprediction"; edge(unknown_model,exception);
        require(!unknown_model.state().predictive.known,"restoration from uncertain C cannot repair P");
        edge(unknown_model,confirmed);
        require(!unknown_model.state().confirmed.top().known,"unknown occupancy and overflow policy cannot establish a top from a new push");
        edge(unknown_model,exception);
        require(!unknown_model.state().predictive.top().known,"unknown-boundary push must not leak a known return target through restoration");
        auto independent_jal=bundle(cfg,0x100); independent_jal.inputs.words[0]=jal(0,8);
        require(unknown_model.select(independent_jal.inputs).target.value==0x108
            && unknown_model.select(independent_jal.inputs).target.known,"EQ08 uncertainty must not disable independent JAL arithmetic");
        edge(unknown_model,reset);
        require(unknown_model.state().confirmed.known && unknown_model.state().predictive.known,"reset reestablishes both histories after EQ08");
        // Confirming a squashed instruction is an environment error, not a DUT failure.
        {
            Config cfg; cfg.lanes=2; Environment causal(cfg); ReferenceModel m(cfg,Contract{});
            Stimulus reset; reset.inputs.rst_n=false; edge(m,reset); edge(m,Stimulus{});
            auto oldest=bundle(cfg,0x100,causal.allocate_bundle()); oldest.campaign=Campaign::Architectural;
            oldest.inputs.words[0]=jal(1,8); oldest.inputs.predictions[0]={0x100,0x900,true,true};
            oldest.inputs.mask=request_mask(oldest.request_pc,oldest.inputs.predictions,cfg); oldest.available_cycle=2;
            causal.request(oldest); causal.validate(oldest,2); auto t=m.plan(oldest,2); causal.consume(oldest,t,2); m.rising_edge(t);
            const auto older_id=causal.pending(4).at(0).id;
            auto younger=bundle(cfg,0x200,causal.allocate_bundle()); younger.campaign=Campaign::Architectural;
            younger.inputs.words[0]=jal(1,8); younger.available_cycle=3; causal.request(younger);
            causal.validate(younger,3); t=m.plan(younger,3); causal.consume(younger,t,3); m.rising_edge(t);
            Stimulus confirm; confirm.campaign=Campaign::Architectural; confirm.inputs.call_confirm=true;
            confirm.inputs.link=0x104; confirm.confirmation_id=older_id; causal.validate(confirm,4);
            causal.consume(confirm,m.plan(confirm,4),4);
            const auto younger_id=causal.pending(5).at(0).id;
            Stimulus flush; flush.campaign=Campaign::Architectural; flush.inputs.flush=true;
            flush.reason="misprediction"; flush.recovery_id=older_id; causal.validate(flush,5);
            causal.consume(flush,m.plan(flush,5),5);
            confirm.confirmation_id=younger_id; confirm.inputs.link=0x204;
            rejects([&]{causal.validate(confirm,6);});
        }
        std::cout<<"PASS: early_jump independent encoder/model/environment, "<<checks<<" checks\n"; return 0;
    } catch(const std::exception& e) { std::cerr<<"FAIL: early_jump independent framework: "<<e.what()<<'\n'; return 1; }
}
