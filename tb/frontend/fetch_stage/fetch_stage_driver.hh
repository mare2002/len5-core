// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_stage_composition.hh"
#include "fetch_stage_ras_witness.hh"
#include <fstream>
#include <memory>
class VerilatedContext;
class VerilatedFstC;
class Vfetch_stage_tb;
namespace len5::frontend {
struct Options {
    uint64_t seed = 1, cycles = 10000, max_cycles = 100000;
    std::string expect_fingerprint;
    std::string scenario = "all", program = "", campaign = "all", profile = "exact-I", ras_order = "updated",
                run_dir, executable, inject, weights, journal = "auto";
    bool random = false, waves = false, guided = true, strict_completion = false, latency_explicit = false;
    unsigned expect_issues = 0, repetitions = 64;
    unsigned directed_repetitions = 0, variant = UINT32_MAX;
    uint64_t directed_cycles = 0;
    LatencyOptions latency;
};
struct Scenario {
    std::string id, title, family, classification = "architectural";
    unsigned variant = 0, repetitions = 64;
    uint64_t budget = 6000;
    std::vector<std::string> witnesses;
    std::string limitation;
    std::string provisional_contract;
};
std::vector<Scenario> scenarios(const Config &);
struct RunStats {
    uint64_t samples = 0, checks = 0, field_errors = 0, failed_samples = 0, transactions = 0, cycles = 0;
    uint64_t confirmed = 0, provisional = 0, injected = 0, environment = 0, framework = 0;
    uint64_t requests = 0, responses = 0, delivered = 0, canceled = 0, dynamic = 0, backend_canceled = 0,
             retired = 0, updates = 0, confirmations = 0, executions = 0, recoveries = 0;
};
class Simulator {
    Options options_;
    Config cfg_;
    std::unique_ptr<VerilatedContext> context_;
    std::unique_ptr<Vfetch_stage_tb> dut_;
    std::unique_ptr<VerilatedFstC> trace_;
    std::unique_ptr<Composition> model_;
    std::unique_ptr<Backend> backend_;
    struct Physical {
        uint64_t id, address, accepted, due;
        fetchmem::Payload payload;
    };
    std::deque<Physical> physical_;
    std::mt19937_64 events_, memory_rng_;
    uint64_t cycle_ = 0, physical_id_ = 1, stimulus_digest_ = UINT64_C(14695981039346656037);
    uint64_t instance_ = 0;
    LatencyOptions active_latency_;
    uint64_t active_latency_seed_ = 0;
    bool injected_ = false, quarantined_ = false;
    bool admission_external_ready_ = true, resource_blocked_ = false;
    Program program_;
    Scenario scenario_;
    std::ofstream journal_, training_, characterization_;
    std::deque<std::string> history_;
    std::map<std::string, uint64_t> coverage_, requirements_, assumptions_, unknowns_, dont_cares_;
    std::map<std::string, uint64_t> local_;
    std::vector<std::string> discrepancies_, results_, programs_;
    unsigned incomplete_results_ = 0, provisional_results_ = 0, invalid_results_ = 0, passed_results_ = 0;
    unsigned mismatch_results_ = 0, environment_results_ = 0, framework_results_ = 0;
    std::set<uint64_t> executed_, trained_, confirmed_, retired_;
    struct Learning {
        uint64_t id, pc, cycle;
        bool public_witness = false, inferred = false, canceled = false;
        uint64_t superseded = UINT64_MAX;
        uint64_t window = 0;
        std::string cancellation_reason;
    };
    std::vector<Learning> learning_;
    std::vector<Learning> learning_archive_;
    struct MemoryLife {
        uint64_t id = 0, window = 0, address = 0, accepted = 0;
        uint64_t response = UINT64_MAX, transfer = UINT64_MAX, delivery = UINT64_MAX;
        std::string cancellation;
    };
    uint64_t reset_window_ = 0;
    std::map<std::pair<uint64_t, uint64_t>, MemoryLife> memory_ledger_;
    std::vector<std::string> backend_ledger_;
    RasWitness ras_witness_;
    std::vector<std::string> ras_windows_;
    void capture_backend_obligations(const std::string &);
    void cancel_memory_obligations(const std::string &, bool younger_only = false);
    std::map<uint64_t, unsigned> site_updates_, cold_jals_;
    std::map<uint64_t, std::set<uint64_t>> ret_targets_;
    struct CellUpdate {
        uint64_t pc = 0, cycle = 0;
        bool taken = false;
    };
    std::map<unsigned, CellUpdate> last_pht_;
    std::map<unsigned, uint64_t> interference_;
    struct PublicDirection {
        uint64_t request = 0, dispatch = 0, pc = 0, generation = 0;
        unsigned counter = 0;
        bool hit = false;
    };
    struct Threshold {
        unsigned index, before, after;
        uint64_t cycle, generation;
        std::optional<PublicDirection> prior, later;
        bool credited = false;
    };
    std::vector<Threshold> thresholds_;
    std::map<std::pair<unsigned, uint64_t>, PublicDirection> public_directions_;
    void threshold_witnesses();
    uint64_t conflict_cycle_ = 0;
    unsigned grant_weight_ = 80, ready_weight_ = 75, response_weight_ = 90;
    void drive(const Inputs &);
    Inputs read_inputs() const;
    Outputs outputs() const;
    void compare(const Field &, uint64_t, const std::string &, const char *, bool &);
    bool sample(const Inputs &, const CompositionPlan &, const char *, bool allow_injection = true);
    void step(Inputs, bool schedule_backend = true);
    void reset();
    void collect_backend();
    void counter(const std::string &, uint64_t amount = 1);
    void error(const std::string &, const std::string &);

  public:
    RunStats stats;
    Simulator(Options, int, char **);
    ~Simulator();
    void run(const Scenario &, uint64_t limit = 0);
    int finish();
    const Config &config() const { return cfg_; }
    uint64_t cycles() const { return stats.cycles; }
    uint64_t observed(const std::string &suffix) const {
        uint64_t n = 0;
        for (const auto &item : coverage_)
            if (item.first.size() > suffix.size() &&
                item.first.compare(item.first.size() - suffix.size(), suffix.size(), suffix) == 0)
                n += item.second;
        return n;
    }
};
} // namespace len5::frontend
