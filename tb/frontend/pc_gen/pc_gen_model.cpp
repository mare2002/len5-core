// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "pc_gen_model.hh"
#include <cinttypes>
#include <cstdio>
#include <initializer_list>
#include <sstream>
#include <stdexcept>
#include <tuple>

namespace len5::pcgen {
const char* name(Event e) {
    switch (e) {
    case Event::Reset: return "reset";
    case Event::Commit: return "commit";
    case Event::TakenRecovery: return "R-T";
    case Event::FallthroughRecovery: return "R-N";
    case Event::Early: return "early";
    case Event::Prediction: return "prediction";
    case Event::Sequential: return "sequential";
    case Event::Hold: return "hold";
    case Event::Unknown: return "unknown";
    }
    throw std::logic_error("invalid event enum");
}
const char* name(Campaign c) {
    switch (c) {
    case Campaign::Architectural: return "architectural";
    case Campaign::Stress: return "interface_stress";
    case Campaign::Characterization: return "characterization";
    }
    throw std::logic_error("invalid campaign enum");
}
void Config::validate() const {
    if (xlen != 64 || instruction_bytes != 4
        || (bundle_instructions!=1 && bundle_instructions!=2 && bundle_instructions!=4 && bundle_instructions!=8))
        throw std::invalid_argument("unsupported configuration: require W=64, ILEN=32, LEN5_MULTIPLE_ISSUES in {1,2,4,8} (Q6)");
}
Contract Contract::strict() {
    Contract c;
    c.valid_on_recovery = c.always_ready = false;
    return c;
}
std::vector<std::string> Contract::assumptions() const {
    std::vector<std::string> r;
    if (valid_on_recovery) r.push_back("Q5:fetch-valid-cancellation-and-early-offer-policy (I)");
    if (always_ready) r.push_back("Q5:sole-active-control-ready (I)");
    r.push_back("Q3/Q9:abstract-held-source-lifecycle-and-younger-cancellation (I)");
    r.push_back("Q4:overridden-metadata-consumer-flush (integration only)");
    return r;
}
bool Inputs::operator==(const Inputs& b) const {
    return std::tie(rst_n,commit,branch_valid,mispredict,taken,prediction,ready,early,
                    commit_pc,branch_pc,branch_target,prediction_target,early_base,early_offset)
        == std::tie(b.rst_n,b.commit,b.branch_valid,b.mispredict,b.taken,b.prediction,b.ready,b.early,
                    b.commit_pc,b.branch_pc,b.branch_target,b.prediction_target,b.early_base,b.early_offset);
}
static Field known(uint64_t value, const char* req, const char* evidence, std::string assumptions = {}) {
    return {value, true, req, evidence, assumptions, {}};
}
static Field unknown(const char* q) { return {0, false, {}, "Q", {}, q}; }
ReferenceModel::ReferenceModel(Config cfg, Contract c): config_(cfg), contract_(c), cursor_(unknown("Q1:uninitialized-before-reset")) {
    cfg.validate();
}
Field ReferenceModel::address(uint64_t v, const char* req, const char* evidence, const std::string& assumptions) const {
    // Q7: pin-level values pass through exactly. ISA alignment belongs to producers.
    return known(v, req, evidence, assumptions);
}
void ReferenceModel::input_change(const Inputs& i) {
    if (!i.rst_n) cursor_ = address(config_.boot_pc, "C1", "D", "");
}
uint64_t ReferenceModel::sequential(uint64_t cursor) const {
    // Address interval of the supplied fetch bundle; no RTL increment algorithm.
    const uint64_t start = (cursor / config_.bundle_bytes()) * config_.bundle_bytes();
    return start + config_.bundle_bytes();
}
Expected ReferenceModel::outputs(const Inputs& i, bool /*malformed*/) const {
    Expected e;
    e.pc = cursor_;
    if (!i.rst_n) e.valid = known(0, "C1", "D");
    else if (!i.commit && !i.recovery() && !i.early) e.valid = known(1, "C7", "D");
    else if (contract_.valid_on_recovery)
        e.valid = known(!i.commit && !i.recovery(), "C4", "I", "Q5:fetch-valid-cancellation-and-early-offer-policy");
    else if (i.commit || i.recovery() || i.early) e.valid = unknown("Q5:fetch-valid-during-control-event");
    else e.valid = known(1, "C7", "D");
    // Ready is a producer acknowledgment, not memory readiness. Reset, idle
    // levels and simultaneous losing-request acknowledgments remain unspecified.
    if (i.rst_n && (i.commit != i.recovery()) && contract_.always_ready)
        e.branch_ready = known(1, "C8", "I", "Q5:sole-active-control-ready");
    else e.branch_ready = unknown("Q5:reset-idle-or-shared-control-acknowledgment");
    if (i.rst_n && i.early && !i.commit && !i.recovery())
        e.early_target = address(i.early_base+i.early_offset, "C6", "D", "");
    else if (!i.rst_n || !i.early || i.commit)
        e.early_target = {0,false,"C6","D",{},"DC:Q4:reset-idle-or-commit-overridden-metadata"};
    else e.early_target = unknown("Q4:branch-overridden-consumer-flush-window");
    return e;
}
Transition ReferenceModel::plan(const Inputs& i, bool /*malformed*/) const {
    // Causal-history annotations cannot change pin-level functional semantics.
    // A raw request in characterization has the same defined PC behavior.
    Transition t;
    const auto offer = outputs(i).valid;
    t.acceptance_known = offer.known;
    t.ordinary_acceptance = offer.known && offer.value && i.ready;
    t.control_acceptance_known = true;
    if (!i.rst_n) {
        t.event = Event::Reset;
        t.next_pc = address(config_.boot_pc,"C1","D", "");
    } else if (i.commit) {
        t.event = Event::Commit;
        t.control_accepted = true; // selected cursor correction, not loser acknowledgment
        t.next_pc = address(i.commit_pc,"C4","D", "");
    } else if (i.recovery()) {
        t.event = i.taken ? Event::TakenRecovery : Event::FallthroughRecovery;
        t.control_accepted = true;
        t.next_pc = address(i.taken ? i.branch_target : i.branch_pc+config_.instruction_bytes,"C5","A/D", "");
    } else if (i.early) {
        t.event = Event::Early;
        t.control_accepted = true; // approved Q3: independent of memory readiness
        t.next_pc = address(i.early_base+i.early_offset,i.prediction?"C9":"C6","D", "");
    } else if (!i.ready) {
        t.acceptance_known = true;
        t.event = Event::Hold; t.next_pc = cursor_;
        t.next_pc.requirement = "C2"; t.next_pc.evidence = "D";
    } else {
        t.event = i.prediction ? Event::Prediction : Event::Sequential;
        t.acceptance_known = t.ordinary_acceptance = true;
        if (i.prediction) t.next_pc = address(i.prediction_target,"C3","D", "");
        else if (cursor_.known) {
            t.next_pc = address(sequential(cursor_.value),"C3","D",cursor_.assumptions);
        } else t.next_pc = unknown("Q1:ordinary-progression-before-state-established");
    }
    return t;
}
std::string hex64(uint64_t v) {
    char result[19];
    std::snprintf(result, sizeof(result), "0x%016" PRIx64, v);
    return result;
}
std::string json_quote(const std::string& v) {
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    result.reserve(v.size() + 2);
    result += '"';
    for (unsigned char c : v) {
        if (c == '"' || c == '\\') {
            result += '\\';
            result += c;
        } else if (c < 32) {
            result += "\\u00";
            result += hex[c >> 4];
            result += hex[c & 15];
        } else result += c;
    }
    result += '"';
    return result;
}
std::string inputs_json(const Inputs& i) {
    std::ostringstream s;
    s << "{\"rst_n\":" << i.rst_n << ",\"E\":" << i.commit << ",\"branch_valid\":" << i.branch_valid
      << ",\"mispredict\":" << i.mispredict << ",\"taken\":" << i.taken << ",\"P\":" << i.prediction
      << ",\"M\":" << i.ready << ",\"J\":" << i.early;
    for (const auto& p : std::initializer_list<std::pair<const char*,uint64_t>>{{"commit_pc",i.commit_pc},
        {"branch_pc",i.branch_pc},{"branch_target",i.branch_target},{"prediction_target",i.prediction_target},
        {"early_base",i.early_base},{"early_offset",i.early_offset}})
        s << ',' << json_quote(p.first) << ':' << json_quote(hex64(p.second));
    s << '}'; return s.str();
}
std::string field_json(const Field& f) {
    return "{\"known\":" + std::string(f.known ? "true" : "false") + ",\"value\":"
        + (f.known ? json_quote(hex64(f.value)) : "null") + ",\"requirement\":" + json_quote(f.requirement)
        + ",\"evidence\":" + json_quote(f.evidence) + ",\"assumptions\":" + json_quote(f.assumptions)
        + ",\"question\":" + json_quote(f.question)
        + ",\"disposition\":" + json_quote(f.known?"required":f.question.rfind("DC:",0)==0?"dont_care":"unresolved") + "}";
}
std::string expected_json(const Expected& e) {
    return "{\"pc\":" + field_json(e.pc) + ",\"valid\":" + field_json(e.valid)
        + ",\"branch_ready\":" + field_json(e.branch_ready) + ",\"early_target\":" + field_json(e.early_target) + "}";
}
std::string specification_status_json() {
    return R"SPEC({
  "contract_revision": "approved-2026-10-14",
  "Q1": {
    "status": "partial",
    "resolved": "asynchronous active-low BOOT_PC reset, dominance, release, no ordinary fetch during reset",
    "remaining": "ready during reset"
  },
  "Q2": {
    "status": "resolved",
    "resolved": "reset>E>R>J>P>sequential",
    "remaining": "losing acknowledgments are Q5; reachability is Q9"
  },
  "Q3": {
    "status": "partial",
    "resolved": "early base plus signed offset, independent of memory readiness",
    "remaining": "producer holds, release and duplicate-offer lifecycle"
  },
  "Q4": {
    "status": "partial",
    "resolved": "selected early metadata exact; reset/idle/commit override not consumed",
    "remaining": "branch-overridden consumer flush timing; physical cancellation outside module"
  },
  "Q5": {
    "status": "partial",
    "resolved": "ordinary valid-and-ready acceptance; memory-independent commit/branch redirect",
    "remaining": "fetch-valid control qualification, ready idle/reset and shared losing acknowledgment"
  },
  "Q6": {
    "status": "resolved",
    "resolved": "source-selected N=1,2,4,8; successor ((pc/(4*N))+1)*(4*N)",
    "remaining": "complete-core configuration validation outside module"
  },
  "Q7": {
    "status": "resolved",
    "resolved": "unmodified supplied addresses and XLEN modular arithmetic; only ordinary successor aligns",
    "remaining": "producer fault/executable validation outside module"
  },
  "Q8": {
    "status": "resolved",
    "resolved": "stable edge sampling; predictions may change during stalls; latest accepted prediction wins",
    "remaining": "physical setup/hold outside simulation"
  },
  "Q9": {
    "status": "partial",
    "resolved": "younger recovery cancellation, older survival, exception dominance",
    "remaining": "physical queues/memory/ROB flush outside module; abstract producer timing"
  },
  "Q10": {
    "status": "outside_scope",
    "resolved": "trap via mtvec, interrupt direct/vector, MRET via mepc; pc_gen forwards supplied commit address",
    "remaining": "producer computation outside module"
  }
})SPEC";
}
} // namespace len5::pcgen
