// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// DUT-independent contract and causal-history tests. No Verilator dependency.
#include "pc_gen_environment.hh"
#include <iostream>
#include <functional>
#include <iomanip>
#include <random>
#include <sstream>
using namespace len5::pcgen;

namespace {
unsigned checks=0;
void require(bool condition, const char* message) {
    ++checks;
    if(!condition) throw std::runtime_error(message);
}
void rejects(const std::function<void()>& f, const char* message) {
    bool rejected=false;
    try { f(); } catch(const EnvironmentError&) { rejected=true; }
    require(rejected,message);
}
void edge(ReferenceModel& m, const Inputs& i) { m.input_change(i); m.rising_edge(m.plan(i)); }
}
int main() {
    try {
        for (unsigned byte=0; byte<256; ++byte) {
            std::ostringstream expected;
            expected << '"';
            if (byte=='"' || byte=='\\') expected << '\\' << char(byte);
            else if (byte<32) expected << "\\u" << std::hex << std::setw(4) << std::setfill('0') << byte;
            else expected << char(byte);
            expected << '"';
            require(json_quote(std::string(1,char(byte)))==expected.str(),"JSON quoting preserves every byte");
        }
        require(json_quote("")=="\"\"", "empty JSON string");
        require(json_quote(std::string("a\0b",3))=="\"a\\u0000b\"", "embedded NUL is escaped");
        std::mt19937_64 formatting(17);
        for (unsigned n=0; n<1024; ++n) {
            const uint64_t value=n==0?0:n==1?UINT64_MAX:formatting();
            std::ostringstream expected;
            expected << "0x" << std::hex << std::setw(16) << std::setfill('0') << value;
            require(hex64(value)==expected.str(),"64-bit hex keeps width, case and all bits");
        }
        Config cfg; Contract contract; ReferenceModel m(cfg,contract);
        require(!m.cursor().known,"model starts unknown");
        Inputs i; i.rst_n=false; m.input_change(i);
        require(m.cursor().known && m.cursor().value==0,"asynchronous boot foundation");
        i=Inputs{}; i.ready=true; i.prediction=true; i.prediction_target=0x104; edge(m,i);
        i.prediction=false; edge(m,i);
        require(m.cursor().value==0x120,"partial bundle reaches 0x120, not PC+4");
        require(m.sequential(0x100)==0x120 && m.sequential(0x11c)==0x120,"bundle interval examples");
        i=Inputs{}; i.branch_valid=true; i.mispredict=true; i.branch_pc=0x104; edge(m,i);
        require(m.cursor().value==0x108,"R-N restarts at the instruction successor");
        require(m.cursor().assumptions.empty(),"approved recovery timing is definitive");
        i=Inputs{}; edge(m,i);
        require(m.cursor().assumptions.empty(),"hold retains definitive cursor provenance");
        i.early=true; i.early_base=0x204; i.early_offset=uint64_t(-4); i.prediction=true; i.prediction_target=0xb00;
        require(m.outputs(i).early_target.value==0x200,"signed older early base arithmetic");
        edge(m,i); require(m.cursor().value==0x200,"C9 early correction displaces speculative prediction");
        i.commit=true; i.commit_pc=0x700;
        require(!m.outputs(i).early_target.known,"Q4 collision sideband cannot be marked correct");
        edge(m,i); require(m.cursor().value==0x700,"proposed commit priority");
        require(m.cursor().assumptions.empty(),"approved priority is definitive");
        ReferenceModel strict(cfg,Contract::strict());
        i=Inputs{}; i.rst_n=false; strict.input_change(i);
        require(strict.cursor().known && strict.cursor().value==cfg.boot_pc,"strict retains approved asynchronous reset");
        edge(strict,i); require(strict.cursor().known && strict.cursor().value==0,"synchronous foundation restores state");
        strict.input_change(i); require(strict.cursor().known,"held reset preserves synchronously established state");
        i=Inputs{}; i.early=true; i.prediction=true; i.early_base=0x204; i.early_offset=uint64_t(-4); i.prediction_target=0xb00;
        require(strict.outputs(i).early_target.known && strict.outputs(i).early_target.value==0x200,"strict retains approved selected metadata");
        edge(strict,i); require(strict.cursor().known && strict.cursor().value==0x200,"strict retains memory-independent early correction");
        i=Inputs{}; edge(strict,i); require(strict.cursor().known && strict.cursor().value==0x200,"hold retains independently established state");
        i.prediction=true; i.ready=true; i.prediction_target=0x500; edge(strict,i);
        require(strict.cursor().known && strict.cursor().value==0x500,"independent accepted target re-establishes state");
        i.early=true; i.commit=true; i.commit_pc=0x700; edge(strict,i);
        require(strict.cursor().known && strict.cursor().value==0x700,"approved priority applies in strict profile");
        i=Inputs{}; i.rst_n=false; edge(strict,i);
        require(strict.cursor().known,"reset restores unknown state without DUT outputs");
        i=Inputs{}; i.ready=true; i.prediction=true; i.prediction_target=0x701;
        require(m.plan(i,true).next_pc.known && m.plan(i,true).next_pc.value==0x701,"Q7 raw target pass-through is exact even in characterization");
        require(m.sequential(UINT64_C(0xfffffffffffffffc))==0,"unsigned W-bit arithmetic boundary");
        Config single=cfg; single.bundle_instructions=1; ReferenceModel sm(single,contract);
        require(sm.sequential(0x104)==0x108,"generic model single-issue arithmetic (not an RTL build claim)");
        for(unsigned low=1;low<=3;++low) {
            i=Inputs{}; i.ready=i.prediction=true; i.prediction_target=0x700+low; edge(m,i);
            require(m.cursor().value==0x700+low,"externally supplied address bits are preserved");
            i.prediction=false; edge(m,i);
            require(m.cursor().value==0x720,"ordinary bundle successor alone clears low address bits");
        }
        for(const auto profile:{contract,Contract::strict()}) {
            ReferenceModel oracle(cfg,profile);
            for(unsigned row=0;row<16;++row) for(bool ready:{false,true}) for(bool taken:{false,true}) {
                i=Inputs{}; i.rst_n=false; edge(oracle,i);
                i=Inputs{}; i.commit=row&8; i.branch_valid=i.mispredict=row&4;
                i.early=row&2; i.prediction=row&1; i.ready=ready; i.taken=taken;
                i.commit_pc=0x701; i.branch_pc=0x105; i.branch_target=0x903;
                i.early_base=0x204; i.early_offset=uint64_t(-3); i.prediction_target=0xb02;
                // Independent decision table with distinct, raw byte targets.
                const uint64_t expected=(row&8)?0x701:(row&4)?(taken?0x903:0x109):
                    (row&2)?0x201:!ready?0:(row&1)?0xb02:32;
                edge(oracle,i);
                require(oracle.cursor().known && oracle.cursor().value==expected && oracle.cursor().assumptions.empty(),
                        "all priority/ready combinations use approved independent targets in both profiles");
                if(row&2) {
                    const auto metadata=oracle.outputs(i).early_target;
                    require((row&8)?(!metadata.known && metadata.question.find("DC:")==0):
                        (row&4)?(!metadata.known && metadata.question.find("Q4:")==0):
                        (metadata.known && metadata.value==0x201 && metadata.assumptions.empty()),
                        "selected, unused and branch-overridden metadata have separate dispositions");
                }
            }
        }
        i=Inputs{}; require(!m.outputs(i).branch_ready.known,"idle ready is not an acknowledgment requirement");
        i.rst_n=false; require(!m.outputs(i).branch_ready.known,"reset ready remains unspecified");
        i.rst_n=true; i.commit=true; require(m.outputs(i).branch_ready.known,"sole active producer retains established acknowledgment assumption");
        i.branch_valid=i.mispredict=true; require(!m.outputs(i).branch_ready.known,"shared losing acknowledgment not invented");
        i=Inputs{}; i.early=i.ready=true;
        require(m.plan(i).acceptance_known && !m.plan(i).ordinary_acceptance &&
                strict.plan(i).acceptance_known && !strict.plan(i).ordinary_acceptance,
                "R10 early correction suppresses ordinary acceptance in both profiles");
        ReferenceModel uninitialized(cfg,contract); i=Inputs{};
        edge(uninitialized,i); require(!uninitialized.cursor().known,"hold cannot repair uninitialized expected state");
        i.ready=true; edge(uninitialized,i); require(!uninitialized.cursor().known,"sequential cannot repair unknown expected state");
        i.prediction=true; i.prediction_target=0x501; edge(uninitialized,i);
        require(uninitialized.cursor().known && uninitialized.cursor().value==0x501,"independent supplied prediction reestablishes state");

        Environment env(cfg);
        Stimulus s; s.campaign=Campaign::Architectural; s.inputs.ready=true;
        env.accept_bundle(0x100,s,5);
        uint64_t id=env.instruction_at(0x104);
        env.describe(id,InstructionKind::Branch,true,0x900);
        s.inputs.branch_valid=true; s.inputs.mispredict=true; s.inputs.taken=true;
        s.inputs.branch_pc=0x104; s.inputs.branch_target=0x900; s.branch_id=id;
        rejects([&]{env.validate(s,m.cursor(),6);},"premature resolution must be rejected");
        env.validate(s,m.cursor(),7); require(true,"live mature branch accepted");
        s.inputs.mispredict=false;
        rejects([&]{env.validate(s,m.cursor(),7);},"correct qualifier contradicting prediction history rejected");
        s.inputs.mispredict=true; s.branch_id=99999;
        rejects([&]{env.validate(s,m.cursor(),7);},"never-fetched branch rejected");
        s.branch_id=id;
        Transition recovery; recovery.event=Event::TakenRecovery; recovery.next_pc.known=true;
        recovery.control_accepted=true;
        env.consume(s,recovery);
        rejects([&]{env.validate(s,m.cursor(),8);},"duplicate branch acceptance rejected");
        require(env.instruction(id-1).live,"older unaffected instruction survives branch recovery");
        const uint64_t younger=id+1;
        rejects([&]{env.instruction(younger);},"younger record squashed by recovery");
        Inputs reset; reset.rst_n=false; env.input_change(reset);
        rejects([&]{env.instruction(id);},"old epoch record cannot resolve after reset");
        require(env.epoch()==1,"reset advances epoch once");
        env.input_change(reset); require(env.epoch()==1,"held reset does not generate new epochs");

        Environment early_env(cfg);
        s=Stimulus{}; s.campaign=Campaign::Architectural; s.inputs.ready=true;
        early_env.accept_bundle(0x200,s,0); id=early_env.instruction_at(0x204);
        early_env.describe(id,InstructionKind::DirectJump,true,0x200,uint64_t(-4));
        s.inputs=Inputs{}; s.inputs.early=true; s.inputs.early_base=0x204; s.inputs.early_offset=uint64_t(-4); s.early_id=id;
        early_env.validate(s,m.cursor(),2);
        Transition correction; correction.event=Event::Early; correction.next_pc.known=true;
        correction.control_accepted=true;
        early_env.consume(s,correction); early_env.input_change(s.inputs);
        early_env.validate(s,m.cursor(),3); require(true,"same early request may be held");
        early_env.input_change(Inputs{});
        rejects([&]{early_env.validate(s,m.cursor(),4);},"released accepted early request cannot be reused");
        Environment window(cfg);
        s=Stimulus{}; s.campaign=Campaign::Architectural;
        window.accept_bundle(0x100,s,10); id=window.instruction_at(0x100);
        require(window.live_records().size()==8,"generator query includes independently fetched lanes");
        rejects([&]{window.set_availability(id,11);},"random latency cannot precede causal minimum");
        window.set_availability(id,20);
        window.describe(id,InstructionKind::Branch,true,0x900);
        s.inputs.branch_valid=s.inputs.mispredict=s.inputs.taken=true;
        s.inputs.branch_pc=0x100; s.inputs.branch_target=0x900; s.branch_id=id;
        rejects([&]{window.validate(s,m.cursor(),19);},"randomized availability gates resolution");
        window.validate(s,m.cursor(),20); require(true,"randomized latency permits mature resolution");
        rejects([&]{window.complete_correct_resolution(id);},"BPU-only completion must truly be correct");
        window.describe(id,InstructionKind::Branch,false,0);
        window.complete_correct_resolution(id);
        require(window.instruction(id).resolved,"correct resolution completes without a DUT request");
        window.request_commit(id,0x700); window.prune(200,64);
        require(window.live_records().size()==1,"pruning preserves pending commit token");
        window.input_change(reset); window.prune(201,64);
        require(window.live_records().empty(),"dead epochs can be discarded without DUT state");
        Environment pending_window(cfg); pending_window.accept_bundle(0x100,Stimulus{},0);
        id=pending_window.instruction_at(0x100);
        pending_window.describe(id,InstructionKind::Branch,true,0x900);
        pending_window.prune(200,64);
        require(pending_window.live_records().size()==1,"unresolved control history cannot silently retire under window pressure");
        // Mathematical and abstract-environment checks only; this does not
        // elaborate or change any production RTL configuration.
        for(unsigned width:{1u,2u,4u,8u}) {
            Config selected=cfg; selected.bundle_instructions=width;
            selected.boot_pc=0x100+(width-1)*selected.instruction_bytes;
            ReferenceModel oracle(selected,contract);
            Inputs pins; pins.rst_n=false; edge(oracle,pins);
            require(oracle.cursor().value==selected.boot_pc,"configured boot is not rounded to bundle start");
            for(unsigned lane=0;lane<width;++lane) {
                const uint64_t pc=0x100+lane*selected.instruction_bytes;
                require(oracle.sequential(pc)==0x100+selected.bundle_bytes(),"every supported lane consumes its whole bundle interval");
                Environment ledger(selected); Stimulus fetch; fetch.inputs.ready=true;
                ledger.accept_bundle(pc,fetch,10);
                require(ledger.live_records().size()==width-lane,"partial-bundle histories retain only eligible lanes");
                fetch.inputs.prediction=true; fetch.prediction_lane=int(lane);
                Environment predicted(selected); predicted.accept_bundle(pc,fetch,10);
                require(predicted.live_records().size()==1,"prediction terminates fetching at its selected eligible lane");
                pins=Inputs{}; pins.branch_valid=pins.mispredict=true; pins.branch_pc=pc;
                edge(oracle,pins); require(oracle.cursor().value==pc+4,"branch fallthrough remains PC+4 at every width/lane");
                pins=Inputs{}; pins.early=true; pins.early_base=pc; pins.early_offset=uint64_t(-4);
                edge(oracle,pins); require(oracle.cursor().value==pc-4,"signed early arithmetic is independent of bundle width");
            }
            require(oracle.sequential(UINT64_MAX-3)==0,"bundle successor wraps independently at every width");
            pins=Inputs{}; pins.ready=true; edge(oracle,pins);
            require(oracle.cursor().assumptions.empty(),"approved sequential continuation stays definitive at every width");
        }
        for(unsigned invalid:{0u,3u,16u}) {
            Config unsupported=cfg; unsupported.bundle_instructions=invalid;
            bool rejected=false;
            try { unsupported.validate(); } catch(const std::invalid_argument&) { rejected=true; }
            require(rejected,"unsupported issue widths fail clearly rather than becoming a second configuration contract");
        }
        std::cout << "PASS: pc_gen independent model/environment, " << checks << " checks\n";
        return 0;
    } catch(const std::exception& e) {
        std::cerr << "FAIL: pc_gen framework: " << e.what() << '\n'; return 1;
    }
}
