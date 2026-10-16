// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Semantic composition: no Verilator headers, DUT handles, or observed outputs.
#include "fetch_stage_composition.hh"
#include <sstream>
namespace len5::frontend {
static Field known(uint64_t x, const char *id, const char *evidence = "I", std::string assumption = {}) {
    return {x, true, id, evidence, assumption, {}};
}
static Field dc() { return fetchmem::dont_care("inactive-or-canceled-frontend-field"); }
static early::Config ecfg(Config c) {
    early::Config e;
    e.lanes = c.lanes;
    e.depth = c.ras_depth;
    return e;
}
static early::Contract econtract(const std::string &order) {
    early::Contract e;
    e.exception = "unknown";
    e.order = order;
    return e;
}
static fetchmem::Config mcfg(Config c) {
    fetchmem::Config m;
    m.lanes = c.lanes;
    m.depth = c.depth;
    return m;
}
Composition::Composition(Config c, const std::string &order)
    : cfg_(c), pc_(pcgen::Config{c.boot, 64, 4, c.lanes}, {}), eju_(ecfg(c), econtract(order)),
      memory_(mcfg(c)), bpu_(c) {
    c.validate();
}
void Composition::input_change(const Inputs &i) {
    pcgen::Inputs pi;
    pi.rst_n = i.rst_n;
    pc_.input_change(pi);
    early::Inputs ei;
    ei.rst_n = i.rst_n;
    eju_.input_change(ei);
    fetchmem::Stimulus ms;
    ms.inputs.rst_n = i.rst_n;
    memory_.input_change(ms);
    if (!i.rst_n) {
        if (!in_reset_) {
            stats.canceled +=
                output_.size() + memory_.state().outstanding.size() + memory_.state().answers.size();
            output_.clear();
            snapshots_.clear();
            ++epoch_;
        }
        initialized_ = true;
        released_ = false;
        bpu_.reset();
    }
    in_reset_ = !i.rst_n;
}
CompositionPlan Composition::plan(const Inputs &i, uint64_t cycle) const {
    CompositionPlan p;
    p.q = unsigned(memory_.state().outstanding.size());
    p.answers = unsigned(memory_.state().answers.size());
    p.output = unsigned(output_.size());
    const bool live = i.rst_n && released_;
    const bool spill_ready = live && !i.flush && output_.size() < 2;
    auto &es = p.es;
    es.reason = i.reason;
    es.inputs.rst_n = i.rst_n;
    es.inputs.flush = i.flush;
    es.inputs.ready = spill_ready;
    es.inputs.call_confirm = i.feedback.call;
    es.inputs.ret_confirm = i.feedback.ret;
    es.inputs.link = i.feedback.link;
    es.confirmation_id = i.feedback.id;
    es.recovery_id = i.feedback.id;
    es.inputs.valid = i.rst_n && memory_.state().released && !memory_.state().answers.empty();
    if (es.inputs.valid) {
        const auto &ans = memory_.state().answers.front();
        es.bundle_id = ans.request.id;
        es.inputs.mask = ans.request.mask;
        es.request_pc = ans.request.start;
        es.inputs.words = ans.payload.words;
        for (unsigned k = 0; k < cfg_.lanes; ++k) {
            const auto &r = ans.request.predictions[k];
            es.inputs.predictions[k] = {r.pc, r.target, r.hit, r.taken};
        }
    }
    p.ee = eju_.outputs(es);
    const auto selection = p.ee.selection;
    auto &pi = p.pi;
    pi.rst_n = i.rst_n;
    pi.commit = i.commit;
    pi.commit_pc = i.commit_pc;
    pi.branch_valid = i.feedback.redirect;
    pi.mispredict = i.feedback.resolution.mispredict;
    pi.taken = i.feedback.resolution.taken;
    pi.branch_pc = i.feedback.resolution.pc;
    pi.branch_target = i.feedback.resolution.target;
    pi.ready = i.grant;
    const auto cursor = pc_.cursor();
    const auto pc = cursor.value;
    std::array<Prediction, MaxLanes> predictions{};
    const uint64_t base = (pc / cfg_.bytes()) * cfg_.bytes();
    for (unsigned k = 0; k < cfg_.lanes; ++k)
        predictions[k] = bpu_.predict(cfg_.lanes == 1 ? pc : base + 4 * k);
    p.start = unsigned((pc % cfg_.bytes()) / 4);
    for (unsigned k = p.start; k < cfg_.lanes; ++k)
        if (predictions[k].hit && predictions[k].taken) {
            pi.prediction = true;
            pi.prediction_target = predictions[k].target;
            break;
        }
    // An empty answer cannot supply an applicable correction, including startup.
    pi.early = es.inputs.valid && p.ee.early.known && p.ee.early.value;
    if (pi.early && selection.base.known && selection.offset.known) {
        pi.early_base = selection.base.value;
        pi.early_offset = selection.offset.value;
    } else if (pi.early) {
        p.uncertain = true;
    }
    if (es.inputs.valid && !p.ee.early.known)
        p.uncertain = true;
    p.pt = pc_.plan(pi);
    auto po = pc_.outputs(pi);
    es.feedback_unused = i.flush;
    es.inputs.feedback = po.early_target.value;
    if (pi.early && !i.commit && !pi.recovery() && selection.target.known)
        es.inputs.feedback = selection.target.value;
    p.ee = eju_.outputs(es);
    p.et = eju_.plan(es, cycle);
    p.early = p.ee.mem_flush.known && p.ee.mem_flush.value;
    auto &ms = p.ms;
    ms.inputs.rst_n = i.rst_n;
    ms.inputs.flush = i.flush || p.early;
    ms.reason = i.flush ? i.reason : p.early ? "early" : "";
    ms.inputs.fetch_valid = po.valid.known && po.valid.value;
    ms.inputs.grant = i.grant;
    ms.inputs.response_valid = i.response_valid;
    ms.inputs.response = i.response;
    ms.inputs.consumer_ready = spill_ready;
    ms.inputs.predictions = predictions;
    ms.inputs.mask = fetchmem::request_mask(pc, predictions, mcfg(cfg_));
    ms.request_id = next_id_;
    ms.start = pc;
    const auto me = memory_.outputs(ms);
    p.mt = memory_.plan(ms, cycle);
    p.a = p.et.accepted && !i.flush;
    p.d = live && !output_.empty() && i.ready && !i.flush;
    if (p.a) {
        const auto &ans = memory_.state().answers.front();
        Bundle b;
        b.id = ans.request.id;
        b.epoch = epoch_;
        unsigned shift = 0;
        while (shift < cfg_.lanes && !(p.ee.selection.retained & (1u << shift)))
            ++shift;
        for (unsigned k = shift; k < cfg_.lanes; ++k) {
            const unsigned dst = k - shift;
            if (!(p.ee.selection.retained & (1u << k)))
                continue;
            b.mask |= 1u << dst;
            auto &l = b.lanes[dst];
            l.word = ans.payload.words[k];
            l.error = (ans.payload.errors >> k) & 1;
            l.cause = ans.payload.causes[k];
            l.raw = ans.request.predictions[k];
            l.prediction = {p.ee.predictions[k].pc.value, p.ee.predictions[k].target.value,
                            bool(p.ee.predictions[k].hit.value), bool(p.ee.predictions[k].taken.value)};
            l.source_lane = k;
            l.request_id = b.id;
            l.request_cycle = ans.request.accepted;
            l.accepted_cycle = cycle;
            l.rewritten =
                int(k) == selection.lane && selection.correction.known && selection.correction.value;
            l.ras_known = eju_.state().predictive.known;
            l.ras_nonempty = l.ras_known && !eju_.state().predictive.entries.empty();
            if (l.ras_nonempty)
                l.ras_top = eju_.state().predictive.entries.back().address;
            l.raw_known = ans.request.metadata_known;
            const auto snapshot = snapshots_.find(b.id);
            if (snapshot != snapshots_.end()) {
                l.prediction_history = snapshot->second.history;
                l.prediction_index = snapshot->second.index[k];
                l.prediction_counter = snapshot->second.counter[k];
            }
            if (!p.ee.predictions[k].pc.known || !p.ee.predictions[k].hit.known ||
                !p.ee.predictions[k].taken.known || (l.prediction.hit && !p.ee.predictions[k].target.known))
                p.uncertain = true;
        }
        p.transfer = b;
    }
    auto &e = p.expected;
    e.request = me.request_valid;
    e.address = me.request_address;
    e.write = me.write;
    e.response_ready = me.response_ready;
    // Cancellation is a dependency of memory readiness. Unknown early control
    // must not be converted to numerical false by the FM stimulus adapter.
    if (es.inputs.valid && !p.ee.mem_flush.known && !i.flush && live && p.answers < 2)
        e.response_ready = fetchmem::unknown("FE21:memory-ready-depends-on-unknown-early-flush");
    e.valid = known(live && !output_.empty(), "FE12", "I", "registered-final-spill (I)");
    e.early_flush = es.inputs.valid ? p.ee.mem_flush : known(0, "FE10", "I", "no-applicable-answer (I)");
    e.branch_ready = po.branch_ready;
    e.mask = dc();
    if (!cursor.known)
        e.address = fetchmem::unknown("FE21:unknown-golden-PC");
    for (auto &l : e.lanes)
        l.word = l.pc = l.hit = l.taken = l.target = l.error = l.cause = dc();
    if (live && !output_.empty() && !i.flush) {
        const auto &b = output_.front();
        p.dispatched = b;
        e.mask = known(b.mask, "FE12", "I", "EJU-cutoff-and-mixer (I)");
        for (unsigned k = 0; k < cfg_.lanes; ++k)
            if (b.mask & (1u << k)) {
                const auto &l = b.lanes[k];
                auto &x = e.lanes[k];
                x.pc = known(l.prediction.pc, "FE06", "D", "independent-prediction-PC-context (I)");
                x.word = l.error ? dc() : known(l.word, "FM06", "D", "independent-lane-context (I)");
                x.hit = known(l.prediction.hit, l.rewritten ? "EJ07" : "FE04", "I",
                              l.rewritten ? "EJU-metadata-rewrite (I)" : "resolution-indexed-gshare-v1 (I)");
                x.taken = known(l.prediction.taken, l.rewritten ? "EJ07" : "FE05", "I",
                                "resolution-indexed-gshare-v1/EJU (I)");
                x.target = l.prediction.hit
                               ? known(l.prediction.target, "FE06", "I", "saved-BPU/EJU-target (I)")
                               : dc();
                x.error = known(l.error, "FM11", "D", "independent-lane-context (I)");
                x.cause = l.error ? known(l.cause, "FM11", "D", "independent-error-context (I)") : dc();
            }
    }
    p.row = (p.mt.k ? 8 : 0) | (p.mt.r ? 4 : 0) | (p.a ? 2 : 0) | (p.d ? 1 : 0);
    return p;
}
std::optional<PredictorUpdate> Composition::edge(const Inputs &i, const CompositionPlan &p) {
    if (!i.rst_n)
        return {};
    if (p.uncertain)
        throw std::runtime_error(
            "FE21/FEQ03: integrated transition uncertain; no numeric fallback or DUT synchronization");
    if (p.d) {
        output_.pop_front();
        ++stats.dispatched;
    }
    if (i.flush) {
        stats.canceled += output_.size();
        output_.clear();
        ++epoch_;
    } else if (p.a) {
        output_.push_back(p.transfer);
        ++stats.transferred;
    }
    stats.accepted += p.mt.k;
    stats.responded += p.mt.r;
    stats.early += p.early;
    stats.canceled += p.mt.canceled_ids.size();
    if (p.mt.k)
        ++next_id_;
    if (p.mt.k) {
        Snapshot snapshot;
        snapshot.history = bpu_.history();
        for (unsigned k = 0; k < cfg_.lanes; ++k) {
            snapshot.index[k] = bpu_.index(p.ms.inputs.predictions[k].pc);
            snapshot.counter[k] = bpu_.counter(snapshot.index[k]);
        }
        snapshots_[p.ms.request_id] = snapshot;
    }
    if (p.a)
        snapshots_.erase(p.transfer.id);
    for (auto id : p.mt.canceled_ids)
        snapshots_.erase(id);
    pc_.rising_edge(p.pt);
    eju_.rising_edge(p.et);
    memory_.rising_edge(p.mt);
    released_ = initialized_;
    if (i.flush_bpu) {
        bpu_.reset();
        return {};
    }
    if (i.feedback.train)
        return bpu_.update(i.feedback.resolution);
    return {};
}
std::string bundle_json(const Bundle &b, unsigned n) {
    std::ostringstream s;
    s << "{\"id\":" << b.id << ",\"epoch\":" << b.epoch << ",\"mask\":" << b.mask << ",\"lanes\":[";
    for (unsigned k = 0; k < n; ++k) {
        if (k)
            s << ',';
        const auto &l = b.lanes[k];
        s << "{\"pc\":" << json_quote(hex64(l.prediction.pc)) << ",\"word\":" << l.word
          << ",\"hit\":" << l.prediction.hit << ",\"taken\":" << l.prediction.taken
          << ",\"target\":" << json_quote(hex64(l.prediction.target)) << ",\"error\":" << l.error
          << ",\"cause\":" << l.cause << '}';
    }
    s << "]}";
    return s.str();
}
std::string inputs_json(const Inputs &i, unsigned n) {
    std::ostringstream s;
    s << "{\"reset\":" << !i.rst_n << ",\"flush\":" << i.flush << ",\"flush_bpu\":" << i.flush_bpu
      << ",\"grant\":" << i.grant << ",\"response_valid\":" << i.response_valid << ",\"ready\":" << i.ready
      << ",\"feedback_id\":" << i.feedback.id << ",\"train\":" << i.feedback.train
      << ",\"redirect\":" << i.feedback.redirect << ",\"call\":" << i.feedback.call
      << ",\"ret\":" << i.feedback.ret << ",\"res_pc\":" << json_quote(hex64(i.feedback.resolution.pc))
      << ",\"res_target\":" << json_quote(hex64(i.feedback.resolution.target))
      << ",\"res_taken\":" << i.feedback.resolution.taken
      << ",\"res_mispredict\":" << i.feedback.resolution.mispredict
      << ",\"link\":" << json_quote(hex64(i.feedback.link)) << ",\"commit\":" << i.commit
      << ",\"commit_pc\":" << json_quote(hex64(i.commit_pc)) << ",\"errors\":" << i.response.errors
      << ",\"words\":[";
    for (unsigned k = 0; k < n; ++k) {
        if (k)
            s << ',';
        s << i.response.words[k];
    }
    s << "],\"causes\":[";
    for (unsigned k = 0; k < n; ++k) {
        if (k)
            s << ',';
        s << i.response.causes[k];
    }
    s << "]}";
    return s.str();
}
std::string outputs_json(const Outputs &o, unsigned n) {
    std::ostringstream s;
    s << "{\"request\":" << o.request << ",\"address\":" << json_quote(hex64(o.address))
      << ",\"response_ready\":" << o.response_ready << ",\"write\":" << o.write << ",\"valid\":" << o.valid
      << ",\"early_flush\":" << o.early_flush << ",\"branch_ready\":" << o.branch_ready
      << ",\"bundle\":" << bundle_json(o.bundle, n) << '}';
    return s.str();
}
} // namespace len5::frontend
