// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Adapted from fetch_mem_driver/scoreboard: public snapshots, independent
// fields, confidence dependencies, phase scheduling, bounded history and native
// logger.
#include "fetch_stage_driver.hh"
#include "Vfetch_stage_tb.h"
#include "tb_macros.hh"
#include <algorithm>
#include <filesystem>
#include <inttypes.h>
#include <sstream>
#include <verilated.h>
#include <verilated_fst_c.h>
namespace len5::frontend {
void Simulator::drive(const Inputs &i) {
    dut_->rst_ni = i.rst_n;
    dut_->flush_i = i.flush;
    dut_->flush_bpu_i = i.flush_bpu;
    dut_->instr_ready_i = i.grant;
    dut_->instr_valid_i = i.response_valid;
    dut_->issue_ready_i = i.ready;
    dut_->bu_bpu_valid_i = i.feedback.train;
    dut_->bu_pcgen_valid_i = i.feedback.redirect;
    dut_->bu_call_confirm_i = i.feedback.call;
    dut_->bu_ret_confirm_i = i.feedback.ret;
    dut_->res_pc_i = i.feedback.resolution.pc;
    dut_->res_target_i = i.feedback.resolution.target;
    dut_->res_taken_i = i.feedback.resolution.taken;
    dut_->res_mispredict_i = i.feedback.resolution.mispredict;
    dut_->bu_link_addr_i = i.feedback.link;
    dut_->comm_except_raised_i = i.commit;
    dut_->comm_except_pc_i = i.commit_pc;
    dut_->instr_except_raised_i = i.response.errors;
    for (unsigned k = 0; k < cfg_.lanes; ++k) {
        dut_->instr_words_i[k] = i.response.words[k];
        dut_->instr_causes_i[k] = i.response.causes[k];
    }
}
Inputs Simulator::read_inputs() const {
    Inputs i;
    i.rst_n = dut_->rst_ni;
    i.flush = dut_->flush_i;
    i.flush_bpu = dut_->flush_bpu_i;
    i.grant = dut_->instr_ready_i;
    i.response_valid = dut_->instr_valid_i;
    i.ready = dut_->issue_ready_i;
    i.feedback.train = dut_->bu_bpu_valid_i;
    i.feedback.redirect = dut_->bu_pcgen_valid_i;
    i.feedback.call = dut_->bu_call_confirm_i;
    i.feedback.ret = dut_->bu_ret_confirm_i;
    i.feedback.resolution = {dut_->res_pc_i, dut_->res_target_i, bool(dut_->res_taken_i),
                             bool(dut_->res_mispredict_i)};
    i.feedback.link = dut_->bu_link_addr_i;
    i.commit = dut_->comm_except_raised_i;
    i.commit_pc = dut_->comm_except_pc_i;
    i.response.errors = dut_->instr_except_raised_i;
    for (unsigned k = 0; k < cfg_.lanes; ++k) {
        i.response.words[k] = dut_->instr_words_i[k];
        i.response.causes[k] = dut_->instr_causes_i[k];
    }
    return i;
}
Outputs Simulator::outputs() const {
    Outputs o;
    o.request = dut_->instr_valid_o;
    o.address = dut_->instr_addr_o;
    o.write = dut_->instr_we_o;
    o.response_ready = dut_->instr_ready_o;
    o.valid = dut_->issue_valid_o;
    o.early_flush = dut_->early_jump_mem_flush_o;
    o.branch_ready = dut_->bu_pcgen_ready_o;
    o.bundle.mask = dut_->issue_valid_instr_o;
    for (unsigned k = 0; k < cfg_.lanes; ++k) {
        auto &l = o.bundle.lanes[k];
        l.word = dut_->issue_words_o[k];
        l.prediction = {dut_->issue_pc_o[k], dut_->issue_target_o[k], bool((dut_->issue_hit_o >> k) & 1),
                        bool((dut_->issue_taken_o >> k) & 1)};
        l.error = (dut_->issue_except_raised_o >> k) & 1;
        l.cause = dut_->issue_causes_o[k];
    }
    return o;
}
Simulator::Simulator(Options o, int argc, char **argv)
    : options_(o), cfg_(read_configuration(o.executable)), context_(new VerilatedContext),
      events_(split_seed(o.seed ^ 0x45564e54)), memory_rng_(split_seed(o.seed ^ 0x4d454d)) {
    if (!o.expect_fingerprint.empty() && o.expect_fingerprint != cfg_.fingerprint)
        throw std::invalid_argument("FE01: replay fingerprint mismatch");
    if (o.expect_issues && o.expect_issues != cfg_.lanes)
        throw std::invalid_argument("FE01: replay issue width mismatch");
    auto dir = o.run_dir + "/logs";
    if (std::filesystem::exists(dir + "/report.json"))
        throw std::invalid_argument("choose a fresh run directory");
    std::filesystem::create_directories(dir);
    journal_.open(dir + "/samples.jsonl");
    training_.open(dir + "/training.jsonl");
    characterization_.open(dir + "/characterization.jsonl");
    context_->commandArgs(argc, argv);
    context_->randSeed(int(o.seed & 0x7fffffff));
    context_->traceEverOn(o.waves);
    dut_ = std::make_unique<Vfetch_stage_tb>(context_.get());
    dut_->clk_i = 0;
    drive(Inputs{});
    dut_->eval();
    if (dut_->config_issues_o != cfg_.lanes || dut_->config_depth_o != cfg_.depth ||
        dut_->config_xlen_o != 64 || dut_->config_ilen_o != 32 || dut_->config_hlen_o != cfg_.hlen ||
        dut_->config_btb_bits_o != cfg_.btb_bits || dut_->config_initial_o != cfg_.initial ||
        dut_->config_ras_depth_o != cfg_.ras_depth || dut_->config_boot_o != cfg_.boot ||
        dut_->config_req_skip_o != 1 || dut_->config_ans_skip_o != 0 || dut_->config_cause_bits_o != 5)
        throw std::invalid_argument("FE01: source/elaboration mismatch");
    if (o.waves) {
        trace_ = std::make_unique<VerilatedFstC>();
        dut_->trace(trace_.get(), 1);
        trace_->open((dir + "/waves.fst").c_str());
    }
    logger.setSimContext(context_.get());
    TB_CONFIG("LEN5_MULTIPLE_ISSUES=%u BOOT_PC=%s HLEN=%u BTB_BITS=%u "
              "INIT_C2B=%u RAS_DEPTH=%u "
              "metadata_depth=%u source/elaboration verified",
              cfg_.lanes, hex64(cfg_.boot).c_str(), cfg_.hlen, cfg_.btb_bits, cfg_.initial, cfg_.ras_depth,
              cfg_.depth);
    TB_CONFIG("seed=%" PRIu64 " profile=%s policy=fetch-stage-closed-loop-v1; latency=%s", o.seed,
              o.profile.c_str(), o.latency.json().c_str());
    TB_CONFIG("fingerprint=%s reports=%s; timestamps=context ticks; "
              "cycles=consuming rising edges",
              cfg_.fingerprint.c_str(), dir.c_str());
    std::istringstream weights(o.weights);
    std::string part;
    while (std::getline(weights, part, ',')) {
        auto n = part.find('=');
        if (n == std::string::npos)
            throw std::invalid_argument("weights use grant/ready/response=0..100");
        const auto raw = part.substr(n + 1);
        size_t end = 0;
        auto val = std::stoul(raw, &end);
        if (raw.empty() || raw[0] == '-' || end != raw.size() || val > 100)
            throw std::invalid_argument("weight >100");
        auto key = part.substr(0, n);
        if (key == "grant")
            grant_weight_ = unsigned(val);
        else if (key == "ready")
            ready_weight_ = unsigned(val);
        else if (key == "response")
            response_weight_ = unsigned(val);
        else
            throw std::invalid_argument("unknown event weight " + key);
    }
}
Simulator::~Simulator() {
    if (dut_)
        dut_->final();
    if (trace_)
        trace_->close();
    logger.setSimContext(nullptr);
}
void Simulator::counter(const std::string &k, uint64_t n) {
    coverage_[scenario_.classification + "/" + k] += n;
    local_[k] += n;
}
void Simulator::error(const std::string &kind, const std::string &message) {
    if (kind == "environment_error")
        ++stats.environment;
    else
        ++stats.framework;
    discrepancies_.push_back("{\"category\":" + json_quote(kind) + ",\"message\":" + json_quote(message) +
                             ",\"cycle\":" + std::to_string(cycle_) + "}");
    TB_ERR("SCB > %s: %s", kind.c_str(), message.c_str());
}
void Simulator::compare(const Field &e, uint64_t actual, const std::string &field, const char *phase,
                        bool &failed) {
    if (!e.known) {
        if (e.question.rfind("DC:", 0) == 0)
            ++dont_cares_[e.question];
        else
            ++unknowns_[e.question];
        return;
    }
    // Safety profile retains exact transport/semantic checks; predictor-dependent
    // comparisons remain explicitly unverified rather than falsely reported
    // matched.
    if (options_.profile == "predictor-agnostic" && (e.requirement == "FE04" || e.requirement == "FE05")) {
        ++unknowns_["FEQ01:exact-predictor-policy-not-selected"];
        return;
    }
    ++stats.checks;
    ++requirements_[e.requirement + "/" + e.evidence];
    if (!e.assumptions.empty())
        ++assumptions_[e.assumptions];
    if (e.value == actual)
        return;
    failed = true;
    ++stats.field_errors;
    bool provisional = !e.assumptions.empty() || e.evidence == "I";
    if (injected_)
        ++stats.injected;
    else if (provisional)
        ++stats.provisional;
    else
        ++stats.confirmed;
    std::ostringstream s;
    s << "{\"scenario\":" << json_quote(scenario_.id) << ",\"field\":" << json_quote(field)
      << ",\"requirement\":" << json_quote(e.requirement) << ",\"evidence\":" << json_quote(e.evidence)
      << ",\"assumptions\":" << json_quote(e.assumptions) << ",\"expected\":" << json_quote(hex64(e.value))
      << ",\"actual\":" << json_quote(hex64(actual)) << ",\"instance\":" << instance_
      << ",\"cycle\":" << cycle_ << ",\"time\":" << context_->time() << ",\"phase\":" << json_quote(phase)
      << '}';
    if (discrepancies_.size() < 128)
        discrepancies_.push_back(s.str());
    if (stats.field_errors <= 8) {
        TB_ERR("SCB > test=%s req=%s evidence=%s seed=%" PRIu64 " cycle=%" PRIu64 " time=%" PRIu64
               " phase=%s",
               scenario_.id.c_str(), e.requirement.c_str(), e.evidence.c_str(), options_.seed, cycle_,
               context_->time(), phase);
        TB_ERR("RSP > %s --> %s (expected: %s) %s", field.c_str(), hex64(actual).c_str(),
               hex64(e.value).c_str(), e.assumptions.c_str());
        for (const auto &h : history_)
            TB_ERR("REQ > recent %s", h.c_str());
    }
}
bool Simulator::sample(const Inputs &i, const CompositionPlan &p, const char *phase, bool allow_injection) {
    ++stats.samples;
    const uint64_t before = stats.checks;
    bool failed = false;
    auto a = outputs();
    if (allow_injection && !injected_ && std::string(phase) == "pre") {
        bool did = false;
        if (options_.inject == "request" && p.expected.address.known) {
            a.address ^= 4;
            did = true;
        } else if (options_.inject == "valid") {
            a.valid = !a.valid;
            did = true;
        } else if (options_.inject == "early") {
            a.early_flush = !a.early_flush;
            did = true;
        } else if (a.valid && a.bundle.mask) {
            unsigned k = 0;
            while (!(a.bundle.mask & (1u << k)))
                ++k;
            if (options_.inject == "word") {
                a.bundle.lanes[k].word ^= 4;
                did = true;
            } else if (options_.inject == "pc") {
                a.bundle.lanes[k].prediction.pc ^= 4;
                did = true;
            } else if (options_.inject == "target" && p.expected.lanes[k].target.known) {
                a.bundle.lanes[k].prediction.target ^= 4;
                did = true;
            } else if (options_.inject == "taken") {
                a.bundle.lanes[k].prediction.taken = !a.bundle.lanes[k].prediction.taken;
                did = true;
            } else if (options_.inject == "error") {
                a.bundle.lanes[k].error = !a.bundle.lanes[k].error;
                did = true;
            } else if (options_.inject == "cause" && a.bundle.lanes[k].error) {
                a.bundle.lanes[k].cause ^= 1;
                did = true;
            } else if (options_.inject == "mask") {
                a.bundle.mask ^= 1u << k;
                did = true;
            }
        }
        if (did)
            injected_ = true;
    }
    const auto &e = p.expected;
    compare(e.request, a.request, "instr_valid_o", phase, failed);
    compare(e.address, a.address, "instr_addr_o", phase, failed);
    compare(e.write, a.write, "instr_we_o", phase, failed);
    compare(e.response_ready, a.response_ready, "instr_ready_o", phase, failed);
    compare(e.valid, a.valid, "issue_valid_o", phase, failed);
    compare(e.early_flush, a.early_flush, "early_jump_mem_flush_o", phase, failed);
    compare(e.branch_ready, a.branch_ready, "bu_pcgen_ready_o", phase, failed);
    compare(e.mask, a.bundle.mask, "issue_valid_instr_o", phase, failed);
    for (unsigned k = 0; k < cfg_.lanes; ++k) {
        const auto &x = e.lanes[k];
        const auto &y = a.bundle.lanes[k];
        auto prefix = "lane[" + std::to_string(k) + "].";
        compare(x.word, y.word, prefix + "word", phase, failed);
        compare(x.pc, y.prediction.pc, prefix + "pc", phase, failed);
        compare(x.hit, y.prediction.hit, prefix + "hit", phase, failed);
        compare(x.taken, y.prediction.taken, prefix + "taken", phase, failed);
        compare(x.target, y.prediction.target, prefix + "target", phase, failed);
        compare(x.error, y.error, prefix + "error", phase, failed);
        compare(x.cause, y.cause, prefix + "cause", phase, failed);
    }
    if (stats.checks > before)
        ++stats.transactions;
    if (failed)
        ++stats.failed_samples;
    // All field comparisons above always occur. Avoid allocating serialized
    // post/falling records when only the bounded pre-edge failure journal is
    // needed.
    const bool retain = options_.journal == "full" || (!options_.random && options_.journal == "auto");
    if (!retain && !failed && std::string(phase) != "pre" && logger.getLogLvl() != LOG_FULL)
        return true;
    std::ostringstream record;
    record << "{\"scenario\":" << json_quote(scenario_.id) << ",\"instance\":" << instance_
           << ",\"cycle\":" << cycle_ << ",\"time\":" << context_->time()
           << ",\"phase\":" << json_quote(phase) << ",\"inputs\":" << inputs_json(i, cfg_.lanes)
           << ",\"actual\":" << outputs_json(a, cfg_.lanes)
           << ",\"golden_pc\":" << pcgen::field_json(model_->cursor())
           << ",\"request_id\":" << model_->next_id()
           << ",\"request_head_id\":" << (physical_.empty() ? 0 : physical_.front().id)
           << ",\"expected_bundle_id\":" << p.dispatched.id << ",\"matched\":" << !failed << '}';
    const auto text = record.str();
    if (options_.journal == "full" || (!options_.random && options_.journal == "auto") || failed) {
        if (failed)
            for (const auto &h : history_)
                journal_ << h << '\n';
        journal_ << text << '\n';
    }
    if (std::string(phase) == "pre") {
        history_.push_back(text);
        if (history_.size() > 8)
            history_.pop_front();
        for (unsigned char ch : text) {
            stimulus_digest_ ^= ch;
            stimulus_digest_ *= UINT64_C(1099511628211);
        }
    }
    TB_LOG(LOG_FULL, "RSP > %s", text.c_str());
    return !failed;
}
void Simulator::cancel_memory_obligations(const std::string &reason, bool younger_only) {
    for (auto &entry : memory_ledger_) {
        auto &m = entry.second;
        if (m.window == reset_window_ && m.delivery == UINT64_MAX && m.cancellation.empty() &&
            (!younger_only || m.transfer == UINT64_MAX))
            m.cancellation = reason;
    }
}
void Simulator::capture_backend_obligations(const std::string &stop) {
    if (!backend_)
        return;
    for (const auto &r : backend_->records()) {
        std::ostringstream record;
        record << "{\"window\":" << reset_window_ << ",\"id\":" << r.id << ",\"epoch\":" << r.epoch
               << ",\"bundle\":" << r.bundle << ",\"lane\":" << r.lane
               << ",\"pc\":" << json_quote(hex64(r.pc)) << ",\"control\":" << r.semantic.control
               << ",\"dispatch\":" << r.dispatch << ",\"sampled_latency\":" << r.latency
               << ",\"trained\":" << r.trained << ",\"confirmed\":" << r.confirmed << ",\"status\":"
               << json_quote(r.retired    ? "retired"
                             : r.canceled ? "canceled-backend-recovery"
                                          : "canceled-" + stop)
               << '}';
        backend_ledger_.push_back(record.str());
    }
}
void Simulator::step(Inputs i, bool schedule_backend) {
    if (cycle_ >= options_.max_cycles)
        throw std::runtime_error("incomplete: maximum cycles reached");
    const Feedback backend_feedback = i.feedback;
    if (scenario_.id == "FE-T20" && i.feedback.id && i.feedback.train && !i.feedback.resolution.mispredict &&
        i.feedback.resolution.pc == program_.labels.at("loop") + 8 && !local_["poisoned-recovery"]) {
        i.feedback.resolution.target += 0x100;
        counter("poisoned-update");
    }
    drive(i);
    dut_->eval();
    model_->input_change(i);
    // Real external memory withdraws grant on public combined cancellation.
    for (unsigned tries = 0; tries < 4; ++tries) {
        bool g = i.grant && !i.flush && !dut_->early_jump_mem_flush_o;
        if (g == bool(dut_->instr_ready_i))
            break;
        i.grant = g;
        drive(i);
        dut_->eval();
    }
    auto read = read_inputs();
    read.feedback.id = i.feedback.id;
    read.reason = i.reason;
    if (inputs_json(read, cfg_.lanes) != inputs_json(i, cfg_.lanes))
        throw std::logic_error("FE24: driver/input readback mismatch");
    auto p = model_->plan(i, cycle_);
    const auto actual = outputs();
    if (!sample(i, p, "pre")) {
        quarantined_ = true;
        throw std::runtime_error("comparison failure: dependent physical feedback "
                                 "quarantined; oracle not repaired");
    }
    if (p.uncertain) {
        counter("FEV20/unknown-transition");
        throw std::runtime_error("incomplete: unresolved integrated transition; reset required");
    }
    if (options_.inject == "environment")
        throw std::invalid_argument("FE17: intentional invalid backend feedback injection");
    if (options_.inject == "framework")
        throw std::logic_error("intentional framework error");
    if (i.rst_n) {
        if (schedule_backend)
            backend_->validate_feedback(backend_feedback, cycle_);
        const bool k = actual.request && i.grant, r = i.response_valid && actual.response_ready,
                   d = actual.valid && i.ready && !i.flush;
        if (k != p.mt.k || r != p.mt.r || d != p.d)
            throw std::logic_error("FE21: observed/expected handshake divergence escaped checks");
        if (r && (physical_.empty() || cycle_ <= physical_.front().accepted))
            throw std::invalid_argument("FE13: unsolicited/zero-latency response");
        if (i.response_valid && !physical_.empty() && !(i.response == physical_.front().payload))
            throw std::invalid_argument("FE13: held memory payload changed");
        if (p.a) {
            auto &record = memory_ledger_.at({reset_window_, p.transfer.id});
            if (record.response == UINT64_MAX || record.transfer != UINT64_MAX ||
                !record.cancellation.empty())
                throw std::logic_error("FE20: duplicate/unassociated answer transfer obligation");
            record.transfer = cycle_;
        }
        if (d) {
            auto &record = memory_ledger_.at({reset_window_, p.dispatched.id});
            if (record.transfer == UINT64_MAX || record.delivery != UINT64_MAX ||
                !record.cancellation.empty())
                throw std::logic_error("FE20: duplicate/unassociated output delivery obligation");
            record.delivery = cycle_;
            bool fault = false;
            for (unsigned lane = 0; lane < cfg_.lanes; ++lane)
                if (p.dispatched.mask & (1u << lane)) {
                    const auto &l = p.dispatched.lanes[lane];
                    fault |= l.error;
                    counter("FEV02/lane/" + std::to_string(l.source_lane));
                    if (l.error) {
                        counter("fault");
                        counter("FEV17/cause/" + std::to_string(l.cause));
                    }
                    auto dec = early::decode(l.word);
                    if (dec.control() && l.prediction.pc < program_.marker) {
                        counter("dispatch-control");
                        if (!l.rewritten) {
                            counter(l.raw.hit ? "raw-hit" : "raw-miss");
                            counter(l.raw.taken ? "raw-taken" : "raw-not-taken");
                        }
                        for (auto &goal : learning_)
                            if (goal.pc == l.prediction.pc &&
                                training_window(l.request_cycle, goal.cycle, goal.superseded) &&
                                !goal.canceled) {
                                if (l.rewritten)
                                    goal.inferred = true;
                                else
                                    goal.public_witness = true;
                            }
                        if (dec.kind == early::Kind::Call || dec.kind == early::Kind::Jal) {
                            if (l.rewritten && l.raw.hit && !l.raw.taken)
                                counter("jal-hit-not-taken");
                            if (l.rewritten && !l.raw.hit) {
                                cold_jals_[l.prediction.pc]++;
                                counter("cold-jal");
                            }
                            if (!l.rewritten && l.raw.hit && l.raw.taken && site_updates_[l.prediction.pc]) {
                                counter("warm-jal");
                                if (cold_jals_[l.prediction.pc])
                                    counter("jal-cold-to-warm");
                            }
                        }
                        if (dec.kind == early::Kind::Return) {
                            counter("return");
                            if (l.ras_nonempty) {
                                counter("return-witness");
                                if (l.raw.hit && l.raw.taken && l.raw.target == l.ras_top)
                                    counter("return-bpu-equals-ras");
                                if (l.raw.hit && l.raw.taken && l.raw.target != l.ras_top)
                                    counter("return-bpu-differs-ras");
                            } else
                                counter("return-empty");
                        }
                        if (dec.kind == early::Kind::Branch && l.raw.hit && site_updates_[l.prediction.pc])
                            counter("conditional-trained");
                        if (dec.kind == early::Kind::Branch && !l.rewritten &&
                            interference_.count(l.prediction_index) &&
                            l.request_cycle > interference_[l.prediction_index])
                            counter("gshare-interference-witness");
                        if (scenario_.id == "FE-T15" && !l.rewritten) {
                            public_directions_[l.prediction_index] = {l.request_cycle, l.raw.taken};
                            for (auto &t : thresholds_)
                                if (t.index == l.prediction_index) {
                                    t.prior |= l.request_cycle < t.cycle && l.raw.taken == t.before;
                                    t.later |= l.request_cycle > t.cycle && l.raw.taken == t.after;
                                    if (t.prior && t.later && !t.credited) {
                                        counter(t.after ? "gshare-public-threshold-up"
                                                        : "gshare-public-threshold-down");
                                        t.credited = true;
                                    }
                                }
                        }
                        if (scenario_.id == "FE-T14" && dec.kind == early::Kind::Branch && !l.raw.hit &&
                            conflict_cycle_ && l.request_cycle > conflict_cycle_ &&
                            (l.prediction.pc == cfg_.boot + 0x18 ||
                             l.prediction.pc == cfg_.boot + 0x18 + 4 * (uint64_t(1) << cfg_.btb_bits)))
                            counter("btb-conflict-miss");
                    }
                }
            if (!fault && local_["fault-delivery"] && local_["frontend-flush"])
                counter("new-epoch-clean");
            if (schedule_backend && !fault)
                backend_->dispatch(p.dispatched, cycle_);
            else if (fault)
                counter("fault-delivery");
            ++stats.delivered;
            counter("FEV01/dispatch");
            if (local_["priority-triple"] && p.dispatched.lanes[0].prediction.pc == program_.marker)
                counter("triple-target-delivered");
            ras_witness_.bind(backend_->records());
        }
        if (r) {
            auto &record = memory_ledger_.at({reset_window_, physical_.front().id});
            if (record.response != UINT64_MAX || !record.cancellation.empty())
                throw std::logic_error("FE20: duplicate/canceled memory response obligation");
            record.response = cycle_;
            physical_.pop_front();
            ++stats.responses;
            counter("FEV01/response");
        }
        if (i.flush || actual.early_flush) {
            stats.canceled += p.mt.canceled_ids.size() + (i.flush ? p.output : 0);
            cancel_memory_obligations(i.flush ? "frontend-" + i.reason : "early-memory-flush", !i.flush);
            physical_.clear();
            counter(actual.early_flush ? "early-flush" : "frontend-flush");
        }
        if (k) {
            if (physical_.size() >= cfg_.depth)
                throw std::invalid_argument("FE13: overcapacity physical grant");
            MemoryLife record;
            record.id = physical_id_;
            record.window = reset_window_;
            record.address = actual.address;
            record.accepted = cycle_;
            if (!memory_ledger_.emplace(std::make_pair(reset_window_, physical_id_), record).second)
                throw std::logic_error("FE20: duplicate physical request identity");
            auto payload = program_.read(actual.address, cfg_.lanes);
            physical_.push_back(
                {physical_id_++, actual.address, cycle_, cycle_ + 1 + bounded(memory_rng_, 8), payload});
            ++stats.requests;
            counter("FEV01/request");
            if (local_["priority-triple"] && actual.address == program_.marker)
                counter("triple-redirect-refetch");
        }
        if (schedule_backend)
            backend_->consume_feedback(backend_feedback, cycle_);
        if (i.feedback.train && !i.flush_bpu) {
            ++stats.updates;
            site_updates_[i.feedback.resolution.pc]++;
            for (auto &goal : learning_)
                if (goal.superseded == UINT64_MAX &&
                    (goal.pc / 4) % (uint64_t(1) << cfg_.btb_bits) ==
                        (i.feedback.resolution.pc / 4) % (uint64_t(1) << cfg_.btb_bits))
                    goal.superseded = cycle_;
            learning_.push_back({i.feedback.id, i.feedback.resolution.pc, cycle_, false, false, false});
            learning_.back().window = reset_window_;
            counter("update");
        }
        if (i.feedback.call || i.feedback.ret) {
            ++stats.confirmations;
            counter("confirmation");
        }
        if (i.feedback.flush) {
            ++stats.recoveries;
            counter("recovery");
            if (scenario_.id == "FE-T20" &&
                backend_->record(i.feedback.id).semantic.decoded.kind == early::Kind::Jal)
                counter("poisoned-recovery");
        }
    } else {
        stats.canceled += physical_.size();
        cancel_memory_obligations("reset");
        physical_.clear();
    }
    if (i.rst_n) {
        uint64_t confirm_pc = 0;
        if (schedule_backend && i.feedback.id && (i.feedback.call || i.feedback.ret))
            confirm_pc = backend_->record(i.feedback.id).pc;
        ras_witness_.edge(p, model_->ras(), cycle_, model_->epoch(), i.flush, i.reason, confirm_pc);
    }
    if (i.rst_n && i.commit && p.pi.recovery() && p.pi.early)
        counter("priority-triple");
    const auto update = model_->edge(i, p);
    context_->timeInc(1);
    dut_->clk_i = 1;
    dut_->eval();
    auto after = model_->plan(i, cycle_);
    bool matched = sample(i, after, "post", false);
    if (trace_)
        trace_->dump(context_->time());
    context_->timeInc(1);
    dut_->clk_i = 0;
    dut_->eval();
    matched = sample(i, after, "falling", false) && matched;
    if (trace_)
        trace_->dump(context_->time());
    if (i.flush_bpu) {
        last_pht_.clear();
        interference_.clear();
        site_updates_.clear();
        cold_jals_.clear();
        for (auto &goal : learning_)
            if (!goal.public_witness && !goal.inferred) {
                goal.canceled = true;
                goal.cancellation_reason = "predictor-flush";
            }
    }
    if (update) {
        if (scenario_.id == "FE-T15" && (update->before >= 2) != (update->after >= 2)) {
            Threshold t{update->index, cycle_, update->before >= 2, update->after >= 2};
            auto prev = public_directions_.find(t.index);
            if (prev != public_directions_.end())
                t.prior = prev->second.first < t.cycle && prev->second.second == t.before;
            thresholds_.push_back(t);
        }
        const auto pc = i.feedback.resolution.pc;
        auto old = last_pht_.find(update->index);
        if (old != last_pht_.end() && old->second.pc != pc &&
            old->second.taken != i.feedback.resolution.taken) {
            counter("gshare-opposing-update");
            interference_[update->index] = cycle_;
        }
        last_pht_[update->index] = {pc, cycle_, i.feedback.resolution.taken};
        if (scenario_.id == "FE-T14" && update->replacement &&
            (pc == cfg_.boot + 0x18 || pc == cfg_.boot + 0x18 + 4 * (uint64_t(1) << cfg_.btb_bits))) {
            counter("btb-conflict-replacement");
            if (!conflict_cycle_)
                conflict_cycle_ = cycle_;
        }
        training_ << "{\"scenario\":" << json_quote(scenario_.id)
                  << ",\"event\":\"bpu-update\",\"id\":" << i.feedback.id
                  << ",\"pc\":" << json_quote(hex64(pc)) << ",\"instance\":" << instance_
                  << ",\"cycle\":" << cycle_ << ",\"history_before\":" << update->history
                  << ",\"index\":" << update->index << ",\"counter_before\":" << update->before
                  << ",\"counter_after\":" << update->after << ",\"taken\":" << i.feedback.resolution.taken
                  << ",\"replacement\":" << update->replacement << ",\"deletion\":" << update->deletion
                  << "}\n";
    }
    if (matched && p.a && p.ee.selection.lane >= 0) {
        const auto lane = unsigned(p.ee.selection.lane);
        const auto &raw = p.es.inputs.predictions[lane];
        training_ << "{\"scenario\":" << json_quote(scenario_.id)
                  << ",\"event\":\"early-accept\",\"cycle\":" << cycle_ << ",\"request_id\":" << p.transfer.id
                  << ",\"pc\":" << json_quote(hex64(raw.pc)) << ",\"raw_hit\":" << raw.hit
                  << ",\"raw_taken\":" << raw.taken << ",\"raw_target\":" << json_quote(hex64(raw.target))
                  << ",\"correction\":"
                  << (p.ee.selection.correction.known && p.ee.selection.correction.value)
                  << ",\"public_memory_flush\":" << p.early
                  << ",\"target\":" << json_quote(hex64(p.ee.selection.target.value)) << "}\n";
    }
    if (i.rst_n) {
        if (matched && p.d) {
            counter("FEV13/public-operation-witness", ras_witness_.dispatch(p.dispatched, cycle_));
            if (ras_witness_.restored_multiple() > local_["RAS-multiple-entry-restoration"])
                counter("RAS-multiple-entry-restoration",
                        ras_witness_.restored_multiple() - local_["RAS-multiple-entry-restoration"]);
        }
        counter("FEV01/row/" + std::to_string(p.row));
        counter("FEV03/q/" + std::to_string(p.q));
        counter("FEV03/answer/" + std::to_string(p.answers));
        counter("FEV03/output/" + std::to_string(p.output));
        if (p.a && p.transfer.mask)
            counter("EJU-accepted");
        if (p.es.inputs.valid && !p.es.inputs.ready)
            counter("EJU-stalled");
        if (p.early)
            counter("FEV10/early-completion");
        if (i.feedback.train && p.a && p.early)
            counter("training-and-early-correction");
        if ((i.feedback.call || i.feedback.ret) && (!i.ready || !i.grant))
            counter("confirmation-during-stall");
        if (i.feedback.train && update) {
            counter("FEV06/transition/" + std::to_string(update->before) + "-" +
                    std::to_string(update->after));
            if (update->replacement)
                counter("btb-replacement");
            if (update->deletion)
                counter("btb-deletion");
        }
    }
    if (schedule_backend && i.rst_n) {
        backend_->advance(cycle_);
        collect_backend();
    }
    ++cycle_;
    ++stats.cycles;
    if (!matched) {
        quarantined_ = true;
        throw std::runtime_error("comparison failure: post-edge divergence; oracle not repaired");
    }
}
void Simulator::collect_backend() {
    for (const auto &r : backend_->records()) {
        if (r.completed && executed_.insert(r.id).second) {
            ++stats.executions;
            if (scenario_.id == "FE-T37" && r.id == 2 && backend_->record(1).latency == 64 &&
                r.latency == 1 && r.execute > backend_->record(1).execute)
                counter("latency64-before1");
            if (r.semantic.control && r.pc < program_.marker) {
                counter("branch-execution");
                counter(r.wrong ? "wrong-effective" : "correct-effective");
                if (r.semantic.decoded.kind == early::Kind::Jal && r.payload.raw.hit && r.payload.raw.taken &&
                    !r.payload.rewritten && r.payload.raw.target != r.semantic.target)
                    counter("wrong-target-jal-suppressed");
                if (r.semantic.decoded.kind == early::Kind::Branch)
                    counter(r.semantic.taken ? "conditional-taken" : "conditional-not-taken");
                if (r.semantic.decoded.kind == early::Kind::Return) {
                    ret_targets_[r.pc].insert(r.semantic.target);
                    if (scenario_.id == "FE-T32") {
                        std::set<uint64_t> targets;
                        for (const auto &site : ret_targets_)
                            targets.insert(site.second.begin(), site.second.end());
                        if (targets.size() == 1 + scenario_.variant % (cfg_.ras_depth + 2))
                            counter("nested-full-unwind");
                    }
                    if (ret_targets_[r.pc].size() > 1)
                        counter("multiple-return-targets");
                    const auto &raw = r.payload.raw;
                    if (raw.hit && raw.taken) {
                        counter(raw.target == r.semantic.target ? "return-bpu-correct" : "return-bpu-stale");
                        if (raw.target == r.semantic.target && r.payload.ras_nonempty &&
                            r.payload.ras_top != r.semantic.target)
                            counter("correct-btb-stale-ras");
                    }
                    if (r.payload.ras_nonempty)
                        counter(r.payload.ras_top == r.semantic.target ? "return-ras-correct"
                                                                       : "return-ras-stale");
                }
                training_ << "{\"scenario\":" << json_quote(scenario_.id)
                          << ",\"event\":\"execute\",\"id\":" << r.id << ",\"epoch\":" << r.epoch
                          << ",\"pc\":" << json_quote(hex64(r.pc)) << ",\"word\":" << r.payload.word
                          << ",\"iteration\":" << r.iteration << ",\"a\":" << json_quote(hex64(r.a))
                          << ",\"b\":" << json_quote(hex64(r.b)) << ",\"raw_hit\":" << r.payload.raw.hit
                          << ",\"raw_taken\":" << r.payload.raw.taken
                          << ",\"raw_target\":" << json_quote(hex64(r.payload.raw.target))
                          << ",\"raw_observation\":"
                          << json_quote(r.payload.rewritten ? "inferred-hidden-by-EJU"
                                                            : "matched-public-saved-metadata")
                          << ",\"rewritten\":" << r.payload.rewritten
                          << ",\"attached_hit\":" << r.payload.prediction.hit
                          << ",\"attached_taken\":" << r.payload.prediction.taken
                          << ",\"attached_target\":" << json_quote(hex64(r.payload.prediction.target))
                          << ",\"taken\":" << r.semantic.taken
                          << ",\"target\":" << json_quote(hex64(r.semantic.target))
                          << ",\"mispredict\":" << r.wrong << ",\"dispatch\":" << r.dispatch
                          << ",\"sampled_latency\":" << r.latency << ",\"earliest\":" << r.earliest
                          << ",\"issue\":" << r.issue << ",\"dependency_ready\":" << r.dependency_ready
                          << ",\"order_delay\":" << r.order_delay << ",\"execute\":" << r.execute << "}\n";
            }
        }
        if (r.trained && trained_.insert(r.id).second) {
            const auto &bp = model_->predictor();
            training_ << "{\"scenario\":" << json_quote(scenario_.id)
                      << ",\"event\":\"update\",\"id\":" << r.id << ",\"pc\":" << json_quote(hex64(r.pc))
                      << ",\"cycle\":" << r.update << ",\"taken\":" << r.semantic.taken
                      << ",\"history_after\":" << bp.history() << "}\n";
        }
        if (r.confirmed && confirmed_.insert(r.id).second)
            counter("FEV13/confirmed");
        if (r.retired && retired_.insert(r.id).second) {
            ++stats.retired;
            if (r.pc == program_.marker)
                counter("program-marker");
        }
    }
}
void Simulator::reset() {
    ++reset_window_;
    ras_witness_ = RasWitness{};
    model_ = std::make_unique<Composition>(cfg_, options_.ras_order);
    active_latency_ = options_.latency;
    active_latency_seed_ = options_.seed;
    if (scenario_.id == "FE-T47" || scenario_.id == "FE-T34") {
        active_latency_ = LatencyOptions{};
        active_latency_.distribution = "fixed";
        active_latency_.fixed = active_latency_.maximum;
    }
    if (scenario_.id == "FE-T38") {
        static const char *distributions[] = {"uniform",         "fixed",           "triangular-early",
                                              "triangular-late", "triangular-mode", "truncated-geometric",
                                              "bimodal"};
        active_latency_.distribution = distributions[scenario_.variant % 7];
    }
    if (scenario_.id == "FE-T37") {
        active_latency_ = LatencyOptions{};
        for (active_latency_seed_ = 0; active_latency_seed_ < 100000; ++active_latency_seed_) {
            LatencySampler sample(active_latency_, active_latency_seed_);
            if (sample.sample() == 64 && sample.sample() == 1)
                break;
        }
        if (active_latency_seed_ == 100000)
            throw std::logic_error("missing 64/1 deterministic fixture");
    }
    backend_ = std::make_unique<Backend>(cfg_, active_latency_, active_latency_seed_);
    physical_.clear();
    physical_id_ = 1;
    executed_.clear();
    trained_.clear();
    confirmed_.clear();
    retired_.clear();
    site_updates_.clear();
    cold_jals_.clear();
    ret_targets_.clear();
    last_pht_.clear();
    interference_.clear();
    thresholds_.clear();
    public_directions_.clear();
    conflict_cycle_ = 0;
    learning_.clear();
    Inputs i;
    i.rst_n = false;
    i.ready = false;
    context_->timeInc(2);
    drive(i);
    dut_->eval();
    model_->input_change(i);
    auto asynchronous = model_->plan(i, cycle_);
    if (!sample(i, asynchronous, "async", false))
        throw std::runtime_error("comparison failure: asynchronous reset");
    if (trace_)
        trace_->dump(context_->time());
    step(i, false);
    step(i, false);
    i.rst_n = true;
    step(i, false);
}
void Simulator::run(const Scenario &s, uint64_t limit) {
    scenario_ = s;
    ++instance_;
    local_.clear();
    memory_ledger_.clear();
    backend_ledger_.clear();
    ras_windows_.clear();
    learning_archive_.clear();
    learning_.clear();
    quarantined_ = false;
    const uint64_t checks_before = stats.checks, errors_before = stats.field_errors;
    std::string problem;
    program_ = make_program(cfg_, s.family, s.repetitions, s.variant);
    if (s.id == "FE-T31")
        program_ = make_program(cfg_, s.family, s.repetitions, unsigned(options_.seed));
    if (!options_.program.empty())
        program_ = make_program(cfg_, options_.program, options_.repetitions, s.variant);
    if (s.id == "FE-T06" || s.id == "FE-T07" || s.id == "FE-T45" || s.id == "FE-T50")
        program_.faults[program_.labels.count("target") ? program_.labels.at("target")
                                                        : cfg_.boot + 4 * (s.variant % cfg_.lanes)] =
            (s.id == "FE-T07" ? 0 : 1);
    if (options_.random && s.classification == "characterization")
        program_.faults[cfg_.boot + 4 * (s.variant % cfg_.lanes)] = s.variant % 2;
    if (s.id == "FE-T50") {
        const auto pc = program_.labels.at("target");
        program_.text[pc] = early::jal(1, int64_t(program_.marker - pc));
    }
    program_.validate();
    programs_.push_back(program_.json());
    std::ofstream(options_.run_dir + "/program-" + s.id + "-" + std::to_string(instance_) + ".json")
        << "{\"scenario\":" << json_quote(s.id) << "," << program_.json().substr(1) << '\n';
    TB_LOG(LOG_LOW, "REQ > starting %s %s program=%s digest=%s", s.id.c_str(), s.title.c_str(),
           program_.family.c_str(), program_.digest().c_str());
    try {
        reset();
        if (s.id == "FE-T40") {
            LatencyOptions timing;
            timing.distribution = "fixed";
            timing.fixed = 2;
            Backend checker(cfg_, timing, 1);
            Bundle b;
            b.id = 1;
            b.mask = 1;
            b.lanes[0].word = early::jal(1, 8);
            b.lanes[0].prediction.pc = cfg_.boot;
            checker.dispatch(b, 0);
            for (uint64_t t = 0; t <= 2; ++t)
                checker.advance(t);
            checker.consume_feedback(checker.feedback(3), 3);
            const auto once = checker.feedback(4);
            checker.consume_feedback(once, 4);
            auto held = once;
            held.train = false;
            bool rejected = false;
            try {
                checker.validate_feedback(held, 5);
            } catch (const std::invalid_argument &) {
                rejected = true;
            }
            if (!rejected || checker.stats.updates != 1 || checker.stats.recoveries != 1)
                throw std::logic_error("FE-T40 held redirect duplicated accepted update/recovery");
            counter("held-redirect-rejected");
        }
        if (s.id == "FE-T53") {
            LatencyOptions timing;
            timing.distribution = "fixed";
            timing.fixed = 2;
            Backend checker(cfg_, timing, 1);
            Bundle b;
            b.id = 1;
            b.mask = 1;
            b.lanes[0].word = early::branch(1, 0, 0, 16);
            b.lanes[0].prediction.pc = cfg_.boot;
            checker.dispatch(b, 0);
            const auto rejects = [&](const std::function<void()> &operation) {
                bool caught = false;
                try {
                    operation();
                } catch (const std::invalid_argument &) {
                    caught = true;
                }
                if (!caught)
                    throw std::logic_error("FE17: negative backend fixture was not rejected");
                counter("backend-negative-rejections");
            };
            rejects([&] { checker.dispatch(b, 0); });
            rejects([&] {
                Feedback f;
                f.id = 999;
                f.train = true;
                checker.validate_feedback(f, 2);
            });
            for (uint64_t t = 0; t < 3; ++t)
                checker.advance(t);
            auto valid = checker.feedback(3);
            if (!valid.train)
                throw std::logic_error("missing independent backend positive fixture");
            auto bad = valid;
            bad.resolution.target += 4;
            rejects([&] { checker.validate_feedback(bad, 3); });
            checker.consume_feedback(valid, 3);
            rejects([&] { checker.validate_feedback(valid, 3); });
        }
        const uint64_t start = cycle_, budget = limit ? (limit > 4 ? limit - 4 : 0) : s.budget;
        bool held_response = false;
        uint64_t fault_cycle = 0, simultaneous_cycle = 0;
        bool observation_only = false, populated_reset = false;
        for (uint64_t step_index = 0; cycle_ - start < budget; ++step_index) {
            bool reset_ready = false;
            if (s.id == "FE-T47" && !populated_reset) {
                bool pending_control = false;
                for (const auto &record : backend_->records())
                    pending_control |= record.semantic.control && !record.trained && !record.canceled;
                const auto state_probe = model_->plan(Inputs{}, cycle_);
                reset_ready = !model_->ras().confirmed.entries.empty() &&
                              !model_->ras().predictive.entries.empty() && !site_updates_.empty() &&
                              state_probe.q == 2 && state_probe.answers == 2 && state_probe.output == 2 &&
                              pending_control;
            }
            if (reset_ready) {
                for (auto goal : learning_) {
                    if (!goal.public_witness && !goal.inferred) {
                        goal.canceled = true;
                        goal.cancellation_reason = "populated-history-reset";
                    }
                    learning_archive_.push_back(goal);
                }
                ras_windows_.push_back(ras_witness_.json("populated-history-reset"));
                cancel_memory_obligations("populated-history-reset");
                capture_backend_obligations("populated-history-reset");
                stats.canceled += model_->pending();
                stats.dynamic += backend_->stats.dispatched;
                stats.backend_canceled += backend_->stats.canceled + backend_->pending();
                backend_->cancel_all();
                reset();
                populated_reset = true;
                held_response = false;
                local_.erase("program-marker");
                counter("populated-history-reset");
                continue;
            }
            Inputs i;
            i.ready = backend_->ready() && bounded(events_, 100) < ready_weight_;
            i.grant = physical_.size() < cfg_.depth && bounded(events_, 100) < grant_weight_;
            i.feedback = backend_->feedback(cycle_);
            i.flush = i.feedback.flush;
            if (i.flush)
                i.reason = "misprediction";
            if (!physical_.empty() && (held_response || (cycle_ >= physical_.front().due &&
                                                         bounded(events_, 100) < response_weight_))) {
                i.response_valid = true;
                i.response = physical_.front().payload;
                held_response = true;
            }
            if ((s.id == "FE-T04" || s.id == "FE-T25" || s.id == "FE-T39") && step_index % 160 < 96)
                i.ready = false;
            if (s.id == "FE-T47" && !populated_reset && !model_->ras().confirmed.entries.empty())
                i.ready = false;
            if ((s.id == "FE-T52" || (options_.random && s.classification == "interface_stress")) &&
                step_index == 200)
                i.flush_bpu = true;
            if (s.id == "FE-T43" || s.id == "FE-T49") {
                if (step_index == 200) {
                    i.flush = i.flush_bpu = true;
                    i.reason = "exception";
                    backend_->cancel_all();
                }
                if (step_index == 206) {
                    i.commit = true;
                    i.commit_pc = program_.marker;
                }
            }
            if (s.id == "FE-T44" && !simultaneous_cycle && model_->plan(i, cycle_).pi.early) {
                simultaneous_cycle = cycle_;
                i.flush = true;
                i.reason = "branch";
                i.commit = true;
                i.commit_pc = program_.marker;
                i.feedback = {0, {cfg_.boot, cfg_.boot + 0x100, true, true}, true, true, true, false, false,
                              0};
                backend_->cancel_all();
            }
            bool special = s.id == "FE-T43" || s.id == "FE-T44" || s.id == "FE-T49";
            if (local_["fault-delivery"] && !fault_cycle)
                fault_cycle = cycle_;
            if (fault_cycle && cycle_ == fault_cycle + 1) {
                i.flush = i.flush_bpu = true;
                i.reason = "exception";
                backend_->cancel_all();
                i.feedback = {};
            }
            if (fault_cycle && cycle_ == fault_cycle + 6) {
                i.commit = true;
                i.commit_pc = program_.marker;
            }
            if (s.id == "FE-T41" && !simultaneous_cycle && i.feedback.call) {
                i.flush = true;
                i.reason = "misprediction";
                simultaneous_cycle = cycle_;
                counter("simultaneous-confirm-restore");
            }
            if (s.id == "FE-T41" && simultaneous_cycle && cycle_ == simultaneous_cycle + 1) {
                i.commit = true;
                i.commit_pc = program_.labels.at("function");
            }
            if (s.id == "FE-T52" && !i.feedback.id) {
                i.feedback.resolution = {events_() & ~uint64_t(3), events_() & ~uint64_t(3),
                                         bool(events_() & 1), bool(events_() & 1)};
                i.feedback.link = events_();
                counter("inactive-feedback-noise");
            }
            const auto responses_before = stats.responses;
            step(i, !special && !fault_cycle && program_.faults.empty() && !observation_only);
            if (simultaneous_cycle && cycle_ == simultaneous_cycle + 1) {
                backend_->cancel_all();
                observation_only = true;
            }
            if (s.id == "FE-T41" && observation_only && local_["return-witness"] &&
                cycle_ > simultaneous_cycle + 20)
                break;
            if (s.id == "FE-T44" && local_["triple-target-delivered"])
                break;
            if (stats.responses != responses_before || i.flush || physical_.empty())
                held_response = false;
            if (local_["fault-delivery"] && local_["new-epoch-clean"] && fault_cycle &&
                cycle_ > fault_cycle + 128 && (!options_.random || cycle_ - start + 512 < budget))
                break;
            if (local_["program-marker"] && (s.id != "FE-T47" || populated_reset) &&
                (!options_.random || cycle_ - start + 512 < budget))
                break;
        }
    } catch (const std::invalid_argument &e) {
        problem = e.what();
        error("environment_error", problem);
    } catch (const std::logic_error &e) {
        problem = e.what();
        error("framework_error", problem);
    } catch (const std::exception &e) {
        problem = e.what();
        if (problem.rfind("comparison failure", 0) != 0 && problem.rfind("incomplete:", 0) != 0)
            error("framework_error", problem);
    }
    std::vector<std::string> missing;
    for (const auto &w : s.witnesses)
        if (!local_[w])
            missing.push_back(w);
    const bool finite_semantic = !options_.random && s.classification == "architectural" &&
                                 s.id != "FE-T06" && s.id != "FE-T07" && s.id != "FE-T45";
    if (finite_semantic && !local_["program-marker"])
        missing.push_back("FE20:program-termination-not-witnessed");
    learning_.insert(learning_.begin(), learning_archive_.begin(), learning_archive_.end());
    uint64_t learning_public = 0, learning_inferred = 0;
    for (const auto &l : learning_) {
        learning_public += l.public_witness;
        learning_inferred += !l.public_witness && l.inferred;
    }
    std::ofstream obligations(options_.run_dir + "/logs/obligations-" + std::to_string(instance_) + ".json");
    obligations << "{\"scenario\":" << json_quote(s.id) << ",\"training\":[";
    bool first_obligation = true;
    for (const auto &goal : learning_) {
        if (!first_obligation)
            obligations << ',';
        first_obligation = false;
        obligations << "{\"id\":" << goal.id << ",\"window\":" << goal.window
                    << ",\"pc\":" << json_quote(hex64(goal.pc)) << ",\"update_cycle\":" << goal.cycle
                    << ",\"superseded_cycle\":";
        if (goal.superseded == UINT64_MAX)
            obligations << "null";
        else
            obligations << goal.superseded;
        obligations << ",\"scope\":\"source-PC/BTB reuse; not individual PHT/GHR observability\",\"status\":"
                    << json_quote(goal.canceled                   ? "canceled-" + goal.cancellation_reason
                                  : goal.public_witness           ? "public-witness"
                                  : goal.inferred                 ? "inferred-with-public-EJU-effect"
                                  : goal.superseded != UINT64_MAX ? "superseded-before-refetch-witness"
                                                                  : "canceled-controlled-stop-unwitnessed")
                    << '}';
    }
    obligations << "]";
    obligations << ",\"RAS_windows\":[";
    for (const auto &window : ras_windows_)
        obligations << window << ',';
    obligations << ras_witness_.json("controlled-stop") << ']';
    counter("FEV05/public-training-witness", learning_public);
    counter("FEV05/inferred-training-witness", learning_inferred);
    const uint64_t bpending = backend_ ? backend_->pending() : 0, mpending = model_ ? model_->pending() : 0;
    uint64_t retired = backend_ ? backend_->stats.retired : 0,
             canceled = backend_ ? backend_->stats.canceled : 0;
    // Controlled stop: close residual speculative work explicitly, never call
    // the active fetch pipeline naturally drained or count reset as a witness.
    if (backend_) {
        capture_backend_obligations("controlled-stop");
        backend_->cancel_all();
        stats.backend_canceled += canceled + bpending;
        stats.dynamic += backend_->stats.dispatched;
    }
    if (model_) {
        const auto canceled_before = stats.canceled;
        Inputs end;
        end.rst_n = false;
        end.ready = false;
        try {
            step(end, false);
        } catch (const std::exception &e) {
            if (problem.empty())
                problem = e.what();
        }
        stats.canceled = canceled_before + mpending;
    }
    obligations << ",\"memory\":[";
    bool first_memory = true;
    uint64_t memory_delivered = 0, memory_canceled = 0, memory_pending = 0;
    for (const auto &entry : memory_ledger_) {
        const auto &m = entry.second;
        if (!first_memory)
            obligations << ',';
        first_memory = false;
        const bool delivered = m.delivery != UINT64_MAX;
        const bool canceled = !m.cancellation.empty();
        memory_delivered += delivered;
        memory_canceled += canceled;
        memory_pending += !delivered && !canceled;
        obligations << "{\"window\":" << m.window << ",\"id\":" << m.id
                    << ",\"address\":" << json_quote(hex64(m.address)) << ",\"accepted\":" << m.accepted;
        for (const auto &phase :
             {std::make_pair("response", m.response), std::make_pair("transfer", m.transfer),
              std::make_pair("delivery", m.delivery)}) {
            obligations << ',' << json_quote(phase.first) << ':';
            if (phase.second == UINT64_MAX)
                obligations << "null";
            else
                obligations << phase.second;
        }
        obligations << ",\"status\":"
                    << json_quote(delivered  ? "delivered"
                                  : canceled ? "canceled"
                                             : "pending")
                    << ",\"cancellation\":" << json_quote(m.cancellation) << '}';
    }
    if (memory_pending)
        missing.push_back("FE20:unclosed-memory-obligations");
    obligations << "],\"memory_totals\":{\"accepted\":" << memory_ledger_.size()
                << ",\"delivered\":" << memory_delivered << ",\"canceled\":" << memory_canceled
                << ",\"pending\":" << memory_pending << "},\"backend\":[";
    for (size_t k = 0; k < backend_ledger_.size(); ++k) {
        if (k)
            obligations << ',';
        obligations << backend_ledger_[k];
    }
    obligations << "]}\n";
    if (options_.profile == "predictor-agnostic")
        missing.push_back("FEQ01:fully-predictor-agnostic-path-oracle-not-implemented");
    const bool mismatch = stats.field_errors != errors_before;
    std::string status = mismatch                                    ? "failed"
                         : problem.rfind("incomplete:", 0) == 0      ? "incomplete"
                         : !problem.empty()                          ? "invalid"
                         : !s.limitation.empty() || !missing.empty() ? "incomplete"
                                                                     : "passed";
    std::ostringstream result;
    result << "{\"scenario\":" << json_quote(s.id) << ",\"title\":" << json_quote(s.title)
           << ",\"status\":" << json_quote(status) << ",\"classification\":" << json_quote(s.classification)
           << ",\"program\":" << json_quote(program_.family)
           << ",\"program_digest\":" << json_quote(program_.digest())
           << ",\"execution_latency\":" << active_latency_.json()
           << ",\"execution_latency_seed\":" << active_latency_seed_
           << ",\"comparisons\":" << stats.checks - checks_before
           << ",\"field_errors\":" << stats.field_errors - errors_before
           << ",\"reason\":" << json_quote(problem.empty() ? s.limitation : problem)
           << ",\"missing_witnesses\":[";
    for (size_t k = 0; k < missing.size(); ++k) {
        if (k)
            result << ',';
        result << json_quote(missing[k]);
    }
    result << "],\"witnesses\":{";
    bool first = true;
    for (const auto &x : local_) {
        if (!first)
            result << ',';
        first = false;
        result << json_quote(x.first) << ':' << x.second;
    }
    result << "},\"controlled_stop\":{\"frontend_canceled\":" << mpending
           << ",\"backend_canceled\":" << bpending << ",\"backend_retired\":" << retired
           << "},\"training_public_witnesses\":" << learning_public
           << ",\"training_inferred_witnesses\":" << learning_inferred << '}';
    results_.push_back(result.str());
    if (status == "passed")
        TB_SUCCESS(LOG_LOW, "Test successfully passed > %s checks=%" PRIu64, s.id.c_str(),
                   stats.checks - checks_before);
    else
        TB_WARN("%s > %s status=%s missing=%zu reason=%s",
                status == "incomplete" ? "Test incomplete" : "Test failed", s.id.c_str(), status.c_str(),
                missing.size(), (problem.empty() ? s.limitation : problem).c_str());
}
int Simulator::finish() {
    bool incomplete = false;
    bool invalid = false;
    for (const auto &r : results_) {
        incomplete |= r.find("\"status\":\"incomplete\"") != std::string::npos;
        invalid |= r.find("\"status\":\"invalid\"") != std::string::npos;
    }
    if (stats.requests != stats.delivered + stats.canceled)
        error("framework_error", "FE20: frontend request conservation failed");
    if (stats.dynamic != stats.retired + stats.backend_canceled)
        error("framework_error", "FE20: dynamic instruction conservation failed");
    const int status = stats.environment || stats.framework || invalid   ? 2
                       : stats.field_errors                              ? 1
                       : incomplete || !stats.checks || results_.empty() ? 3
                                                                         : 0;
    const auto dir = options_.run_dir + "/logs";
    std::ofstream cov(dir + "/coverage.json");
    cov << "{\"counters\":{";
    bool first = true;
    for (const auto &v : coverage_) {
        if (!first)
            cov << ',';
        first = false;
        cov << json_quote(v.first) << ':' << v.second;
    }
    cov << "},\"full_feature_closure\":false,\"excluded\":[\"immutable-JAL wrong "
           "BTB target requires "
           "poisoned-feedback stress\",\"internal occupancy and raw overwritten "
           "BPU state are "
           "inferred\",\"N-dependent lane crosses require active N\"]}\n";
    std::string replay =
        "'" + options_.executable + "' --scenario=" + options_.scenario +
        " --seed=" + std::to_string(options_.seed) + " --cycles=" + std::to_string(options_.cycles) +
        " --max_cycles=" + std::to_string(options_.max_cycles) + " --expect_fingerprint=" + cfg_.fingerprint +
        " --expect_issues=" + std::to_string(cfg_.lanes) + " --profile=" + options_.profile +
        " --ras_order=" + options_.ras_order +
        " --exec_latency_min=" + std::to_string(options_.latency.minimum) +
        " --exec_latency_max=" + std::to_string(options_.latency.maximum) +
        " --exec_latency_dist=" + options_.latency.distribution +
        " --journal=full --run_dir=NEW_REPLAY_DIRECTORY";
    replay += " --exec_latency_fixed=" + std::to_string(options_.latency.fixed) +
              " --exec_latency_mode=" + std::to_string(options_.latency.mode) +
              " --exec_geo_u=" + std::to_string(options_.latency.geo_u) +
              " --exec_geo_v=" + std::to_string(options_.latency.geo_v) +
              " --exec_short_u=" + std::to_string(options_.latency.short_u) +
              " --exec_short_v=" + std::to_string(options_.latency.short_v) +
              " --exec_short_min=" + std::to_string(options_.latency.short_min) +
              " --exec_short_max=" + std::to_string(options_.latency.short_max) +
              " --exec_long_min=" + std::to_string(options_.latency.long_min) +
              " --exec_long_max=" + std::to_string(options_.latency.long_max) +
              " --repetitions=" + std::to_string(options_.repetitions) + " --campaign=" + options_.campaign +
              " --guided=" + (options_.guided ? "true" : "false") + " --weights='" + options_.weights + "'";
    replay += " --directed_cycles=" + std::to_string(options_.directed_cycles) +
              " --directed_repetitions=" + std::to_string(options_.directed_repetitions);
    if (options_.variant != UINT32_MAX)
        replay += " --variant=" + std::to_string(options_.variant);
    if (options_.random)
        replay += " --random";
    if (!options_.program.empty())
        replay += " --program=" + options_.program;
    if (!options_.inject.empty())
        replay += " --inject_failure=" + options_.inject;
    std::ofstream report(dir + "/report.json");
    report << "{\"status\":"
           << json_quote(status == 0   ? "passed"
                         : status == 1 ? "failed"
                         : status == 2 ? "invalid"
                                       : "incomplete")
           << ",\"exit_status\":" << status << ",\"full_contract_signoff\":false,\"seed\":" << options_.seed
           << ",\"policy\":\"fetch-stage-closed-loop-v1\",\"profile\":" << json_quote(options_.profile)
           << ",\"config\":{\"LEN5_MULTIPLE_ISSUES\":" << cfg_.lanes
           << ",\"boot_pc\":" << json_quote(hex64(cfg_.boot))
           << ",\"fingerprint\":" << json_quote(cfg_.fingerprint)
           << "},\"latency\":" << options_.latency.json() << ",\"cycles_executed\":" << stats.cycles
           << ",\"sampled_records\":" << stats.samples << ",\"transactions\":" << stats.transactions
           << ",\"field_checks\":" << stats.checks << ",\"field_errors\":" << stats.field_errors
           << ",\"confirmed_mismatches\":" << stats.confirmed
           << ",\"provisional_mismatches\":" << stats.provisional
           << ",\"injected_failures\":" << stats.injected << ",\"environment_errors\":" << stats.environment
           << ",\"framework_errors\":" << stats.framework << ",\"requests\":" << stats.requests
           << ",\"responses\":" << stats.responses << ",\"delivered\":" << stats.delivered
           << ",\"canceled\":" << stats.canceled << ",\"dynamic_instructions\":" << stats.dynamic
           << ",\"retired\":" << stats.retired << ",\"backend_canceled\":" << stats.backend_canceled
           << ",\"updates\":" << stats.updates << ",\"confirmations\":" << stats.confirmations
           << ",\"executions\":" << stats.executions << ",\"recoveries\":" << stats.recoveries
           << ",\"stimulus_digest\":" << json_quote(hex64(stimulus_digest_))
           << ",\"replay_command\":" << json_quote(replay) << ",\"scenarios\":[";
    for (size_t k = 0; k < results_.size(); ++k) {
        if (k)
            report << ',';
        report << results_[k];
    }
    report << "],\"discrepancies\":[";
    for (size_t k = 0; k < discrepancies_.size(); ++k) {
        if (k)
            report << ',';
        report << discrepancies_[k];
    }
    report << "],\"requirement_checks\":{";
    first = true;
    for (const auto &r : requirements_) {
        if (!first)
            report << ',';
        first = false;
        report << json_quote(r.first) << ':' << r.second;
    }
    report << "},\"assumption_checks\":{";
    first = true;
    for (const auto &r : assumptions_) {
        if (!first)
            report << ',';
        first = false;
        report << json_quote(r.first) << ':' << r.second;
    }
    report << "},\"unknown_output_samples\":{";
    first = true;
    for (const auto &r : unknowns_) {
        if (!first)
            report << ',';
        first = false;
        report << json_quote(r.first) << ':' << r.second;
    }
    report << "},\"unresolved_questions\":[";
    for (unsigned k = 1; k <= 13; ++k) {
        if (k > 1)
            report << ',';
        report << json_quote(std::string("FEQ") + (k < 10 ? "0" : "") + std::to_string(k));
    }
    report << "],\"known_defects\":[\"EQ08 exception-contaminated confirmed "
              "RAS\",\"FQ12 delayed exception "
              "recovery window\"]}\n";
    if (!report || !cov || !training_ || !journal_)
        throw std::runtime_error("report output failure");
    if (status)
        TB_ERR("TEST FAILED > errors: %" PRIu64 "/%" PRIu64, stats.failed_samples, stats.transactions);
    else
        TB_SUCCESS(LOG_LOW, "TEST SUCCEEDED > errors: %" PRIu64 "/%" PRIu64, stats.failed_samples,
                   stats.transactions);
    TB_LOG(LOG_LOW,
           "SCB > cycles=%" PRIu64 " comparisons=%" PRIu64 " mismatches=%" PRIu64 " updates=%" PRIu64
           " confirmations=%" PRIu64 " report=%s/report.json",
           stats.cycles, stats.checks, stats.field_errors, stats.updates, stats.confirmations, dir.c_str());
    return status;
}
} // namespace len5::frontend
