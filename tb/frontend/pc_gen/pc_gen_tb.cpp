// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_driver.hh"
#include "pc_gen_random.hh"
#include "tb_macros.hh"
#include <getopt.h>
#include <unistd.h>
#include <cstdlib>
#include <cstdio>
#include <functional>
#include <inttypes.h>
#include <random>
#include <algorithm>
#include <filesystem>

TbLogger logger;
using namespace len5::pcgen;

namespace {
uint64_t number(const char* text) {
    std::string s(text); size_t end=0;
    if(s.empty() || s[0]=='-') throw std::invalid_argument("expected an unsigned integer");
    uint64_t result=std::stoull(s,&end,0);
    if(end!=s.size()) throw std::invalid_argument("invalid unsigned integer: "+s);
    return result;
}
bool boolean(const char* text) {
    const std::string s(text);
    if(s=="true" || s=="1") return true;
    if(s=="false" || s=="0") return false;
    throw std::invalid_argument("expected true/false or 1/0");
}
RunOptions options(int argc, char** argv) {
    RunOptions o; o.executable=std::filesystem::absolute(argv[0]).string();
    const option flags[]={{"seed",required_argument,nullptr,'s'},{"max_cycles",required_argument,nullptr,'c'},
        {"log_level",required_argument,nullptr,'l'},{"dump_waves",required_argument,nullptr,'w'},
        {"run_dir",required_argument,nullptr,'r'},{"scenario",required_argument,nullptr,'t'},
        {"contract",required_argument,nullptr,1000},{"early_accept",required_argument,nullptr,1001},
        {"early_target",required_argument,nullptr,1002},{"inject_failure",required_argument,nullptr,1003},
        {"random",optional_argument,nullptr,1100},{"cycles",required_argument,nullptr,1101},
        {"campaign",required_argument,nullptr,1102},{"weights",required_argument,nullptr,1103},
        {"guided",required_argument,nullptr,1104},{"journal",required_argument,nullptr,1105},
        {"expect_issues",required_argument,nullptr,1106},
        {"help",no_argument,nullptr,'h'},{nullptr,0,nullptr,0}};
    std::string early_accept,early_target; bool explicit_limit=false;
    int opt;
    while((opt=getopt_long(argc,argv,"s:c:l:w:r:t:h",flags,nullptr))!=-1) {
        switch(opt) {
        case 's': o.seed=number(optarg); break;
        case 'c': o.max_cycles=number(optarg); explicit_limit=true; break;
        case 'w': o.dump_waves=boolean(optarg); break;
        case 'r': o.run_dir=optarg; break;
        case 't': o.selection=optarg; break;
        case 'l': {
            const std::string level(optarg);
            const std::vector<std::string> names={"LOG_NONE","LOG_LOW","LOG_MEDIUM","LOG_HIGH","LOG_FULL","LOG_DEBUG"};
            auto pos=std::find(names.begin(),names.end(),level);
            if(pos==names.end()) throw std::invalid_argument("use a canonical LOG_* verbosity name");
            logger.setLogLvl(int(pos-names.begin())); break;
        }
        case 1000: o.contract_name=optarg; break;
        case 1001: early_accept=optarg; break;
        case 1002: early_target=optarg; break;
        case 1003: o.inject_failure=optarg; break;
        case 1100: o.random=optarg?boolean(optarg):true; break;
        case 1101: o.random_cycles=number(optarg); break;
        case 1102: o.campaign=optarg; break;
        case 1103: o.weights=optarg; break;
        case 1104: o.guided=boolean(optarg); break;
        case 1105: o.journal=optarg; break;
        case 1106: {
            const auto n=number(optarg);
            if(n!=1 && n!=2 && n!=4 && n!=8) throw std::invalid_argument("replay issue width must be 1,2,4,8");
            o.expect_issues=unsigned(n); break;
        }
        case 'h':
            std::printf("Usage: %s [--scenario all|T01..T22] [--seed N] [--max_cycles N]\n"
                "  --log_level LOG_NONE|LOG_LOW|LOG_MEDIUM|LOG_HIGH|LOG_FULL|LOG_DEBUG\n"
                "  --dump_waves true|false --run_dir NEW_DIRECTORY\n"
                "  --contract proposed|strict --early_accept level (compatibility alias; Q3 approved)\n"
                "  --early_target relevant (compatibility alias; Q4 approved)\n"
                "  --inject_failure pc|valid|environment|framework|empty (checker validation)\n"
                "  --random --cycles N --campaign all|architectural|stress|characterization\n"
                "  --weights normal=40,stall=20,branch=15,early=10,commit=5,overlap=5,reset=5,prediction=25,ready=65\n"
                "  --guided true|false --journal auto|full|failures\n"
                "  --expect_issues N (replay guard only; width is selected in the RTL source)\n"
                "BOOT_PC is an elaboration parameter. No runtime PC synchronization.\n",argv[0]);
            std::exit(0);
        default: throw std::invalid_argument("unrecognized argument; use --help");
        }
    }
    if(optind!=argc) throw std::invalid_argument("unexpected positional argument");
    if(o.contract_name=="strict") o.contract=Contract::strict();
    else if(o.contract_name!="proposed") throw std::invalid_argument("contract must be proposed or strict");
    if(!early_accept.empty() && early_accept!="level")
        throw std::invalid_argument("Q3 approved: early correction is memory-independent; obsolete early_accept hypothesis rejected");
    if(!early_target.empty() && early_target!="relevant")
        throw std::invalid_argument("Q4 approved: selected early metadata is exact; overridden/idle metadata is not always arithmetic; obsolete early_target hypothesis rejected");
    if(!o.inject_failure.empty() && o.inject_failure!="pc" && o.inject_failure!="valid"
        && o.inject_failure!="environment" && o.inject_failure!="framework" && o.inject_failure!="empty")
        throw std::invalid_argument("invalid failure injection name");
    if(o.journal!="auto" && o.journal!="full" && o.journal!="failures") throw std::invalid_argument("journal must be auto, full or failures");
    if(o.random && !explicit_limit) o.max_cycles=std::max(o.max_cycles,o.random_cycles);
    if(o.random) { RandomWeights weights; weights.parse(o.weights); }
    if(o.run_dir.empty()) o.run_dir="build/pc-gen/run/native-"+std::to_string(o.seed)+"-"+std::to_string(getpid());
    return o;
}

class Directed {
    Simulator& sim_;
    std::string selection_,id_,title_,requirements_;
    Campaign campaign_=Campaign::Stress;
    std::mt19937_64 durations_;
    Stimulus stimulus(const Inputs& i, Campaign campaign) const {
        Stimulus s; s.inputs=i; s.campaign=campaign; s.scenario=id_; s.test_name=title_; s.requirements=requirements_; return s;
    }
    void send(const Inputs& i) { sim_.step(stimulus(i,campaign_)); }
    void architectural(const Inputs& i) { sim_.step(stimulus(i,Campaign::Architectural)); }
    void test(const char* id, const char* title, const char* req, const std::function<void()>& f) {
        if(selection_!="all" && selection_!=id) return;
        id_=id; title_=title; requirements_=req; campaign_=Campaign::Stress;
        TB_LOG(LOG_LOW,"REQ > Starting %s: %s requirements=%s",id,title,req); f();
    }
    void reset() {
        Inputs i; i.rst_n=false; sim_.probe(stimulus(i,Campaign::Stress)); send(i); send(i);
        i.rst_n=true; send(i);
    }
    void anchor(uint64_t pc) {
        Inputs i; i.prediction=true; i.prediction_target=pc; i.ready=true; send(i);
    }
    uint64_t prepare(uint64_t pc, InstructionKind kind, bool taken, uint64_t target, uint64_t offset=0, bool predicted=false) {
        reset(); anchor(pc);
        Inputs i; i.ready=true; i.prediction=predicted; i.prediction_target=0x900;
        Stimulus s=stimulus(i,Campaign::Architectural);
        s.prediction_lane=int((pc%sim_.config().bundle_bytes())/sim_.config().instruction_bytes);
        sim_.step(s);
        uint64_t id=sim_.environment().instruction_at(pc);
        sim_.environment().describe(id,kind,taken,target,offset);
        architectural(Inputs{}); architectural(Inputs{});
        anchor(0x500); // A known speculative offer, independent of the older record.
        return id;
    }
    void resolve(uint64_t record, bool ready) {
        const auto& r=sim_.environment().instruction(record);
        Inputs i; i.branch_valid=true; i.mispredict=true; i.taken=r.actual_taken;
        i.branch_pc=r.pc; i.branch_target=r.actual_target; i.ready=ready;
        Stimulus s=stimulus(i,Campaign::Architectural); s.branch_id=record;
        s.branch_cause=r.predicted_taken!=r.actual_taken?"direction":"target_only";
        s.record_age=sim_.cycles()-r.fetched_cycle; sim_.step(s);
    }
    void early(uint64_t record, bool ready, bool predicted=true) {
        const auto& r=sim_.environment().instruction(record);
        Inputs i; i.early=true; i.early_base=r.kind==InstructionKind::Return?0:r.pc;
        i.early_offset=r.kind==InstructionKind::Return?r.return_prediction:r.offset;
        i.ready=ready; i.prediction=predicted; i.prediction_target=0xb00;
        Stimulus s=stimulus(i,Campaign::Architectural); s.early_id=record;
        s.early_source=r.kind==InstructionKind::Return?"return_prediction":"direct_jal";
        s.record_age=sim_.cycles()-r.fetched_cycle;
        s.prediction_lane=sim_.cursor().known?int((sim_.cursor().value%sim_.config().bundle_bytes())/4):0;
        sim_.step(s);
    }
    static Inputs combination(unsigned row, bool ready, bool taken=false) {
        Inputs i; i.commit=row&8; i.branch_valid=row&4; i.mispredict=row&4; i.early=row&2; i.prediction=row&1;
        i.taken=taken; i.ready=ready; i.commit_pc=0x700; i.branch_pc=0x104; i.branch_target=0x900;
        i.early_base=0x204; i.early_offset=uint64_t(-4); i.prediction_target=0xb00; return i;
    }
public:
    Directed(Simulator& s, const RunOptions& o): sim_(s),selection_(o.selection),durations_(o.seed) {}
    void run() {
        test("T01","reset assertion, hold, release and boot","C1 C2 C8 Q1 Q5",[&]{
            reset(); Inputs i; i.ready=true; send(i); reset();
        });
        test("T02","sequential progression from every starting lane","C2 C3 Q6",[&]{
            for(unsigned lane=0;lane<sim_.config().bundle_instructions;++lane) {
                reset(); anchor(0x100+lane*4); Inputs i; i.ready=true;
                for(unsigned n=0;n<3;++n) architectural(i);
            }
        });
        test("T03","stall onset, duration and release","C2 C3 C8",[&]{
            for(unsigned duration:{1u,2u,sim_.config().bundle_instructions,unsigned(17+durations_()%17)}) {
                reset(); anchor(0x104); Inputs i; i.prediction=true; i.prediction_target=0x80000104;
                for(unsigned n=0;n<duration;++n) send(i);
                i.ready=true; send(i); i.prediction=false; send(i);
            }
        });
        test("T04","taken and not-taken prediction qualification","C2 C3 C7",[&]{
            reset(); anchor(0x104); Inputs i; i.prediction_target=0x700; send(i);
            i.prediction=true; send(i); i.ready=true; send(i);
            i.prediction=false; i.prediction_target=UINT64_MAX; send(i);
            reset(); anchor(0x104); i=Inputs{};
            for(unsigned n=0;n<13;++n) {
                i.prediction=n%3!=0; i.prediction_target=0x900+4*n;
                send(i); // Q8: changes while stalled cannot advance the PC.
            }
            i.prediction=true; i.prediction_target=0xb04;
            sim_.probe(stimulus(i,Campaign::Stress));
            i.ready=true; send(i); // The final edge-qualified target is accepted.
            for(unsigned lane=0;lane<sim_.config().bundle_instructions;++lane) {
                i=Inputs{}; i.prediction=i.ready=true;
                i.prediction_target=0x700+lane*sim_.config().instruction_bytes; send(i);
                i.prediction=false; send(i);
            }
        });
        test("T05","taken recovery from a live older branch","C4 C5 Q2 Q5",[&]{
            for(bool ready:{false,true}) for(bool predicted:{false,true}) {
                uint64_t id=prepare(0x104,InstructionKind::Branch,true,0x904,0,predicted);
                resolve(id,ready); architectural(Inputs{}); sim_.environment().resume_after_backend_flush();
            }
        });
        test("T06","not-taken recovery from every instruction lane","C4 C5 Q6",[&]{
            for(unsigned lane=0;lane<sim_.config().bundle_instructions;++lane) for(bool ready:{false,true}) {
                uint64_t id=prepare(0x100+lane*4,InstructionKind::Branch,false,0xabc,0,true);
                resolve(id,ready); Inputs i; i.ready=true; architectural(i); sim_.environment().resume_after_backend_flush();
            }
        });
        test("T07","correct and invalid resolutions with poisoned fields","C2 C3 C7",[&]{
            reset(); anchor(0x104);
            for(unsigned bits=0;bits<8;++bits) {
                if((bits&6)==6) continue; // effective recovery belongs to T05/T06/T12
                for(bool ready:{false,true}) for(bool prediction:{false,true}) {
                    Inputs i; i.branch_valid=bits&4; i.mispredict=bits&2; i.taken=bits&1;
                    i.branch_pc=0x8000000000000104; i.branch_target=UINT64_MAX;
                    i.ready=ready; i.prediction=prediction; i.prediction_target=0x704; send(i);
                }
            }
        });
        test("T08","commit redirect from a live commit control event","C4 Q2 Q5",[&]{
            for(bool ready:{false,true}) {
                uint64_t id=prepare(0x104,InstructionKind::Ordinary,false,0);
                sim_.environment().request_commit(id,0x700);
                Inputs i; i.commit=true; i.commit_pc=0x700; i.ready=ready;
                Stimulus s=stimulus(i,Campaign::Architectural); s.commit_id=id; sim_.step(s); architectural(Inputs{});
            }
        });
        test("T09","decoded signed JAL correction and priority over prediction","C6 C9 Q3 Q4",[&]{
            for(int64_t off:{INT64_C(-1048576),INT64_C(-4),INT64_C(0),INT64_C(4),INT64_C(1048572)})
                for(bool ready:{false,true}) {
                    uint64_t id=prepare(0x100204,InstructionKind::DirectJump,true,0x100204+uint64_t(off),uint64_t(off));
                    early(id,ready); send(Inputs{});
                }
            const auto& cfg=sim_.config();
            const uint64_t last=0x100000+cfg.bundle_bytes()-cfg.instruction_bytes;
            for(uint64_t off:{cfg.bundle_bytes(),uint64_t(0)-cfg.bundle_bytes()}) {
                uint64_t id=prepare(last,InstructionKind::DirectJump,true,last+off,off);
                early(id,false); send(Inputs{});
            }
        });
        test("T10","RAS-shaped return prediction is not an architectural target guarantee","C6 C9 Q3 Q4",[&]{
            for(uint64_t target:{UINT64_C(0x204),UINT64_C(0x8000000000010000)}) {
                uint64_t id=prepare(0x104,InstructionKind::Return,true,target); early(id,false); send(Inputs{});
                sim_.environment().correct_return_execution(id,0x700);
                resolve(id,true); sim_.environment().resume_after_backend_flush();
            }
        });
        test("T11","held early correction across ready and stall","C6 C9 Q3 Q4 Q9",[&]{
            uint64_t id=prepare(0x204,InstructionKind::DirectJump,true,0x200,uint64_t(-4));
            for(bool ready:{false,false,true,false,true}) early(id,ready);
            send(Inputs{}); Inputs i; i.ready=true; send(i);
        });
        test("T12","complete simultaneous-event matrix","C4 C5 C6 C9 Q2 Q3 Q5",[&]{
            for(unsigned row=0;row<16;++row) for(bool ready:{false,true})
                for(unsigned taken=0;taken<((row&4)?2u:1u);++taken) {
                    reset(); anchor(0x500); send(combination(row,ready,taken)); send(Inputs{});
                    Inputs released; released.ready=true; send(released); // Losing requests have no delayed effect.

                }
        });
        test("T13","reset dominance for every combination and release with events","C1 C4 C9 Q1 Q2",[&]{
            for(unsigned row=0;row<16;++row) for(bool ready:{false,true}) {
                Inputs i=combination(row,ready); i.rst_n=false;
                sim_.probe(stimulus(i,Campaign::Stress)); send(i); i.rst_n=true; send(i); send(Inputs{});
            }
        });
        test("T14","consecutive redirects including synthetic consecutive recoveries","C3 C4 C5 C6 C9 Q2 Q9",[&]{
            reset(); anchor(0x500);
            for(unsigned repeat=0;repeat<2;++repeat) for(unsigned row:{8u,4u,2u,1u,8u,6u,3u,0u}) {
                Inputs i=combination(row,true,true);
                if(!repeat) {
                    i.commit_pc=i.branch_target=i.prediction_target=i.early_base=0x500;
                    i.early_offset=0;
                }
                send(i);
            }
        });
        test("T15","equal-PC and nearby/far/boot redirect targets","C3 C4 C5 C6 Q2",[&]{
            const auto& cfg=sim_.config();
            const uint64_t start=0x500+(cfg.bundle_instructions>1?cfg.instruction_bytes:0);
            std::vector<uint64_t> targets={start,UINT64_C(0x500),0x500+cfg.bundle_bytes(),0x500-cfg.bundle_bytes(),cfg.boot_pc,UINT64_C(0x90000000)};
            if(cfg.bundle_instructions>2) targets.push_back(0x500+2*cfg.instruction_bytes);
            for(uint64_t target:targets)
                for(unsigned row:{8u,4u,2u,1u}) {
                    reset(); anchor(start); Inputs i=combination(row,true,true);
                    i.commit_pc=i.branch_target=i.prediction_target=i.early_base=target; i.early_offset=0; send(i);
                }
        });
        test("T16","clock-stopped pulses and output stability","C2 C7 C8 Q8",[&]{
            reset(); anchor(0x500);
            for(unsigned row:{1u,2u,4u,8u,15u}) {
                sim_.probe(stimulus(combination(row,false,true),Campaign::Stress));
                sim_.probe(stimulus(Inputs{},Campaign::Stress));
            }
            send(Inputs{});
        });
        test("T17","64-bit carry, wrap and early displacement underflow","C3 C5 C6 Q7",[&]{
            for(uint64_t pc:{UINT64_C(0xfffffffc),UINT64_C(0x7ffffffffffffffc),UINT64_C(0xfffffffffffffffc)}) {
                reset(); anchor(pc); Inputs i; i.ready=true; send(i);
                i=Inputs{}; i.branch_valid=true; i.mispredict=true; i.branch_pc=pc; send(i);
            }
            reset(); Inputs i; i.early=true; i.early_base=0; i.early_offset=uint64_t(-4); send(i);
        });
        test("T18","reset during stall, prediction and active redirects","C1 C2 C4 C8 Q1 Q9",[&]{
            for(unsigned row:{0u,1u,2u,4u,8u,15u}) {
                reset(); anchor(0x500);
                for(unsigned hold=0;hold<sim_.config().bundle_instructions+3;++hold) send(combination(row,false,true));
                Inputs i=combination(row,false,true); i.rst_n=false;
                sim_.probe(stimulus(i,Campaign::Stress)); send(i); i=Inputs{}; send(i);
            }
        });
        test("T19","unaligned target pass-through and subsequent bundle progression","C2 C3 C4 C5 C6 C7 Q7 Q9",[&]{
            for(unsigned low=1;low<=3;++low) for(unsigned row:{8u,4u,2u,1u})
                for(unsigned taken=0;taken<(row==4?2u:1u);++taken) {
                reset(); anchor(0x500); Inputs i=combination(row,true,row!=4 || taken);
                i.branch_pc=0x700+low;
                i.commit_pc=i.branch_target=i.prediction_target=i.early_base=0x700+low; i.early_offset=0;
                Stimulus s=stimulus(i,Campaign::Characterization); s.malformed=true; sim_.step(s);
                s.inputs=Inputs{}; sim_.step(s); // Defined hold after raw target pass-through.
                s.inputs.ready=true; sim_.step(s); // Only ordinary progression aligns.
                reset();
            }
        });
        test("T20","one-at-a-time inactive and losing payload mutation","C7 Q2",[&]{
            reset(); anchor(0x500); Inputs i;
            for(unsigned field=0;field<8;++field) {
                i=Inputs{};
                switch(field) {
                case 0:i.branch_pc=UINT64_MAX;break; case 1:i.branch_target=UINT64_MAX;break;
                case 2:i.taken=true;break; case 3:i.mispredict=true;break;
                case 4:i.commit_pc=UINT64_MAX;break; case 5:i.prediction_target=UINT64_MAX;break;
                case 6:i.early_base=UINT64_MAX;break; case 7:i.early_offset=UINT64_MAX;break;
                }
                send(i);
            }
            for(unsigned field=0;field<6;++field) {
                i=combination(15,false,true);
                switch(field) {
                case 0:i.branch_pc=UINT64_MAX;break; case 1:i.branch_target=UINT64_MAX;break;
                case 2:i.taken=false;break; case 3:i.prediction_target=UINT64_MAX;break;
                case 4:i.early_base=UINT64_MAX;break; case 5:i.early_offset=UINT64_MAX;break;
                }
                send(i);
            }
            for(uint64_t target:{UINT64_C(0),UINT64_MAX}) { i=combination(4,false,false); i.branch_target=target; send(i); }
        });
        test("T21","early sideband under commit/branch collision","C4 C5 Q4",[&]{
            campaign_=Campaign::Characterization;
            reset(); anchor(0x500); send(combination(10,false)); send(combination(6,true,true)); send(Inputs{});
        });
        test("T22","supplied trap and MRET redirect addresses","C4 Q10",[&]{
            reset(); anchor(0x500); Inputs i; i.commit=true; i.commit_pc=0x700; send(i);
            i.commit_pc=0x104; send(i); // Supplied mepc-shaped address, no producer check.
            i.commit_pc=0x8000012c; send(i); // Supplied vectored-interrupt-shaped address.
            send(Inputs{});
        });
    }
};
} // namespace

