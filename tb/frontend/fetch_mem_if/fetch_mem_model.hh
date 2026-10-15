// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "pc_gen_model.hh" // Unchanged pc_gen Field/provenance/Campaign/JSON helpers.
#include <array>
#include <deque>
#include <map>
#include <stdexcept>
namespace len5::fetchmem {
using pcgen::Field; using pcgen::Campaign; using pcgen::name;
using pcgen::hex64; using pcgen::json_quote; using pcgen::field_json;
constexpr unsigned MaxLanes=8;
struct Config {
    unsigned lanes=1,depth=2,xlen=64,ilen=32,cause_bits=5,req_skip=1,ans_skip=0;
    std::string source,fingerprint;
    unsigned bytes() const { return lanes*4; }
    unsigned mask() const { return (1u<<lanes)-1; }
    void validate() const;
};
struct Contract {
    std::string profile="integrated";
    bool raw_transport=true;
    void validate() const;
    std::string json() const;
};
struct Prediction {
    uint64_t pc=0,target=0; bool hit=false,taken=false;
    bool operator==(const Prediction& p) const { return pc==p.pc && target==p.target && hit==p.hit && taken==p.taken; }
};
struct Payload {
    std::array<uint32_t,MaxLanes> words{};
    std::array<unsigned,MaxLanes> causes{};
    unsigned errors=0;
    bool operator==(const Payload& p) const { return words==p.words && causes==p.causes && errors==p.errors; }
};
struct Inputs {
    bool rst_n=true,flush=false,fetch_valid=false,grant=false,response_valid=false,consumer_ready=true;
    std::array<Prediction,MaxLanes> predictions{};
    unsigned mask=0;
    Payload response;
    bool operator==(const Inputs&) const;
};
struct Offer {
    uint64_t id=0,start=0,latency=1;
    std::array<Prediction,MaxLanes> predictions{};
    unsigned mask=0;
    Payload memory_data; // Environment-owned future memory data, never used to predict output data.
};
struct Stimulus {
    Inputs inputs;
    uint64_t request_id=0,response_id=0,start=0,latency=1;
    Payload memory_data;
    Campaign campaign=Campaign::Architectural;
    std::string scenario="unspecified",title="memory transport",reason,question;
    bool malformed=false,turnover=false;
};
struct Request {
    Campaign campaign=Campaign::Architectural;
    uint64_t id=0,epoch=0,start=0,accepted=0;
    unsigned mask=0;
    std::array<Prediction,MaxLanes> predictions{};
    bool metadata_known=true;
};
struct Answer { Request request; Payload payload; uint64_t arrived=0; };
struct Counters {
    uint64_t accepted=0,responded=0,delivered=0,canceled=0,canceled_buffered=0;
    uint64_t fault_responses=0,fault_deliveries=0,fault_cancellations=0,ambiguous=0;
};
struct State {
    std::deque<Request> outstanding;
    std::deque<Answer> answers;
    bool initialized=false,released=false,association_known=true,in_reset=false;
    uint64_t epoch=0;
    Counters totals;
    std::array<Counters,3> campaigns{};
};
struct ExpectedLane { Field word,pc,hit,taken,target,error,cause; };
struct Expected {
    Field fetch_ready,request_valid,request_address,write,response_ready,valid,mask;
    std::array<ExpectedLane,MaxLanes> lanes;
};
struct Transition {
    State next;
    bool k=false,r=false,d=false,ambiguous=false;
    uint64_t delivered_id=0,response_id=0;
    std::vector<uint64_t> canceled_ids;
    unsigned row() const { return unsigned(k)*4+unsigned(r)*2+unsigned(d); }
};
class ReferenceModel {
    Config cfg_; Contract contract_; State state_;
    void cancel(State&,Campaign) const;
public:
    ReferenceModel(Config,Contract={});
    const State& state() const { return state_; }
    void input_change(const Stimulus&);
    Expected outputs(const Stimulus&) const;
    Transition plan(const Stimulus&,uint64_t) const;
    void rising_edge(const Transition& t) { state_=t.next; }
};
Field known(uint64_t,const char*,const char* = "D",std::string={});
Field unknown(const std::string&);
Field dont_care(const std::string&);
unsigned request_mask(uint64_t,const std::array<Prediction,MaxLanes>&,const Config&);
std::string inputs_json(const Inputs&,unsigned);
std::string state_json(const State&);
std::string config_json(const Config&);
std::string counters_json(const Counters&,uint64_t pending);
std::string specification_json();
Config read_build_configuration(const std::string&);
} // namespace len5::fetchmem
