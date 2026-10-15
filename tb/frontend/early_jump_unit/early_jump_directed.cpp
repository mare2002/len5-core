// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Scenario lifecycle and reporting adapted from pc_gen T01-T22, with real encoded bundles.
#include "early_jump_directed.hh"
#include "tb_macros.hh"
#include <functional>
#include <inttypes.h>
#include <random>
namespace len5::early {
namespace {
class Directed {
    Simulator& sim_;
    const RunOptions& options_;
    std::string id_,title_;
    std::mt19937_64 rng_;
    Stimulus tagged(Stimulus s) const { s.scenario=id_; s.title=title_; return s; }
    void send(Stimulus s) { sim_.step(tagged(s)); }
    void idle(unsigned n=1) { for(unsigned k=0;k<n;++k) send(Stimulus{}); }
    void reset() {
        Stimulus s; s.inputs.rst_n=false; sim_.probe(tagged(s)); send(s); send(s); idle();
    }
    Stimulus word(uint64_t pc,uint32_t instruction) {
        auto s=bundle(sim_.config(),pc,sim_.environment().allocate_bundle());
        s.inputs.words[(pc%sim_.config().bundle_bytes())/4]=instruction; return s;
    }
    void call(uint64_t pc,bool predicted=false) {
        auto s=word(pc,jal(1,8)); const unsigned lane=(pc%sim_.config().bundle_bytes())/4;
        s.inputs.predictions[lane].hit=s.inputs.predictions[lane].taken=predicted;
        s.inputs.predictions[lane].target=pc+8; s.inputs.mask=request_mask(pc,s.inputs.predictions,sim_.config()); send(s);
    }
    void ret(uint64_t pc=0x600) { send(word(pc,jalr(0,1,0))); }
    void confirm(bool call_type,uint64_t link) {
        Stimulus s; s.inputs.call_confirm=call_type; s.inputs.ret_confirm=!call_type; s.inputs.link=link; send(s);
    }
    void recover(const char* reason="misprediction") { Stimulus s; s.inputs.flush=true; s.reason=reason; send(s); }
    void guard() { sim_.guard(id_.c_str()); }
    void architectural(Stimulus s) {
        s.campaign=Campaign::Architectural; s.requested_cycle=sim_.cycles(); s.available_cycle=sim_.cycles()+s.response_delay;
        sim_.environment().request(s); idle(s.response_delay); send(s);
    }
    void test(unsigned number,const char* title,const std::function<void()>& f) {
        char id[16]; std::snprintf(id,sizeof id,"EJ-T%02u",number);
        if(options_.selection!="all" && options_.selection!=id) return;
        id_=id; title_=title;
        TB_LOG(LOG_LOW,"REQ > Starting %s: %s",id,title);
        const auto checks=sim_.scoreboard().field_checks(),errors=sim_.scoreboard().field_errors();
        try { reset(); f(); } catch(...) { TB_ERR("Test failed > id=%s",id); throw; }
        if(sim_.scoreboard().field_checks()==checks) { sim_.scoreboard().problem("framework_error",id_+": no meaningful comparisons"); }
        if(sim_.scoreboard().field_errors()!=errors) TB_ERR("Test failed > id=%s mismatches=%" PRIu64,id,sim_.scoreboard().field_errors()-errors);
        else TB_SUCCESS(LOG_LOW,"Test successfully passed > id=%s: %s",id,title);
    }
public:
    Directed(Simulator& sim,const RunOptions& o):sim_(sim),options_(o),rng_(o.seed) {}
    void run() {
        const auto cfg=sim_.config();
        test(1,"async reset dominates populated histories and controls",[&]{
            call(0x104); confirm(true,0x208); Stimulus s=word(0x300,jal(1,8));
            s.inputs.rst_n=false; s.inputs.flush=s.inputs.call_confirm=s.inputs.ret_confirm=true;
            sim_.probe(tagged(s)); send(s); idle(); ret(); recover(); ret();
        });
        test(2,"reset release and immediate live-response characterization",[&]{
            idle(); call(0x104); Stimulus s; s.inputs.rst_n=false; send(s);
            s=word(0x200,jal(1,8)); s.campaign=Campaign::Characterization; send(s); ret(); reset(); ret();
        });
        test(3,"JAL from every lane and D x1-only push policy",[&]{
            for(unsigned lane=0;lane<cfg.lanes;++lane) for(unsigned rd:{0u,1u,5u,31u}) {
                reset(); call(0x400); guard(); send(word(0x100+4*lane,jal(rd,-4))); guard(); ret(); ret();
            }
        });
        test(4,"J immediate layout, sign, extrema and address wrap",[&]{
            for(int64_t off:{INT64_C(-1048576),INT64_C(-4096),INT64_C(-2048),INT64_C(-4),INT64_C(0),INT64_C(2),INT64_C(4),INT64_C(2048),INT64_C(524288),INT64_C(1048574)})
                for(uint64_t pc:{UINT64_C(0),UINT64_C(0xfffffffc),UINT64_C(0x7ffffffffffffffc),UINT64_MAX-3}) {
                    send(word(pc,jal(0,off)));
                }
            for(unsigned bit=1;bit<20;++bit) {
                send(word(0x100,jal(0,int64_t(1)<<bit)));
                send(word(0x100,jal(0,-(int64_t(1)<<bit))));
            }
            call(UINT64_MAX-3); ret();
        });
        test(5,"partial starting bundles and excluded prefix control words",[&]{
            for(unsigned start=0;start<cfg.lanes;++start) {
                auto s=word(0x100+4*start,jal(0,8));
                for(unsigned k=0;k<start;++k) { s.inputs.words[k]=jal(1,16); s.inputs.predictions[k].hit=s.inputs.predictions[k].taken=true; }
                s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            }
        });
        test(6,"canonical return versus valid and invalid near misses",[&]{
            call(0x104); guard();
            for(unsigned n=0;n<256;++n) {
                auto s=word(0x200,near_miss(rng_));
                if(!decode(s.inputs.words[0]).valid) s.campaign=Campaign::Characterization;
                // A random single-bit near miss can be an actual CALL; retain real decoding rather than pretending ordinary.
                send(s);
                if(sim_.state().predictive.entries.empty()) call(0x104);
            }
            guard(); ret();
        });
        test(7,"long randomized ordinary sequence cannot corrupt RAS",[&]{
            call(0x104); call(0x208); guard();
            for(unsigned n=0;n<4096;++n) {
                auto s=bundle(cfg,0x800+4*(n%cfg.lanes),sim_.environment().allocate_bundle());
                for(unsigned k=0;k<cfg.lanes;++k) s.inputs.words[k]=ordinary(rng_,n+k);
                send(s);
            }
            guard(); ret(); ret(); ret();
        });
        test(8,"JAL selected-lane prediction four-state qualification",[&]{
            for(unsigned lane=0;lane<cfg.lanes;++lane) for(unsigned pred=0;pred<4;++pred) for(bool correct:{false,true}) {
                auto s=word(0x100+4*lane,jal(0,8)); auto& p=s.inputs.predictions[lane];
                p.hit=pred&2; p.taken=pred&1; p.target=correct?p.pc+8:p.pc+0x100;
                s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            }
        });
        test(9,"not-taken branch allows later JAL; taken branch excludes it",[&]{
            if(cfg.lanes<2) { idle(); return; }
            call(0x400); guard();
            for(bool taken:{false,true}) {
                auto s=bundle(cfg,0x100,sim_.environment().allocate_bundle()); s.inputs.words[0]=branch(0,2,3,8);
                s.inputs.words[cfg.lanes-1]=jal(1,-4); s.inputs.predictions[0]={0x100,0x800,true,taken};
                s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s); guard();
            }
        });
        test(10,"multiple raw taken/not-taken predictions and inclusive mask",[&]{
            for(unsigned start=0;start<cfg.lanes;++start) for(unsigned stop=start;stop<cfg.lanes;++stop) {
                auto s=bundle(cfg,0x100+4*start,sim_.environment().allocate_bundle());
                for(unsigned k=0;k<cfg.lanes;++k) { s.inputs.words[k]=branch(1,1,2,8); s.inputs.predictions[k].hit=true; s.inputs.predictions[k].taken=k>=stop; s.inputs.predictions[k].target=0x800+k*0x100; }
                s.inputs.words[cfg.lanes-1]=jal(0,16); s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            }
        });
        test(11,"oldest jump beats younger correction and current prediction",[&]{
            auto s=word(0x100,jal(0,16));
            if(cfg.lanes>1) { s.inputs.words[1]=jal(1,-4); s.inputs.predictions[1].hit=s.inputs.predictions[1].taken=true; s.inputs.predictions[1].target=0x900; }
            s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            s.inputs.predictions[0].hit=s.inputs.predictions[0].taken=true; s.inputs.predictions[0].target=0x800;
            s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            if(cfg.lanes>1) {
                s=word(0x100,jal(0,-4)); s.inputs.words[1]=branch(1,2,3,16);
                s.inputs.predictions[1]={0x104,0x900,true,true};
                s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s);
            }
        });
        test(12,"call/return bundle ordering including empty returns",[&]{
            auto s=word(0x100,jal(1,8)); if(cfg.lanes>1) s.inputs.words[1]=jalr(0,1,0); send(s); ret();
            s=word(0x200,jalr(0,1,0)); if(cfg.lanes>1) s.inputs.words[1]=jal(1,8); send(s); ret();
            if(cfg.lanes>1) for(bool taken:{false,true}) {
                call(0x404); guard(); s=bundle(cfg,0x100,sim_.environment().allocate_bundle());
                s.inputs.words[0]=branch(0,2,3,8); s.inputs.words[cfg.lanes-1]=jalr(0,1,0);
                s.inputs.predictions[0]={0x100,0x900,true,taken};
                s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg); send(s); guard();
            }
        });
        test(13,"all retained prediction fields and explicit feedback propagation",[&]{
            auto s=word(0x100+4*(cfg.lanes-1),jal(0,-4));
            s.request_pc=0x100; s.inputs.mask=cfg.all_lanes();
            for(unsigned k=0;k<cfg.lanes;++k) { s.inputs.predictions[k].hit=true; s.inputs.predictions[k].taken=false; s.inputs.predictions[k].target=0x800+k*4; }
            s.inputs.feedback=0x1234567887654320; s.feedback_explicit=true; send(s);
        });
        test(14,"predicted call still pushes without early correction",[&]{ call(0x104,true); ret(); });
        test(15,"nested speculative links expose newest-first history",[&]{
            for(unsigned k=0;k<cfg.depth;++k) call(0x104+k*0x100);
            for(unsigned k=0;k<=cfg.depth;++k) ret();
        });
        test(16,"confirmation during idle/stall observed through later recovery",[&]{
            call(0x104); confirm(true,0x808); auto s=word(0x300,jal(0,8)); s.inputs.ready=false; s.inputs.call_confirm=true; s.inputs.link=0x908;
            send(s); s.inputs.call_confirm=false; send(s); s.inputs.ready=true; send(s); recover(); ret(); ret();
            confirm(false,0); recover(); ret();
        });
        test(17,"causal correct and mispredicted branch-unit confirmations",[&]{
            auto s=word(0x100,jal(1,8)); s.inputs.predictions[0]={0x100,0x900,true,true}; s.inputs.mask=request_mask(s.request_pc,s.inputs.predictions,cfg);
            architectural(s); idle(2); auto pending=sim_.environment().pending(sim_.cycles());
            if(pending.empty()) throw std::logic_error("directed causal call missing");
            Stimulus c; c.campaign=Campaign::Architectural; c.confirmation_id=pending[0].id; c.inputs.call_confirm=true; c.inputs.link=0x104; send(c);
            c=Stimulus{}; c.campaign=Campaign::Architectural; c.inputs.flush=true; c.reason="misprediction"; c.recovery_id=pending[0].id; send(c); ret();
            reset();
            auto correct=word(0x200,jal(1,8)); architectural(correct); idle(2);
            auto p=sim_.environment().pending(sim_.cycles());
            if(p.empty()) throw std::logic_error("missing correct call confirmation source");
            c=Stimulus{}; c.campaign=Campaign::Architectural; c.confirmation_id=p[0].id;
            c.inputs.call_confirm=true; c.inputs.link=p[0].pc+4; send(c);
            auto returned=word(0x400,jalr(0,1,0)); returned.executed_taken[0]=returned.execution_known[0]=true;
            returned.rs1_value[0]=returned.executed_target[0]=0x204;
            architectural(returned); idle(2); p=sim_.environment().pending(sim_.cycles());
            if(p.empty()) throw std::logic_error("missing correct return confirmation source");
            c=Stimulus{}; c.campaign=Campaign::Architectural; c.confirmation_id=p[0].id; c.inputs.ret_confirm=true; send(c);
            recover(); ret();
        });
        test(18,"simultaneous predictive and confirmed push/pop",[&]{
            for(bool spec_call:{false,true}) for(bool resolved_call:{false,true}) {
                reset(); call(0x104); confirm(true,0x808);
                auto s=word(0x300,spec_call?jal(1,8):jalr(0,1,0)); s.inputs.call_confirm=resolved_call; s.inputs.ret_confirm=!resolved_call; s.inputs.link=0x908;
                send(s); ret(); recover(); ret();
            }
        });
        test(19,"divergent P/C restored from confirmed history",[&]{
            call(0x104); confirm(true,0x108); call(0x208); call(0x30c); recover(); ret(); ret();
        });
        test(20,"complete semantic operation/confirmation/flush matrix",[&]{
            for(unsigned op=0;op<3;++op) for(unsigned c=0;c<3;++c) for(bool f:{false,true}) for(bool ready:{false,true}) {
                reset(); call(0x104); call(0x208); confirm(true,0x808);
                auto s=word(0x300,op==1?jal(1,8):op==2?jalr(0,1,0):0x13);
                s.inputs.ready=ready; s.inputs.flush=f; s.inputs.call_confirm=c==1; s.inputs.ret_confirm=c==2; s.inputs.link=0x908; s.reason="misprediction"; send(s);
                if(!ready && !f) { s.inputs.ready=true; s.inputs.call_confirm=s.inputs.ret_confirm=false; send(s); }
                ret(); recover(); ret();
            }
        });
        test(21,"held JAL correction and readiness-dependent memory flush",[&]{
            for(unsigned length:{1u,2u,cfg.lanes,cfg.lanes+1,40u}) {
                auto s=word(0x100,jal(1,-4)); s.inputs.ready=false;
                for(unsigned k=0;k<length;++k) send(s); s.inputs.ready=true; send(s); idle(); ret();
            }
        });
        test(22,"held return top stable while confirmed history changes",[&]{
            call(0x104); call(0x208); auto s=word(0x300,jalr(0,1,0)); s.inputs.ready=false;
            for(unsigned k=0;k<16;++k) { s.inputs.call_confirm=k%5==0; s.inputs.link=0x800+4*k; send(s); }
            s.inputs.call_confirm=false; s.inputs.ready=true; send(s); ret(); recover(); ret();
        });
        test(23,"flush cancels held correction without a latent offer",[&]{
            call(0x104); confirm(true,0x808); auto s=word(0x300,jalr(0,1,0)); s.inputs.ready=false; send(s);
            s.inputs.flush=true; s.reason="misprediction"; send(s); idle(); ret();
        });
        test(24,"early memory flush does not restore speculative RAS",[&]{ call(0x104); call(0x208); ret(); ret(); });
        test(25,"independent P/C full and overflow histories",[&]{
            for(unsigned n:{0u,1u,cfg.depth-1,cfg.depth,cfg.depth+1,2*cfg.depth+1}) {
                reset(); for(unsigned k=0;k<n;++k) { call(0x104+0x100*k); confirm(true,0x804+0x100*k); }
                for(unsigned k=0;k<=cfg.depth;++k) ret(); recover(); for(unsigned k=0;k<=cfg.depth;++k) ret();
            }
        });
        test(26,"empty predictive and confirmed pops",[&]{ ret(); ret(); confirm(false,0xdeadbeef); recover(); ret(); });
        test(27,"consecutive causal calls and distinct confirmations",[&]{
            for(unsigned k=0;k<3;++k) architectural(word(0x104+0x100*k,jal(1,8)));
            idle(2);
            for(unsigned k=0;k<3;++k) { auto p=sim_.environment().pending(sim_.cycles()); if(p.empty()) throw std::logic_error("missing confirmation source");
                Stimulus c; c.campaign=Campaign::Architectural; c.confirmation_id=p[0].id; c.inputs.call_confirm=true; c.inputs.link=p[0].pc+4; send(c); }
            recover(); ret(); ret(); ret();
        });
        test(28,"exception restoration remains explicitly EQ08",[&]{
            call(0x104); confirm(true,0x808); call(0x208); recover("exception"); ret();
            // A later branch flush does not prove exception-surviving C is known.
            // Minimal profile characterizes existing restoration; established retains Q.
            recover(); ret(); send(word(0x300,jal(0,8))); reset();
        });
        test(29,"overridden and irrelevant feedback metadata",[&]{
            auto s=word(0x100,jal(0,8)); s.feedback_unused=s.feedback_explicit=true; s.inputs.feedback=0x900;
            s.inputs.flush=true; s.reason="exception"; send(s); idle();
        });
        test(30,"clock-stopped inputs do not consume RAS",[&]{
            call(0x104); guard(); auto s=word(0x300,jal(1,8)); sim_.probe(tagged(s));
            s=word(0x400,jalr(0,1,0)); sim_.probe(tagged(s)); idle(); guard(); ret();
        });
        test(31,"D excluded x5/indirect/coroutine hints have no RAS effect",[&]{
            call(0x104); call(0x208); guard();
            for(unsigned rd:{0u,1u,5u,7u}) for(unsigned rs1:{0u,1u,5u,7u}) for(int64_t off:{INT64_C(0),INT64_C(4),INT64_C(-4)}) {
                if(rd==0 && rs1==1 && off==0) continue;
                send(word(0x300,jalr(rd,rs1,off)));
            }
            guard(); ret(); ret();
        });
        test(32,"malformed masks, confirmer types and held prediction changes",[&]{
            auto s=word(0x100,jal(0,8)); s.campaign=Campaign::Characterization; s.inputs.ready=false; send(s);
            s.inputs.predictions[0].taken=true; s.malformed=true; send(s);
            s.inputs.call_confirm=s.inputs.ret_confirm=true; s.inputs.flush=true; send(s); idle();
            s=word(0x200,0xffffffff); s.campaign=Campaign::Characterization; s.inputs.mask=0; send(s); reset();
        });
        test(33,"consecutive recoveries and new return after restoration",[&]{
            confirm(true,0x808); recover(); recover(); ret(); confirm(true,0x908); recover(); ret();
        });
        test(34,"fault-prone encoded JAL without invented fault output",[&]{
            auto s=word(0x100,jal(1,2)); s.campaign=Campaign::Characterization; send(s); ret(); reset();
        });
    }
};
}
void run_directed(Simulator& sim,const RunOptions& o) { Directed(sim,o).run(); }
} // namespace len5::early
