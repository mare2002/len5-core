#include "checker.hh"
#include <algorithm>
#include <filesystem>
#include <iomanip>
#include <sstream>
#include <stdexcept>

namespace len5::diff {
const char *name(Stage s) {
    static const char *names[] = {"fetch",  "dispatch",   "execution", "memory",
                                  "commit", "checkpoint", "recovery",  "overall"};
    return names[static_cast<unsigned>(s)];
}
const char *name(Field s) {
    static const char *names[] = {"pc",
                                  "instruction",
                                  "rs1",
                                  "rs2",
                                  "rd",
                                  "write_enable",
                                  "rs1_value",
                                  "rs2_value",
                                  "result",
                                  "address",
                                  "mask",
                                  "size",
                                  "raw_data",
                                  "next_pc",
                                  "exception",
                                  "register_value",
                                  "rob_unique",
                                  "identity",
                                  "unauthorized_store",
                                  "timeout",
                                  "speculative_divergence",
                                  "authorization",
                                  "external_write",
                                  "load_index",
                                  "store_index",
                                  "squash",
                                  "csr",
                                  "unsupported",
                                  "completion",
                                  "store_order"};
    return names[static_cast<unsigned>(s)];
}
uint64_t data_mask(unsigned size) {
    return size == 8 ? ~uint64_t{0} : size ? (uint64_t{1} << (size * 8)) - 1 : 0;
}
Decode decode(uint32_t i) {
    Decode d;
    d.rs1 = (i >> 15) & 31;
    d.rs2 = (i >> 20) & 31;
    d.rd = (i >> 7) & 31;
    switch (i & 127) {
    case 0x37:
    case 0x17:
        d.write = true;
        break;
    case 0x13:
    case 0x1b:
        d.use_rs1 = d.write = true;
        break;
    case 0x33:
    case 0x3b:
        d.use_rs1 = d.use_rs2 = d.write = true;
        break;
    case 0x03:
        d.use_rs1 = d.write = d.load = true;
        d.size = 1u << ((i >> 12) & 3);
        break;
    case 0x23:
        d.use_rs1 = d.use_rs2 = d.store = true;
        d.size = 1u << ((i >> 12) & 3);
        break;
    case 0x63:
        d.use_rs1 = d.use_rs2 = d.branch = true;
        break;
    case 0x6f:
        d.write = d.jump = true;
        break;
    case 0x67:
        d.use_rs1 = d.write = d.jump = true;
        break;
    case 0x73: {
        d.csr = true;
        auto csr = i >> 20;
        auto f = (i >> 12) & 7;
        d.supported = f && (csr == 0x305 || (csr >= 0x340 && csr <= 0x343));
        d.use_rs1 = f && f < 4;
        d.write = f;
        break;
    }
    case 0x0f:
        d.supported = false;
        break;
    default:
        d.supported = false;
    }
    d.write &= d.rd != 0;
    return d;
}
Checker::Checker(Reference &s, const std::string &dir, Config c)
    : spike_(s), config_(c), directory_(dir) {
    std::filesystem::create_directories(dir);
    journal_.open(dir + "/events.bin", std::ios::binary);
    if (!journal_)
        throw std::runtime_error("cannot open differential event journal");
}
std::shared_ptr<ReferenceRecord> Checker::reference(uint64_t order) {
    while (next_reference_ <= order) {
        auto r = std::make_shared<ReferenceRecord>(spike_.step());
        r->order = next_reference_;
        references_[next_reference_++] = r;
    }
    return references_.at(order);
}
void Checker::event(const Ptr &p, Stage stage, Field field, uint64_t e, uint64_t a, Stamp t,
                    bool mismatch, bool confirmed, uint32_t index) {
    Event v;
    v.serial = serial_++;
    v.time = t.time;
    v.cycle = t.cycle;
    v.stage = stage;
    v.field = field;
    v.expected = e;
    v.actual = a;
    v.mismatch = mismatch;
    v.register_index = index;
    if (p) {
        v.id = p->instruction_id;
        v.pc = p->pc;
        v.instruction = p->instruction;
        v.rob = p->rob_idx;
        v.load = p->load_idx;
        v.store = p->store_idx;
    }
    if (p && p->reference)
        v.architectural_order = p->reference->order;
    journal_.write(reinterpret_cast<const char *>(&v), sizeof v);
    if (!journal_)
        throw std::runtime_error("differential journal write failed");
    if (mismatch) {
        if (p)
            p->discrepancies.push_back(discrepancies_.size());
        discrepancies_.push_back({v, confirmed, false, confirmed ? t : Stamp{}});
    }
}
void Checker::compare(const Ptr &p, Stage s, Field f, uint64_t e, uint64_t a, Stamp t,
                      bool confirmed, uint32_t index) {
    event(p, s, f, e, a, t, e != a, confirmed || (p && p->committed), index);
}
void Checker::source_at_dispatch(uint32_t rob, uint64_t value, Stamp t) {
    auto p = active(rob, t, Stage::dispatch);
    if (p && p->reference && p->reference->decoded.use_rs1)
        compare(p, Stage::dispatch, Field::rs1_value, p->reference->rs1_value, value, t);
}
Checker::Ptr Checker::active(uint32_t rob, Stamp t, Stage s) {
    auto i = active_rob_.find(rob);
    if (i == active_rob_.end() || i->second->committed || i->second->squashed) {
        compare({}, s, Field::identity, 1, 0, t, true);
        return {};
    }
    return i->second;
}
uint64_t Checker::fetch(uint64_t pc, uint32_t insn, Stamp t) {
    auto p = std::make_shared<TrackedInstruction>();
    p->instruction_id = next_id_++;
    p->pc = pc;
    p->instruction = insn;
    p->fetch_stamp = t;
    instructions_[p->instruction_id] = p;
    frontend_.push_back(p);
    auto r = reference(fetch_order_);
    if (!diverged_ && pc == r->pc) {
        p->reference = r;
        architectural_[fetch_order_++] = p;
        if (divergence_start_) {
            ++recoveries_;
            event(p, Stage::fetch, Field::speculative_divergence, 0, 0, t, false, false);
            divergence_start_.reset();
        }
        compare(p, Stage::fetch, Field::pc, r->pc, pc, t);
        compare(p, Stage::fetch, Field::instruction, r->instruction, insn, t);
    } else {
        diverged_ = true;
        if (!divergence_start_)
            divergence_start_ = t;
        event(p, Stage::fetch, Field::speculative_divergence, r->pc, pc, t, false, false);
    }
    return p->instruction_id;
}
void Checker::dispatch(uint32_t rob, uint64_t pc, uint32_t insn, uint8_t rs1, uint8_t rs2,
                       uint8_t rd, bool write, Stamp t) {
    if (frontend_.empty()) {
        compare({}, Stage::dispatch, Field::identity, 1, 0, t, true);
        return;
    }
    auto p = frontend_.front();
    frontend_.pop_front();
    p->dispatched = true;
    p->rob_idx = rob;
    p->dispatch_stamp = t;
    p->rs1 = rs1;
    p->rs2 = rs2;
    p->rd = rd;
    compare(p, Stage::dispatch, Field::pc, p->pc, pc, t);
    compare(p, Stage::dispatch, Field::instruction, p->instruction, insn, t);
    if (active_rob_.count(rob)) {
        compare(p, Stage::dispatch, Field::rob_unique, 0, 1, t, true);
        return;
    }
    active_rob_[rob] = p;
    if (auto r = p->reference) {
        if (r->decoded.use_rs1)
            compare(p, Stage::dispatch, Field::rs1, r->decoded.rs1, rs1, t);
        if (r->decoded.use_rs2)
            compare(p, Stage::dispatch, Field::rs2, r->decoded.rs2, rs2, t);
        compare(p, Stage::dispatch, Field::write_enable, r->decoded.write, write && rd != 0, t);
        if (r->decoded.write)
            compare(p, Stage::dispatch, Field::rd, r->decoded.rd, rd, t);
    }
}
void Checker::allocate(uint32_t rob, uint32_t index, bool store, Stamp t) {
    auto p = active(rob, t, Stage::memory);
    if (!p)
        return;
    auto &q = store ? stores_ : loads_;
    if (q.count(index)) {
        compare(p, Stage::memory, Field::identity, 0, 1, t, true);
        return;
    }
    q[index] = p;
    (store ? p->store_idx : p->load_idx) = index;
    event(p, Stage::memory, store ? Field::store_index : Field::load_index, index, index, t, false,
          false);
}
void Checker::execute(uint32_t rob, uint64_t rs1, uint64_t rs2, uint64_t result, bool exception,
                      bool mispredicted, Stamp t) {
    auto p = active(rob, t, Stage::execution);
    if (!p)
        return;
    p->executed = true;
    p->execution_stamp = t;
    p->rs1_value = rs1;
    p->rs2_value = rs2;
    p->rd_value = result;
    p->except_raised = exception;
    p->mispredicted = mispredicted;
    event(p, Stage::execution, Field::completion, 1, 1, t, false, false);
    if (auto r = p->reference) {
        if (r->decoded.use_rs1)
            compare(p, Stage::execution, Field::rs1_value, r->rs1_value, rs1, t);
        if (r->decoded.use_rs2)
            compare(p, Stage::execution, Field::rs2_value, r->rs2_value, rs2, t);
        if (r->decoded.write)
            compare(p, Stage::execution, Field::result, r->result, result, t);
        if (r->decoded.store)
            compare(p, Stage::execution, Field::address, r->address, result, t);
        compare(p, Stage::execution, Field::exception, r->trap, exception, t);
    }
    if (p->load_idx != no_index)
        loads_.erase(p->load_idx);
    // Store identity survives CDB/commit until the external transaction completes.
    if (p->store_idx != no_index && p->store_done)
        stores_.erase(p->store_idx);
}
void Checker::memory(uint32_t index, bool store, uint64_t addr, uint8_t size, uint8_t mask,
                     uint64_t raw, bool has_data, Stamp t) {
    auto &q = store ? stores_ : loads_;
    auto it = q.find(index);
    if (it == q.end()) {
        compare({}, Stage::memory, Field::identity, 1, 0, t, true);
        return;
    }
    auto p = it->second;
    if (auto r = p->reference) {
        compare(p, Stage::memory, Field::address, r->address, addr, t);
        compare(p, Stage::memory, Field::size, r->decoded.size, size, t);
        compare(p, Stage::memory, Field::mask, r->byte_mask, mask, t);
        if (has_data)
            compare(p, Stage::memory, Field::raw_data, r->raw_data,
                    raw & data_mask(r->decoded.size), t);
    }
}
void Checker::authorize(uint32_t index, uint32_t rob, Stamp t) {
    auto it = stores_.find(index);
    if (it == stores_.end()) {
        compare({}, Stage::memory, Field::identity, 1, 0, t, true);
        return;
    }
    auto p = it->second;
    compare(p, Stage::memory, Field::identity, p->rob_idx, rob, t, true);
    bool safe = p->reference && !p->squashed;
    // Clearance may precede store commit, but never unresolved control flow or faults.
    for (const auto &[id, older] : instructions_) {
        if (id >= p->instruction_id)
            break;
        if (older->squashed || older->committed || !older->dispatched)
            continue;
        auto d = decode(older->instruction);
        if ((d.branch || d.jump || d.load || d.csr || !d.supported) &&
            (!older->executed || older->except_raised || older->mispredicted))
            safe = false;
    }
    compare(p, Stage::memory, Field::unauthorized_store, 1, safe, t, true);
    p->authorized = safe;
    p->authorization_stamp = t;
    event(p, Stage::memory, Field::authorization, 1, safe, t, false, false);
}
void Checker::external_store(uint32_t index, uint64_t addr, uint8_t mask, uint64_t value, Stamp t) {
    auto it = stores_.find(index);
    if (it == stores_.end()) {
        compare({}, Stage::memory, Field::unauthorized_store, 1, 0, t, true);
        return;
    }
    auto p = it->second;
    compare(p, Stage::memory, Field::unauthorized_store, 1,
            p->authorized && !p->squashed && !p->external_write, t, true);
    p->external_write = true;
    if (auto r = p->reference) {
        // Overlapping stores must become externally visible in architectural
        // order even when their commit notifications arrive out of order.
        for (const auto &[id, older] : instructions_) {
            auto before = older->reference;
            if (older->squashed || older->external_write || !before || !before->decoded.store ||
                before->order >= r->order)
                continue;
            const bool overlap = (r->address - before->address < before->decoded.size) ||
                                 (before->address - r->address < r->decoded.size);
            if (overlap)
                compare(p, Stage::memory, Field::store_order, 1, 0, t, true);
        }
        compare(p, Stage::memory, Field::address, r->address, addr, t, true);
        compare(p, Stage::memory, Field::mask, r->byte_mask, mask, t, true);
        compare(p, Stage::memory, Field::raw_data, r->raw_data, value & data_mask(r->decoded.size),
                t, true);
    }
    confirm(p, t);
    event(p, Stage::memory, Field::external_write, 1, 1, t, false, true);
}
void Checker::store_response(uint32_t index, bool exception, Stamp t) {
    auto it = stores_.find(index);
    if (it == stores_.end()) {
        compare({}, Stage::memory, Field::identity, 1, 0, t, true);
        return;
    }
    auto p = it->second;
    p->store_done = true;
    compare(p, Stage::memory, Field::external_write, 1, p->external_write, t, true);
    compare(p, Stage::memory, Field::exception, 0, exception, t, true);
    if (p->executed)
        stores_.erase(it);
}
void Checker::load_request(uint32_t index, uint64_t addr, uint8_t mask, Stamp t) {
    auto it = loads_.find(index);
    if (it == loads_.end()) {
        compare({}, Stage::memory, Field::identity, 1, 0, t, true);
        return;
    }
    auto p = it->second;
    if (p->reference) {
        compare(p, Stage::memory, Field::address, p->reference->address, addr, t);
        compare(p, Stage::memory, Field::mask, p->reference->byte_mask, mask, t);
    }
    load_transactions_[index].push_back({p, addr, mask});
}
void Checker::load_response(uint32_t index, uint64_t data, bool exception, Stamp t) {
    auto it = load_transactions_.find(index);
    if (it == load_transactions_.end() || it->second.empty()) {
        compare({}, Stage::memory, Field::identity, 1, 0, t, true);
        return;
    }
    auto transaction = it->second.front();
    it->second.pop_front();
    if (it->second.empty())
        load_transactions_.erase(it);
    auto p = transaction.instruction;
    // Memory pipelines are NOT flushed by a backend flush. Keep transaction
    // tombstones until the response, independently of reuse of the LQ index.
    if (p->squashed)
        return;
    if (auto r = p->reference) {
        compare(p, Stage::memory, Field::raw_data, r->raw_data, data & data_mask(r->decoded.size),
                t);
        compare(p, Stage::memory, Field::exception, r->trap, exception, t);
    }
}
void Checker::confirm(const Ptr &p, Stamp t) {
    for (auto n : p->discrepancies) {
        auto &d = discrepancies_[n];
        if (!d.confirmed) {
            d.confirmed = true;
            d.confirmation = t;
        }
    }
}
void Checker::commit(uint32_t rob, uint64_t pc, uint32_t insn, uint8_t rd, bool write,
                     uint64_t value, bool exception, Stamp t) {
    auto p = active(rob, t, Stage::commit);
    if (!p)
        return;
    p->committed = true;
    p->commit_stamp = t;
    active_rob_.erase(rob); // Exactly the requested active-ROB lifetime; no generations.
    ++committed_count_;
    last_progress_ = t;
    event(p, Stage::commit, Field::completion, 1, 1, t, false, true);
    confirm(p, t);
    if (!p->reference) {
        compare(p, Stage::commit, Field::speculative_divergence, 0, 1, t, true);
        return;
    }
    auto r = p->reference;
    if (!r->unsupported.empty()) {
        stop(r->unsupported, t, true);
        return;
    }
    if (r->order != prefix_)
        ++out_of_order_commits_;
    compare(p, Stage::commit, Field::pc, r->pc, pc, t, true);
    compare(p, Stage::commit, Field::instruction, r->instruction, insn, t, true);
    compare(p, Stage::commit, Field::write_enable, r->decoded.write, write && rd != 0, t, true);
    if (r->decoded.write) {
        compare(p, Stage::commit, Field::rd, r->decoded.rd, rd, t, true);
        compare(p, Stage::commit, Field::result, r->result, value, t, true);
    }
    compare(p, Stage::commit, Field::exception, r->trap, exception, t, true);
    newest_commit_ = std::max(newest_commit_, r->order + 1);
    while (architectural_.count(prefix_) && architectural_.at(prefix_)->committed)
        ++prefix_;
    // Resolve adjacent architectural orders independently of notification order.
    for (auto order : {r->order, r->order ? r->order - 1 : r->order}) {
        auto a = architectural_.find(order), b = architectural_.find(order + 1);
        if (a != architectural_.end() && b != architectural_.end() && a->second->committed &&
            b->second->committed && !a->second->next_pc_checked) {
            compare(a->second, Stage::commit, Field::next_pc, a->second->reference->next_pc,
                    b->second->pc, t, true);
            a->second->next_pc_checked = true;
        }
    }
}
void Checker::checkpoint(const std::array<uint64_t, 32> &regs, Stamp t,
                         const std::map<uint32_t, uint64_t> &csrs) {
    if (prefix_ == 0 || prefix_ != newest_commit_ || prefix_ == last_checkpoint_)
        return;
    auto p = architectural_.at(prefix_ - 1);
    for (unsigned i = 0; i < 32; ++i) {
        compare(p, Stage::checkpoint, Field::register_value, p->reference->registers[i], regs[i], t,
                true, i);
    }
    for (const auto &[addr, value] : p->reference->csrs) {
        auto it = csrs.find(addr);
        if (it == csrs.end())
            stop("missing observed CSR at architectural checkpoint", t, true);
        else
            compare(p, Stage::checkpoint, Field::csr, value, it->second, t, true, addr);
    }
    for (auto &[order, q] : architectural_)
        if (order < prefix_)
            q->checkpoint_checked = true;
    last_checkpoint_ = prefix_;
    ++checkpoint_count_;
    prune();
}
void Checker::squash(const Ptr &p, Stamp t) {
    if (p->committed)
        return;
    if (p->external_write)
        compare(p, Stage::recovery, Field::unauthorized_store, 0, 1, t, true);
    p->squashed = true;
    ++squashed_count_;
    if (p->rob_idx != no_index)
        active_rob_.erase(p->rob_idx);
    if (p->load_idx != no_index)
        loads_.erase(p->load_idx);
    if (p->store_idx != no_index)
        stores_.erase(p->store_idx);
    if (p->reference)
        architectural_.erase(p->reference->order);
    for (auto n : p->discrepancies)
        discrepancies_[n].squashed = true;
    event(p, Stage::recovery, Field::squash, 1, 1, t, false, false);
}
void Checker::reset_cursor() {
    fetch_order_ = prefix_;
    while (architectural_.count(fetch_order_))
        ++fetch_order_;
    diverged_ = false; // A match, not this flush, clears the recovery timer.
}
void Checker::flush_frontend(Stamp t) {
    for (auto &p : frontend_)
        squash(p, t);
    frontend_.clear();
    reset_cursor();
    if (!divergence_start_)
        divergence_start_ = t;
    prune();
}
void Checker::flush_backend(Stamp t) {
    std::vector<Ptr> victims;
    for (auto &[rob, p] : active_rob_)
        victims.push_back(p);
    for (auto &p : victims)
        squash(p, t);
    reset_cursor();
    prune();
}
void Checker::redirect(uint64_t pc, Stamp t) {
    event({}, Stage::recovery, Field::next_pc, 0, pc, t, false, false);
}
void Checker::resolve_branch(uint32_t rob, uint64_t next, bool mispredicted, Stamp t) {
    auto branch = active(rob, t, Stage::execution);
    if (!branch)
        return;
    if (branch->reference)
        compare(branch, Stage::execution, Field::next_pc, branch->reference->next_pc, next, t);
    if (!mispredicted)
        return;
    // LEN5 redirects/flushed the frontend before flushing the backend. Even if
    // prediction selected the correct PC (e.g. a taken branch to PC+4), younger
    // dispatches will be killed later. Release their architectural associations
    // now so the refetched path can reuse those ORDERS, retaining active ROB tags.
    for (auto &[id, p] : instructions_)
        if (id > branch->instruction_id && !p->squashed) {
            if (p->committed || p->external_write)
                compare(p, Stage::recovery, Field::squash, 0, 1, t, true);
            if (p->reference) {
                architectural_.erase(p->reference->order);
                p->reference.reset();
            }
            for (auto n : p->discrepancies)
                if (!discrepancies_[n].confirmed)
                    discrepancies_[n].squashed = true;
        }
    diverged_ = true;
    if (!divergence_start_)
        divergence_start_ = t;
    redirect(next, t);
}
void Checker::tick(Stamp t) {
    if (divergence_start_ && t.cycle - divergence_start_->cycle >= config_.recovery_cycles)
        stop("frontend recovery timeout: no accepted return to the architectural path", t);
    if (t.cycle - last_progress_.cycle >= config_.progress_cycles)
        stop("no architectural commit progress", t);
}
void Checker::stop(const std::string &reason, Stamp t, bool unsupported) {
    if (!stop_reason_.empty())
        return;
    stop_reason_ = reason;
    unsupported_ = unsupported;
    event({}, Stage::overall, unsupported ? Field::unsupported : Field::timeout, 0, 1, t,
          !unsupported, true);
}
void Checker::prune() {
    for (auto it = instructions_.begin(); it != instructions_.end();) {
        auto p = it->second;
        if (p->squashed || (p->committed && p->next_pc_checked && p->checkpoint_checked &&
                            (p->store_idx == no_index || p->store_done))) {
            if (p->reference && !p->squashed)
                architectural_.erase(p->reference->order);
            it = instructions_.erase(it);
        } else
            ++it;
    }
    // Retain uncommitted references for replay after flush, plus the latest checkpoint.
    auto retain = prefix_ ? prefix_ - 1 : 0;
    for (auto it = references_.begin(); it != references_.end() && it->first < retain;)
        it = references_.erase(it);
}
bool Checker::failed() const {
    return std::any_of(discrepancies_.begin(), discrepancies_.end(),
                       [](const auto &d) { return d.confirmed; });
}
int Checker::status() const {
    return failed() ? 1 : unsupported_ ? 2 : (!finished_ || !stop_reason_.empty()) ? 3 : 0;
}
std::optional<Event> Checker::first_error() const {
    std::optional<Event> result;
    for (const auto &d : discrepancies_)
        if (d.confirmed && (!result || d.event.time < result->time))
            result = d.event;
    return result;
}
std::shared_ptr<const TrackedInstruction> Checker::instruction(uint64_t id) const {
    auto it = instructions_.find(id);
    return it == instructions_.end() ? nullptr : it->second;
}
static std::string quote(const std::string &s) {
    std::ostringstream o;
    o << '"';
    for (unsigned char c : s) {
        if (c == '"' || c == '\\')
            o << '\\' << c;
        else if (c < 32)
            o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << unsigned(c);
        else
            o << c;
    }
    o << '"';
    return o.str();
}
void Checker::finish(bool normal, Stamp t) {
    if (!normal && !stopped())
        stop("simulation ended without normal program exit", t);
    if (normal && !stopped() && !committed_count_)
        stop("simulation exited without checked commits", t);
    if (normal && !stopped() && prefix_ != newest_commit_)
        stop("simulation exited with an incomplete architectural checkpoint", t);
    for (const auto &[idx, p] : stores_)
        if (p->committed && !p->store_done && !stopped())
            stop("committed store has no external completion", t);
    finished_ = true;
    journal_.close();
    report();
}
void Checker::report() {
    std::ofstream f(directory_ + "/report.json");
    uint64_t pending_next_pc = 0;
    for (const auto &[id, p] : instructions_)
        if (p->committed && !p->next_pc_checked)
            ++pending_next_pc;
    f << "{\n  \"status\": "
      << quote(status() == 0   ? "passed"
               : status() == 1 ? "failed"
               : status() == 2 ? "unsupported"
                               : "incomplete")
      << ",\n  \"reason\": " << quote(stop_reason_) << ",\n  \"committed\": " << committed_count_
      << ",\n  \"checkpoints\": " << checkpoint_count_
      << ",\n  \"active_at_exit\": " << active_rob_.size()
      << ",\n  \"deferred_next_pc_pending\": " << pending_next_pc
      << ",\n  \"pending_stores\": " << stores_.size()
      << ",\n  \"out_of_order_commits\": " << out_of_order_commits_
      << ",\n  \"squashed\": " << squashed_count_ << ",\n  \"frontend_recoveries\": " << recoveries_
      << ",\n  \"timestamp_unit\": \"original FST tick\",\n  \"discrepancies\": [";
    bool first = true;
    for (const auto &d : discrepancies_) {
        const auto &e = d.event;
        if (!first)
            f << ',';
        first = false;
        f << "\n    {\"instruction_id\":" << e.id << ",\"pc\":" << e.pc
          << ",\"instruction\":" << e.instruction << ",\"rob_idx\":" << e.rob
          << ",\"architectural_order\":" << e.architectural_order << ",\"load_idx\":" << e.load
          << ",\"store_idx\":" << e.store << ",\"stage\":" << quote(name(e.stage))
          << ",\"field\":" << quote(name(e.field)) << ",\"register_index\":" << e.register_index
          << ",\"expected\":" << e.expected << ",\"actual\":" << e.actual
          << ",\"cycle\":" << e.cycle << ",\"event_time\":" << e.time
          << ",\"confirmed\":" << (d.confirmed ? "true" : "false")
          << ",\"squashed\":" << (d.squashed ? "true" : "false")
          << ",\"confirmation_time\":" << d.confirmation.time << '}';
    }
    f << "\n  ]\n}\n";
    if (!f)
        throw std::runtime_error("cannot write differential report");
}
} // namespace len5::diff