int main(int argc, char** argv) {
    std::setvbuf(stdout,nullptr,_IOLBF,0);
    try {
        RunOptions o=options(argc,argv);
        if(o.selection!="all" && (o.selection.size()!=3 || o.selection[0]!='T'
            || o.selection[1]<'0' || o.selection[1]>'9' || o.selection[2]<'0' || o.selection[2]>'9'
            || std::stoi(o.selection.substr(1))<1 || std::stoi(o.selection.substr(1))>22))
            throw std::invalid_argument("scenario must be all or T01..T22");
        Simulator sim(o,argc,argv);
        TB_LOG(LOG_LOW,"Starting simulation...");
        std::string reason;
        try {
            if(o.inject_failure!="empty") { if(o.random) RandomScenarios(sim,o).run(); else Directed(sim,o).run(); }
        } catch(const EnvironmentError& e) {
            reason=e.what(); sim.scoreboard().problem("environment_error",reason);
        } catch(const Timeout& e) {
            reason=e.what(); TB_ERR("%s",e.what());
        } catch(const std::exception& e) {
            reason=e.what(); sim.scoreboard().problem("framework_error",reason);
        }
        return sim.scoreboard().finish(reason,!o.random && o.selection=="all",o.random?"random/"+o.campaign:o.selection);
    } catch(const std::exception& e) {
        TB_ERR("SCB > invalid configuration or output failure: %s",e.what());
        return 2;
    }
}
