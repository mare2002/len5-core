// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_driver.hh"
#include "pc_gen_configuration.hh"
#include "Vpc_gen_tb.h"
#include "tb_macros.hh"
#include <verilated.h>
#include <verilated_fst_c.h>
#include <filesystem>
#include <inttypes.h>

namespace len5::pcgen {
void Simulator::drive(const Inputs& i) {
    dut_->rst_ni=i.rst_n; dut_->comm_except_raised_i=i.commit; dut_->comm_except_pc_i=i.commit_pc;
    dut_->bu_res_valid_i=i.branch_valid; dut_->bu_mispredict_i=i.mispredict; dut_->bu_taken_i=i.taken;
    dut_->bu_pc_i=i.branch_pc; dut_->bu_target_i=i.branch_target;
    dut_->pred_taken_i=i.prediction; dut_->pred_target_i=i.prediction_target; dut_->mem_ready_i=i.ready;
    dut_->early_jump_valid_i=i.early; dut_->early_jump_base_i=i.early_base; dut_->early_jump_offs_i=i.early_offset;
}
Inputs Simulator::read_inputs() const {
    Inputs i;
    i.rst_n=dut_->rst_ni; i.commit=dut_->comm_except_raised_i; i.commit_pc=dut_->comm_except_pc_i;
    i.branch_valid=dut_->bu_res_valid_i; i.mispredict=dut_->bu_mispredict_i; i.taken=dut_->bu_taken_i;
    i.branch_pc=dut_->bu_pc_i; i.branch_target=dut_->bu_target_i;
    i.prediction=dut_->pred_taken_i; i.prediction_target=dut_->pred_target_i; i.ready=dut_->mem_ready_i;
    i.early=dut_->early_jump_valid_i; i.early_base=dut_->early_jump_base_i; i.early_offset=dut_->early_jump_offs_i;
    return i;
}
Outputs Simulator::read_outputs() const {
    return {dut_->pc_o,dut_->early_jump_target_o,bool(dut_->valid_o),bool(dut_->bu_ready_o)};
}
Simulator::Simulator(const RunOptions& o, int argc, char** argv): options_(o), context_(new VerilatedContext) {
    const std::string directory=o.run_dir+"/logs";
    if (std::filesystem::exists(directory+"/report.json") || std::filesystem::exists(directory+"/samples.jsonl"))
        throw std::invalid_argument("run directory already contains evidence; choose a new --run_dir");
    std::filesystem::create_directories(directory);
    context_->commandArgs(argc,argv);
    context_->randSeed(int(o.seed & 0x7fffffff));
    context_->traceEverOn(o.dump_waves);
    dut_=std::make_unique<Vpc_gen_tb>(context_.get());
    dut_->clk_i=0;
    // Establish a real reset assertion later, rather than relying on a
    // two-state simulator to treat initially-low reset as a falling edge.
    Inputs initialized; initialized.rst_n=true; drive(initialized); dut_->eval();
    // Source-derived metadata is independently checked against elaboration;
    // static DUT outputs can neither select a contract nor repair model state.
    const auto build=read_build_configuration(o.executable);
    config_=build.expected;
    if(dut_->config_boot_pc_o!=config_.boot_pc || dut_->config_xlen_o!=config_.xlen
        || dut_->config_ilen_bytes_o!=config_.instruction_bytes || dut_->config_bundle_instructions_o!=config_.bundle_instructions
        || dut_->config_alen_o!=build.alen || dut_->config_issue_bits_o!=build.issue_bits
        || dut_->config_instruction_bits_o!=build.instruction_bits || dut_->config_lwidth_o!=build.lwidth)
        throw std::invalid_argument("build/configuration failure: source constants disagree with elaborated DUT adapter");
    if(o.expect_issues && o.expect_issues!=config_.bundle_instructions)
        throw std::invalid_argument("replay configuration mismatch: required LEN5_MULTIPLE_ISSUES="+std::to_string(o.expect_issues)
            +", elaborated="+std::to_string(config_.bundle_instructions));
    model_=std::make_unique<ReferenceModel>(config_,o.contract);
    environment_=std::make_unique<Environment>(config_);
    scoreboard_=std::make_unique<Scoreboard>(config_,o.contract,o.seed,directory,o.journal=="full" || (o.journal=="auto" && !o.random));
    scoreboard_->build_configuration(build.source,build.fingerprint,build.issue_bits);
    model_->input_change(initialized); environment_->input_change(initialized);
    if(o.dump_waves) {
        trace_=std::make_unique<VerilatedFstC>(); dut_->trace(trace_.get(),1); trace_->open((directory+"/waves.fst").c_str());
    }
    logger.setSimContext(context_.get());
    TB_CONFIG("BOOT_PC: %s; XLEN=%u instruction_bytes=%u LEN5_MULTIPLE_ISSUES=%u",
        hex64(config_.boot_pc).c_str(),config_.xlen,config_.instruction_bytes,config_.bundle_instructions);
    TB_CONFIG("Configuration source: %s; fingerprint=%s; bundle_bytes=%" PRIu64 " issue_bits=%u (source/elaboration verified)",
        build.source.c_str(),build.fingerprint.c_str(),config_.bundle_bytes(),build.issue_bits);
    TB_CONFIG("PRG seed: %" PRIu64 "; Verilator seed: %u",o.seed,unsigned(o.seed & 0x7fffffff));
    TB_CONFIG("Max simulation cycles: %" PRIu64 "; log level: %u; contract=%s",o.max_cycles,logger.getLogLvl(),o.contract_name.c_str());
    TB_CONFIG("Cycle: zero-based consuming rising edge including reset; logger timestamp: context tick");
    TB_CONFIG("Wave dump: %s; wave dump file: %s/waves.fst",o.dump_waves?"ENABLED":"DISABLED",directory.c_str());
    TB_CONFIG("Report: %s/report.json; coverage: %s/coverage.json; samples: %s/samples.jsonl",directory.c_str(),directory.c_str(),directory.c_str());
    for(const auto& a:o.contract.assumptions()) TB_CONFIG("Provisional assumption: %s",a.c_str());
    TB_CONFIG("Approved contract: Q1 reset, Q2 priority, Q3 memory-independent early correction, Q6 bundles, Q7 raw targets, Q8 stalled predictions");
    TB_CONFIG("Residual details: Q1/Q5 control acknowledgment, Q3 held lifecycle, Q4 branch-overridden metadata, Q9 cancellation timing; Q10 producer outside scope");
}
Simulator::~Simulator() {
    if(dut_) dut_->final();
    if(trace_) trace_->close();
    logger.setSimContext(nullptr);
}
void Simulator::dump() { if(trace_) trace_->dump(context_->time()); }
void Simulator::sample(const Stimulus& s, const Field& previous, const Transition& t, const std::string& phase) {
    Sample record;
    record.cycle=cycles_; record.time=context_->time(); record.epoch=environment_->epoch(); record.phase=phase;
    record.stimulus=s; record.previous_pc=previous; record.transition=t;
    record.observed_inputs=read_inputs(); record.actual=read_outputs(); record.expected=model_->outputs(s.inputs,s.malformed);
    if(!(record.observed_inputs==s.inputs)) throw std::logic_error("flat port driver/readback disagreement");
    if(phase=="falling" || phase=="probe") {
        record.expected.pc.requirement="C8"; record.expected.pc.evidence="D";
        // Keep dependency provenance: a state value established provisionally
        // must not turn into a confirmed golden value on a later sample.
    }
    if(!fault_injected_ && phase=="post" && options_.inject_failure=="pc" && record.expected.pc.known) {
        record.actual.pc^=1; record.injected=true; fault_injected_=true;
    }
    if(!fault_injected_ && phase=="post" && options_.inject_failure=="valid" && record.expected.valid.known) {
        record.actual.valid=!record.actual.valid; record.injected=true; fault_injected_=true;
    }
    scoreboard_->sample(record);
}
void Simulator::step(const Stimulus& s) {
    if(cycles_>=options_.max_cycles) throw Timeout("Simulation timeout expired. Exiting...");
    if(dut_->clk_i) throw std::logic_error("input setup requires the low clock phase");
    const Field previous=model_->cursor();
    drive(s.inputs); dut_->eval();
    model_->input_change(s.inputs); environment_->input_change(s.inputs);
    if(options_.inject_failure=="environment" && s.campaign==Campaign::Architectural && s.inputs.rst_n)
        throw EnvironmentError("intentional invalid environment record injection");
    try { environment_->validate(s,model_->cursor(),cycles_); }
    catch (const EnvironmentError& e) {
        throw EnvironmentError("id="+s.scenario+" test="+s.test_name+" cycle="+std::to_string(cycles_)
            +" phase=pre inputs="+inputs_json(s.inputs)+" > "+e.what());
    }
    const Transition t=model_->plan(s.inputs,s.malformed);
    if(logger.getLogLvl()>=LOG_HIGH) TB_LOG(LOG_HIGH,"REQ > id=%s cycle=%" PRIu64 " phase=pre combination=X%u M=%u winner=%s inputs=%s",
        s.scenario.c_str(),cycles_,s.inputs.combination(),s.inputs.ready,name(t.event),inputs_json(s.inputs).c_str());
    sample(s,previous,t,"pre"); dump();
    if(options_.inject_failure=="framework") throw std::logic_error("intentional reference-model/framework failure");
    // No observed output is passed to the model or expected environment.
    const Field consumed=model_->cursor();
    if(t.ordinary_acceptance && consumed.known && s.campaign==Campaign::Architectural)
        environment_->accept_bundle(consumed.value,s,cycles_);
    environment_->consume(s,t);
    model_->rising_edge(t);
    context_->timeInc(1); dut_->clk_i=1; dut_->eval();
    sample(s,consumed,t,"post"); dump();
    context_->timeInc(1); dut_->clk_i=0; dut_->eval();
    sample(s,consumed,t,"falling"); // Dump after the next low-phase input setup.
    ++cycles_;
}
void Simulator::probe(const Stimulus& s) {
    if(dut_->clk_i) throw std::logic_error("clock-stopped probe requires clock low");
    const Field previous=model_->cursor();
    context_->timeInc(2); drive(s.inputs); dut_->eval();
    model_->input_change(s.inputs); environment_->input_change(s.inputs);
    environment_->validate(s,model_->cursor(),cycles_);
    sample(s,previous,model_->plan(s.inputs,s.malformed),s.inputs.rst_n?"probe":"async"); dump();
}
} // namespace len5::pcgen
