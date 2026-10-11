#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace len5::diff {
constexpr uint32_t no_index = ~uint32_t{0};
struct Stamp {
    uint64_t cycle = 0, time = 0;
};
enum class Stage : uint32_t {
    fetch,
    dispatch,
    execution,
    memory,
    commit,
    checkpoint,
    recovery,
    overall
};
enum class Field : uint32_t {
    pc,
    instruction,
    rs1,
    rs2,
    rd,
    write_enable,
    rs1_value,
    rs2_value,
    result,
    address,
    mask,
    size,
    raw_data,
    next_pc,
    exception,
    register_value,
    rob_unique,
    identity,
    unauthorized_store,
    timeout,
    speculative_divergence,
    authorization,
    external_write,
    load_index,
    store_index,
    squash,
    csr,
    unsupported,
    completion,
    store_order,
    rs3,
    rs3_value,
    register_bank,
    fp_register_value
};
const char *name(Stage);
const char *name(Field);
struct Decode {
    uint8_t rs1 = 0, rs2 = 0, rs3 = 0, rd = 0, size = 0;
    bool fp_rs1 = false, fp_rs2 = false, fp_rd = false, use_rs3 = false;
    bool use_rs1 = false, use_rs2 = false, write = false, load = false, store = false,
         branch = false, jump = false, csr = false, supported = true;
};
Decode decode(uint32_t instruction);
uint64_t data_mask(unsigned size);
struct ReferenceRecord {
    uint64_t order = 0, pc = 0, next_pc = 0;
    uint32_t instruction = 0;
    uint8_t length = 4, privilege = 3;
    Decode decoded;
    uint64_t rs1_value = 0, rs2_value = 0, rs3_value = 0, result = 0, address = 0, raw_data = 0;
    uint8_t byte_mask = 0;
    bool trap = false;
    uint64_t cause = 0, tval = 0;
    std::array<uint64_t, 32> registers{}, fp_registers{};
    bool has_fp = false;
    std::map<uint32_t, uint64_t> csr_changes;
    std::map<uint32_t, uint64_t> csrs;
    std::string unsupported;
};
class Reference {
  public:
    virtual ~Reference() = default;
    virtual ReferenceRecord step() = 0;
};
struct TrackedInstruction {
    uint64_t instruction_id = 0, pc = 0;
    uint32_t instruction = 0, rob_idx = no_index, load_idx = no_index, store_idx = no_index;
    uint8_t instruction_length = 4, rs1 = 0, rs2 = 0, rd = 0;
    uint64_t rs1_value = 0, rs2_value = 0, rd_value = 0;
    bool fetched = true, dispatched = false, executed = false, committed = false, squashed = false;
    bool authorized = false, external_write = false, store_done = false, next_pc_checked = false;
    bool checkpoint_checked = false, except_raised = false, mispredicted = false;
    bool beyond_reference_boundary = false;
    Stamp fetch_stamp, dispatch_stamp, execution_stamp, commit_stamp, authorization_stamp;
    std::shared_ptr<ReferenceRecord> reference;
    std::vector<size_t> discrepancies;
};
// Fixed-size on-disk journal. Same-time events get distinct lane numbers during annotation.
struct Event {
    uint64_t serial = 0, time = 0, cycle = 0, id = 0, pc = 0, expected = 0, actual = 0;
    uint64_t architectural_order = ~uint64_t{0};
    uint32_t instruction = 0, rob = no_index, load = no_index, store = no_index;
    uint32_t register_index = no_index;
    Stage stage = Stage::overall;
    Field field = Field::identity;
    uint32_t mismatch = 0;
};
struct Discrepancy {
    Event event;
    bool confirmed = false, squashed = false;
    Stamp confirmation;
};
struct Config {
    uint64_t recovery_cycles = 10000, progress_cycles = 10000;
    bool record_events = true;
};
class Checker {
  public:
    Checker(Reference &, const std::string &directory, Config = {});
    uint64_t fetch(uint64_t pc, uint32_t instruction, Stamp);
    void dispatch(uint32_t rob, uint64_t pc, uint32_t instruction, uint8_t rs1, uint8_t rs2,
                  uint8_t rd, bool write, Stamp, uint8_t rs3 = 0);
    void allocate(uint32_t rob, uint32_t index, bool store, Stamp);
    void execute(uint32_t rob, uint64_t rs1, uint64_t rs2, uint64_t result, bool exception,
                 bool mispredicted, Stamp, uint64_t rs3 = 0);
    void memory(uint32_t index, bool store, uint64_t address, uint8_t size, uint8_t mask,
                uint64_t raw, bool has_data, Stamp);
    void authorize(uint32_t index, uint32_t rob, Stamp);
    void external_store(uint32_t index, uint64_t address, uint8_t mask, uint64_t data, Stamp);
    void store_response(uint32_t index, bool exception, Stamp);
    void load_request(uint32_t index, uint64_t address, uint8_t mask, Stamp);
    void load_response(uint32_t index, uint64_t data, bool exception, Stamp);
    void commit(uint32_t rob, uint64_t pc, uint32_t instruction, uint8_t rd, bool write,
                uint64_t result, bool exception, Stamp, bool fp_write = false);
    void checkpoint(const std::array<uint64_t, 32> &registers, Stamp,
                    const std::map<uint32_t, uint64_t> &csrs = {},
                    const std::array<uint64_t, 32> *fp_registers = nullptr);
    void source_at_dispatch(uint32_t rob, uint64_t value, Stamp);
    void flush_frontend(Stamp);
    void flush_backend(Stamp);
    void redirect(uint64_t pc, Stamp);
    void resolve_branch(uint32_t rob, uint64_t next_pc, bool mispredicted, Stamp);
    void tick(Stamp);
    void stop(const std::string &reason, Stamp, bool unsupported = false);
    void finish(bool normal_exit, Stamp);
    bool failed() const;
    bool stopped() const { return !stop_reason_.empty() || failed(); }
    int status() const;
    const std::vector<Discrepancy> &discrepancies() const { return discrepancies_; }
    const std::string &directory() const { return directory_; }
    std::optional<Event> first_error() const;
    size_t active_count() const { return active_rob_.size(); }
    uint64_t committed_count() const { return committed_count_; }
    uint64_t checkpoint_count() const { return checkpoint_count_; }
    std::shared_ptr<const TrackedInstruction> instruction(uint64_t id) const;

