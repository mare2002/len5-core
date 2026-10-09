#include "monitor.hh"
#include <algorithm>
#include <filesystem>
#include <gtkwave/fstapi.h>
#include <limits>
#include <set>
#include <stdexcept>
#include <tuple>
namespace len5::diff {
namespace {
using Key = std::tuple<Stage, unsigned, std::string>;
struct Merger {
    fstWriterContext *writer = nullptr;
    std::vector<fstHandle> rtl;
    std::map<Key, fstHandle> signals;
    std::map<std::string, fstHandle> overall;
    std::ifstream events;
    Event next{};
    bool have = false;
    uint64_t time = std::numeric_limits<uint64_t>::max(),
             event_time = std::numeric_limits<uint64_t>::max();
    std::map<Stage, unsigned> lanes;
    std::map<uint64_t, const Discrepancy *> errors;
    std::vector<fstHandle> pulses;
    std::optional<Event> first;
    ~Merger() {
        if (writer)
            fstWriterClose(writer);
    }
    void emit(fstHandle h, uint64_t value, unsigned width = 64) {
        fstWriterEmitValueChange64(writer, h, width, value);
    }
    void at(uint64_t t) {
        if (time == t)
            return;
        fstWriterEmitTimeChange(writer, t);
        time = t;
        for (auto h : pulses)
            emit(h, 0, 1);
        pulses.clear();
    }
    void read() { have = bool(events.read(reinterpret_cast<char *>(&next), sizeof next)); }
    void annotations(uint64_t through) {
        while (have && next.time <= through) {
            const auto e = next;
            at(e.time);
            if (event_time != e.time) {
                lanes.clear();
                event_time = e.time;
            }
            auto lane = lanes[e.stage]++;
            auto sig = [&](const std::string &n) { return signals.at({e.stage, lane, n}); };
            emit(sig("event_valid"), 1, 1);
            pulses.push_back(sig("event_valid"));
            emit(sig("instruction_id"), e.id);
            emit(sig("pc"), e.pc);
            emit(sig("instruction"), e.instruction);
            emit(sig("architectural_order"), e.architectural_order);
            emit(sig("rob_idx"), e.rob);
            emit(sig("load_idx"), e.load);
            emit(sig("store_idx"), e.store);
            emit(sig("cycle"), e.cycle);
            emit(sig("event_time"), e.time);
            emit(sig("field"), uint32_t(e.field));
            emit(sig("register_index"), e.register_index);
            emit(sig("expected_value"), e.expected);
            emit(sig("actual_value"), e.actual);
            emit(sig(std::string("expected_") + name(e.field)), e.expected);
            emit(sig(std::string("actual_") + name(e.field)), e.actual);
            auto it = errors.find(e.serial);
            bool confirmed = it != errors.end() && it->second->confirmed;
            emit(sig("mismatch"), e.mismatch, 1);
            emit(sig("confirmed"), confirmed, 1);
            emit(sig("squashed"), it != errors.end() && it->second->squashed, 1);
            emit(sig("confirmation_time"), it == errors.end() ? 0 : it->second->confirmation.time);
            if (e.mismatch) {
                pulses.push_back(sig("mismatch"));
                emit(overall.at("mismatch_pulse"), 1, 1);
                pulses.push_back(overall.at("mismatch_pulse"));
            }
            if (confirmed)
                emit(overall.at("verification_failed"), 1, 1);
            if (first && e.serial == first->serial) {
                emit(overall.at("first_error_cycle"), e.cycle);
                emit(overall.at("first_error_time"), e.time);
                emit(overall.at("first_error_stage"), uint32_t(e.stage));
                emit(overall.at("first_error_instruction_id"), e.id);
                emit(overall.at("first_error_rob_idx"), e.rob);
            }
            read();
        }
    }
    static void rtl_change(void *ptr, uint64_t t, fstHandle h, const unsigned char *value) {
        auto &m = *static_cast<Merger *>(ptr);
        m.annotations(t);
        m.at(t);
        fstWriterEmitValueChange(m.writer, m.rtl.at(h), value);
    }
    static void rtl_string(void *ptr, uint64_t t, fstHandle h, const unsigned char *value,
                           uint32_t size) {
        auto &m = *static_cast<Merger *>(ptr);
        m.annotations(t);
        m.at(t);
        fstWriterEmitVariableLengthValueChange(m.writer, m.rtl.at(h), value, size);
    }
};
} // namespace
void annotate(const std::string &original, const Checker &checker) {
    const auto dir = std::filesystem::absolute(checker.directory());
    auto *r = fstReaderOpen(original.c_str());
    if (!r)
        throw std::runtime_error("cannot read original FST: " + original);
    struct ReaderGuard {
        fstReaderContext *r;
        ~ReaderGuard() { fstReaderClose(r); }
    } guard{r};
    Merger m;
    m.first = checker.first_error();
    for (const auto &d : checker.discrepancies())
        m.errors[d.event.serial] = &d;
    // First streaming pass sizes event lanes; no trace or full event stream is retained in RAM.
    std::ifstream scan(dir / "events.bin", std::ios::binary);
    Event e;
    std::map<Stage, unsigned> counts, maximum;
    std::map<Stage, std::set<std::string>> fields;
    uint64_t last = 0;
    while (scan.read(reinterpret_cast<char *>(&e), sizeof e)) {
        if (e.time < last)
            throw std::runtime_error("nonmonotonic event journal");
        if (e.time != last) {
            counts.clear();
            last = e.time;
        }
        maximum[e.stage] = std::max(maximum[e.stage], ++counts[e.stage]);
        fields[e.stage].insert(name(e.field));
    }
    if (!scan.eof())
        throw std::runtime_error("cannot scan event journal");
    m.writer = fstWriterCreate((dir / "annotated.fst").c_str(), 1);
    if (!m.writer)
        throw std::runtime_error("cannot create annotated FST");
    fstWriterSetTimescale(m.writer, fstReaderGetTimescale(r));
    fstWriterSetTimezero(m.writer, fstReaderGetTimezero(r));
    fstWriterSetVersion(m.writer, "LEN5 Spike differential annotation");
    fstWriterSetPackType(m.writer, FST_WR_PT_LZ4);
    m.rtl.resize(fstReaderGetMaxHandle(r) + 1);
    while (auto *h = fstReaderIterateHier(r)) {
        switch (h->htyp) {
        case FST_HT_SCOPE:
            fstWriterSetScope(m.writer, static_cast<fstScopeType>(h->u.scope.typ), h->u.scope.name,
                              h->u.scope.component);
            break;
        case FST_HT_UPSCOPE:
            fstWriterSetUpscope(m.writer);
            break;
        case FST_HT_VAR: {
            const auto &v = h->u.var;
            auto handle = fstWriterCreateVar(m.writer, static_cast<fstVarType>(v.typ),
                                             static_cast<fstVarDir>(v.direction), v.length, v.name,
                                             v.is_alias ? m.rtl.at(v.handle) : 0);
            if (!v.is_alias)
                m.rtl.at(v.handle) = handle;
            break;
        }
        case FST_HT_ATTRBEGIN:
            fstWriterSetAttrBegin(m.writer, static_cast<fstAttrType>(h->u.attr.typ),
                                  h->u.attr.subtype, h->u.attr.name, h->u.attr.arg);
            break;
        case FST_HT_ATTREND:
            fstWriterSetAttrEnd(m.writer);
            break;
        }
    }
    std::ofstream gtkw(dir / "annotated.gtkw");
    gtkw << "[*] LEN5 differential verification\n[dumpfile] \"" << (dir / "annotated.fst").string()
         << "\"\n[timestart] 0\n*0.0 " << (m.first ? std::to_string(m.first->time) : "-1");
    for (unsigned i = 0; i < 26; ++i)
        gtkw << " -1";
    gtkw << "\n[treeopen] verification.\n";
    auto var = [&](const std::string &n, unsigned width) {
        return fstWriterCreateVar(m.writer, FST_VT_VCD_WIRE, FST_VD_IMPLICIT, width, n.c_str(), 0);
    };
    fstWriterSetScope(m.writer, FST_ST_VCD_MODULE, "verification", nullptr);
    fstWriterSetScope(m.writer, FST_ST_VCD_MODULE, "overall", nullptr);
    for (auto n : {"verification_failed", "mismatch_pulse", "first_error_cycle", "first_error_time",
                   "first_error_stage", "first_error_instruction_id", "first_error_rob_idx"}) {
        unsigned w =
            std::string(n) == "verification_failed" || std::string(n) == "mismatch_pulse" ? 1 : 64;
        m.overall[n] = var(n, w);
        gtkw << "verification.overall." << n << (w == 64 ? "[63:0]" : "") << '\n';
    }
    fstWriterSetUpscope(m.writer);
    for (auto [stage, n] : maximum) {
        fstWriterSetScope(m.writer, FST_ST_VCD_MODULE, name(stage), nullptr);
        for (unsigned lane = 0; lane < n; ++lane) {
            auto ln = "lane" + std::to_string(lane);
            fstWriterSetScope(m.writer, FST_ST_VCD_MODULE, ln.c_str(), nullptr);
            auto add = [&](const std::string &name, unsigned w = 64) {
                m.signals[{stage, lane, name}] = var(name, w);
            };
            for (auto key : {"event_valid", "mismatch", "confirmed", "squashed"})
                add(key, 1);
            for (auto key :
                 {"instruction_id", "architectural_order", "pc", "instruction", "rob_idx",
                  "load_idx", "store_idx", "cycle", "event_time", "field", "register_index",
                  "expected_value", "actual_value", "confirmation_time"})
                add(key);
            for (const auto &f : fields[stage]) {
                add("expected_" + f);
                add("actual_" + f);
            }
            // Show useful comparison lanes by default, including every simultaneous event.
            for (auto key :
                 {"event_valid", "instruction_id", "field", "expected_value", "actual_value",
                  "mismatch", "confirmed", "event_time", "confirmation_time"}) {
                bool bit = std::string(key) == "event_valid" || std::string(key) == "mismatch" ||
                           std::string(key) == "confirmed";
                gtkw << "verification." << name(stage) << '.' << ln << '.' << key
                     << (bit ? "" : "[63:0]") << '\n';
            }
            fstWriterSetUpscope(m.writer);
        }
        fstWriterSetUpscope(m.writer);
    }
    fstWriterSetUpscope(m.writer);
    m.at(0);
    for (const auto &[key, h] : m.overall)
        m.emit(h, 0, (key == "verification_failed" || key == "mismatch_pulse") ? 1 : 64);
    for (const auto &[key, h] : m.signals) {
        auto n = std::get<2>(key);
        bool bit = n == "event_valid" || n == "mismatch" || n == "confirmed" || n == "squashed";
        m.emit(h, 0, bit ? 1 : 64);
    }
    m.events.open(dir / "events.bin", std::ios::binary);
    m.read();
    fstReaderSetFacProcessMaskAll(r);
    fstReaderIterBlocksSetNativeDoublesOnCallback(r, 1);
    if (!fstReaderIterBlocks2(r, Merger::rtl_change, Merger::rtl_string, &m, nullptr))
        throw std::runtime_error("FST block merge failed");
    m.annotations(std::numeric_limits<uint64_t>::max());
    if (m.time < fstReaderGetEndTime(r))
        m.at(fstReaderGetEndTime(r));
    if (fstReaderGetFseekFailed(r) || fstWriterGetFseekFailed(m.writer))
        throw std::runtime_error("FST seek/write failure");
    std::ofstream legend(dir / "fields.json");
    legend << "{\n";
    for (unsigned i = 0; i <= unsigned(Field::store_order); ++i)
        legend << "  \"" << i << "\": \"" << name(Field(i)) << "\""
               << (i == unsigned(Field::store_order) ? "\n" : ",\n");
    legend << "}\n";
}
} // namespace len5::diff
