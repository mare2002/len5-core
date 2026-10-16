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
        iq < lanes || !branch_capacity || rob < iq)
        throw std::invalid_argument("FE01/FEQ11: unsupported source configuration (N=1/2/4/8, depth2/RAS4, "
                                    "aligned BOOT, positive predictor widths)");
}
Predictor::Predictor(Config c) : cfg_(c), targets_(size_t(1) << c.btb_bits), counters_(size_t(1) << c.hlen) {
    c.validate();
    reset();
}
void Predictor::reset() {
    std::fill(targets_.begin(), targets_.end(), Entry{});
    std::fill(counters_.begin(), counters_.end(), cfg_.initial);
    history_ = 0;
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
bool Backend::ready() const {
    size_t iq = 0, total = 0;
    for (const auto &r : records_)
        if (!r.canceled && !r.retired) {
            ++total;
            iq += !r.issued;
        }
    return iq + cfg_.lanes <= cfg_.iq && total + cfg_.lanes <= cfg_.rob;
}
void Backend::dispatch(const Bundle &b, uint64_t cycle) {
    if (!b.id || !accepted_bundles_.insert(b.id).second)
        throw std::invalid_argument("FE17: duplicate/absent accepted bundle ID");
    if (!ready())
        throw std::runtime_error("FE17: backend capacity exceeded");
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
void Backend::advance(uint64_t cycle) {
    if (freeze_id_ && resume_cycle_ && cycle >= resume_cycle_ && records_[freeze_id_ - 1].retired) {
        freeze_id_ = resume_cycle_ = 0;
        ++stats.resumes;
    }
    if (!freeze_id_) {
        unsigned occupied = 0;
        for (const auto &r : records_)
            if (r.issued && !r.completed && !r.canceled && r.semantic.control)
                ++occupied;
        for (auto &r : records_)
            if (!r.issued && !r.canceled && !r.retired) {
                if (!r.semantic.control || occupied < cfg_.branch_capacity) {
                    r.issued = true;
                    r.issue = cycle;
                }
                break;
            }
    }
    uint64_t oldest_branch = 0;
    for (const auto &r : records_)
        if (!r.canceled && !r.completed && r.semantic.control) {
            oldest_branch = r.id;
            break;
        }
    bool branch_executed = false;
    for (auto &r : records_)
        if (r.issued && !r.completed && !r.canceled) {
            const auto dep_ready = [&](uint64_t id) { return !id || records_[id - 1].completed; };
            if (!dep_ready(r.dep_a) || !dep_ready(r.dep_b))
                continue;
            uint64_t dependencies = 0;
            for (auto id : {r.dep_a, r.dep_b})
                if (id)
                    dependencies = std::max(dependencies, records_[id - 1].execute + 1);
            r.dependency_ready = dependencies;
            if (cycle < std::max({r.earliest, r.issue + 1, dependencies}))
                continue;
            if (r.semantic.control && (freeze_id_ || r.id != oldest_branch || branch_executed)) {
                ++r.order_delay;
                ++stats.order_blocks;
                continue;
            }
            r.completed = true;
            r.execute = cycle;
            ++stats.executed;
            if (!r.semantic.control)
                continue;
            branch_executed = true;
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
    for (auto &r : records_)
        if (!r.retired && !r.canceled) {
            if (!r.completed || (r.semantic.control && !r.trained))
                break;
            if (r.pc != expected_retire_pc_)
                throw std::runtime_error("FE19: surviving stream PC " + hex64(r.pc) +
                                         " differs from independent semantic PC " +
                                         hex64(expected_retire_pc_));
            auto d = early::decode(r.payload.word);
            auto s = evaluate(r.payload.word, r.pc, committed_[d.rs1], committed_[d.rs2]);
            if (s.value != r.semantic.value || s.next != r.semantic.next)
                throw std::runtime_error("FE16: speculative operand/rollback result "
                                         "differs from in-order semantics");
            if (s.writes)
                committed_[s.rd] = s.value;
            expected_retire_pc_ = s.next;
            r.retired = true;
            r.retire = cycle;
            ++stats.retired;
            break;
        }
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