  private:
    using Ptr = std::shared_ptr<TrackedInstruction>;
    Reference &spike_;
    Config config_;
    std::string directory_, stop_reason_;
    bool unsupported_ = false, finished_ = false, diverged_ = false;
    std::optional<Stamp> divergence_start_;
    std::optional<uint64_t> reference_boundary_;
    Stamp last_progress_{};
    uint64_t next_id_ = 1, next_reference_ = 0, fetch_order_ = 0, prefix_ = 0, newest_commit_ = 0;
    uint64_t serial_ = 0, committed_count_ = 0, checkpoint_count_ = 0, last_checkpoint_ = 0;
    uint64_t out_of_order_commits_ = 0, squashed_count_ = 0, recoveries_ = 0;
    std::map<uint64_t, Ptr> instructions_, architectural_;
    std::deque<Ptr> frontend_;
    std::map<uint32_t, Ptr> active_rob_, loads_, stores_;
    struct LoadTransaction {
        Ptr instruction;
        uint64_t address;
        uint8_t mask;
    };
    std::map<uint32_t, std::deque<LoadTransaction>> load_transactions_;
    std::map<uint64_t, std::shared_ptr<ReferenceRecord>> references_;
    std::ofstream journal_;
    std::vector<Discrepancy> discrepancies_;
    std::shared_ptr<ReferenceRecord> reference(uint64_t);
    Ptr active(uint32_t, Stamp, Stage);
    void compare(const Ptr &, Stage, Field, uint64_t expected, uint64_t actual, Stamp,
                 bool confirmed = false, uint32_t index = no_index);
    void event(const Ptr &, Stage, Field, uint64_t expected, uint64_t actual, Stamp, bool mismatch,
               bool confirmed, uint32_t index = no_index);
    void confirm(const Ptr &, Stamp);
    void squash(const Ptr &, Stamp);
    void reset_cursor();
    void prune();
    void report();
};
} // namespace len5::diff
