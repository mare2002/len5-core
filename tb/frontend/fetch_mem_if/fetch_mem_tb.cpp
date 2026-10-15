// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Native CLI, lifecycle and failure paths adapted from EJU/pc_gen.
#include "fetch_mem_directed.hh"
#include "fetch_mem_random.hh"
#include "tb_macros.hh"
#include <algorithm>
#include <filesystem>
#include <unistd.h>
TbLogger logger;
using namespace len5::fetchmem;
static uint64_t number(const std::string& s){size_t end=0;if(s.empty()||s[0]=='-')throw std::invalid_argument("expected unsigned integer");const auto n=std::stoull(s,&end,0);if(end!=s.size())throw std::invalid_argument("invalid unsigned integer");return n;}
static bool boolean(const std::string& s){if(s=="true"||s=="1")return true;if(s=="false"||s=="0")return false;throw std::invalid_argument("expected true/false");}
static RunOptions options(int argc,char** argv) {
    RunOptions o;o.executable=std::filesystem::absolute(argv[0]).string();
    for(int k=1;k<argc;++k){const std::string flag=argv[k];const auto equal=flag.find('=');const auto key=flag.substr(0,equal);const auto value=equal==std::string::npos?"true":flag.substr(equal+1);
        if(key=="--seed")o.seed=number(value);else if(key=="--scenario")o.selection=value;else if(key=="--run_dir")o.run_dir=value;
        else if(key=="--cycles")o.cycles=number(value);else if(key=="--max_cycles")o.max_cycles=number(value);else if(key=="--random")o.random=boolean(value);
        else if(key=="--guided")o.guided=boolean(value);else if(key=="--dump_waves")o.waves=boolean(value);else if(key=="--campaign")o.campaign=value;
        else if(key=="--weights")o.weights=value;else if(key=="--journal")o.journal=value;else if(key=="--contract")o.contract.profile=value;
        else if(key=="--inject_failure")o.inject=value;else if(key=="--expect_issues")o.expect_issues=number(value);else if(key=="--expect_depth")o.expect_depth=number(value);
        else if(key=="--log_level"){const std::vector<std::string> names={"LOG_NONE","LOG_LOW","LOG_MEDIUM","LOG_HIGH","LOG_FULL","LOG_DEBUG"};auto p=std::find(names.begin(),names.end(),value);if(p==names.end())throw std::invalid_argument("use canonical LOG_* names");logger.setLogLvl(int(p-names.begin()));}
        else if(key=="--help"){std::printf("fetch_mem_if: --scenario=all|FM-T01..FM-T40 --random --seed=N --cycles=N --campaign=all|architectural|stress|characterization --contract=integrated|established --guided=true|false --weights=name=percent,... --journal=auto|full|failures --dump_waves=true|false --run_dir=NEW_DIRECTORY --expect_issues=N --expect_depth=N (guards only)\n");std::exit(0);}
        else throw std::invalid_argument("unknown option: "+key);
    }
    if(!o.max_cycles || (o.random&&!o.cycles))throw std::invalid_argument("positive cycle limits required");
    if(o.contract.profile=="established")o.contract.raw_transport=false;
    o.contract.validate();
    if(o.campaign!="all"&&o.campaign!="architectural"&&o.campaign!="stress"&&o.campaign!="characterization")throw std::invalid_argument("unknown campaign");
    if(o.journal!="auto"&&o.journal!="full"&&o.journal!="failures")throw std::invalid_argument("unknown journal policy");
    const std::vector<std::string> injections={"","request","ready","valid","word","pc","target","mask","error","cause","environment","framework","empty","incomplete"};
    if(std::find(injections.begin(),injections.end(),o.inject)==injections.end())throw std::invalid_argument("unknown failure injection");
    if(o.run_dir.empty())o.run_dir="build/fetch-mem-if/run/native-"+std::to_string(o.seed)+"-"+std::to_string(getpid());
    Weights w;w.parse(o.weights);return o;
}
int main(int argc,char** argv){std::unique_ptr<Simulator> sim;RunOptions o;std::string reason;
    try{o=options(argc,argv);sim=std::make_unique<Simulator>(o,argc,argv);TB_LOG(LOG_LOW,"Starting simulation...");
        if(o.inject=="incomplete"){sim->begin("FM-T40","intentional unfinished obligation");sim->reset();auto a=sim->offer(0x100);sim->tick(&a,false);}
        else if(o.inject!="empty"){if(o.random)run_random(*sim,o);else run_directed(*sim,o);}
    }catch(const StopOnMismatch& e){reason=e.what();TB_ERR("SCB > %s",e.what());}
    catch(const Timeout& e){reason=e.what();TB_ERR("%s",e.what());}
    catch(const EnvironmentError& e){if(sim)sim->scoreboard().problem("environment_error",e.what());else{TB_ERR("%s",e.what());return 2;}}
    catch(const std::invalid_argument& e){TB_ERR("SCB > build/configuration failure: %s",e.what());return 2;}
    catch(const std::exception& e){if(sim)sim->scoreboard().problem("framework_error",e.what());else{TB_ERR("%s",e.what());return 2;}}
    return sim?sim->finish(reason,!o.random&&o.selection=="all"&&o.inject.empty(),o.random?"random":o.selection):2;
}
