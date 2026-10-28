// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// CLI, startup/final results and exception paths adapted from pc_gen_tb.cpp.
#include "early_jump_directed.hh"
#include "early_jump_random.hh"
#include "tb_macros.hh"
#include <algorithm>
#include <filesystem>
#include <getopt.h>
#include <unistd.h>
TbLogger logger;
using namespace len5::early;
static uint64_t number(const char* text) {
    std::string s(text); size_t end=0;
    if(s.empty() || s[0]=='-') throw std::invalid_argument("expected unsigned integer");
    const auto value=std::stoull(s,&end,0); if(end!=s.size()) throw std::invalid_argument("invalid unsigned integer"); return value;
}
static bool boolean(const char* text) {
    const std::string s(text); if(s=="true" || s=="1") return true; if(s=="false" || s=="0") return false;
    throw std::invalid_argument("expected true/false or 1/0");
}
static RunOptions options(int argc,char** argv) {
    RunOptions o; o.executable=std::filesystem::absolute(argv[0]).string();
    std::string profile="len5_minimal",order,exception,boundaries,lifecycle;
    const option flags[]={{"seed",required_argument,nullptr,'s'},{"max_cycles",required_argument,nullptr,'m'},
        {"log_level",required_argument,nullptr,'l'},{"dump_waves",required_argument,nullptr,'w'},
        {"run_dir",required_argument,nullptr,'d'},{"scenario",required_argument,nullptr,'t'},
        {"random",optional_argument,nullptr,'r'},{"cycles",required_argument,nullptr,'c'},
        {"campaign",required_argument,nullptr,1000},{"contract",required_argument,nullptr,1001},
        {"weights",required_argument,nullptr,1002},{"guided",required_argument,nullptr,1003},
        {"journal",required_argument,nullptr,1004},{"inject_failure",required_argument,nullptr,1005},
        {"expect_issues",required_argument,nullptr,1006},{"expect_ras_depth",required_argument,nullptr,1007},
        {"order",required_argument,nullptr,1008},{"exception",required_argument,nullptr,1009},
        {"boundaries",required_argument,nullptr,1010},{"lifecycle",required_argument,nullptr,1011},
        {"help",no_argument,nullptr,'h'},{nullptr,0,nullptr,0}};
    int flag;
    while((flag=getopt_long(argc,argv,"",flags,nullptr))!=-1) {
        switch(flag) {
        case 's': o.seed=number(optarg); break;
        case 'm': o.max_cycles=number(optarg); break;
        case 'w': o.waves=boolean(optarg); break;
        case 'd': o.run_dir=optarg; break;
        case 't': o.selection=optarg; break;
        case 'r': o.random=optarg?boolean(optarg):true; break;
        case 'c': o.cycles=number(optarg); break;
        case 'l': {
            const std::vector<std::string> names={"LOG_NONE","LOG_LOW","LOG_MEDIUM","LOG_HIGH","LOG_FULL","LOG_DEBUG"};
            const auto p=std::find(names.begin(),names.end(),optarg);
            if(p==names.end()) throw std::invalid_argument("use canonical LOG_* names");
            logger.setLogLvl(int(p-names.begin())); break;
        }
        case 1000: o.campaign=optarg; break;
        case 1001: profile=optarg; break;
        case 1002: o.weights=optarg; break;
        case 1003: o.guided=boolean(optarg); break;
        case 1004: o.journal=optarg; break;
        case 1005: o.inject=optarg; break;
        case 1006: { const auto n=number(optarg); if(n!=1 && n!=2 && n!=4 && n!=8) throw std::invalid_argument("replay issue guard must be 1,2,4,8"); o.expect_issues=n; break; }
        case 1007: { const auto n=number(optarg); if(n!=4) throw std::invalid_argument("initial replay depth guard must be 4"); o.expect_depth=n; break; }
        case 1008: order=optarg; break;
        case 1009: exception=optarg; break;
        case 1010: boundaries=optarg; break;
        case 1011: lifecycle=optarg; break;
        case 'h':
            std::printf("early_jump: --scenario all|EJ-T01..EJ-T34 --seed N --max_cycles N\n"
                " --random --cycles N --campaign all|architectural|stress|characterization --weights name=integer,... --guided true|false\n"
                " --contract len5_minimal|established --order updated (approved EQ07; previous/unknown rejected) --exception restore|unknown\n"
                " --boundaries recent|unknown --lifecycle held|unknown --journal auto|full|failures\n"
                " --log_level LOG_NONE|LOG_LOW|LOG_MEDIUM|LOG_HIGH|LOG_FULL|LOG_DEBUG --dump_waves true|false --run_dir NEW_DIRECTORY\n"
                " --expect_issues N --expect_ras_depth 4 (replay guards; configuration comes only from source)\n"); std::exit(0);
        default: throw std::invalid_argument("unknown argument; use --help");
        }
    }
    if(optind!=argc) throw std::invalid_argument("unexpected positional argument");
    o.contract=profile=="established"?Contract::established():Contract{}; o.contract.profile=profile;
    if(!order.empty()) o.contract.order=order;
    if(!exception.empty()) o.contract.exception=exception;
    if(!boundaries.empty()) o.contract.boundaries=boundaries;
    if(!lifecycle.empty()) o.contract.lifecycle=lifecycle;
    o.contract.validate();
    if(o.campaign!="all" && o.campaign!="architectural" && o.campaign!="stress" && o.campaign!="characterization") throw std::invalid_argument("invalid campaign");
    if(o.journal!="auto" && o.journal!="full" && o.journal!="failures") throw std::invalid_argument("invalid journal policy");
    const std::vector<std::string> injections={"","missed-jal","false-jal","immediate","lane","target","predictive","confirmed","restore","return","arbitration","environment","framework","empty"};
    if(std::find(injections.begin(),injections.end(),o.inject)==injections.end()) throw std::invalid_argument("unknown failure injection");
    if(o.run_dir.empty()) o.run_dir="build/early-jump/run/native-"+std::to_string(o.seed)+"-"+std::to_string(getpid());
    Weights w; w.parse(o.weights); return o;
}
int main(int argc,char** argv) {
    std::unique_ptr<Simulator> sim;
    RunOptions o; std::string reason;
    try {
        o=options(argc,argv); sim=std::make_unique<Simulator>(o,argc,argv);
        TB_LOG(LOG_LOW,"Starting simulation...");
        if(o.inject!="empty") { if(o.random) RandomScenarios(*sim,o).run(); else run_directed(*sim,o); }
    } catch(const Timeout& e) { reason=e.what(); TB_ERR("%s",e.what()); }
    catch(const EnvironmentError& e) { if(sim) sim->scoreboard().problem("environment_error",e.what()); else { TB_ERR("%s",e.what()); return 2; } }
    catch(const std::invalid_argument& e) { TB_ERR("SCB > build/configuration failure: %s",e.what()); return 2; }
    catch(const std::exception& e) { if(sim) sim->scoreboard().problem("framework_error",e.what()); else { TB_ERR("%s",e.what()); return 2; } }
    try {
        return sim?sim->scoreboard().finish(reason,!o.random && o.selection=="all" && o.inject.empty(),o.random?"random":o.selection):2;
    } catch(const std::exception& e) { TB_ERR("SCB > output failure: %s",e.what()); return 2; }
}
