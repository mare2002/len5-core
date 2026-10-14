// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_random.hh"
#include "tb_macros.hh"
#include <sstream>
#include <inttypes.h>
#include <limits>
#include <algorithm>

namespace len5::pcgen {
static uint64_t split_seed(uint64_t x) {
    x+=UINT64_C(0x9e3779b97f4a7c15); x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);
    x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb); return x^(x>>31);
}
void RandomWeights::parse(const std::string& text) {
    std::istringstream stream(text); std::string pair;
    while(std::getline(stream,pair,',')) {
        auto equal=pair.find('=');
        if(equal==std::string::npos) throw std::invalid_argument("weights require name=integer pairs");
        const auto key=pair.substr(0,equal), value=pair.substr(equal+1);
        if(value.empty() || value.find_first_not_of("0123456789")!=std::string::npos) throw std::invalid_argument("invalid event weight");
        const auto n=std::stoull(value); if(n>10000) throw std::invalid_argument("event weight exceeds 10000");
        unsigned* field=nullptr;
        if(key=="normal") field=&normal; else if(key=="stall") field=&stall; else if(key=="branch") field=&branch;
        else if(key=="early") field=&early; else if(key=="commit") field=&commit; else if(key=="overlap") field=&overlap;
        else if(key=="reset") field=&reset; else if(key=="prediction") field=&prediction; else if(key=="ready") field=&ready;
        else throw std::invalid_argument("unknown event weight: "+key);
        *field=unsigned(n);
    }
    if(!(normal+stall+branch+early+commit+overlap+reset) || prediction>100 || ready>100)
        throw std::invalid_argument("action weights must have positive total; prediction/ready are percentages 0..100");
}
std::string RandomWeights::text() const {
    return "normal="+std::to_string(normal)+",stall="+std::to_string(stall)+",branch="+std::to_string(branch)
        +",early="+std::to_string(early)+",commit="+std::to_string(commit)+",overlap="+std::to_string(overlap)
        +",reset="+std::to_string(reset)+",prediction="+std::to_string(prediction)+",ready="+std::to_string(ready);
}
RandomScenarios::RandomScenarios(Simulator& sim, const RunOptions& o):sim_(sim),options_(o),
    events_(split_seed(o.seed)),payloads_(split_seed(o.seed^UINT64_C(0x5041594c4f4144))),
    latencies_(split_seed(o.seed^UINT64_C(0x4c4154454e4359))) {
    weights_.parse(o.weights);
    if(sim.config().boot_pc%sim.config().instruction_bytes && (o.campaign=="all" || o.campaign=="architectural"))
        throw EnvironmentError("Q7: architectural random campaign requires aligned BOOT_PC; use stress or characterization");
    if(o.campaign!="all" && o.campaign!="architectural" && o.campaign!="stress" && o.campaign!="characterization")
        throw std::invalid_argument("campaign must be all, architectural, stress or characterization");
}
uint64_t RandomScenarios::address(uint64_t old) {
    const auto& cfg=sim_.config();
    const uint64_t corners[]={0,cfg.boot_pc,UINT64_C(0xfffffffc),UINT64_C(0x100000000),
        UINT64_C(0x7ffffffffffffffc),UINT64_C(0x8000000000000000),UINT64_MAX-3,
        old,old+4,(old/cfg.bundle_bytes())*cfg.bundle_bytes()+cfg.bundle_bytes(),old-cfg.bundle_bytes()};
    const auto choice=payloads_()%20;
    if(choice<11) return corners[choice]&~UINT64_C(3);
    // Architectural executable map is abstract. High/wrap addresses are interface
    // arithmetic tests, not a claim that physical memory implements these regions.
    return (payloads_() & UINT64_C(0xfffffffffffc));
}
uint64_t RandomScenarios::displacement() {
    const int64_t corner[]={-1048576,-4,0,4,1048572};
    const auto choice=payloads_()%10;
    return uint64_t(choice<5?corner[choice]:int64_t(payloads_()%524288)*4-1048576);
}
bool RandomScenarios::ready() {
    if(!burst_) {
        memory_ready_=latencies_()%100<weights_.ready;
        const unsigned n=sim_.config().bundle_instructions;
        const unsigned lengths[]={1,2,n,n+1,32,64};
        burst_=latencies_()%2?1+latencies_()%12:lengths[latencies_()%6];
    }
    --burst_; return memory_ready_;
}
unsigned RandomScenarios::action() {
    const unsigned w[]={weights_.normal,weights_.stall,weights_.branch,weights_.early,weights_.commit,weights_.overlap,weights_.reset};
    uint64_t total=0; for(auto n:w) total+=n;
    auto pick=events_()%total;
    for(unsigned a=0;a<7;++a) { if(pick<w[a]) return a; pick-=w[a]; }
    throw std::logic_error("weighted action selection");
}
Stimulus RandomScenarios::base(Campaign c,const char* scenario) {
    Stimulus s; s.campaign=c; s.scenario=scenario; s.test_name="constrained-random policy v3";
    s.requirements="C1 C2 C3 C4 C5 C6 C7 C8 C9 Q1-Q10";
    s.inputs.ready=ready();
    // Poison inactive fields independently. Architectural qualification bits stay
    // canonical; stress supplies all six non-R branch encodings separately.
    s.inputs.commit_pc=payloads_(); s.inputs.branch_pc=payloads_(); s.inputs.branch_target=payloads_();
    s.inputs.prediction_target=payloads_(); s.inputs.early_base=payloads_(); s.inputs.early_offset=payloads_();
    return s;
}
void RandomScenarios::describe_fetched() {
    auto& env=sim_.environment();
    for(auto id:env.live_records()) if(id>described_) {
        const auto r=env.instruction(id);
        const auto choice=payloads_()%100;
        auto kind=choice<15?InstructionKind::Branch:choice<23?InstructionKind::DirectJump:
            choice<27?InstructionKind::Return:InstructionKind::Ordinary;
        if(r.predicted_taken && kind==InstructionKind::Ordinary) kind=InstructionKind::Branch;
        const bool need_fallthrough=options_.guided && r.predicted_taken &&
            (sim_.scoreboard().coverage.combination_count(Campaign::Architectural,5,false,false)<5 ||
             sim_.scoreboard().coverage.combination_count(Campaign::Architectural,5,true,false)<5);
        if(need_fallthrough) kind=InstructionKind::Branch;
        bool taken=kind!=InstructionKind::Ordinary && (kind!=InstructionKind::Branch || payloads_()%2);
        if(need_fallthrough) taken=false;
        uint64_t off=displacement();
        uint64_t target=kind==InstructionKind::DirectJump?r.pc+off:address(r.pc);
        // Some branches are genuinely correctly predicted; these update the
        // abstract BPU only. Other taken predictions deliberately miss by target.
        if(kind==InstructionKind::Branch && !need_fallthrough && payloads_()%4==0) {
            taken=r.predicted_taken; if(taken) target=r.predicted_target;
        }
        if(kind==InstructionKind::Branch && !taken) {
            // A not-taken instruction is a conditional branch: its unused
            // producer target still comes from a decoded signed B immediate.
            off%=8192; if(off>4092) off-=8192;
            target=r.pc+off;
        }
        env.describe(id,kind,taken,target,off);
        if(kind==InstructionKind::Return && payloads_()%4==0) env.correct_return_execution(id,address(r.pc));
        if(r.fetched_cycle!=last_fetch_cycle_) {
            last_fetch_cycle_=r.fetched_cycle;
            last_return_cycle_=std::max(last_return_cycle_,r.fetched_cycle+2+latencies_()%11);
        }
        // Fetch responses are ordered. All lanes of one bundle mature together;
        // eligibility adds no claim about internal execution queue scheduling.
        env.set_availability(id,last_return_cycle_);
        described_=id;
    }
}
Stimulus RandomScenarios::architectural() {
    auto s=base(Campaign::Architectural,"RA"); auto& i=s.inputs; auto& env=sim_.environment();
    const auto cursor=sim_.cursor();
    unsigned a=action();
    if(sim_.cycles()==0 || (!cursor.known && !held_early_) || a==6) {
        i.rst_n=false;
        // Reset can interrupt a held request. Keep its actual operands visible.
        if(held_early_) {
            const auto& r=env.instruction(held_early_); i.early=true;
            i.early_base=r.kind==InstructionKind::Return?0:r.pc;
            i.early_offset=r.kind==InstructionKind::Return?r.return_prediction:r.offset;
        }
        else if(cursor.known && a==6) {
            // Interrupt one pending producer before its consuming edge. Reset
            // discards these identities; release never reuses a pre-reset record.
            for(auto id:env.live_records()) {
                const auto& r=env.instruction(id);
                if(r.committed || r.resolved || sim_.cycles()<r.available_cycle) continue;
                if((r.kind==InstructionKind::DirectJump && !r.predicted_taken && !r.early_applied)
                    || (r.kind==InstructionKind::Return && !r.early_applied)) {
                    i.early=true; i.early_base=r.kind==InstructionKind::Return?0:r.pc;
                    i.early_offset=r.kind==InstructionKind::Return?r.return_prediction:r.offset;
                } else if(r.kind!=InstructionKind::Ordinary && (r.predicted_taken!=r.actual_taken
                    || (r.actual_taken && r.predicted_target!=r.actual_target)) && !env.branch_blocked()) {
                    i.branch_valid=i.mispredict=true; i.taken=r.actual_taken; i.branch_pc=r.pc; i.branch_target=r.actual_target;
                } else { i.commit=true; i.commit_pc=address(cursor.value); }
                break;
            }
            i.prediction=have_prediction_?held_prediction_:events_()%100<weights_.prediction;
            i.prediction_target=have_prediction_?held_prediction_target_:address(cursor.value);
        }
        held_early_=0; backend_wait_=0; last_recovery_=0; have_prediction_=false; last_return_cycle_=0; last_fetch_cycle_=UINT64_MAX; s.scenario="RA-reset"; return s;
    }
    // Q8: the BPU may revise a stalled offer. Only the prediction at an
    // accepted fetch edge is recorded in independent instruction history.
    if(cursor.known && (!have_prediction_ || held_prediction_pc_!=cursor.value
        || (!i.ready && events_()%4==0))) {
        held_prediction_pc_=cursor.value; held_prediction_=events_()%100<weights_.prediction;
        held_prediction_target_=address(cursor.value);
        if(options_.guided && held_prediction_ && payloads_()%5==0) {
            for(auto id:env.live_records()) {
                const auto& r=env.instruction(id);
                if(!r.resolved && !r.committed && !r.early_applied
                    && (r.kind==InstructionKind::DirectJump || r.kind==InstructionKind::Return)) break;
                if(!r.resolved && !r.committed && r.kind==InstructionKind::Branch && r.predicted_taken && !r.actual_taken) {
                    held_prediction_target_=r.pc+sim_.config().instruction_bytes; ++guided_choices_; break;
                }
            }
        }
        const unsigned first=(cursor.value%sim_.config().bundle_bytes())/sim_.config().instruction_bytes;
        held_prediction_lane_=first+payloads_()%(sim_.config().bundle_instructions-first);
        have_prediction_=true;
    }
    i.prediction=have_prediction_&&held_prediction_; i.prediction_target=held_prediction_target_;
    s.prediction_lane=held_prediction_lane_;
    if(held_early_) {
        const auto& r=env.instruction(held_early_);
        i.early=true; s.early_id=r.id; i.early_base=r.kind==InstructionKind::Return?0:r.pc;
        i.early_offset=r.kind==InstructionKind::Return?r.return_prediction:r.offset;
        s.record_age=sim_.cycles()-r.fetched_cycle; s.early_source=r.kind==InstructionKind::Return?"return":"decoded_jal";
        s.scenario="RA-held-early"; if(latencies_()%8==0) held_early_=0;
        return s;
    }
    if(backend_wait_) {
        --backend_wait_; if(!backend_wait_) env.resume_after_backend_flush();
        s.scenario="RA-backend-wait";
        // The branch producer waits for flush; an older commit producer is
        // independent and may redirect on the immediately following cycle.
        if(a==4) for(auto id:env.live_records()) {
            const auto& r=env.instruction(id);
            if(id>=last_recovery_) break;
            if(r.committed || r.resolved) continue;
            if(r.kind!=InstructionKind::Ordinary || sim_.cycles()<r.available_cycle) break;
            i.commit=true; i.commit_pc=address(cursor.value); s.commit_id=id;
            env.request_commit(id,i.commit_pc); s.record_age=sim_.cycles()-r.fetched_cycle;
            s.scenario="RA-older-commit-during-recovery"; have_prediction_=false;
            // Commit flush invalidates the younger recovery's pending episode.
            backend_wait_=0; env.resume_after_backend_flush(); break;
        }
        return s;
    }
    if(normal_remaining_) { --normal_remaining_; a=0; }
    else if(a==0 && latencies_()%4==0) normal_remaining_=8+latencies_()%57;
    // Deterministic deficit weighting never invents a record. If a desired
    // control source is unavailable, continue fetching until it becomes eligible.
    if(options_.guided && !normal_remaining_ && events_()%4==0) {
        unsigned best=0; uint64_t least=UINT64_MAX;
        for(unsigned row:{0u,1u,2u,3u,4u,5u,8u,9u}) {
            if(bool(row&1)!=i.prediction) continue;
            const auto count=sim_.scoreboard().coverage.combination_count(Campaign::Architectural,row,i.ready,events_()%2);
            if(count<least) { least=count; best=row; }
        }
        if(least<5) {
            a=(best&8)?4:(best&4)?2:(best&2)?3:0;
            ++guided_choices_;
        }
    }
    if(a==1 && memory_ready_) { i.ready=false; memory_ready_=false; burst_=1+latencies_()%32; s.scenario="RA-stall"; }
    const auto ids=env.live_records();
    if(ids.size()>=sim_.config().bundle_instructions*64) i.ready=false;
    for(auto id:ids) {
        const auto r=env.instruction(id);
        if(r.committed || r.resolved) continue;
        if(a==4 && r.kind!=InstructionKind::Ordinary) break;
        const bool early_eligible=!r.early_applied && ((r.kind==InstructionKind::DirectJump && !r.predicted_taken) || r.kind==InstructionKind::Return);
        // Younger backend events cannot pass an older jump that has not yet
        // passed the in-order early decoder. Its eventual correction squashes
        // those younger fetched records before they can execute or commit.
        if((a==2 || a==4) && early_eligible) break;
        if((a==3 || a==5) && early_eligible && sim_.cycles()<r.available_cycle) break;
        if(sim_.cycles()<r.available_cycle) continue;
        if((a==3 || a==5) && early_eligible) {
            i.early=true; s.early_id=id; i.early_base=r.kind==InstructionKind::Return?0:r.pc;
            i.early_offset=r.kind==InstructionKind::Return?r.return_prediction:r.offset;
            s.early_source=r.kind==InstructionKind::Return?"return":"decoded_jal";
            s.record_age=sim_.cycles()-r.fetched_cycle; held_early_=id; s.scenario="RA-early"; break;
        }
        if(a==2 && r.kind!=InstructionKind::Ordinary && !env.branch_blocked()) {
            // Decode direct jumps through the early producer first; branch and
            // return execution can subsequently correct direction or saved target.
            if(r.kind==InstructionKind::DirectJump && !r.early_applied && !r.predicted_taken) continue;
            const bool wrong=r.predicted_taken!=r.actual_taken || (r.actual_taken && r.predicted_target!=r.actual_target);
            if(!wrong) { env.complete_correct_resolution(id); s.branch_cause="correct_BPU_only"; break; }
            i.branch_valid=i.mispredict=true; i.taken=r.actual_taken;
            i.branch_pc=r.pc; i.branch_target=r.actual_target; s.branch_id=id;
            s.branch_cause=r.predicted_taken!=r.actual_taken?"direction_error":"taken_target_error";
            s.record_age=sim_.cycles()-r.fetched_cycle; backend_wait_=2+latencies_()%12; last_recovery_=id; s.scenario="RA-resolution"; break;
        }
        if(a==4) {
            i.commit=true; i.commit_pc=address(cursor.value); s.commit_id=id;
            env.request_commit(id,i.commit_pc); s.record_age=sim_.cycles()-r.fetched_cycle; s.scenario="RA-commit"; break;
        }
    }
    if(i.ready && !i.commit && !i.recovery() && !i.early) have_prediction_=false;
    if(i.commit || i.recovery()) have_prediction_=false;
    return s;
}
Stimulus RandomScenarios::stress(bool characterization) {
    const auto c=characterization?Campaign::Characterization:Campaign::Stress;
    if(hold_remaining_) { --hold_remaining_; auto held=held_controls_; held.inputs.ready=ready(); return held; }
    auto s=base(c,characterization?"RC":"RS"); auto& i=s.inputs;
    const uint64_t old=sim_.cursor().known?sim_.cursor().value:0;
    const unsigned a=action();
    unsigned row=a==2?4:a==3?2:a==4?8:a==5?unsigned(events_()%16):a==0?(events_()%100<weights_.prediction?1:0):0;
    bool direction=events_()%2;
    i.rst_n=sim_.cycles()!=0 && a!=6;
    // Coverage-guided pin combinations preferentially select under-hit bins at
    // half of scheduling opportunities. Zero base event weights are intentional exclusions unless
    // the user explicitly enables guidance (guidance may offer any legal row).
    if(options_.guided && events_()%2==0) {
        unsigned candidates[48], count=0;
        for(unsigned r=0;r<16;++r) for(unsigned m=0;m<2;++m) for(unsigned t=0;t<((r&4)?2:1);++t)
            if((i.rst_n?sim_.scoreboard().coverage.combination_count(c,r,m,t):sim_.scoreboard().coverage.reset_count(c,r,m))<5)
                candidates[count++]=r*4+m*2+t;
        if(count) {
            const unsigned pick=candidates[events_()%count]; row=pick/4; i.ready=(pick/2)%2; direction=pick%2; ++guided_choices_;
        }
    }
    if(a==1 && memory_ready_) { i.ready=false; memory_ready_=false; burst_=1+latencies_()%64; }
    i.commit=row&8; i.branch_valid=i.mispredict=row&4; i.early=row&2; i.prediction=row&1; i.taken=direction;
    if(!(row&4)) {
        const unsigned raw=events_()%6;
        i.branch_valid=raw>=4; i.mispredict=raw<4 && raw>=2; i.taken=raw%2;
    }
    i.commit_pc=address(old); i.branch_pc=address(old); i.branch_target=address(old);
    i.prediction_target=address(old); i.early_base=address(old); i.early_offset=displacement();
    s.early_source="signed_interface_offset";
    if(payloads_()%5==0) { i.early_offset=payloads_()&~UINT64_C(3); s.early_source="full_width_offset"; }
    if(events_()%4==0) { i.early_base=0; i.early_offset=address(old); s.early_source="return_shaped_stress"; }
    // Equal-target episodes explicitly test no-change redirects. Otherwise make
    // EVERY offered source different, independently of the eventual winner.
    if(events_()%5==0) {
        const uint64_t target=address(old); i.commit_pc=i.branch_target=i.prediction_target=target;
        i.branch_pc=target-4; i.early_base=target; i.early_offset=0;
    } else {
        uint64_t targets[4]={i.commit_pc,i.taken?i.branch_target:i.branch_pc+4,i.early_base+i.early_offset,i.prediction_target};
        for(unsigned n=1;n<4;++n) {
            bool conflict;
            do { conflict=false; for(unsigned k=0;k<n;++k) if(targets[n]==targets[k]) { targets[n]+=4; conflict=true; } } while(conflict);
        }
        i.commit_pc=targets[0]; if(i.taken) i.branch_target=targets[1]; else i.branch_pc=targets[1]-4;
        i.early_offset=targets[2]-i.early_base; i.prediction_target=targets[3];
    }
    if(characterization) {
        switch(events_()%5) {
        case 0: // Non-ISA addresses still have exact pin-level Q7 semantics.
            switch(payloads_()%5) {
            case 0: i.prediction=true; i.prediction_target|=1+payloads_()%3; break;
            case 1: i.commit=true; i.commit_pc|=1+payloads_()%3; break;
            case 2: i.branch_valid=i.mispredict=i.taken=true; i.branch_target|=1+payloads_()%3; break;
            case 3: i.branch_valid=i.mispredict=true; i.taken=false; i.branch_pc|=1+payloads_()%3; break;
            default: i.early=true; i.early_offset|=1+payloads_()%3; break;
            }
            s.malformed=true; s.scenario="RC-misaligned"; break;
        case 1: i.early=true; i.commit=true; s.scenario="RC-sideband-collision"; break;
        case 2: i.early=true; s.malformed=true; s.scenario="RC-absent-history"; break;
        case 3: s.scenario="RC-held-controls"; held_controls_=s; hold_remaining_=1+latencies_()%32; break;
        default: s.scenario="RC-pulse"; break;
        }
    }
    return s;
}
void RandomScenarios::run() {
    const auto start=sim_.cycles();
    TB_CONFIG("Random policy=v3 seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " guided=%u weights=%s journal=%s",
        options_.seed,options_.campaign.c_str(),options_.random_cycles,options_.guided,weights_.text().c_str(),options_.journal.c_str());
    std::string executable="'";
    for(char ch:options_.executable) executable+=ch=='\''?"'\\''":std::string(1,ch);
    executable+='\'';
    const std::string command=executable+" --random --seed="
        +std::to_string(options_.seed)+" --cycles="+std::to_string(options_.random_cycles)+" --max_cycles="+std::to_string(options_.max_cycles)
        +" --expect_issues="+std::to_string(sim_.config().bundle_instructions)
        +" --campaign="+options_.campaign+" --guided="+(options_.guided?"true":"false")+" --weights="+weights_.text()
        +" --contract="+options_.contract_name
        +(options_.inject_failure.empty()?"":" --inject_failure="+options_.inject_failure)+" --journal=full --log_level=LOG_HIGH --dump_waves=true --run_dir=NEW_REPLAY_DIRECTORY";
    const auto metadata=[&]() {
        return "{\"policy\":\"v3\",\"LEN5_MULTIPLE_ISSUES\":"+std::to_string(sim_.config().bundle_instructions)
            +",\"bundle_bytes\":"+std::to_string(sim_.config().bundle_bytes())+",\"campaign\":"+json_quote(options_.campaign)+",\"cycles_requested\":"+std::to_string(options_.random_cycles)
            +",\"guided\":"+(options_.guided?"true":"false")+",\"guided_choices\":"+std::to_string(guided_choices_)
            +",\"weights\":"+json_quote(weights_.text())+",\"contract\":"+json_quote(options_.contract_name)
            +",\"streams\":\"splitmix64 seeded mt19937_64: events,payloads,latencies; integer modulo draws\"}";
    };
    sim_.scoreboard().random_run(metadata(),command);
    while(sim_.cycles()-start<options_.random_cycles) {
        const uint64_t index=sim_.cycles()-start;
        Campaign desired=options_.campaign=="architectural"?Campaign::Architectural:options_.campaign=="stress"?Campaign::Stress:
            options_.campaign=="characterization"?Campaign::Characterization:static_cast<Campaign>((index/256)%3);
        if(desired!=campaign_) {
            campaign_=desired; held_early_=backend_wait_=burst_=hold_remaining_=normal_remaining_=0; have_prediction_=false; last_return_cycle_=0; last_fetch_cycle_=UINT64_MAX; last_recovery_=0;
            auto s=base(campaign_,"R-campaign-reset"); s.inputs.rst_n=false; sim_.step(s); prior_reset_=true; continue;
        }
        auto s=campaign_==Campaign::Architectural?architectural():stress(campaign_==Campaign::Characterization);
        // Between-edge pulses and reset assertion use the existing race-free
        // driver. They add context ticks, never fictitious consuming cycles.
        if(campaign_==Campaign::Characterization && s.scenario=="RC-pulse" && s.inputs.rst_n) {
            sim_.probe(s); auto ended=s; ended.inputs=Inputs{}; sim_.probe(ended);
        }
        if(!s.inputs.rst_n && !prior_reset_) sim_.probe(s);
        prior_reset_=!s.inputs.rst_n;
        sim_.step(s);
        if(campaign_==Campaign::Architectural) {
            describe_fetched();
        }
        sim_.environment().prune(sim_.cycles(),64);
    }
    sim_.scoreboard().random_run(metadata(),command);
    TB_LOG(LOG_LOW,"SCB > Random completed: seed=%" PRIu64 " campaign=%s cycles=%" PRIu64 " comparisons=%" PRIu64 " guided_choices=%" PRIu64,
        options_.seed,options_.campaign.c_str(),sim_.cycles()-start,sim_.scoreboard().field_checks(),guided_choices_);
}
} // namespace len5::pcgen
