// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_stage_composition.hh"
#include <sstream>
namespace len5::frontend {
// A provenance/obligation ledger over the reused oracle, never another RAS
// model. A model transition creates an obligation. Only a subsequently compared
// public output, linked to its earlier independently selected return, can
// witness it.
class RasWitness {
    struct Record {
        uint64_t id = 0, cycle = 0, epoch = 0, request = 0, dynamic = 0, pc = 0, address = 0;
        uint64_t cancellation_cycle = UINT64_MAX;
        unsigned lane = 0;
        unsigned restore_entries = 0;
        bool recovered_pop = false;
        std::string state, operation, token, successor, status = "unwitnessed";
        std::string cancellation_reason;
        std::set<std::string> remaining;
        std::vector<uint64_t> probes;
    };
    struct Probe {
        uint64_t request, pc, cycle;
        unsigned lane;
        std::string top;
    };
    std::vector<Record> records_;
    std::vector<Probe> probes_;
    uint64_t next_ = 1;
    static std::string key(const early::Entry &e) {
        return std::string(e.word ? "P:" : "C:") + std::to_string(e.source_id) + ":" +
               std::to_string(e.cycle);
    }
    static std::string top(const early::History &h) {
        return !h.known ? "unknown" : h.entries.empty() ? "empty" : key(h.entries.back());
    }

  public:
    void edge(const CompositionPlan &p, const early::State &before, uint64_t cycle, uint64_t epoch,
              bool flush, const std::string &reason, uint64_t confirm_pc = 0) {
        const auto &after = p.et.next;
        auto add = [&](const char *state, early::Operation op, const early::History &old,
                       const early::History &now, uint64_t request, uint64_t dynamic, uint64_t pc,
                       unsigned lane) {
            if (op == early::Operation::None)
                return;
            Record r;
            r.id = next_++;
            r.cycle = cycle;
            r.epoch = epoch;
            r.request = request;
            r.dynamic = dynamic;
            r.pc = pc;
            r.lane = lane;
            r.state = state;
            r.operation = early::name(op);
            if (op == early::Operation::Push && !now.entries.empty()) {
                r.token = key(now.entries.back());
                r.address = now.entries.back().address;
            } else {
                r.successor = top(now);
                r.address = old.entries.empty() ? 0 : old.entries.back().address;
            }
            records_.push_back(r);
        };
        add("confirmed", p.et.confirmation, before.confirmed, after.confirmed, 0, p.es.confirmation_id,
            confirm_pc, 0);
        if (flush) {
            for (auto &r : records_)
                if (r.state == "predictive" && r.cancellation_cycle == UINT64_MAX) {
                    r.cancellation_cycle = cycle;
                    r.cancellation_reason = reason;
                    if (r.status == "unwitnessed")
                        r.status = "canceled-recovery-unwitnessed";
                }
            Record r;
            r.id = next_++;
            r.cycle = cycle;
            r.epoch = epoch;
            r.state = "predictive";
            r.operation = "restore";
            r.status = after.predictive.known ? "unwitnessed" : "unknown-" + reason;
            for (const auto &e : after.predictive.entries)
                r.remaining.insert(key(e));
            r.restore_entries = unsigned(r.remaining.size());
            r.recovered_pop = before.predictive.entries.size() < after.predictive.entries.size();
            if (after.predictive.known && r.remaining.empty())
                r.remaining.insert("empty");
            records_.push_back(r);
        } else if (p.a && p.ee.selection.lane >= 0) {
            auto lane = unsigned(p.ee.selection.lane);
            auto pc = p.es.inputs.predictions[lane].pc;
            if (p.et.speculative == early::Operation::Pop && before.predictive.known)
                probes_.push_back({p.transfer.id, pc, cycle, lane, top(before.predictive)});
            add("predictive", p.et.speculative, before.predictive, after.predictive, p.transfer.id, 0, pc,
                lane);
        }
    }
    void bind(const std::vector<Instruction> &instructions) {
        for (auto &r : records_)
            if (r.state == "predictive" && r.request && !r.dynamic)
                for (const auto &i : instructions)
                    if (i.bundle == r.request && i.pc == r.pc) {
                        r.dynamic = i.id;
                        break;
                    }
    }
    uint64_t dispatch(const Bundle &b, uint64_t cycle) {
        uint64_t count = 0;
        for (auto probe = probes_.begin(); probe != probes_.end();) {
            if (probe->request != b.id) {
                ++probe;
                continue;
            }
            bool valid = false;
            for (unsigned lane = 0; lane < MaxLanes; ++lane)
                if ((b.mask & (1u << lane)) && b.lanes[lane].source_lane == probe->lane &&
                    b.lanes[lane].prediction.pc == probe->pc &&
                    early::decode(b.lanes[lane].word).kind == early::Kind::Return)
                    valid = true;
            if (!valid)
                throw std::logic_error("RAS witness lacks matched public return tuple");
            for (auto &r : records_) {
                if (r.cycle >= probe->cycle || r.status != "unwitnessed")
                    continue;
                bool relevant = (r.operation == "push" && r.token == probe->top) ||
                                (r.operation == "pop" && r.successor == probe->top);
                if (r.operation == "restore" && r.remaining.erase(probe->top)) {
                    relevant = true;
                    r.probes.push_back(cycle);
                    if (r.remaining.empty()) {
                        r.status = "public-return-witness";
                        ++count;
                    }
                } else if (relevant) {
                    r.probes.push_back(cycle);
                    r.status = "public-return-witness";
                    ++count;
                }
            }
            probe = probes_.erase(probe);
        }
        return count;
    }
    uint64_t witnessed() const {
        uint64_t n = 0;
        for (const auto &r : records_)
            n += r.status == "public-return-witness";
        return n;
    }
    uint64_t restored_multiple() const {
        uint64_t n = 0;
        for (const auto &r : records_)
            n += r.operation == "restore" && r.restore_entries > 1 && r.recovered_pop &&
                 r.status == "public-return-witness";
        return n;
    }
    std::string json(const std::string &stop) const {
        std::ostringstream s;
        s << '[';
        bool first = true;
        for (const auto &r : records_) {
            if (!first)
                s << ',';
            first = false;
            s << "{\"id\":" << r.id << ",\"cycle\":" << r.cycle << ",\"epoch\":" << r.epoch
              << ",\"request\":" << r.request << ",\"dynamic_id\":" << r.dynamic
              << ",\"pc\":" << json_quote(hex64(r.pc)) << ",\"address\":" << json_quote(hex64(r.address))
              << ",\"state\":" << json_quote(r.state) << ",\"operation\":" << json_quote(r.operation)
              << ",\"cancellation_reason\":" << json_quote(r.cancellation_reason)
              << ",\"cancellation_cycle\":";
            if (r.cancellation_cycle == UINT64_MAX)
                s << "null";
            else
                s << r.cancellation_cycle;
            s << ",\"provenance\":\"I:oracle-state; matched public return/flush "
                 "witnesses\",\"status\":"
              << json_quote(r.status == "unwitnessed" ? "canceled-" + stop + "-unwitnessed" : r.status)
              << ",\"restore_entries\":" << r.restore_entries << ",\"recovered_pop\":" << r.recovered_pop
              << ",\"remaining_entries\":" << r.remaining.size() << ",\"public_probe_cycles\":[";
            for (size_t k = 0; k < r.probes.size(); ++k) {
                if (k)
                    s << ',';
                s << r.probes[k];
            }
            s << "]}";
        }
        s << ']';
        return s.str();
    }
};
} // namespace len5::frontend
