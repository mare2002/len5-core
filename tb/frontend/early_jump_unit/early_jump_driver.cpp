// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Native phase scheduling, FST lifecycle and input readback adapted from pc_gen_driver.
#include "early_jump_driver.hh"
#include "Vearly_jump_tb.h"
#include "tb_macros.hh"
#include <verilated.h>
#include <verilated_fst_c.h>
#include <filesystem>
#include <inttypes.h>
namespace len5::early {
void Simulator::drive(const Inputs& i) {
    dut_->rst_ni=i.rst_n; dut_->flush_i=i.flush; dut_->instr_valid_i=i.valid; dut_->issue_ready_i=i.ready;
    dut_->call_confirm_i=i.call_confirm; dut_->ret_confirm_i=i.ret_confirm;
    dut_->res_link_addr_i=i.link; dut_->early_jump_target_i=i.feedback; dut_->valid_instr_i=i.mask;
    dut_->pred_hit_i=0; dut_->pred_taken_i=0;
    for(unsigned k=0;k<config_.lanes;++k) {
        dut_->words_i[k]=i.words[k]; dut_->pred_pc_i[k]=i.predictions[k].pc; dut_->pred_target_i[k]=i.predictions[k].target;
        dut_->pred_hit_i|=unsigned(i.predictions[k].hit)<<k; dut_->pred_taken_i|=unsigned(i.predictions[k].taken)<<k;
    }
}
Inputs Simulator::read_inputs() const {
    Inputs i; i.rst_n=dut_->rst_ni; i.flush=dut_->flush_i; i.valid=dut_->instr_valid_i; i.ready=dut_->issue_ready_i;
    i.call_confirm=dut_->call_confirm_i; i.ret_confirm=dut_->ret_confirm_i;
    i.link=dut_->res_link_addr_i; i.feedback=dut_->early_jump_target_i; i.mask=dut_->valid_instr_i;
    for(unsigned k=0;k<config_.lanes;++k) {
        i.words[k]=dut_->words_i[k]; i.predictions[k]={dut_->pred_pc_i[k],dut_->pred_target_i[k],bool((dut_->pred_hit_i>>k)&1),bool((dut_->pred_taken_i>>k)&1)};
    }
    return i;
}
Outputs Simulator::read_outputs() const {
    Outputs o; o.early=dut_->early_jump_valid_o; o.mem_flush=dut_->mem_flush_o; o.base=dut_->early_jump_base_o;
    o.offset=dut_->early_jump_offs_o; o.mask=dut_->valid_instr_o;
    for(unsigned k=0;k<config_.lanes;++k) o.predictions[k]={dut_->issue_pc_o[k],dut_->issue_target_o[k],bool((dut_->issue_hit_o>>k)&1),bool((dut_->issue_taken_o>>k)&1)};
    return o;
}
Simulator::Simulator(const RunOptions& options,int argc,char** argv):options_(options),context_(new VerilatedContext) {
    const auto directory=options.run_dir+"/logs";
    if(std::filesystem::exists(directory+"/report.json") || std::filesystem::exists(directory+"/samples.jsonl"))
        throw std::invalid_argument("run directory already contains evidence; choose a new directory");
    std::filesystem::create_directories(directory);
    config_=read_build_configuration(options.executable);
    context_->commandArgs(argc,argv); context_->randSeed(int(options.seed&0x7fffffff)); context_->traceEverOn(options.waves);
    dut_=std::make_unique<Vearly_jump_tb>(context_.get()); dut_->clk_i=0;
    Inputs initial; drive(initial); dut_->eval();
    if(dut_->config_issues_o!=config_.lanes || dut_->config_depth_o!=config_.depth || dut_->config_xlen_o!=config_.xlen
        || dut_->config_alen_o!=config_.alen || dut_->config_ilen_o!=4*8)
        throw std::invalid_argument("build/configuration failure: source constants disagree with elaborated DUT adapter");
    if((options.expect_issues && options.expect_issues!=config_.lanes) || (options.expect_depth && options.expect_depth!=config_.depth))
        throw std::invalid_argument("replay configuration mismatch: source-selected issue width or RAS depth differs");
    model_=std::make_unique<ReferenceModel>(config_,options.contract); environment_=std::make_unique<Environment>(config_);
    scoreboard_=std::make_unique<Scoreboard>(config_,options.contract,options.seed,directory,options.journal=="full" || (options.journal=="auto" && !options.random));
    if(options.waves) { trace_=std::make_unique<VerilatedFstC>(); dut_->trace(trace_.get(),1); trace_->open((directory+"/waves.fst").c_str()); }
    logger.setSimContext(context_.get());
    TB_CONFIG("LEN5_MULTIPLE_ISSUES=%u RAS_DEPTH=%u XLEN=%u instruction_bytes=%u (source/elaboration verified)",config_.lanes,config_.depth,config_.xlen,config_.instruction_bytes);
    TB_CONFIG("Configuration source=%s fingerprint=%s",config_.source.c_str(),config_.fingerprint.c_str());
    TB_CONFIG("PRG seed: %" PRIu64 "; contract=%s; log level=%u",options.seed,options.contract.json().c_str(),logger.getLogLvl());
    TB_CONFIG("Approved D: x1 JAL push; exact 0x00008067 pop; other JAL/JALR RAS no-op; independent confirmed/predictive histories");
    TB_CONFIG("EQ04 RET suppression and EQ07 confirm-before-restore are approved D; EQ05 lifecycle, EQ08 exception survival and remaining EQ questions retain I/Q provenance");
    TB_CONFIG("Cycle: zero-based consuming rising edge including reset; logger timestamp: context tick");
    TB_CONFIG("Reports=%s/report.json coverage.json samples.jsonl; waves=%s",directory.c_str(),options.waves?"ENABLED":"DISABLED");
}
Simulator::~Simulator() { if(dut_) dut_->final(); if(trace_) trace_->close(); logger.setSimContext(nullptr); }
void Simulator::dump() { if(trace_) trace_->dump(context_->time()); }
void Simulator::sample(const Stimulus& stimulus,const State& previous,const Transition& transition,const char* phase) {
    Sample s; s.cycle=cycles_; s.time=context_->time(); s.epoch=environment_->epoch(); s.phase=phase;
    s.stimulus=stimulus; s.before=previous; s.after=model_->state(); s.transition=transition;
    s.observed_inputs=read_inputs(); s.actual=read_outputs(); s.expected=model_->outputs(stimulus);
    if(!(s.observed_inputs==stimulus.inputs)) throw std::logic_error("flat port driver/readback disagreement");
    const auto& injection=options_.inject;
    if(!fault_ && s.phase=="pre") {
        bool injected=false;
        if(injection=="missed-jal" && s.expected.early.known && s.expected.early.value && s.expected.selection.instruction.kind!=Kind::Return) {
            s.actual.early=false; injected=true;
        } else if(injection=="false-jal" && stimulus.inputs.valid && s.expected.early.known && !s.expected.early.value && s.expected.selection.lane<0) {
            s.actual.early=true; injected=true;
        } else if((injection=="immediate" || injection=="lane") && s.expected.offset.known && s.expected.selection.instruction.kind!=Kind::Return) {
            if(injection=="immediate") s.actual.offset^=4; else s.actual.base^=4; injected=true;
        } else if(injection=="target" && s.expected.selection.lane>=0 && s.expected.predictions[s.expected.selection.lane].target.known) {
            s.actual.predictions[s.expected.selection.lane].target^=4; injected=true;
        } else if((injection=="predictive" || injection=="confirmed" || injection=="restore" || injection=="return")
            && s.expected.selection.instruction.kind==Kind::Return && s.expected.offset.known) {
            s.actual.offset^=4; injected=true;
        } else if(injection=="arbitration" && s.expected.mask.known && s.expected.selection.lane>=0) {
            s.actual.mask^=1; injected=true;
        }
        if(injected) { s.injected=true; fault_=true; }
    }
    scoreboard_->sample(s);
}
void Simulator::step(Stimulus s) {
    if(cycles_>=options_.max_cycles) throw Timeout("Simulation timeout expired. Exiting...");
    if(dut_->clk_i) throw std::logic_error("input setup requires clock low");
    const State previous=model_->state();
    if(!s.feedback_explicit && !s.feedback_unused) s.inputs.feedback=model_->feedback(s.inputs);
    drive(s.inputs); dut_->eval(); model_->input_change(s.inputs); environment_->input_change(s.inputs);
    if(options_.inject=="environment" && s.campaign==Campaign::Architectural && s.inputs.rst_n)
        throw EnvironmentError("intentional invalid environment injection");
    try { environment_->validate(s,cycles_); } catch(const EnvironmentError& e) {
        throw EnvironmentError(std::string(e.what())+" scenario="+s.scenario+" cycle="+std::to_string(cycles_));
    }
    const auto transition=model_->plan(s,cycles_);
    if(logger.getLogLvl()>=LOG_HIGH) TB_LOG(LOG_HIGH,"REQ > id=%s cycle=%" PRIu64 " phase=pre inputs=%s",s.scenario.c_str(),cycles_,inputs_json(s.inputs,config_.lanes).c_str());
    sample(s,previous,transition,"pre"); dump();
    if(options_.inject=="framework") throw std::logic_error("intentional framework injection");
    // Expectations and causal consumption are planned before observing the DUT edge.
    environment_->consume(s,transition,cycles_); model_->rising_edge(transition);
    context_->timeInc(1); dut_->clk_i=1; dut_->eval(); sample(s,previous,transition,"post"); dump();
    context_->timeInc(1); dut_->clk_i=0; dut_->eval(); sample(s,previous,transition,"falling"); ++cycles_;
    environment_->prune(cycles_);
}
void Simulator::probe(Stimulus s) {
    if(dut_->clk_i) throw std::logic_error("clock-stopped probe requires clock low");
    const State previous=model_->state(); context_->timeInc(2);
    if(!s.feedback_explicit && !s.feedback_unused) s.inputs.feedback=model_->feedback(s.inputs);
    drive(s.inputs); dut_->eval(); model_->input_change(s.inputs); environment_->input_change(s.inputs);
    sample(s,previous,model_->plan(s,cycles_),s.inputs.rst_n?"probe":"async"); dump();
}
void Simulator::reset() {
    Stimulus s; s.scenario="reset"; s.inputs.rst_n=false; probe(s); step(s); step(s);
    s.inputs=Inputs{}; step(s);
}
void Simulator::guard(const char* scenario,Campaign campaign) {
    if(!state().predictive.known && state().predictive.entries.empty()) return;
    auto s=bundle(config_,0x600); s.inputs.words[0]=jalr(0,1,0); s.inputs.ready=false;
    s.guard_probe=true; s.scenario=scenario; s.campaign=campaign; s.title="nonconsuming public return witness";
    probe(s);
}
} // namespace len5::early
