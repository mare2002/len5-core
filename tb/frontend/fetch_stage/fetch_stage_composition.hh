// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_stage_components.hh"
namespace len5::frontend {
struct Inputs {
    bool rst_n = true, flush = false, flush_bpu = false, grant = false, response_valid = false, ready = true;
    fetchmem::Payload response;
    Feedback feedback;
    bool commit = false;
    uint64_t commit_pc = 0;
    std::string reason;
};
struct Outputs {
    bool request = false, response_ready = false, write = false, valid = false, early_flush = false,
         branch_ready = false;
    uint64_t address = 0;
    Bundle bundle;
};
struct Expected {
    Field request, address, response_ready, write, valid, early_flush, branch_ready, mask;
    std::array<fetchmem::ExpectedLane, MaxLanes> lanes;
};
struct CompositionPlan {
    Expected expected;
    pcgen::Inputs pi;
    pcgen::Transition pt;
    early::Stimulus es;
    early::Expected ee;
    early::Transition et;
    fetchmem::Stimulus ms;
    fetchmem::Transition mt;
    Bundle transfer, dispatched;
    bool a = false, d = false, early = false, uncertain = false;
    unsigned row = 0, q = 0, answers = 0, output = 0, start = 0;
};
struct FlowStats {
    uint64_t accepted = 0, responded = 0, transferred = 0, dispatched = 0, canceled = 0, early = 0;
};
class Composition {
    Config cfg_;
    pcgen::ReferenceModel pc_;
    early::ReferenceModel eju_;
    fetchmem::ReferenceModel memory_;
    Predictor bpu_;
    std::deque<Bundle> output_;
    struct Snapshot {
        unsigned history = 0;
        std::array<unsigned, MaxLanes> index{}, counter{};
        std::array<uint64_t, MaxLanes> generation{};
    };
    std::map<uint64_t, Snapshot> snapshots_;
    bool initialized_ = false, released_ = false, in_reset_ = false;
    uint64_t next_id_ = 1, epoch_ = 0;

  public:
    FlowStats stats;
    Composition(Config, const std::string &ras_order = "updated");
    void input_change(const Inputs &);
    CompositionPlan plan(const Inputs &, uint64_t) const;
    std::optional<PredictorUpdate> edge(const Inputs &, const CompositionPlan &);
    uint64_t next_id() const { return next_id_; }
    uint64_t epoch() const { return epoch_; }
    size_t pending() const {
        return memory_.state().outstanding.size() + memory_.state().completed.size() + memory_.state().answers.size() + output_.size();
    }
    const Predictor &predictor() const { return bpu_; }
    const early::State &ras() const { return eju_.state(); }
    pcgen::Field cursor() const { return pc_.cursor(); }
    const fetchmem::State &memory_state() const { return memory_.state(); }
};
std::string inputs_json(const Inputs &, unsigned);
std::string outputs_json(const Outputs &, unsigned);
std::string bundle_json(const Bundle &, unsigned);
} // namespace len5::frontend
