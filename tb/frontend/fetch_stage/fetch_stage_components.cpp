// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// New semantic predictor/backend; existing PC/EJU/RAS/memory models are linked
// unchanged.
#include "fetch_stage_components.hh"
#include <algorithm>
#include <limits>
#include <sstream>

namespace len5::frontend {
uint64_t split_seed(uint64_t x) {
    x += UINT64_C(0x9e3779b97f4a7c15);
    x = (x ^ (x >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
    x = (x ^ (x >> 27)) * UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
uint64_t bounded(std::mt19937_64 &r, uint64_t n) {
    if (!n)
        throw std::invalid_argument("zero RNG bound");
    const auto threshold = uint64_t(-n) % n;
    for (;;) {
        auto x = r();
        if (x >= threshold)
            return x % n;
    }
}
void Config::validate() const {
    if ((lanes != 1 && lanes != 2 && lanes != 4 && lanes != 8) || depth != 2 || ras_depth != 4 || hlen < 2 ||
        hlen > 16 || (1u << hlen) <= lanes || btb_bits < 1 || btb_bits > 16 || initial > 3 || boot % 4 ||
        iq < lanes || !branch_capacity || !alu_capacity || rob < iq)
        throw std::invalid_argument("FE01/FEQ11: unsupported source configuration (N=1/2/4/8, depth2/RAS4, "
                                    "aligned BOOT, positive predictor widths)");
}
Predictor::Predictor(Config c) : cfg_(c), targets_(size_t(1) << c.btb_bits), counters_(size_t(1) << c.hlen), generations_(size_t(1) << c.hlen) {
    c.validate();
    reset();
}
void Predictor::reset() {
    std::fill(targets_.begin(), targets_.end(), Entry{});
    std::fill(counters_.begin(), counters_.end(), cfg_.initial);
    history_ = 0;
    std::fill(generations_.begin(), generations_.end(), 0);
}
Prediction Predictor::predict(uint64_t pc) const {
    auto w = pc / 4;
    const auto &e = targets_[w % targets_.size()];
    return {pc, e.target * 4, e.valid && e.tag == w / targets_.size(), counters_[index(pc)] >= 2};
}
PredictorUpdate Predictor::update(const Resolution &r) {
    PredictorUpdate u;
    u.history = history_;
    u.index = index(r.pc);
    u.before = counters_[u.index];
    u.after = r.taken ? std::min(3u, u.before + 1) : (u.before ? u.before - 1 : 0);
    counters_[u.index] = u.after;
    ++generations_[u.index];
    history_ = unsigned((history_ * 2 + unsigned(r.taken)) % counters_.size());
    auto w = r.pc / 4;
    u.row = unsigned(w % targets_.size());
    auto &e = targets_[u.row];
    u.deletion = r.mispredict && !r.taken;
    u.replacement = e.valid && e.tag != w / targets_.size();
    if (u.deletion)
        e = {};
    else
        e = {true, w / targets_.size(), r.target / 4};
    return u;
}
void LatencyOptions::validate() const {
    static const std::set<std::string> names = {"uniform",         "fixed",           "triangular-early",
                                                "triangular-late", "triangular-mode", "truncated-geometric",
                                                "bimodal"};
    if (!minimum || minimum > maximum || maximum > 1000000 || !names.count(distribution) ||
        (fixed && (fixed < minimum || fixed > maximum)) || (mode && (mode < minimum || mode > maximum)) ||
        !geo_u || geo_u > geo_v || geo_v > 1000000 || !short_v || short_u > short_v)
        throw std::invalid_argument("FE18: invalid latency parameters");
    if (short_min || short_max || long_min || long_max)
        if (short_min < minimum || short_min > short_max || short_max > maximum || long_min < minimum ||
            long_min > long_max || long_max > maximum)
            throw std::invalid_argument("FE18: invalid bimodal intervals");
    if (distribution == "truncated-geometric" &&
        uint64_t(geo_v) > uint64_t(geo_u) * (maximum - minimum + 1) * 10000)
        throw std::invalid_argument("FE18: geometric acceptance too small for bounded sampler");
}
std::string LatencyOptions::json() const {
    std::ostringstream s;
    s << "{\"minimum\":" << minimum << ",\"maximum\":" << maximum
      << ",\"distribution\":" << json_quote(distribution) << ",\"fixed\":" << fixed << ",\"mode\":" << mode
      << ",\"geo_u\":" << geo_u << ",\"geo_v\":" << geo_v << ",\"short_u\":" << short_u
      << ",\"short_v\":" << short_v << ",\"short_min\":" << short_min << ",\"short_max\":" << short_max
      << ",\"long_min\":" << long_min << ",\"long_max\":" << long_max << '}';
    return s.str();
}
LatencySampler::LatencySampler(LatencyOptions o, uint64_t seed)
    : options_(o), rng_(split_seed(seed ^ UINT64_C(0x455845434c4154))) {
    o.validate();
    if (o.distribution.rfind("triangular", 0) == 0) {
        uint64_t total = 0, m = o.mode ? o.mode : o.minimum + (o.maximum - o.minimum) / 2;
        for (uint64_t k = o.minimum; k <= o.maximum; ++k) {
            uint64_t w = o.distribution == "triangular-early"  ? o.maximum - k + 1
                         : o.distribution == "triangular-late" ? k - o.minimum + 1
                         : k <= m                              ? (k - o.minimum + 1) * (o.maximum - m + 1)
                                                               : (o.maximum - k + 1) * (m - o.minimum + 1);
            if (UINT64_MAX - total < w)
                throw std::invalid_argument("latency CDF overflow");
            cdf_.push_back(total += w);
        }
    }
}
uint64_t LatencySampler::sample() {
    const auto &o = options_;
    const auto n = o.maximum - o.minimum + 1;
    if (o.distribution == "fixed")
        return o.fixed ? o.fixed : o.maximum;
    if (o.distribution == "uniform")
        return o.minimum + bounded(rng_, n);
    if (!cdf_.empty())
        return o.minimum + uint64_t(std::upper_bound(cdf_.begin(), cdf_.end(), bounded(rng_, cdf_.back())) -
                                    cdf_.begin());
    if (o.distribution == "truncated-geometric") {
        for (unsigned retry = 0; retry < 1000000; ++retry)
            for (uint64_t k = o.minimum; k <= o.maximum; ++k)
                if (bounded(rng_, o.geo_v) < o.geo_u)
                    return k;
        throw std::runtime_error("FE18: geometric retry budget exhausted; no biased fallback");
    }
    const bool short_part = bounded(rng_, o.short_v) < o.short_u;
    uint64_t lo, hi;
    if (o.short_min || o.short_max || o.long_min || o.long_max) {
        lo = short_part ? o.short_min : o.long_min;
        hi = short_part ? o.short_max : o.long_max;
    } else {
        lo = short_part ? o.minimum : o.minimum + 3 * (n - 1) / 4;
        hi = short_part ? o.minimum + (n - 1) / 8 : o.maximum;
    }
    return lo + bounded(rng_, hi - lo + 1);
}
static bool less_signed(uint64_t a, uint64_t b) {
    return (a ^ UINT64_C(0x8000000000000000)) < (b ^ UINT64_C(0x8000000000000000));
}
Semantic evaluate(uint32_t word, uint64_t pc, uint64_t a, uint64_t b) {
    Semantic s;
    s.decoded = early::decode(word);
    auto d = s.decoded;
    s.rd = d.rd;
    s.next = pc + 4;
    if (!d.valid)
        throw std::invalid_argument("FE16: unsupported instruction " + hex64(word));
    if (!d.rs1)
        a = 0;
    if (!d.rs2)
        b = 0;
    const auto op = word & 127;
    const unsigned f7 = word >> 25;
    if (d.control()) {
        s.control = true;
        auto o = early::outcome(word, pc, a, b);
        s.taken = o.taken;
        s.target = o.target;
        s.next = o.taken ? o.target : pc + 4;
        s.writes = d.kind != early::Kind::Branch && d.rd != 0;
        s.value = pc + 4;
    } else if (op == 0x13) {
        s.writes = d.rd != 0;
        uint64_t imm = uint64_t(d.immediate);
        switch (d.funct3) {
        case 0:
            s.value = a + imm;
            break;
        case 7:
            s.value = a & imm;
            break;
        case 6:
            s.value = a | imm;
            break;
        case 4:
            s.value = a ^ imm;
            break;
        case 2:
            s.value = less_signed(a, imm);
            break;
        case 3:
            s.value = a < imm;
            break;
        case 1:
            s.value = a << ((word >> 20) & 63);
            break;
        case 5: {
            unsigned sh = (word >> 20) & 63;
            s.value = a >> sh;
            if ((word >> 30) & 1)
                if (sh && (a >> 63))
                    s.value |= UINT64_MAX << (64 - sh);
            break;
        }
        default:
            throw std::invalid_argument("unsupported immediate");
        }
    } else if (op == 0x33 && (f7 == 0 || f7 == 32)) {
        s.writes = d.rd != 0;
        switch (d.funct3) {
        case 0:
            s.value = f7 == 32 ? a - b : a + b;
            break;
        case 7:
            s.value = a & b;
            break;
        case 6:
            s.value = a | b;
            break;
        case 4:
            s.value = a ^ b;
            break;
        case 2:
            s.value = less_signed(a, b);
            break;
        case 3:
            s.value = a < b;
            break;
        case 1:
            s.value = a << (b & 63);
            break;
        case 5: {
            unsigned sh = b & 63;
            s.value = a >> sh;
            if (f7 == 32 && sh && (a >> 63))
                s.value |= UINT64_MAX << (64 - sh);
            break;
        }
        default:
            throw std::invalid_argument("unsupported ALU");
        }
    } else if (op == 0x37 || op == 0x17) {
        s.writes = d.rd != 0;
        s.value = uint64_t(d.immediate) + (op == 0x17 ? pc : 0);
    } else
        throw std::invalid_argument("FE16: instruction has no execution semantics; "
                                    "opaque payload cannot influence backend");
    return s;
}
uint32_t immediate(unsigned f, unsigned rd, unsigned rs, int64_t v) {
    if (f > 7 || rd > 31 || rs > 31 || v < -2048 || v > 2047)
        throw std::invalid_argument("invalid immediate encoding");
    return ((uint32_t(v) & 4095) << 20) | (rs << 15) | (f << 12) | (rd << 7) | 0x13;
}
Backend::Backend(Config c, LatencyOptions l, uint64_t seed) : cfg_(c), sampler_(l, seed) {
    c.validate();
    reset();
}
void Backend::reset() {
    committed_.fill(0);
    for (auto &v : versions_)
        v.clear();
    records_.clear();
    events_.clear();
    iterations_.clear();
    accepted_bundles_.clear();
    epoch_ = freeze_id_ = resume_cycle_ = 0;
    expected_retire_pc_ = cfg_.boot;
    stats = {};
    last_advance_ = UINT64_MAX;
}
uint64_t Backend::read(unsigned reg, uint64_t &dependency) const {
    dependency = 0;
    if (!reg)
        return 0;
    for (auto i = versions_[reg].rbegin(); i != versions_[reg].rend(); ++i) {
        const auto &r = records_.at(*i - 1);
        if (!r.canceled && !r.retired) {
            dependency = r.id;
            return r.semantic.value;
        }
    }
    return committed_[reg];
}
void validate_resources(const Config &c, Resources r) {
    if (r.iq > c.iq || r.rob > c.rob || r.branch > c.branch_capacity || r.alu > c.alu_capacity ||
        r.branch + r.alu > r.rob)
        throw std::logic_error("FE17: backend resource capacity/conservation violation");
}
void validate_lifecycle(const Instruction &r) {
    if ((r.issued && (r.issue <= r.dispatch)) ||
        (r.start != UINT64_MAX && (!r.issued || r.start <= r.issue || r.start < r.earliest ||
                                  r.start < r.dependency_ready)) ||
        (r.completed && (r.start == UINT64_MAX || r.execute <= r.start)) ||
        (r.publication != UINT64_MAX && (!r.completed || r.publication <= r.execute)) ||
        (r.retired && (r.canceled || r.publication == UINT64_MAX || r.retire <= r.publication)))
        throw std::logic_error("FE17/18: backend lifecycle/latency violation");
}
void validate_backend_history(const std::vector<Instruction> &records) {
    std::set<uint64_t> ids;
    std::map<uint64_t, unsigned> issues, publications, retirements, alu_starts, branch_starts;
    for (const auto &r : records) {
        if (!r.id || !ids.insert(r.id).second)
            throw std::logic_error("FE17: duplicate dynamic identity/completion/retirement record");
        validate_lifecycle(r);
        if (r.issued && ++issues[r.issue] > 1)
            throw std::logic_error("FE17: excess scalar issue bandwidth");
        if (r.start != UINT64_MAX && ++(r.semantic.control ? branch_starts : alu_starts)[r.start] > 1)
            throw std::logic_error("FE17: excess per-unit execution initiation");
        if (r.publication != UINT64_MAX && ++publications[r.publication] > 1)
            throw std::logic_error("FE17: excess CDB result publication");
        if (r.retired && ++retirements[r.retire] > 1)
            throw std::logic_error("FE17: excess retirement bandwidth");
        for (auto id : {r.dep_a, r.dep_b})
            if (id) {
                auto p = std::find_if(records.begin(), records.end(), [&](const Instruction &o) { return o.id == id; });
                if (p == records.end() || id >= r.id || (!r.canceled && p->canceled) ||
                    (r.start != UINT64_MAX && (p->publication == UINT64_MAX || r.start <= p->publication)))
                    throw std::logic_error("FE16/17: invalid dependency/forwarding history");
            }
    }
}
Resources Backend::resources() const {
    Resources s;
    for (const auto &r : records_)
        if (!r.canceled && !r.retired) {
            if (!r.issued)
                ++s.iq;
            else {
                ++s.rob;
                if (r.publication == UINT64_MAX)
                    r.semantic.control ? ++s.branch : ++s.alu;
            }
        }
    return s;
}
void Backend::audit(bool sample) {
    auto r = resources();
    validate_resources(cfg_, r);
    if (sample) {
        stats.iq_high = std::max<uint64_t>(stats.iq_high, r.iq);
        stats.rob_high = std::max<uint64_t>(stats.rob_high, r.rob);
        stats.branch_high = std::max<uint64_t>(stats.branch_high, r.branch);
        stats.alu_high = std::max<uint64_t>(stats.alu_high, r.alu);
        stats.inflight_high = std::max<uint64_t>(stats.inflight_high, r.iq + r.rob);
    }
    uint64_t issued = 0, started = 0, completed = 0, published = 0, retired = 0, canceled = 0;
    for (const auto &i : records_) {
        validate_lifecycle(i);
        issued += i.issued;
        started += i.start != UINT64_MAX;
        completed += i.completed;
        published += i.publication != UINT64_MAX;
        retired += i.retired;
        canceled += i.canceled;
    }
    if (stats.dispatched != records_.size() || issued != stats.issued || started != stats.started ||
        completed != stats.executed || published != stats.published || retired != stats.retired ||
        canceled != stats.canceled || stats.dispatched != pending() + retired + canceled)
        throw std::logic_error("FE17/20: allocation/release conservation violation");
}
bool Backend::ready(unsigned mask) const {
    if (mask == UINT32_MAX)
        mask = (1u << cfg_.lanes) - 1;
    if (mask >= (1u << cfg_.lanes) || (mask && (mask & (mask + 1))))
        throw std::invalid_argument("FE17: whole-bundle admission requires a contiguous low mask");
    return resources().iq + unsigned(__builtin_popcount(mask)) <= cfg_.iq;
}
void Backend::offered(bool valid, bool capacity_ready, bool random_ready) {
    // Called once after a matched consuming edge using the immutable pre-edge
    // admission decision. Count valid-offer stalls separately from capacity
    // driven ready-low cycles; an idle output is not a stalled transaction.
    if (!capacity_ready) ++stats.resource_stalls;
    if (valid) {
        ++stats.offered;
        if (!capacity_ready) ++stats.iq_blocks;
        if (!random_ready) ++stats.random_stalls;
    }
}
std::string BackendStats::json() const {
    std::ostringstream s;
    s << "{\"offered_bundles\":" << offered << ",\"accepted_bundles\":" << accepted
      << ",\"admitted_instructions\":" << dispatched << ",\"issued\":" << issued
      << ",\"started\":" << started << ",\"completed\":" << executed
      << ",\"published\":" << published << ",\"retired\":" << retired
      << ",\"canceled\":" << canceled << ",\"iq_high\":" << iq_high
      << ",\"rob_high\":" << rob_high << ",\"branch_high\":" << branch_high
      << ",\"alu_high\":" << alu_high << ",\"inflight_high\":" << inflight_high
      << ",\"iq_block_cycles\":" << iq_blocks << ",\"rob_block_cycles\":" << rob_blocks
      << ",\"branch_block_cycles\":" << branch_blocks << ",\"alu_block_cycles\":" << alu_blocks
      << ",\"resource_stall_cycles\":" << resource_stalls << ",\"random_stall_cycles\":" << random_stalls
      << ",\"publication_contention_cycles\":" << publication_blocks << '}';
    return s.str();
}
void Backend::dispatch(const Bundle &b, uint64_t cycle) {
    if (!b.id || accepted_bundles_.count(b.id))
        throw std::invalid_argument("FE17: duplicate/absent accepted bundle ID");
    if (!b.mask || !ready(b.mask))
        throw std::logic_error("FE17: illegal whole-bundle admission/capacity exceeded");
    if (cycle > UINT64_MAX - sampler_.options().maximum)
        throw std::invalid_argument("FE18: dispatch/readiness arithmetic overflow");
    // Reject an invalid later lane before allocating IDs, versions or RNG draws.
    for (unsigned k = 0; k < cfg_.lanes; ++k)
        if (b.mask & (1u << k)) {
            if (b.lanes[k].error)
                throw std::invalid_argument("FE16: faulting bundle cannot enter ordinary execution");
            evaluate(b.lanes[k].word, b.lanes[k].prediction.pc, 0, 0);
        }
    accepted_bundles_.insert(b.id);
    ++stats.accepted;
    for (unsigned k = 0; k < cfg_.lanes; ++k)
        if (b.mask & (1u << k)) {
            const auto &p = b.lanes[k];
            Instruction r;
            r.id = records_.size() + 1;
            r.epoch = epoch_;
            r.bundle = b.id;
            r.lane = k;
            r.pc = p.prediction.pc;
            r.payload = p;
            r.dispatch = cycle;
            r.latency = sampler_.sample();
            r.earliest = cycle + r.latency;
            r.iteration = iterations_[r.pc]++;
            if (p.error)
                throw std::invalid_argument("FE16: fetch-fault must be handled by exception episode, not "
                                            "ordinary execution");
            auto d = early::decode(p.word);
            const unsigned opcode = p.word & 127;
            r.a = (opcode == 0x13 || opcode == 0x33 || opcode == 0x63 || opcode == 0x67)
                      ? read(d.rs1, r.dep_a)
                      : 0;
            r.b = (opcode == 0x33 || opcode == 0x63) ? read(d.rs2, r.dep_b) : 0;
            r.semantic = evaluate(p.word, r.pc, r.a, r.b);
            r.wrong =
                r.semantic.control &&
                ((p.prediction.hit && p.prediction.taken) != r.semantic.taken ||
                 ((p.prediction.hit && p.prediction.taken) && p.prediction.target != r.semantic.target));
            records_.push_back(r);
            if (r.semantic.writes)
                versions_[r.semantic.rd].push_back(r.id);
            ++stats.dispatched;
        }
    audit(false);
}
const Instruction &Backend::record(uint64_t id) const {
    if (!id || id > records_.size())
        throw std::invalid_argument("FE17: absent dynamic ID");
    return records_[id - 1];
}
Feedback Backend::feedback(uint64_t cycle) const {
    auto p = events_.find(cycle);
    return p == events_.end() ? Feedback{} : p->second;
}
void Backend::enqueue(uint64_t cycle, const Feedback &f) {
    if (!events_.emplace(cycle, f).second)
        throw std::logic_error("FE17: feedback port collision");
}
void Backend::validate_feedback(const Feedback &f, uint64_t cycle) const {
    if (!f.id) {
        if (f.train || f.call || f.ret || f.redirect || f.flush)
            throw std::invalid_argument("FE17: feedback without instruction");
        return;
    }
    const auto &r = record(f.id);
    if (r.canceled || r.retired || !r.completed || !r.semantic.control || r.epoch > epoch_)
        throw std::invalid_argument("FE17: canceled/absent/ineligible feedback");
    if (f.resolution.pc != r.pc || f.resolution.target != r.semantic.target ||
        f.resolution.taken != r.semantic.taken || f.resolution.mispredict != r.wrong || (f.call && f.ret))
        throw std::invalid_argument("FE16/17: feedback semantic payload mismatch");
    if (f.train && (r.trained || cycle != r.execute + (r.wrong ? 2 : 1)))
        throw std::invalid_argument("FE17: duplicate/premature training");
    if (f.redirect && (!f.train || r.trained || cycle != r.execute + 2))
        throw std::invalid_argument("FE17: repeated/unqualified redirect after "
                                    "always-ready acknowledgment");
    if (f.call || f.ret) {
        if (r.confirmed || cycle != r.execute + 1 || f.link != r.pc + 4 || r.semantic.target % 4 ||
            f.call != (r.semantic.decoded.kind == early::Kind::Call) ||
            f.ret != (r.semantic.decoded.kind == early::Kind::Return))
            throw std::invalid_argument("FE17: invalid confirmation");
    }
    for (const auto &o : records_)
        if (o.id < r.id && !o.canceled && o.semantic.control && !o.completed)
            throw std::invalid_argument("FE17: younger feedback overtook older branch");
    if (f.flush != f.redirect || (f.flush && !r.wrong))
        throw std::invalid_argument("FE17: invalid recovery");
}
void Backend::rollback(uint64_t id) {
    for (auto &r : records_)
        if (r.id > id && !r.canceled && !r.retired) {
            r.canceled = true;
            ++stats.canceled;
        }
    for (auto &v : versions_)
        v.erase(std::remove_if(v.begin(), v.end(), [&](uint64_t x) { return records_[x - 1].canceled; }),
                v.end());
    for (auto i = events_.begin(); i != events_.end();)
        if (i->second.id > id)
            i = events_.erase(i);
        else
            ++i;
    ++epoch_;
    audit();
}
void Backend::consume_feedback(const Feedback &f, uint64_t cycle) {
    validate_feedback(f, cycle);
    if (!f.id)
        return;
    auto &r = records_[f.id - 1];
    if (f.train) {
        r.trained = true;
        r.update = cycle;
        ++stats.updates;
    }
    if (f.call || f.ret) {
        r.confirmed = true;
        r.confirmation = cycle;
        ++stats.confirmations;
    }
    events_.erase(cycle);
    if (f.flush) {
        rollback(f.id);
        ++stats.recoveries;
        resume_cycle_ = cycle + 1;
    }
}
void Backend::advance(uint64_t cycle, bool retirement_ready) {
    if (last_advance_ != UINT64_MAX && cycle <= last_advance_)
        throw std::logic_error("FE17: duplicate/nonmonotonic scheduler edge (excess issue/publication/retirement)");
    if (!events_.empty() && events_.begin()->first <= cycle)
        throw std::logic_error("FE17: scheduled feedback was not consumed before scheduler advance");
    last_advance_ = cycle;
    audit(false);
    const auto before = resources();
    if (freeze_id_ && resume_cycle_ && cycle >= resume_cycle_ && records_[freeze_id_ - 1].retired) {
        freeze_id_ = resume_cycle_ = 0;
        ++stats.resumes;
    }
    // Scalar IQ -> ROB + destination RS allocation. No pre-edge full lookahead.
    if (!freeze_id_)
        for (auto &r : records_)
            if (!r.issued && !r.canceled && !r.retired) {
                if (cycle <= r.dispatch)
                    break;
                if (before.rob == cfg_.rob)
                    ++stats.rob_blocks;
                else if (r.semantic.control && before.branch == cfg_.branch_capacity)
                    ++stats.branch_blocks;
                else if (!r.semantic.control && before.alu == cfg_.alu_capacity)
                    ++stats.alu_blocks;
                else {
                    r.issued = true;
                    r.issue = cycle;
                    ++stats.issued;
                }
                break;
            }
    uint64_t oldest_branch = 0;
    for (const auto &r : records_)
        if (!r.canceled && !r.completed && r.semantic.control) {
            oldest_branch = r.id;
            break;
        }
    // One result capture per unit, one-cycle service. L is the unchanged
    // dispatch-relative minimum readiness delay, NOT time spent in a busy FU.
    bool alu_started = false, branch_started = false;
    for (auto &r : records_)
        if (r.issued && r.start == UINT64_MAX && !r.canceled) {
            uint64_t dependencies = 0;
            bool available = true;
            for (auto id : {r.dep_a, r.dep_b})
                if (id) {
                    const auto &producer = records_[id - 1];
                    available &= producer.publication != UINT64_MAX;
                    if (producer.publication != UINT64_MAX)
                        dependencies = std::max(dependencies, producer.publication + 1);
                }
            r.dependency_ready = dependencies;
            if (!available || cycle < std::max({r.earliest, r.issue + 1, dependencies}))
                continue;
            if (r.semantic.control && (freeze_id_ || r.id != oldest_branch || branch_started)) {
                ++r.order_delay;
                ++stats.order_blocks;
                continue;
            }
            if (!r.semantic.control && alu_started)
                continue;
            r.start = cycle;
            ++stats.started;
            r.semantic.control ? branch_started = true : alu_started = true;
        }
    // Independent ALU and branch paths can complete together. Result capture
    // does not release an RS/ROB entry and does not forward before publication.
    for (auto &r : records_)
        if (!r.canceled && !r.completed && r.start != UINT64_MAX && cycle > r.start) {
            r.completed = true;
            r.execute = cycle;
            ++stats.executed;
            if (!r.semantic.control)
                continue;
            ++stats.branch_executions;
            r.wrong ? ++stats.wrong : ++stats.correct;
            Feedback f;
            f.id = r.id;
            f.resolution = {r.pc, r.semantic.target, r.semantic.taken, r.wrong};
            f.link = r.pc + 4;
            f.call = r.semantic.decoded.kind == early::Kind::Call && r.semantic.target % 4 == 0;
            f.ret = r.semantic.decoded.kind == early::Kind::Return && r.semantic.target % 4 == 0;
            if (r.wrong) {
                freeze_id_ = r.id;
                enqueue(cycle + 1, f);
                f.call = f.ret = false;
                f.train = f.redirect = f.flush = true;
                enqueue(cycle + 2, f);
            } else {
                f.train = true;
                enqueue(cycle + 1, f);
            }
        }
    // The production CDB has one result port. Oldest-ready arbitration is a
    // conservative fair abstraction, not a copy of the physical arbiter.
    unsigned contenders = 0;
    for (auto &r : records_)
        if (!r.canceled && r.completed && r.execute < cycle && r.publication == UINT64_MAX) {
            if (!contenders++) {
                r.publication = cycle;
                ++stats.published;
            }
        }
    stats.publication_blocks += contenders > 1;
    for (auto &r : records_)
        if (!r.retired && !r.canceled) {
            if (!retirement_ready || r.publication == UINT64_MAX || r.publication >= cycle ||
                (r.semantic.control && !r.trained))
                break;
            if (r.pc != expected_retire_pc_)
                throw std::runtime_error("FE19: surviving stream PC " + hex64(r.pc) +
                                         " differs from independent semantic PC " + hex64(expected_retire_pc_));
            auto d = early::decode(r.payload.word);
            auto s = evaluate(r.payload.word, r.pc, committed_[d.rs1], committed_[d.rs2]);
            if (s.value != r.semantic.value || s.next != r.semantic.next)
                throw std::runtime_error("FE16: speculative operand/rollback result differs from in-order semantics");
            if (s.writes)
                committed_[s.rd] = s.value;
            expected_retire_pc_ = s.next;
            r.retired = true;
            r.retire = cycle;
            ++stats.retired;
            break;
        }
    audit();
}
void Backend::cancel_all() {
    rollback(0);
    events_.clear();
    freeze_id_ = resume_cycle_ = 0;
}
size_t Backend::pending() const {
    size_t n = 0;
    for (const auto &r : records_)
        n += !r.canceled && !r.retired;
    return n;
}
} // namespace len5::frontend
