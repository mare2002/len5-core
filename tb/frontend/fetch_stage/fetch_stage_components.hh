// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "early_jump_model.hh"
#include "fetch_mem_model.hh"
#include "pc_gen_model.hh"
#include <array>
#include <deque>
#include <functional>
#include <map>
#include <optional>
#include <random>
#include <set>
#include <stdexcept>

namespace len5::frontend {
using pcgen::Campaign;
using pcgen::Field;
using pcgen::hex64;
using pcgen::json_quote;
using Prediction = fetchmem::Prediction;
constexpr unsigned MaxLanes = 8;
uint64_t split_seed(uint64_t);
uint64_t bounded(std::mt19937_64 &, uint64_t);
// A request samples before the edge, including an edge that overwrites the row.
inline bool training_window(uint64_t request, uint64_t update, uint64_t superseded) {
    return request > update && request <= superseded;
}
struct Config {
    unsigned lanes = 4, hlen = 4, btb_bits = 4, initial = 2, depth = 2, ras_depth = 4;
    unsigned iq = 16, rob = 32, branch_capacity = 4, alu_capacity = 8;
    uint64_t boot = 0;
    std::string fingerprint, source;
    unsigned bytes() const { return lanes * 4; }
    void validate() const;
};
Config read_configuration(const std::string &executable);
struct Resolution {
    uint64_t pc = 0, target = 0;
    bool taken = false, mispredict = false;
};
struct PredictorUpdate {
    unsigned history = 0, index = 0, before = 0, after = 0, row = 0;
    bool replacement = false, deletion = false;
};
class Predictor {
    struct Entry {
        bool valid = false;
        uint64_t tag = 0, target = 0;
    };
    Config cfg_;
    std::vector<Entry> targets_;
    std::vector<unsigned> counters_;
    std::vector<uint64_t> generations_;
    unsigned history_ = 0;

  public:
    explicit Predictor(Config);
    void reset();
    Prediction predict(uint64_t) const;
    PredictorUpdate update(const Resolution &);
    unsigned history() const { return history_; }
    unsigned index(uint64_t pc) const { return history_ ^ unsigned((pc / 4) % counters_.size()); }
    unsigned counter(unsigned k) const { return counters_.at(k); }
    uint64_t generation(unsigned k) const { return generations_.at(k); }
};
struct LatencyOptions {
    uint64_t minimum = 1, maximum = 64, fixed = 0, mode = 0;
    unsigned geo_u = 1, geo_v = 8, short_u = 1, short_v = 2;
    uint64_t short_min = 0, short_max = 0, long_min = 0, long_max = 0;
    std::string distribution = "uniform";
    void validate() const;
    std::string json() const;
};
class LatencySampler {
    LatencyOptions options_;
    std::mt19937_64 rng_;
    std::vector<uint64_t> cdf_;

  public:
    LatencySampler(LatencyOptions, uint64_t);
    uint64_t sample();
    const LatencyOptions &options() const { return options_; }
};
struct Semantic {
    early::Decoded decoded;
    bool writes = false, control = false, taken = false;
    unsigned rd = 0;
    uint64_t value = 0, target = 0, next = 0;
};
Semantic evaluate(uint32_t word, uint64_t pc, uint64_t a, uint64_t b);
uint32_t immediate(unsigned funct3, unsigned rd, unsigned rs1, int64_t value);
struct Program {
    std::string family;
    uint64_t boot = 0, marker = 0;
    std::map<uint64_t, uint32_t> text;
    std::map<uint64_t, unsigned> faults;
    std::map<std::string, uint64_t> labels;
    uint32_t word(uint64_t) const;
    fetchmem::Payload read(uint64_t, unsigned) const;
    std::string digest() const;
    std::string json() const;
    void validate() const;
};
class Assembler {
    struct Fix {
        uint64_t pc;
        std::string label;
        unsigned rd, funct3, rs1, rs2;
        bool jump;
    };
    Program p_;
    uint64_t cursor_;
    std::vector<Fix> fixes_;

