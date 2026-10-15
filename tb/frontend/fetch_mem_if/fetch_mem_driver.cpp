// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Phase scheduling, public readback, static audit and FST lifecycle adapted from EJU driver.
#include "fetch_mem_driver.hh"
#include "Vfetch_mem_tb.h"
#include "tb_macros.hh"
#include <verilated.h>
#include <verilated_fst_c.h>
#include <filesystem>
#include <inttypes.h>
namespace len5::fetchmem {
void Simulator::drive(const Inputs& i) {
    dut_->rst_ni=i.rst_n;dut_->flush_i=i.flush;dut_->fetch_valid_i=i.fetch_valid;dut_->instr_ready_i=i.grant;dut_->instr_valid_i=i.response_valid;dut_->issue_ready_i=i.consumer_ready;
    dut_->pred_hit_i=dut_->pred_taken_i=0;dut_->valid_instr_i=i.mask;dut_->instr_except_raised_i=i.response.errors;
    for(unsigned k=0;k<cfg_.lanes;++k){dut_->pred_pc_i[k]=i.predictions[k].pc;dut_->pred_target_i[k]=i.predictions[k].target;
        dut_->pred_hit_i|=unsigned(i.predictions[k].hit)<<k;dut_->pred_taken_i|=unsigned(i.predictions[k].taken)<<k;
        dut_->instr_words_i[k]=i.response.words[k];dut_->instr_causes_i[k]=i.response.causes[k];}
}
Inputs Simulator::read_inputs() const {
    Inputs i;i.rst_n=dut_->rst_ni;i.flush=dut_->flush_i;i.fetch_valid=dut_->fetch_valid_i;i.grant=dut_->instr_ready_i;i.response_valid=dut_->instr_valid_i;i.consumer_ready=dut_->issue_ready_i;
    i.mask=dut_->valid_instr_i;i.response.errors=dut_->instr_except_raised_i;
    for(unsigned k=0;k<cfg_.lanes;++k){i.predictions[k]={dut_->pred_pc_i[k],dut_->pred_target_i[k],bool((dut_->pred_hit_i>>k)&1),bool((dut_->pred_taken_i>>k)&1)};
        i.response.words[k]=dut_->instr_words_i[k];i.response.causes[k]=dut_->instr_causes_i[k];}return i;
}
Outputs Simulator::read_outputs() const {
    Outputs o;o.fetch_ready=dut_->fetch_ready_o;o.request_valid=dut_->instr_valid_o;o.address=dut_->instr_addr_o;o.write=dut_->instr_we_o;o.response_ready=dut_->instr_ready_o;o.valid=dut_->issue_valid_o;
    o.mask=dut_->valid_instr_o;o.payload.errors=dut_->issue_except_raised_o;
    for(unsigned k=0;k<cfg_.lanes;++k){o.predictions[k]={dut_->issue_pc_o[k],dut_->issue_target_o[k],bool((dut_->issue_hit_o>>k)&1),bool((dut_->issue_taken_o>>k)&1)};
        o.payload.words[k]=dut_->issue_words_o[k];o.payload.causes[k]=dut_->issue_causes_o[k];}return o;
}
Simulator::Simulator(const RunOptions& o,int argc,char** argv):options_(o),cfg_(read_build_configuration(o.executable)),context_(new VerilatedContext) {
    const auto dir=o.run_dir+"/logs";if(std::filesystem::exists(dir+"/report.json")||std::filesystem::exists(dir+"/samples.jsonl"))throw std::invalid_argument("choose a new run directory; existing evidence cannot be overwritten");
    std::filesystem::create_directories(dir);context_->commandArgs(argc,argv);context_->randSeed(int(o.seed&0x7fffffff));context_->traceEverOn(o.waves);dut_=std::make_unique<Vfetch_mem_tb>(context_.get());
    dut_->clk_i=0;Inputs initial;drive(initial);dut_->eval();
    if(dut_->config_issues_o!=cfg_.lanes||dut_->config_depth_o!=cfg_.depth||dut_->config_xlen_o!=cfg_.xlen||dut_->config_ilen_o!=cfg_.ilen||dut_->config_req_skip_o!=cfg_.req_skip||dut_->config_ans_skip_o!=cfg_.ans_skip||dut_->config_cause_bits_o!=cfg_.cause_bits)
        throw std::invalid_argument("FM19: source constants disagree with elaborated DUT adapter");
    if((o.expect_issues&&o.expect_issues!=cfg_.lanes)||(o.expect_depth&&o.expect_depth!=cfg_.depth))throw std::invalid_argument("replay configuration mismatch: source/elaborated configuration differs");
    model_=std::make_unique<ReferenceModel>(cfg_,o.contract);environment_=std::make_unique<Environment>(cfg_);
    scoreboard_=std::make_unique<Scoreboard>(cfg_,o.contract,o.seed,dir,o.journal=="full"||(o.journal=="auto"&&!o.random));
    if(o.waves){trace_=std::make_unique<VerilatedFstC>();dut_->trace(trace_.get(),1);trace_->open((dir+"/waves.fst").c_str());}
    logger.setSimContext(context_.get());
    TB_CONFIG("LEN5_MULTIPLE_ISSUES=%u metadata_depth=%u XLEN=%u ILEN=%u request_skip=%u answer_skip=%u source/elaboration verified",cfg_.lanes,cfg_.depth,cfg_.xlen,cfg_.ilen,cfg_.req_skip,cfg_.ans_skip);
    TB_CONFIG("Configuration source=%s fingerprint=%s",cfg_.source.c_str(),cfg_.fingerprint.c_str());
    TB_CONFIG("PRG seed: %" PRIu64 "; contract=%s",o.seed,o.contract.json().c_str());
    TB_CONFIG("Cycle: zero-based consuming rising edge including reset; timestamp: context tick; FQ01-FQ13 remain explicit");
    TB_CONFIG("Reports=%s; fault address identity is saved lane PC, not mtval; no full-core recovery claim",dir.c_str());
    std::string replay="'"+o.executable+"' --seed="+std::to_string(o.seed)+" --scenario="+o.selection+" --contract="+o.contract.profile+" --expect_issues="+std::to_string(cfg_.lanes)+" --expect_depth="+std::to_string(cfg_.depth)
        +" --max_cycles="+std::to_string(o.max_cycles)+" --journal=full --log_level=LOG_HIGH --dump_waves=true --run_dir=NEW_REPLAY_DIRECTORY";
    if(o.random)replay+=" --random --cycles="+std::to_string(o.cycles)+" --campaign="+o.campaign+" --guided="+(o.guided?"true":"false")+" --weights='"+o.weights+"'";
    if(!o.inject.empty())replay+=" --inject_failure="+o.inject;
    scoreboard_->metadata("null",replay);
}
Simulator::~Simulator(){if(dut_)dut_->final();if(trace_)trace_->close();logger.setSimContext(nullptr);}
void Simulator::dump(){if(trace_)trace_->dump(context_->time());}
void Simulator::begin(const std::string& s,const std::string& t,Campaign c){scenario_=s;title_=t;campaign_=c;}
bool Simulator::sample(const Stimulus& st,const State& before,const Transition& t,const char* phase) {
    Sample s;s.cycle=cycle_;s.time=context_->time();s.phase=phase;s.stimulus=st;s.before=before;s.after=model_->state();s.transition=t;s.observed=read_inputs();s.actual=read_outputs();s.expected=model_->outputs(st);
    if(!(s.observed==st.inputs))throw std::logic_error("flat port driver/readback disagreement");
    if(!injected_&&s.phase=="pre") {
        const auto& inj=options_.inject;bool changed=false;
        if(inj=="request"&&s.expected.request_valid.value){s.actual.address^=4;changed=true;}
        else if(inj=="ready"&&s.expected.response_ready.known){s.actual.response_ready=!s.actual.response_ready;changed=true;}
        else if(inj=="valid"&&s.expected.valid.known){s.actual.valid=!s.actual.valid;changed=true;}
        else if(s.expected.valid.known&&s.expected.valid.value&&s.expected.mask.known){
            unsigned lane=0;while(lane+1<cfg_.lanes&&!(s.expected.mask.value&(1u<<lane)))++lane;
            if(inj=="word"){s.actual.payload.words[lane]^=4;changed=true;}
            if(inj=="pc"){s.actual.predictions[lane].pc^=4;changed=true;}
            if(inj=="target"){s.actual.predictions[lane].target^=4;changed=true;}
            if(inj=="mask"){s.actual.mask^=1u<<lane;changed=true;}
            if(inj=="error"){s.actual.payload.errors^=1u<<lane;changed=true;}
            if(inj=="cause"&&s.expected.lanes[lane].cause.known){s.actual.payload.causes[lane]^=1;changed=true;}
        }
        if(changed){s.injected=true;injected_=true;}
    }
    return scoreboard_->sample(s);
}
void Simulator::step(Stimulus s) {
    if(cycle_>=options_.max_cycles)throw Timeout("Simulation timeout expired. Exiting...");
    s.scenario=scenario_;s.title=title_;s.campaign=campaign_;
    const State previous=model_->state();drive(s.inputs);dut_->eval();model_->input_change(s);environment_->input_change(s.inputs);
    const auto t=model_->plan(s,cycle_);environment_->validate(s,t,cycle_);
    if(options_.inject=="environment"&&s.inputs.rst_n)throw EnvironmentError("intentional invalid memory-protocol injection");
    if(logger.getLogLvl()>=LOG_HIGH)TB_LOG(LOG_HIGH,"REQ > id=%s cycle=%" PRIu64 " inputs=%s",scenario_.c_str(),cycle_,inputs_json(s.inputs,cfg_.lanes).c_str());
    if(!sample(s,previous,t,"pre"))throw StopOnMismatch("public request/response controls diverged; physical episode stopped without oracle repair");dump();
    if(options_.inject=="framework")throw std::logic_error("intentional framework injection");
    environment_->consume(s,t,cycle_);model_->rising_edge(t);last_=t;
    context_->timeInc(1);dut_->clk_i=1;dut_->eval();const bool controls=sample(s,previous,t,"post");dump();
    context_->timeInc(1);dut_->clk_i=0;dut_->eval();sample(s,previous,t,"falling");++cycle_;
    if(!controls)throw StopOnMismatch("post-edge controls diverged; physical episode stopped without oracle repair");
}
void Simulator::probe(Stimulus s) {
    s.scenario=scenario_;s.title=title_;s.campaign=campaign_;const State previous=model_->state();context_->timeInc(2);
    drive(s.inputs);dut_->eval();model_->input_change(s);environment_->input_change(s.inputs);Transition t;t.next=model_->state();
    sample(s,previous,t,s.inputs.rst_n?"probe":"async");dump();
}
void Simulator::tick(const Offer* o,bool response,bool ready,bool grant,const std::string& reason) {step(environment_->compose(o,cycle_,response,ready,grant,reason,campaign_));}
void Simulator::reset(){Stimulus s;s.inputs.rst_n=false;s.inputs.consumer_ready=false;probe(s);step(s);step(s);s.inputs=Inputs{};step(s);}
void Simulator::drain(unsigned limit){for(unsigned k=0;k<limit;++k){if(environment_->empty()&&state().outstanding.empty()&&state().answers.empty())return;tick();}throw Timeout("unfulfilled temporal obligations after bounded fair drain");}
Offer Simulator::offer(uint64_t p,unsigned v,unsigned e,unsigned c){return make_offer(cfg_,environment_->allocate(),p,v,e,c);}
int Simulator::finish(const std::string& reason,bool all,const std::string& selection){scoreboard_->final_state(model_->state());return scoreboard_->finish(reason,all,selection);}
} // namespace len5::fetchmem
