// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fetch_stage_components.hh"
#include <algorithm>
#include <iomanip>
#include <sstream>
namespace len5::frontend {
uint32_t Program::word(uint64_t pc) const {
    auto i = text.find(pc);
    return i == text.end() ? 0x13 : i->second;
}
fetchmem::Payload Program::read(uint64_t base, unsigned n) const {
    fetchmem::Payload p;
    for (unsigned k = 0; k < n; ++k) {
        auto pc = base + 4 * k;
        p.words[k] = word(pc);
        auto f = faults.find(pc);
        if (f != faults.end()) {
            p.errors |= 1u << k;
            p.causes[k] = f->second;
        }
    }
    return p;
}
std::string Program::digest() const {
    uint64_t h = UINT64_C(14695981039346656037);
    auto feed = [&](uint64_t x) {
        for (unsigned i = 0; i < 8; ++i) {
            h ^= (x >> (i * 8)) & 255;
            h *= UINT64_C(1099511628211);
        }
    };
    feed(boot);
    feed(marker);
    for (auto p : text) {
        feed(p.first);
        feed(p.second);
    }
    for (auto p : faults) {
        feed(p.first);
        feed(p.second);
    }
    return hex64(h);
}
std::string Program::json() const {
    std::ostringstream s;
    s << "{\"family\":" << json_quote(family) << ",\"digest\":" << json_quote(digest())
      << ",\"boot\":" << json_quote(hex64(boot)) << ",\"marker\":" << json_quote(hex64(marker))
      << ",\"words\":[";
    bool first = true;
    for (auto p : text) {
        if (!first)
            s << ',';
        first = false;
        s << '[' << json_quote(hex64(p.first)) << ',' << p.second << ']';
    }
    s << "],\"faults\":[";
    first = true;
    for (auto p : faults) {
        if (!first)
            s << ',';
        first = false;
        s << '[' << json_quote(hex64(p.first)) << ',' << p.second << ']';
    }
    s << "],\"labels\":{";
    first = true;
    for (auto p : labels) {
        if (!first)
            s << ',';
        first = false;
        s << json_quote(p.first) << ':' << json_quote(hex64(p.second));
    }
    s << "}}";
    return s.str();
}
void Program::validate() const {
    if (boot % 4 || marker % 4 || !text.count(boot) || !text.count(marker))
        throw std::invalid_argument("FE07: malformed program entry/marker");
    for (auto p : text) {
        if (p.first % 4)
            throw std::invalid_argument("unaligned program word");
        auto d = early::decode(p.second);
        if (!d.valid)
            throw std::invalid_argument("invalid generated word");
        if (d.kind == early::Kind::Call || d.kind == early::Kind::Jal || d.kind == early::Kind::Branch) {
            auto t = p.first + uint64_t(d.immediate);
            if (t % 4 || !text.count(t))
                throw std::invalid_argument("FE16: invalid relocated branch target");
        }
    }
    // Execute the immutable resolved-path image before supplying it to RTL.
    // This rejects broken relocation/link/loop templates; fixed-word semantic
    // fixtures are tested separately, so this is not an encoder round trip.
    std::array<uint64_t, 32> registers{};
    uint64_t pc = boot;
    for (unsigned count = 0; count < 500000; ++count) {
        if (pc == marker)
            return;
        const auto instruction = text.find(pc);
        if (instruction == text.end() || pc % 4)
            throw std::invalid_argument("FE16: program leaves mapped instruction text");
        const auto w = instruction->second;
        const auto result = evaluate(w, pc, registers[(w >> 15) & 31], registers[(w >> 20) & 31]);
        if (result.writes && result.rd)
            registers[result.rd] = result.value;
        pc = result.next;
    }
    throw std::invalid_argument("FE16: generated template fails its bounded termination proof");
}
Assembler::Assembler(uint64_t boot, const std::string &f) : cursor_(boot) {
    p_.boot = boot;
    p_.family = f;
}
void Assembler::at(uint64_t pc) {
    if (pc % 4)
        throw std::invalid_argument("assembler alignment");
    cursor_ = pc;
}
void Assembler::label(const std::string &n) {
    if (!p_.labels.emplace(n, cursor_).second)
        throw std::invalid_argument("duplicate label");
}
void Assembler::emit(uint32_t w) {
    if (!p_.text.emplace(cursor_, w).second)
        throw std::invalid_argument("program text overlap");
    cursor_ += 4;
}
void Assembler::addi(unsigned rd, unsigned rs, int64_t i) { emit(immediate(0, rd, rs, i)); }
void Assembler::jal(unsigned rd, const std::string &l) {
    fixes_.push_back({cursor_, l, rd, 0, 0, 0, true});
    emit(0x13);
}
void Assembler::branch(unsigned f, unsigned a, unsigned b, const std::string &l) {
    fixes_.push_back({cursor_, l, 0, f, a, b, false});
    emit(0x13);
}
Program Assembler::finish(const std::string &m) {
    for (const auto &f : fixes_) {
        auto i = p_.labels.find(f.label);
        if (i == p_.labels.end())
            throw std::invalid_argument("undefined label " + f.label);
        const auto delta = int64_t(i->second - f.pc);
        p_.text[f.pc] = f.jump ? early::jal(f.rd, delta) : early::branch(f.funct3, f.rs1, f.rs2, delta);
    }
    p_.marker = p_.labels.at(m);
    // Immutable mapped padding, including wrong-path reads. No run-time code
    // mutation.
    for (uint64_t offset = 0; offset < 0x2000; offset += 4)
        p_.text.emplace(p_.boot + offset, 0x13);
    p_.validate();
    return p_;
}
Program make_program(const Config &c, const std::string &family, unsigned reps, unsigned v) {
    if (reps < 2 || reps > 2047)
        throw std::invalid_argument("repetitions must be 2..2047");
    Assembler a(c.boot, family);
    const auto base = c.boot;
    auto done = [&]() {
        a.at(base + 0x700);
        a.label("done");
        a.addi(0, 0, 0);
        a.jal(0, "done");
    };
    if (family == "reset-loaded") {
        a.jal(1, "function");
        a.jal(0, "done");
        a.at(base + 0x200);
        a.label("function");
        for (unsigned k = 0; k < 64; ++k) {
            if (k == 8)
                a.branch(1, 0, 0, "done");
            else
                a.addi(8 + k % 8, 0, k);
        }
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "ordered-pair") {
        a.branch(1, 0, 0, "tail");
        a.branch(1, 0, 0, "tail");
        a.label("tail");
        a.jal(0, "done");
    } else if (family == "sequential" || family == "short-sequential") {
        for (unsigned k = 0; k < (family == "short-sequential" ? 12u : 256u); ++k)
            a.addi(8 + k % 8, 0, int(k));
        a.jal(0, "done");
    } else if (family == "loop-a" || family == "long") {
        a.addi(10, 0, reps);
        a.label("loop");
        a.addi(10, 10, -1);
        a.branch(1, 10, 0, "loop");
        a.jal(0, "done");
    } else if (family == "loop-b") {
        a.addi(10, 0, 0);
        a.addi(11, 0, reps);
        a.label("loop");
        a.branch(0, 10, 11, "done");
        a.addi(10, 10, 1);
        a.jal(0, "loop");
    } else if (family == "phase" || family == "alternating" || family == "interacting" ||
               family == "conflict") {
        a.addi(10, 0, 0);
        a.addi(11, 0, reps);
        a.addi(13, 0, 0);
        a.addi(14, 0, 0);
        a.addi(15, 0, reps / 2);
        a.label("loop");
        if (family == "phase")
            a.branch(4, 10, 15, "yes");
        else {
            a.emit(immediate(7, 12, 10, 1));
            a.branch(0, 12, 0, "yes");
        }
        a.addi(13, 13, 1);
        a.jal(0, "join");
        a.label("yes");
        a.addi(14, 14, 1);
        a.label("join");
        if (family == "interacting" || family == "conflict") {
            a.emit(immediate(7, 12, 10, 2));
            if (family == "conflict")
                a.at(base + 0x18 + 4 * (uint64_t(1) << c.btb_bits));
            a.branch(1, 12, 0, "second");
            a.addi(13, 13, 1);
            a.label("second");
        }
        a.addi(10, 10, 1);
        a.branch(4, 10, 11, "loop");
        a.jal(0, "done");
    } else if (family == "jal-nt") {
        // Immutable JAL at word index 0. Four real NT resolutions shift H to
        // zero; the NT at 0x120 trains counter[0] while retaining BTB row 0.
        a.addi(10, 0, reps);
        a.addi(11, 0, 1);
        a.jal(0, "probe");
        a.at(base + 0x100);
        a.label("body");
        a.addi(10, 10, -1);
        a.branch(0, 10, 0, "done");
        a.branch(0, 0, 11, "done");
        a.at(base + 0x110);
        a.branch(0, 0, 11, "done");
        a.at(base + 0x120);
        a.branch(0, 0, 11, "done");
        a.at(base + 0x12c);
        a.branch(0, 0, 11, "done");
        a.at(base + 0x180);
        a.label("probe");
        a.jal(0, "body");
    } else if (family == "jal-loop") {
        a.addi(10, 0, reps);
        a.jal(0, "loop");
        a.at(base + 0x104 + (v % c.lanes) * 4);
        a.label("loop");
        a.addi(10, 10, -1);
        a.branch(0, 10, 0, "done");
        a.jal(v == 5 ? 5 : 0, "loop");
    } else if (family == "call-kind") {
        a.emit(0x00000097);
        a.addi(1, 1, 12);
        a.jal(v == 1 ? 1 : v == 5 ? 5 : 0, "function");
        a.jal(0, "done");
        a.at(base + 0x300);
        a.label("function");
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "multiple-jumps") {
        a.emit(0x00000097);
        a.addi(1, 1, 0x700);
        a.jal(0, "pair");
        a.at(base + 0x100 + (v % (c.lanes > 1 ? c.lanes - 1 : 1)) * 4);
        a.label("pair");
        a.jal(0, "function");
        a.jal(1, "poison");
        a.at(base + 0x300);
        a.label("function");
        a.emit(early::jalr(0, 1, 0));
        a.at(base + 0x400);
        a.label("poison");
        a.jal(0, "done");
    } else if (family == "mask-cutoff") {
        a.addi(10, 0, reps);
        a.jal(0, "loop");
        a.at(base + 0x100);
        a.label("loop");
        a.addi(10, 10, -1);
        a.branch(1, 10, 0, "loop");
        a.jal(1, "function");
        a.jal(0, "done");
        a.at(base + 0x300);
        a.label("function");
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "nt-call") {
        a.addi(10, 0, 0);
        a.addi(11, 0, reps / 2);
        a.jal(0, "loop");
        a.at(base + 0x100);
        a.label("loop");
        a.branch(5, 10, 11, "survive");
        a.jal(1, "function");
        a.addi(10, 10, 1);
        a.jal(0, "loop");
        a.at(base + 0x300);
        a.label("function");
        a.emit(early::jalr(0, 1, 0));
        a.at(base + 0x500);
        a.label("survive");
        a.emit(0x00000097);
        a.addi(1, 1, 0x200);
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "caller-order") {
        std::mt19937_64 order(split_seed(v));
        std::array<unsigned, 3> choices{0, 1, 2};
        for (unsigned k = 0; k < std::min(reps, 32u); ++k) {
            if (k % 3 == 0) {
                for (unsigned j = 2; j; j--)
                    std::swap(choices[j], choices[bounded(order, j + 1)]);
            }
            a.emit(0x00000c17); // AUIPC x24: continuation of this immutable call episode
            a.addi(24, 24, 16);
            a.addi(12, 0, choices[k % 3]);
            a.jal(0, "select");
        }
        a.jal(0, "done");
        a.at(base + 0x300);
        a.label("select");
        a.branch(0, 12, 0, "caller0");
        a.addi(13, 0, 1);
        a.branch(0, 12, 13, "caller1");
        a.jal(0, "caller2");
        for (unsigned k = 0; k < 3; ++k) {
            a.at(base + 0x340 + k * 0x40);
            a.label("caller" + std::to_string(k));
            a.jal(1, "function");
            a.emit(early::jalr(0, 24, 0));
        }
        a.at(base + 0x510);
        a.label("function");
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "call" || family == "multi-caller" || family == "three-callers") {
        a.addi(10, 0, reps);
        a.addi(20, 0, 0);
        a.addi(21, 0, 0);
        a.addi(22, 0, 0);
        a.label("loop");
        a.jal(1, "function");
        a.addi(20, 20, 1);
        if (family != "call") {
            a.jal(1, "function");
            a.addi(21, 21, 1);
        }
        if (family == "three-callers") {
            a.jal(1, "function");
            a.addi(22, 22, 1);
        }
        a.addi(10, 10, -1);
        a.branch(1, 10, 0, "loop");
        a.jal(0, "done");
        a.at(base + 0x304 + (v % c.lanes) * 4);
        a.label("function");
        a.addi(23, 0, 17);
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "nested" || family == "wrong-return-deep") {
        unsigned depth = family == "wrong-return-deep" ? 3 : 1 + v % (c.ras_depth + 2);
        a.jal(1, "f0");
        a.jal(0, "done");
        for (unsigned k = 0; k < depth; ++k) {
            a.at(base + 0x200 + k * 0x80);
            a.label("f" + std::to_string(k));
            if (k + 1 < depth) {
                a.addi(16 + k, 1, 0);
                a.jal(1, "f" + std::to_string(k + 1));
                a.addi(1, 16 + k, 0);
            } else if (family == "wrong-return-deep") {
                a.label("loop");
                a.branch(0, 0, 0, "surviving-unwind");
            }
            a.emit(early::jalr(0, 1, 0));
        }
        if (family == "wrong-return-deep") {
            a.at(base + 0x380);
            a.label("surviving-unwind");
            a.emit(early::jalr(0, 1, 0));
        }
    } else if (family == "stale-ras") {
        a.addi(10, 0, 0);
        a.emit(0x00000097);
        a.addi(1, 1, 0xfc);
        a.jal(0, "shared_ret");
        a.at(base + 0x100);
        a.label("destination");
        a.addi(10, 10, 1);
        a.addi(11, 0, 2);
        a.branch(0, 10, 11, "done");
        a.jal(1, "noncanonical");
        a.addi(0, 0, 0);
        a.emit(0x00000097);
        a.addi(1, 1, -0x14);
        a.jal(0, "shared_ret");
        a.at(base + 0x200);
        a.label("noncanonical");
        a.emit(early::jalr(0, 1, 4));
        a.at(base + 0x304);
        a.label("shared_ret");
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "empty-ret" || family == "indirect") {
        // AUIPC establishes a real operand, independent of any predicted return.
        a.emit(0x00000097);
        a.addi(1, 1, 0x304);
        if (family == "indirect") {
            a.emit(early::jalr(1, 1, 0));
            a.jal(0, "done");
            a.at(base + 0x304);
            a.emit(early::jalr(0, 1, 0));
        } else {
            a.emit(early::jalr(0, 1, 0));
            a.at(base + 0x304);
            a.jal(0, "done");
        }
    } else if (family == "wrong-return") {
        a.jal(1, "outer");
        a.jal(0, "done");
        a.at(base + 0x100);
        a.label("outer");
        a.addi(20, 1, 0);
        a.addi(10, 0, reps);
        a.label("loop");
        a.addi(10, 10, -1);
        a.branch(1, 10, 0, "loop");
        a.addi(1, 20, 0);
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "wrong-call") {
        a.jal(1, "outer");
        a.jal(0, "done");
        a.at(base + 0x100);
        a.label("outer");
        a.addi(20, 1, 0);
        a.addi(10, 0, reps);
        a.label("loop");
        a.addi(10, 10, -1);
        a.branch(0, 10, 0, "survive");
        if (family == "wrong-call")
            a.jal(1, "younger");
        else {
            a.addi(1, 20, 0);
            a.emit(early::jalr(0, 1, 0));
        }
        a.jal(0, "loop");
        a.at(base + 0x300);
        a.label("younger");
        a.addi(1, 20, 0);
        a.jal(0, "loop");
        a.at(base + 0x500);
        a.label("survive");
        a.addi(1, 20, 0);
        a.emit(early::jalr(0, 1, 0));
    } else if (family == "lanes") {
        a.jal(v == 1 ? 1 : v == 5 ? 5 : 0, "target");
        a.at(base + 0x100 + (v % c.lanes) * 4);
        a.label("target");
        a.addi(12, 0, 42);
        a.jal(0, "done");
    } else
        throw std::invalid_argument("unknown persistent program family " + family);
    done();
    return a.finish();
}
} // namespace len5::frontend
