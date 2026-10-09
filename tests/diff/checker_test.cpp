#include "checker.hh"
#include "monitor.hh"
#include <filesystem>
#include <functional>
#include <gtkwave/fstapi.h>
#include <iostream>
#include <stdexcept>
using namespace len5::diff;
#define REQUIRE(x)                                                                                 \
    do {                                                                                           \
        if (!(x))                                                                                  \
            throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__) +      \
                                     ": " #x);                                                     \
    } while (0)
struct Records : Reference {
    std::vector<ReferenceRecord> records;
    size_t cursor = 0;
    ReferenceRecord step() override { return records.at(cursor++); }
    void add(uint8_t rd, uint8_t rs, uint64_t value, uint64_t pc = 0) {
        ReferenceRecord r;
        r.order = records.size();
        r.pc = pc ? pc : 0x1000 + 4 * r.order;
        r.next_pc = r.pc + 4;
        r.instruction = (1u << 20) | (uint32_t(rs) << 15) | (uint32_t(rd) << 7) | 0x13;
        r.decoded = decode(r.instruction);
        if (!records.empty())
            r.registers = records.back().registers;
        r.rs1_value = r.registers[rs];
        r.result = value;
        r.registers[rd] = value;
        records.push_back(r);
    }
    void load(uint8_t rd, uint64_t data) {
        add(rd, 0, data);
        auto &r = records.back();
        r.instruction = (3u << 12) | (uint32_t(rd) << 7) | 3;
        r.decoded = decode(r.instruction);
        r.address = 0x8000;
        r.raw_data = data;
        r.byte_mask = 255;
    }
    void store(uint64_t data) {
        add(0, 0, 0);
        auto &r = records.back();
        r.instruction = (2u << 20) | (3u << 12) | 0x23;
        r.decoded = decode(r.instruction);
        r.address = 0x8000;
        r.rs2_value = data;
        r.raw_data = data;
        r.byte_mask = 255;
    }
};
Stamp at(uint64_t n) { return {n, n * 2}; }
void dispatch(Checker &c, const ReferenceRecord &r, unsigned rob, Stamp t) {
    c.dispatch(rob, r.pc, r.instruction, r.decoded.rs1, r.decoded.rs2, r.decoded.rd,
               r.decoded.write, t);
}
void commit(Checker &c, const ReferenceRecord &r, unsigned rob, Stamp t) {
    c.commit(rob, r.pc, r.instruction, r.decoded.rd, r.decoded.write, r.result, false, t);
}
void fetch_dispatch(Checker &c, const ReferenceRecord &r, unsigned rob, uint64_t t) {
    c.fetch(r.pc, r.instruction, at(t));
    dispatch(c, r, rob, at(t + 1));
}
void original_fst(const std::string &path) {
    auto *w = fstWriterCreate(path.c_str(), 1);
    REQUIRE(w);
    fstWriterSetTimescale(w, -12);
    fstWriterSetTimezero(w, 0);
    fstWriterSetScope(w, FST_ST_VCD_MODULE, "rtl", nullptr);
    auto h = fstWriterCreateVar(w, FST_VT_VCD_WIRE, FST_VD_IMPLICIT, 1, "clk", 0);
    fstWriterCreateVar(w, FST_VT_VCD_WIRE, FST_VD_IMPLICIT, 1, "clk_alias", h);
    fstWriterSetUpscope(w);
    for (unsigned t = 0; t < 500; ++t) {
        fstWriterEmitTimeChange(w, t);
        fstWriterEmitValueChange32(w, h, 1, t & 1);
    }
    fstWriterClose(w);
}
int main(int argc, char **argv) {
    const std::string base = argc > 1 ? argv[1] : "build/diff-unit";
    std::filesystem::create_directories(base);
    unsigned passed = 0;
    auto test = [&](const std::string &label, const std::function<void(const std::string &)> &fn) {
        auto dir = base + "/" + label;
        std::filesystem::create_directories(dir);
        fn(dir);
        ++passed;
        std::cout << "PASS " << label << '\n';
    };
    try {
        test("sequential_dependencies_multicycle", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.add(2, 1, 2);
            Checker c(r, dir);
            for (unsigned i = 0; i < 2; ++i) {
                auto &e = r.records[i];
                fetch_dispatch(c, e, i, 10 + i * 10);
                c.execute(i, e.rs1_value, 0, e.result, false, false, at(15 + i * 10));
                commit(c, e, i, at(16 + i * 10));
                c.checkpoint(e.registers, at(16 + i * 10));
            }
            c.finish(true, at(40));
            REQUIRE(c.status() == 0);
            REQUIRE(c.checkpoint_count() == 2);
        });
        test("same_time_multiple_lanes", [](auto dir) {
            Records r;
            for (unsigned i = 1; i <= 4; ++i)
                r.add(i, 0, i);
            Checker c(r, dir);
            for (auto &e : r.records)
                c.fetch(e.pc, e.instruction, at(10));
            for (auto &e : r.records)
                dispatch(c, e, e.order, at(11));
            for (auto &e : r.records)
                c.execute(e.order, 0, 0, e.result, false, false, at(20));
            for (auto &e : r.records)
                commit(c, e, e.order, at(21));
            c.checkpoint(r.records.back().registers, at(21));
            c.finish(true, at(22));
            REQUIRE(c.status() == 0);
            original_fst(dir + "/original.fst");
            annotate(dir + "/original.fst", c);
            auto *f = fstReaderOpen((dir + "/annotated.fst").c_str());
            REQUIRE(f);
            REQUIRE(fstReaderGetTimescale(f) == -12);
            unsigned expected = 0, actual = 0, lanes = 0;
            bool rtl = false;
            while (auto *h = fstReaderIterateHier(f)) {
                if (h->htyp == FST_HT_VAR) {
                    std::string n = h->u.var.name;
                    expected += n == "expected_value";
                    actual += n == "actual_value";
                    rtl |= n == "clk";
                }
                if (h->htyp == FST_HT_SCOPE && std::string(h->u.scope.name) == "lane3")
                    ++lanes;
            }
            REQUIRE(expected > 4 && expected == actual && lanes >= 3 && rtl);
            REQUIRE(fstReaderGetAliasCount(f) >= 1);
            fstReaderClose(f);
        });
        test("repeated_pc_and_rob_reuse_after_commit", [](auto dir) {
            Records r;
            for (unsigned i = 0; i < 40; ++i)
                r.add(1, 1, i + 1, 0x1000);
            for (auto &e : r.records)
                e.next_pc = 0x1000;
            Checker c(r, dir);
            for (unsigned i = 0; i < 40; ++i) {
                auto &e = r.records[i];
                fetch_dispatch(c, e, 0, 10 + i * 4);
                c.execute(0, i, 0, i + 1, false, false, at(12 + i * 4));
                commit(c, e, 0, at(13 + i * 4));
                c.checkpoint(e.registers, at(13 + i * 4));
            }
            c.finish(true, at(180));
            REQUIRE(c.status() == 0);
            REQUIRE(c.active_count() == 0);
            REQUIRE(c.committed_count() == 40);
        });
        test("wrong_path_execution_flush_and_reuse", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.add(2, 0, 2);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            commit(c, r.records[0], 0, at(12));
            c.fetch(0xdead, 0x13, at(13));
            c.dispatch(1, 0xdead, 0x13, 0, 0, 0, false, at(14));
            c.execute(1, 99, 99, 99, false, false, at(15));
            c.flush_frontend(at(16));
            c.flush_backend(at(17));
            fetch_dispatch(c, r.records[1], 1, 18);
            commit(c, r.records[1], 1, at(20));
            c.checkpoint(r.records[1].registers, at(20));
            c.finish(true, at(21));
            REQUIRE(c.status() == 0);
        });
        test("correct_prediction_no_flush", [](auto dir) {
            Records r;
            r.add(0, 0, 0);
            r.records[0].instruction = 0x63;
            r.records[0].decoded = decode(0x63);
            r.add(1, 0, 1);
            Checker c(r, dir);
            for (auto &e : r.records) {
                fetch_dispatch(c, e, e.order, 10 + e.order * 3);
                commit(c, e, e.order, at(12 + e.order * 3));
            }
            c.checkpoint(r.records[1].registers, at(16));
            c.finish(true, at(17));
            REQUIRE(c.status() == 0);
        });
        test("squashed_discrepancy_is_not_architectural", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            c.execute(0, 0, 0, 999, false, false, at(12));
            REQUIRE(!c.failed());
            c.flush_backend(at(13));
            fetch_dispatch(c, r.records[0], 0, 14);
            commit(c, r.records[0], 0, at(16));
            c.checkpoint(r.records[0].registers, at(16));
            c.finish(true, at(17));
            REQUIRE(c.status() == 0);
            REQUIRE(c.discrepancies()[0].squashed);
        });
        test("out_of_order_complete_checkpoint", [](auto dir) {
            Records r;
            for (unsigned i = 1; i <= 6; ++i)
                r.add(i, 0, i);
            Checker c(r, dir);
            for (auto &e : r.records)
                fetch_dispatch(c, e, e.order, 10 + 2 * e.order);
            commit(c, r.records[0], 0, at(30));
            c.checkpoint(r.records[0].registers, at(30));
            REQUIRE(c.checkpoint_count() == 1);
            commit(c, r.records[2], 2, at(31));
            commit(c, r.records[3], 3, at(32));
            c.checkpoint({}, at(32));
            REQUIRE(!c.failed());
            commit(c, r.records[1], 1, at(33));
            c.checkpoint(r.records[3].registers, at(33));
            REQUIRE(c.checkpoint_count() == 2);
            commit(c, r.records[5], 5, at(34));
            c.checkpoint({}, at(34));
            REQUIRE(!c.failed());
            REQUIRE(c.checkpoint_count() == 2);
            commit(c, r.records[4], 4, at(35));
            c.checkpoint(r.records[5].registers, at(35));
            c.finish(true, at(36));
            REQUIRE(c.status() == 0);
        });
        test("same_register_ooo_overwrite_detected", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.add(1, 0, 2);
            Checker c(r, dir);
            for (auto &e : r.records)
                fetch_dispatch(c, e, e.order, 10 + e.order * 2);
            commit(c, r.records[1], 1, at(20));
            c.checkpoint(r.records[1].registers, at(20));
            REQUIRE(!c.failed());
            commit(c, r.records[0], 0, at(21));
            c.checkpoint(r.records[0].registers, at(21));
            c.finish(true, at(22));
            REQUIRE(c.status() == 1);
            REQUIRE(c.discrepancies().back().event.field == Field::register_value);
        });
        for (auto kind : {"operand", "cdb", "register"})
            test(std::string("fault_") + kind, [kind](auto dir) {
                Records r;
                r.add(1, 0, 1);
                Checker c(r, dir);
                fetch_dispatch(c, r.records[0], 0, 10);
                c.execute(0, std::string(kind) == "operand" ? 99 : 0, 0,
                          std::string(kind) == "cdb" ? 99 : 1, false, false, at(20));
                REQUIRE(!c.failed());
                c.commit(0, r.records[0].pc, r.records[0].instruction, 1, true,
                         std::string(kind) == "register" ? 99 : 1, false, at(30));
                c.finish(true, at(31));
                REQUIRE(c.status() == 1);
                REQUIRE(c.first_error()->cycle == (std::string(kind) == "register" ? 30 : 20));
                original_fst(dir + "/original.fst");
                annotate(dir + "/original.fst", c);
                auto *f = fstReaderOpen((dir + "/annotated.fst").c_str());
                REQUIRE(f);
                fstReaderClose(f);
            });
        test("multiple_loads_same_address_complete_reversed", [](auto dir) {
            Records r;
            r.load(1, 42);
            r.load(2, 42);
            Checker c(r, dir);
            for (auto &e : r.records) {
                fetch_dispatch(c, e, e.order, 10 + e.order * 2);
                c.allocate(e.order, e.order, false, at(14));
            }
            for (unsigned idx : {1, 0}) {
                c.memory(idx, false, 0x8000, 8, 255, 42, true, at(20 + 2 * (1 - idx)));
                c.execute(idx, 0, 0, 42, false, false, at(21 + 2 * (1 - idx)));
            }
            commit(c, r.records[1], 1, at(25));
            commit(c, r.records[0], 0, at(26));
            c.checkpoint(r.records[1].registers, at(26));
            c.finish(true, at(27));
            REQUIRE(c.status() == 0);
        });
        test("store_forwarding_and_delayed_external_completion", [](auto dir) {
            Records r;
            r.store(42);
            r.load(1, 42);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            c.allocate(0, 3, true, at(12));
            c.memory(3, true, 0x8000, 8, 255, 42, true, at(13));
            c.authorize(3, 0, at(14));
            fetch_dispatch(c, r.records[1], 1, 15);
            c.allocate(1, 4, false, at(17));
            c.memory(4, false, 0x8000, 8, 255, 42, true, at(18));
            c.execute(1, 0, 0, 42, false, false, at(19));
            c.execute(0, 0, 42, 0x8000, false, false, at(20));
            commit(c, r.records[0], 0, at(21));
            // ROB 0 is now reusable while store tag 3 remains live.
            REQUIRE(c.active_count() == 1);
            c.external_store(3, 0x8000, 255, 42, at(22));
            c.store_response(3, false, at(24));
            commit(c, r.records[1], 1, at(25));
            c.checkpoint(r.records[1].registers, at(25));
            c.finish(true, at(26));
            REQUIRE(c.status() == 0);
        });
        test("unauthorized_store", [](auto dir) {
            Records r;
            r.store(42);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            c.allocate(0, 3, true, at(12));
            c.external_store(3, 0x8000, 255, 42, at(13));
            c.finish(false, at(14));
            REQUIRE(c.status() == 1);
            REQUIRE(c.first_error()->field == Field::unauthorized_store);
        });
        test("unknown_store", [](auto dir) {
            Records r;
            Checker c(r, dir);
            c.external_store(9, 0x8000, 255, 42, at(10));
            c.finish(false, at(11));
            REQUIRE(c.status() == 1);
        });
        test("wrong_path_commit", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            Checker c(r, dir);
            c.fetch(0x2000, 0x13, at(10));
            c.dispatch(0, 0x2000, 0x13, 0, 0, 0, false, at(11));
            c.commit(0, 0x2000, 0x13, 0, false, 0, false, at(12));
            c.finish(true, at(13));
            REQUIRE(c.status() == 1);
        });
        test("flush_does_not_reset_recovery_timeout", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            Checker c(r, dir, {5, 100});
            c.fetch(0xdead, 0x13, at(10));
            c.flush_frontend(at(12));
            c.tick(at(15));
            c.finish(false, at(16));
            REQUIRE(c.status() == 1);
            REQUIRE(c.first_error()->field == Field::timeout);
        });
        test("actual_recovery_clears_watchdog", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            Checker c(r, dir, {5, 100});
            c.fetch(0xdead, 0x13, at(10));
            c.flush_frontend(at(12));
            fetch_dispatch(c, r.records[0], 0, 13);
            commit(c, r.records[0], 0, at(15));
            c.checkpoint(r.records[0].registers, at(15));
            c.tick(at(18));
            c.finish(true, at(19));
            REQUIRE(c.status() == 0);
        });
        test("active_rob_collision", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.add(2, 0, 2);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            fetch_dispatch(c, r.records[1], 0, 12);
            REQUIRE(c.failed());
        });
        test("deferred_next_pc_reversed_commit", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.add(2, 0, 2);
            r.records[0].next_pc = 0xbad;
            Checker c(r, dir);
            for (auto &e : r.records)
                fetch_dispatch(c, e, e.order, 10 + e.order * 2);
            commit(c, r.records[1], 1, at(20));
            REQUIRE(!c.failed());
            commit(c, r.records[0], 0, at(21));
            REQUIRE(c.failed());
            REQUIRE(c.first_error()->field == Field::next_pc);
        });
        test("same_pc_recovery_before_backend_flush", [](auto dir) {
            Records r;
            r.add(0, 0, 0);
            r.records[0].instruction = 0x263;
            r.records[0].decoded = decode(0x263);
            r.add(1, 0, 1);
            r.add(2, 0, 2);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            fetch_dispatch(c, r.records[1], 1, 12);
            c.resolve_branch(0, r.records[0].next_pc, true, at(14));
            c.flush_frontend(at(15));
            auto replacement = c.fetch(r.records[1].pc, r.records[1].instruction, at(16));
            REQUIRE(c.instruction(replacement)->reference->order == 1);
            commit(c, r.records[0], 0, at(17));
            c.flush_backend(at(17));
            dispatch(c, r.records[1], 1, at(18));
            commit(c, r.records[1], 1, at(19));
            c.checkpoint(r.records[1].registers, at(19));
            c.finish(true, at(20));
            REQUIRE(c.status() == 0);
        });
        test("flushed_load_response_after_index_reuse", [](auto dir) {
            Records r;
            r.load(1, 42);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            c.allocate(0, 0, false, at(12));
            c.load_request(0, 0x8000, 255, at(13));
            c.flush_backend(at(14));
            fetch_dispatch(c, r.records[0], 0, 15);
            c.allocate(0, 0, false, at(17));
            c.load_request(0, 0x8000, 255, at(18));
            c.load_response(0, 999, false, at(19)); // stale transaction is independently tombstoned
            c.load_response(0, 42, false, at(20));
            c.execute(0, 0, 0, 42, false, false, at(21));
            commit(c, r.records[0], 0, at(22));
            c.checkpoint(r.records[0].registers, at(22));
            c.finish(true, at(23));
            REQUIRE(c.status() == 0);
        });
        test("load_byte_mask_fault", [](auto dir) {
            Records r;
            r.load(1, 42);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            c.allocate(0, 0, false, at(12));
            c.load_request(0, 0x8000, 15, at(13));
            commit(c, r.records[0], 0, at(14));
            c.finish(true, at(15));
            REQUIRE(c.status() == 1);
            REQUIRE(c.first_error()->field == Field::mask);
        });
        test("architectural_csr_snapshot", [](auto dir) {
            Records r;
            r.add(1, 0, 1);
            r.records[0].csrs[0x340] = 7;
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            commit(c, r.records[0], 0, at(12));
            c.checkpoint(r.records[0].registers, at(12), {{0x340, 9}});
            c.finish(true, at(13));
            REQUIRE(c.status() == 1);
            REQUIRE(c.first_error()->field == Field::csr);
            REQUIRE(c.first_error()->register_index == 0x340);
        });
        for (bool reversed : {false, true})
            test(reversed ? "overlapping_store_order_fault" : "overlapping_stores_ordered",
                 [reversed](auto dir) {
                     Records r;
                     r.store(42);
                     r.store(99);
                     Checker c(r, dir);
                     for (unsigned i = 0; i < 2; ++i) {
                         fetch_dispatch(c, r.records[i], i, 10 + 3 * i);
                         c.allocate(i, i, true, at(12 + 3 * i));
                         c.authorize(i, i, at(12 + 3 * i));
                     }
                     for (unsigned n = 0; n < 2; ++n) {
                         unsigned i = reversed ? 1 - n : n;
                         c.external_store(i, 0x8000, 255, r.records[i].raw_data, at(20 + n));
                         c.store_response(i, false, at(20 + n));
                     }
                     for (unsigned i = 0; i < 2; ++i) {
                         c.execute(i, 0, r.records[i].raw_data, 0x8000, false, false, at(25 + i));
                         commit(c, r.records[i], i, at(25 + i));
                     }
                     c.checkpoint(r.records.back().registers, at(27));
                     c.finish(true, at(28));
                     REQUIRE(c.status() == int(reversed));
                     if (reversed)
                         REQUIRE(c.first_error()->field == Field::store_order);
                 });
        test("authorization_cannot_bypass_unresolved_branch", [](auto dir) {
            Records r;
            r.add(0, 0, 0);
            r.records[0].instruction = 0x63;
            r.records[0].decoded = decode(0x63);
            r.store(42);
            Checker c(r, dir);
            fetch_dispatch(c, r.records[0], 0, 10);
            fetch_dispatch(c, r.records[1], 1, 12);
            c.allocate(1, 0, true, at(14));
            c.authorize(0, 1, at(15));
            c.finish(false, at(16));
            REQUIRE(c.status() == 1);
            REQUIRE(c.first_error()->field == Field::unauthorized_store);
        });
        std::cout << passed << " tests passed\n";
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
