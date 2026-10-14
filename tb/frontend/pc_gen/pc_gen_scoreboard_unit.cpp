// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Synthetic public-port evidence tests confidence, without simulating RTL.
#include "pc_gen_scoreboard.hh"
#include "tb_macros.hh"
#include <filesystem>
#include <stdexcept>
#include <sstream>
TbLogger logger;
using namespace len5::pcgen;
int main(int argc,char** argv) {
    if(argc!=3) return 2;
    if(std::string(argv[2])=="coverage") {
        // Pure collector fixtures: no RTL elaboration or configuration sweep.
        for(unsigned width:{1u,2u,4u,8u}) {
            Config cfg; cfg.bundle_instructions=width; Coverage cov(cfg);
            Sample s; s.phase="pre"; s.stimulus.campaign=Campaign::Architectural;
            s.observed_inputs.ready=true; s.transition.event=Event::Sequential;
            for(unsigned lane=0;lane<width;++lane) {
                s.cycle=lane;
                s.previous_pc={0x100+4*lane,true,"C3","I",{}, {}};
                s.actual.pc=s.previous_pc.value; s.expected.pc=s.previous_pc;
                cov.sample(s,true);
            }
            s.cycle=width; s.observed_inputs.ready=false; s.transition.event=Event::Hold; cov.sample(s,true);
            s.phase="post"; cov.sample(s,true);
            s.phase="pre"; s.cycle=width+10; cov.sample(s,true);
            s.phase="post"; cov.sample(s,true);
            s.phase="pre"; ++s.cycle; s.observed_inputs.ready=true;
            s.observed_inputs.prediction=true; s.observed_inputs.prediction_target=0x500;
            s.transition.event=Event::Prediction; cov.sample(s,true);
            s.phase="post"; s.actual.pc=s.expected.pc.value=0x500; cov.sample(s,true);
            const auto directory=std::filesystem::path(argv[1])/std::to_string(width);
            std::filesystem::create_directories(directory);
            cov.write((directory/"coverage.json").string(),{},{},{});
        }
        return 0;
    }
    const bool definitive=std::string(argv[2])=="definitive";
    const bool matched=std::string(argv[2])=="matched";
    std::filesystem::create_directories(argv[1]);
    Scoreboard scb(Config{},Contract{},1,argv[1]);
    Sample s; s.phase="pre"; s.stimulus.scenario="confidence-context";
    s.stimulus.test_name="SYNTHETIC evidence: hold versus selecting current prediction";
    s.observed_inputs.early=s.observed_inputs.prediction=true;
    s.observed_inputs.early_base=8; s.observed_inputs.prediction_target=4;
    s.stimulus.inputs=s.observed_inputs;
    s.previous_pc={0,true,"C2","I","SYNTHETIC:prior-state-hypothesis",{}};
    if(definitive) s.previous_pc={0,false,{},"Q",{},"SYNTHETIC:unknown-prior-state"};
    s.expected.pc=s.previous_pc;
    s.expected.valid={1,true,"C7","I",{}, {}};
    s.expected.branch_ready={1,true,"C8","O","Q5:always-ready",{}};
    s.expected.early_target={8,true,"C6","I","",{}};
    s.actual={matched?0u:4u,8,true,true};
    s.transition.event=Event::Early;
    scb.sample(s);
    s.phase="post"; s.time=1;
    s.expected.pc={8,true,"C9","D","SYNTHETIC:inherited-state-hypothesis",{}};
    if(definitive) s.expected.pc.assumptions.clear(); // Exact C9 comparison remains active with unknown prior context.
    // Artificial residual-state fixture: this is not an alternative approved Q3 rule.
    // With a verified old PC of 0, 4 cannot be either hold or early correction.
    s.actual.pc=4; scb.sample(s);
    return scb.finish("",false,"scoreboard-confidence"); // Expected nonzero in both cases.
}
