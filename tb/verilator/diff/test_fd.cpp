// Standalone checker regression: c++ -std=c++17 checker.cpp test_fd.cpp -o /tmp/test_fd
#include "checker.hh"
#include <cassert>
#include <filesystem>
#include <iostream>
using namespace len5::diff;
namespace {
constexpr uint32_t fadd0 = 0x00208053; // fadd.s f0,f1,f2
constexpr uint32_t fmadd = 0x18208243; // fmadd.s f4,f1,f2,f3
struct Stream : Reference {
    std::vector<ReferenceRecord> records;
    unsigned cursor = 0;
    ReferenceRecord step() override { return records.at(cursor++); }
};
ReferenceRecord record(uint32_t insn, uint64_t pc = 0x1000) {
    ReferenceRecord r;
    r.pc = pc;
    r.next_pc = pc + 4;
    r.instruction = insn;
    r.decoded = decode(insn);
    r.has_fp = true;
    r.rs1_value = 0xffffffff3f800000;
    r.rs2_value = 0xffffffff40000000;
    r.rs3_value = 0xffffffff40400000;
    r.result = 0xffffffff40400000;
    r.fp_registers[r.decoded.rd] = r.result;
    r.csrs[3] = 1;
    return r;
}
void dispatch(Checker &c, const ReferenceRecord &r, unsigned rob) {
    c.fetch(r.pc, r.instruction, {1, 2});
    c.dispatch(rob, r.pc, r.instruction, r.decoded.rs1, r.decoded.rs2, r.decoded.rd,
               r.decoded.write, {2, 4}, r.decoded.rs3);
}
void retire(Checker &c, const ReferenceRecord &r, unsigned rob, bool wrong_bank = false) {
    c.commit(rob, r.pc, r.instruction, r.decoded.rd, wrong_bank, r.result, false, {4, 8},
             !wrong_bank);
}
bool has_error(const Checker &c, Field field) {
    for (auto &d : c.discrepancies())
        if (d.confirmed && d.event.field == field)
            return true;
    return false;
}
} // namespace
int main(int argc, char **argv) {
    assert(argc == 2); // All output belongs in the caller's temporary directory.
    const std::string root = argv[1];
    auto path = [&](const char *name) { return root + "/" + name; };
    assert(decode(fadd0).write && decode(fadd0).fp_rd);
    assert(!decode(0x00000013).write); // x0 remains hardwired.
    assert(decode(fmadd).use_rs3 && decode(fmadd).rs3 == 3);
    auto ld = decode(0x0000b007), st = decode(0x0020b027);
    assert(ld.load && ld.fp_rd && !ld.fp_rs1 && ld.size == 8);
    assert(st.store && st.fp_rs2 && !st.fp_rs1 && st.size == 8);
    assert(!decode(0x00408053).use_rs3);
    assert(!decode(0x04008053).supported); // Unsupported FP format.
    assert(decode(0x1000a007).supported);  // FLW.
    auto cvt = decode(0xd0008053);         // fcvt.s.w f0,x1
    assert(cvt.write && cvt.fp_rd && !cvt.fp_rs1 && !cvt.use_rs2);
    cvt = decode(0xc0008053); // fcvt.w.s x0,f1
    assert(!cvt.write && cvt.fp_rs1 && !cvt.fp_rd && !cvt.use_rs2);
    for (const auto *fault : {"pass", "operand3", "boxing", "bank", "f0", "flags"}) {
        const std::string f = fault;
        auto r = record(f == "operand3" ? fmadd : fadd0);
        Stream ref;
        ref.records = {r};
        Checker c(ref, path(fault), {10000, 10000, false});
        dispatch(c, r, 0);
        c.execute(0, r.rs1_value, r.rs2_value, r.result ^ (f == "boxing" ? 1ULL << 63 : 0), false,
                  false, {3, 6}, r.rs3_value ^ (f == "operand3"));
        retire(c, r, 0, f == "bank");
        auto fp = r.fp_registers;
        fp[0] ^= f == "f0";
        auto csrs = r.csrs;
        csrs[3] ^= f == "flags";
        c.checkpoint(r.registers, {4, 8}, csrs, &fp);
        c.finish(true, {5, 10});
        assert(c.status() == (f == "pass" ? 0 : 1));
        if (f == "operand3")
            assert(has_error(c, Field::rs3_value));
        if (f == "boxing")
            assert(has_error(c, Field::result));
        if (f == "bank")
            assert(has_error(c, Field::register_bank));
        if (f == "f0")
            assert(has_error(c, Field::fp_register_value));
        if (f == "flags")
            assert(has_error(c, Field::csr));
    }
    // An out-of-order FP commit must wait for the full prefix before checking FPRs.
    auto a = record(fadd0), b = record(fmadd, 0x1004);
    b.fp_registers[0] = a.result;
    Stream ref;
    ref.records = {a, b};
    Checker c(ref, path("out-of-order"), {10000, 10000, false});
    dispatch(c, a, 0);
    dispatch(c, b, 1);
    retire(c, b, 1);
    c.checkpoint(b.registers, {4, 8}, b.csrs, &b.fp_registers);
    assert(c.checkpoint_count() == 0);
    retire(c, a, 0);
    c.checkpoint(b.registers, {4, 8}, b.csrs, &b.fp_registers);
    c.finish(true, {5, 10});
    assert(c.status() == 0 && c.checkpoint_count() == 1);
    // A bad FP result on a squashed path must remain tentative.
    Stream squash_ref;
    squash_ref.records = {a};
    Checker squashed(squash_ref, path("squashed"), {10000, 10000, false});
    dispatch(squashed, a, 0);
    squashed.execute(0, a.rs1_value, a.rs2_value, a.result ^ 1, false, false, {3, 6});
    squashed.flush_backend({4, 8});
    assert(!squashed.failed() && !squashed.discrepancies().empty());
    for (const auto &d : squashed.discrepancies())
        assert(d.squashed && !d.confirmed);
    std::cout << "F/D checker regressions passed\n";
}
