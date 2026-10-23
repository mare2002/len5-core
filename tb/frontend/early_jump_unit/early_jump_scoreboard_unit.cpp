// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic public-port observations: no Verilated DUT and no golden-state repair.
#include "early_jump_scoreboard.hh"
#include "tb_macros.hh"
#include <filesystem>
#include <iostream>
TbLogger logger;
using namespace len5::early;
static Outputs actual(const Expected& e,unsigned lanes) {
    Outputs o; o.early=e.early.value; o.mem_flush=e.mem_flush.value; o.base=e.base.value; o.offset=e.offset.value; o.mask=e.mask.value;
    for(unsigned k=0;k<lanes;++k) o.predictions[k]={e.predictions[k].pc.value,e.predictions[k].target.value,bool(e.predictions[k].hit.value),bool(e.predictions[k].taken.value)};
    return o;
}
int main(int argc,char** argv) {
    if(argc!=3) return 2;
    const std::string directory=argv[1],test=argv[2]; std::filesystem::create_directories(directory);
    logger.setLogLvl(LOG_NONE); Config c; c.lanes=2; Contract contract;
    if(test=="definitive") contract.boundaries="unknown";
    ReferenceModel model(c,contract);
    Stimulus reset; reset.inputs.rst_n=false; model.input_change(reset.inputs); model.rising_edge(model.plan(reset,0));
    Stimulus release; model.rising_edge(model.plan(release,1));
    Stimulus call; call.inputs.valid=call.inputs.ready=true; call.inputs.mask=1; call.inputs.words[0]=jal(1,16);
    call.inputs.predictions[0].pc=0x1000; model.rising_edge(model.plan(call,2));
    if(test=="coverage") {
        for(unsigned lanes:{1u,2u,4u,8u}) {
            Config width; width.lanes=lanes; Coverage cov(width);
            for(unsigned k=0;k<lanes;++k) {
                Sample s; s.phase="pre"; s.cycle=k; s.observed_inputs.rst_n=s.observed_inputs.valid=true;
                s.observed_inputs.mask=1u<<k; s.observed_inputs.words[k]=jal(0,16);
                s.stimulus.request_pc=k*4; s.stimulus.campaign=Campaign::Architectural;
                cov.sample(s,false);
            }
            std::filesystem::create_directories(directory+"/"+std::to_string(lanes));
            std::ofstream f(directory+"/"+std::to_string(lanes)+"/coverage.json"); f<<cov.json();
            for(unsigned k=0;k<lanes;++k) if(cov.count("architectural/EV02/start/"+std::to_string(k))!=1) return 2;
        }
        std::cout<<"PASS: four pure coverage configurations; no alternate RTL build\n"; return 0;
    }
    Scoreboard scb(c,contract,1,directory,true);
    if(test=="output-failure") {
        Sample matched; matched.phase="pre";
        matched.expected.early={0,true,"EJ06","D",{}, {}};
        scb.sample(matched);
        std::filesystem::create_symlink("/dev/full",std::filesystem::path(directory)/"report.json");
        try { scb.finish("",false,"output-failure"); }
        catch(const std::runtime_error& e) {
            return std::string(e.what())=="report write failed"?0:2;
        }
        return 1;
    }
    Stimulus probe; probe.guard_probe=true; probe.inputs.valid=true; probe.inputs.mask=1; probe.inputs.words[0]=jalr(0,1,0);
    auto take=[&](Stimulus s,std::string phase,uint64_t cycle,bool fault) {
        s.inputs.feedback=model.feedback(s.inputs); Sample sample; sample.stimulus=s; sample.phase=phase; sample.cycle=cycle;
        sample.before=model.state(); sample.observed_inputs=s.inputs; sample.transition=model.plan(s,cycle);
        sample.after=sample.transition.next; sample.expected=model.outputs(s); sample.actual=actual(sample.expected,c.lanes);
        if(fault) sample.actual.offset^=4;
        scb.sample(sample);
        if(phase=="pre") model.rising_edge(sample.transition);
    };
    if(test=="definitive") {
        // An unresolved overflow loses P knowledge; JAL arithmetic remains independently checkable.
        for(unsigned k=0;k<4;++k) model.rising_edge(model.plan(call,3+k));
        if(model.state().predictive.known) return 2;
        // Verified selected PC, wrong independently decoded immediate: exact A.
        call.inputs.words[0]=jal(0,16); take(call,"probe",3,true);
    } else {
        take(probe,"probe",3,test=="unverified");
        Stimulus ordinary; ordinary.inputs.valid=ordinary.inputs.ready=true; ordinary.inputs.mask=3;
        ordinary.inputs.words[0]=0x00108093; ordinary.inputs.words[1]=0x00028067;
        take(ordinary,"pre",4,false);
        take(probe,"probe",5,true);
    }
    return scb.finish("",false,test);
}
