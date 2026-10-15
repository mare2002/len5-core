// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_model.hh" // Reuse Field/provenance, Campaign, and JSON/address helpers unchanged.
#include "early_jump_instructions.hh"
#include <array>

namespace len5::early {
using pcgen::Field;
using pcgen::Campaign;
using pcgen::hex64;
using pcgen::json_quote;
using pcgen::field_json;
using pcgen::name;
constexpr unsigned MaxLanes=8;
enum class Operation { None, Push, Pop };
const char* name(Operation);
struct Config {
    unsigned lanes=1, depth=4, xlen=64, alen=64, instruction_bytes=4;
    std::string source, fingerprint;
    unsigned bundle_bytes() const { return lanes*instruction_bytes; }
    unsigned all_lanes() const { return (1u<<lanes)-1; }
    void validate() const;
};
struct Contract {
    std::string profile="len5_minimal", order="updated", exception="restore", boundaries="recent", lifecycle="held";
    static Contract established();
    void validate() const;
    std::string json() const;
};
struct Prediction {
    uint64_t pc=0,target=0;
    bool hit=false,taken=false;
    bool operator==(const Prediction& b) const { return pc==b.pc && target==b.target && hit==b.hit && taken==b.taken; }
};
struct Inputs {
    bool rst_n=true, flush=false, valid=false, ready=false, call_confirm=false, ret_confirm=false;
    uint64_t link=0,feedback=0;
    unsigned mask=0;
    std::array<uint32_t,MaxLanes> words{};
    std::array<Prediction,MaxLanes> predictions{};
    bool operator==(const Inputs&) const;
    bool same_bundle(const Inputs&) const;
};
struct Stimulus {
    Inputs inputs;
    Campaign campaign=Campaign::Stress;
    std::string scenario="unspecified",title="public interface",requirements,reason;
    uint64_t bundle_id=0, request_pc=0, requested_cycle=0, available_cycle=0;
    uint64_t confirmation_id=0,recovery_id=0;
    unsigned response_delay=2;
    bool malformed=false, canceled=false, feedback_unused=false, feedback_explicit=false, guard_probe=false;
    std::array<bool,MaxLanes> executed_taken{};
    std::array<uint64_t,MaxLanes> executed_target{};
    std::array<uint64_t,MaxLanes> rs1_value{},rs2_value{};
    std::array<bool,MaxLanes> execution_known{};
};
struct Entry {
    uint64_t address=0,source_id=0,cycle=0,pc=0;
    uint32_t word=0;
    std::string dependency;
};
struct History {
    std::vector<Entry> entries;
    bool known=false;
    std::string uncertainty="before reset",dependency;
    Field top() const;
    void reset();
    void apply(Operation,const Entry&,const Config&,const Contract&);
};
struct State {
    History predictive,confirmed;
    bool initialized=false,startup=true,pending=false,pending_known=false;
    std::string control_uncertainty="EQ02:before-reset";
};
struct Selection {
    int lane=-1;
    Decoded instruction;
    Operation offered=Operation::None;
    unsigned retained=0;
    Field correction,target,base,offset;
};
struct ExpectedPrediction { Field pc,hit,taken,target; };
struct Expected {
    Field early,mem_flush,base,offset,mask;
    std::array<ExpectedPrediction,MaxLanes> predictions;
    Selection selection;
};
struct Transition {
    State next;
    Selection selection;
    bool accepted=false;
    Operation speculative=Operation::None,confirmation=Operation::None;
};
class ReferenceModel {
    Config config_;
    Contract contract_;
    State state_;
public:
    ReferenceModel(Config,Contract);
    const Config& config() const { return config_; }
    const Contract& contract() const { return contract_; }
    const State& state() const { return state_; }
    void input_change(const Inputs&);
    Selection select(const Inputs&) const;
    Expected outputs(const Stimulus&) const;
    Transition plan(const Stimulus&,uint64_t cycle) const;
    void rising_edge(const Transition& t) { state_=t.next; }
    uint64_t feedback(const Inputs&) const;
};
Field known(uint64_t,const char*,const char*,std::string assumptions={});
Field unknown(const char*);
Field dont_care(const char*);
unsigned request_mask(uint64_t,const std::array<Prediction,MaxLanes>&,const Config&);
std::string inputs_json(const Inputs&,unsigned lanes);
std::string state_json(const State&);
std::string expected_json(const Expected&,unsigned lanes);
std::string specification_json();
Config read_build_configuration(const std::string& executable);
} // namespace len5::early