  public:
    Assembler(uint64_t, const std::string &);
    void at(uint64_t);
    void label(const std::string &);
    void emit(uint32_t);
    void addi(unsigned, unsigned, int64_t);
    void jal(unsigned, const std::string &);
    void branch(unsigned, unsigned, unsigned, const std::string &);
    uint64_t pc() const { return cursor_; }
    Program finish(const std::string &marker = "done");
};
Program make_program(const Config &, const std::string &, unsigned repetitions = 32, unsigned variant = 0);

struct Lane {
    uint32_t word = 0;
    Prediction prediction, raw;
    bool error = false, rewritten = false, raw_known = true;
    unsigned cause = 0, source_lane = 0;
    uint64_t request_id = 0, request_cycle = 0, accepted_cycle = 0;
    bool ras_known = false, ras_nonempty = false;
    uint64_t ras_top = 0;
    unsigned prediction_history = 0, prediction_index = 0, prediction_counter = 0;
    uint64_t prediction_generation = 0;
};
struct Bundle {
    uint64_t id = 0, epoch = 0;
    unsigned mask = 0;
    std::array<Lane, MaxLanes> lanes{};
};
struct Instruction {
    uint64_t id = 0, epoch = 0, bundle = 0, pc = 0, dispatch = 0, latency = 0, earliest = 0;
    uint64_t issue = UINT64_MAX, execute = UINT64_MAX, update = UINT64_MAX, confirmation = UINT64_MAX;
    uint64_t dependency_ready = 0, order_delay = 0, retire = UINT64_MAX;
    uint64_t start = UINT64_MAX, publication = UINT64_MAX;
    unsigned lane = 0, iteration = 0;
    Lane payload;
    Semantic semantic;
    uint64_t a = 0, b = 0, dep_a = 0, dep_b = 0;
    bool issued = false, completed = false, canceled = false, retired = false, trained = false,
         confirmed = false;
    bool wrong = false;
};
struct Feedback {
    uint64_t id = 0;
    Resolution resolution;
    bool train = false, redirect = false, flush = false, call = false, ret = false;
    uint64_t link = 0;
};
struct BackendStats {
    uint64_t dispatched = 0, executed = 0, retired = 0, canceled = 0, updates = 0, confirmations = 0,
             recoveries = 0;
    uint64_t branch_executions = 0, correct = 0, wrong = 0, order_blocks = 0, resumes = 0;
    uint64_t offered = 0, accepted = 0, issued = 0, started = 0, published = 0;
    uint64_t iq_high = 0, rob_high = 0, branch_high = 0, alu_high = 0, inflight_high = 0;
    uint64_t iq_blocks = 0, rob_blocks = 0, branch_blocks = 0, alu_blocks = 0;
    uint64_t resource_stalls = 0, random_stalls = 0, publication_blocks = 0;
    std::string json() const;
};
struct Resources {
    unsigned iq = 0, rob = 0, branch = 0, alu = 0;
};
// Public semantic invariant validators, also used by independent negative fixtures.
void validate_resources(const Config &, Resources);
void validate_lifecycle(const Instruction &);
void validate_backend_history(const std::vector<Instruction> &);
class Backend {
    Config cfg_;
    LatencySampler sampler_;
    std::array<uint64_t, 32> committed_{};
    std::array<std::vector<uint64_t>, 32> versions_;
    std::vector<Instruction> records_;
    std::map<uint64_t, Feedback> events_;
    std::map<uint64_t, unsigned> iterations_;
    std::set<uint64_t> accepted_bundles_;
    uint64_t epoch_ = 0, freeze_id_ = 0, resume_cycle_ = 0, expected_retire_pc_ = 0;
    uint64_t last_advance_ = UINT64_MAX;
    uint64_t read(unsigned, uint64_t &) const;
    void rollback(uint64_t);
    void enqueue(uint64_t, const Feedback &);
    void audit(bool sample = true);

  public:
    BackendStats stats;
    Backend(Config, LatencyOptions, uint64_t);
    void reset();
    bool ready(unsigned mask = UINT32_MAX) const;
    Resources resources() const;
    void offered(bool valid, bool capacity_ready, bool random_ready);
    void dispatch(const Bundle &, uint64_t);
    Feedback feedback(uint64_t) const;
    void validate_feedback(const Feedback &, uint64_t) const;
    void consume_feedback(const Feedback &, uint64_t);
    void advance(uint64_t, bool retirement_ready = true);
    void cancel_all();
    size_t pending() const;
    const std::vector<Instruction> &records() const { return records_; }
    const Instruction &record(uint64_t id) const;
    uint64_t committed(unsigned r) const { return committed_.at(r); }
    uint64_t speculative(unsigned r) const {
        uint64_t dep = 0;
        return read(r, dep);
    }
    uint64_t expected_pc() const { return expected_retire_pc_; }
};
} // namespace len5::frontend
