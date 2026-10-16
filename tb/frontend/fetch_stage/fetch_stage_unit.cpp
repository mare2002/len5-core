// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#include "fetch_stage_components.hh"
#include "fetch_stage_composition.hh"
#include "fetch_stage_ras_witness.hh"
#include <iostream>
#include <numeric>
using namespace len5::frontend;
static unsigned checks = 0;
static void check(bool ok, const char *what) {
    ++checks;
    if (!ok)
        throw std::runtime_error(what);
}
template <class F> static void rejects(F f, const char *what) {
    bool rejected = false;
    try {
        f();
    } catch (const std::exception &) {
        rejected = true;
    }
    check(rejected, what);
}
static Bundle bundle(uint64_t pc, std::initializer_list<uint32_t> words) {
    Bundle b;
    static uint64_t next_bundle_id = 1;
    b.id = next_bundle_id++;
    unsigned k = 0;
    for (auto w : words) {
        b.mask |= 1u << k;
        b.lanes[k].word = w;
        b.lanes[k].prediction.pc = pc + 4 * k;
        ++k;
    }
    return b;
}
int main() {
    try {
        Config c;
        check(!training_window(10, 10, 20), "training edge sees old prediction");
        check(training_window(11, 10, 20), "next request can witness training");
        check(training_window(20, 10, 20), "overwrite edge freezes preceding prediction");
        check(!training_window(21, 10, 20), "overwritten state cannot witness old update");
        {
            Predictor p(c);
            p.update({8, 0x180, true, false});
            p.update({0x180, 0x100, true, false});
            for (auto pc : {0x104u, 0x108u, 0x110u, 0x120u, 0x12cu})
                p.update({pc, 0x700, false, false});
            auto jal = p.predict(0x180);
            check(jal.hit && !jal.taken && jal.target == 0x100,
                  "independent coherent JAL hit/NT with preserved source tag");
            check(make_program(c, "jal-nt", 8).word(0x180) == 0xf81ff06f,
                  "fixed backward JAL encoding in persistent interference program");
        }
        {
            RasWitness ledger;
            len5::early::State old;
            old.predictive.known = true;
            old.confirmed.known = true;
            CompositionPlan p;
            p.a = true;
            p.transfer.id = 1;
            p.ee.selection.lane = 0;
            p.es.inputs.predictions[0].pc = 0x100;
            p.et.speculative = len5::early::Operation::Push;
            p.et.next = old;
            p.et.next.predictive.entries.push_back({0x104, 1, 1, 0x100, 0x008000ef, {}});
            ledger.edge(p, old, 1, 0, false, "");
            check(ledger.witnessed() == 0, "RAS transition alone is not coverage");
            old = p.et.next;
            p.transfer.id = 2;
            p.es.inputs.predictions[0].pc = 0x200;
            p.et.speculative = len5::early::Operation::Pop;
            p.et.next.predictive.entries.clear();
            ledger.edge(p, old, 2, 0, false, "");
            check(ledger.witnessed() == 0, "RAS generated probe alone is not coverage");
            auto b = bundle(0x200, {0x00008067});
            b.id = 2;
            check(ledger.dispatch(b, 3) == 1 && ledger.witnessed() == 1,
                  "matched public return completes preceding push obligation");
            check(ledger.json("stop").find("canceled-stop-unwitnessed") != std::string::npos,
                  "unprobed pop remains explicitly unwitnessed at stop");
        }
        {
            RasWitness ledger;
            len5::early::State empty, full;
            empty.predictive.known = empty.confirmed.known = true;
            full = empty;
            full.confirmed.entries = {{0x104, 1, 1, 0x100, 0, {}}, {0x204, 2, 2, 0x200, 0, {}}};
            full.predictive = full.confirmed;
            CompositionPlan p;
            p.et.next = full;
            ledger.edge(p, empty, 10, 0, true, "branch");
            ledger.edge(p, full, 11, 1, true, "branch"); // could repair an unobserved bad first restore
            p.a = true;
            p.ee.selection.lane = 0;
            p.et.speculative = len5::early::Operation::Pop;
            for (unsigned k = 0; k < 2; ++k) {
                p.transfer.id = 20 + k;
                p.es.inputs.predictions[0].pc = 0x300 + 4 * k;
                p.et.next = full;
                p.et.next.predictive.entries.pop_back();
                ledger.edge(p, full, 12 + 2 * k, 2, false, "");
                auto b = bundle(0x300 + 4 * k, {0x00008067});
                b.id = p.transfer.id;
                ledger.dispatch(b, 13 + 2 * k);
                full = p.et.next;
            }
            check(ledger.restored_multiple() == 0,
                  "later recovery cannot witness an earlier potentially repaired restore");
            check(ledger.json("stop").find("canceled-recovery-unwitnessed") != std::string::npos,
                  "superseded restoration stays explicitly unwitnessed");
        }
        check(evaluate(0xfff00093, 0, 0, 0).value == UINT64_MAX, "fixed ADDI negative");
        check(evaluate(0x800000b7, 0, 0, 0).value == UINT64_C(0xffffffff80000000), "LUI sign extension");
        check(evaluate(0x00001097, 0x100, 0, 0).value == 0x1100, "AUIPC fixed");
        check(evaluate(0x008000ef, 0x100, 0, 0).target == 0x108, "fixed JAL displacement");
        check(evaluate(0xffd100e7, 0x100, 0x206, 0).target == 0x202, "fixed JALR bit zero");
        check(evaluate(0x00008067, 0x100, 0x444, 0).target == 0x444, "canonical RET");
        check(!evaluate(0x00028067, 0x100, 0x444, 0).decoded.recognized(), "x5 return excluded");
        for (unsigned f : {0u, 1u, 4u, 5u, 6u, 7u})
            for (auto a : {uint64_t(0), uint64_t(1), UINT64_MAX, UINT64_C(0x8000000000000000)})
                for (auto b : {uint64_t(0), uint64_t(1), UINT64_MAX, UINT64_C(0x8000000000000000)}) {
                    const bool sl = (a >> 63) != (b >> 63) ? bool(a >> 63) : a < b;
                    bool expected = f == 0   ? a == b
                                    : f == 1 ? a != b
                                    : f == 4 ? sl
                                    : f == 5 ? !sl
                                    : f == 6 ? a < b
                                             : a >= b;
                    auto s = evaluate(len5::early::branch(f, 2, 3, -16), 0x100, a, b);
                    check(s.taken == expected && s.target == 0xf0, "six branch conditions");
                }
        for (int x : {-2048, -1, 0, 1, 2047})
            for (unsigned f : {0u, 4u, 6u, 7u}) {
                auto s = evaluate(immediate(f, 2, 3, x), 0, 0xabcdef, 0);
                auto i = uint64_t(int64_t(x));
                uint64_t v = f == 0   ? 0xabcdef + i
                             : f == 4 ? 0xabcdef ^ i
                             : f == 6 ? 0xabcdef | i
                                      : 0xabcdef & i;
                check(s.value == v, "logical immediate semantics");
            }
        check(evaluate(0x002081b3, 0, UINT64_MAX, 1).value == 0, "fixed ADD modular overflow");
        check(evaluate(0x402081b3, 0, UINT64_MAX, 1).value == UINT64_MAX - 1, "fixed SUB");
        check(evaluate(0x0020f1b3, 0, 0xa5, 0x0f).value == 5, "fixed AND");
        check(evaluate(0x0020e1b3, 0, 0xa5, 0x0f).value == 0xaf, "fixed OR");
        check(evaluate(0x0020c1b3, 0, 0xa5, 0x0f).value == 0xaa, "fixed XOR");
        check(evaluate(0x002091b3, 0, 1, 65).value == 2, "fixed SLL masks shift count");
        check(evaluate(0x0020d1b3, 0, UINT64_C(0x8000000000000000), 63).value == 1, "fixed SRL");
        check(evaluate(0x4020d1b3, 0, UINT64_C(0x8000000000000000), 63).value == UINT64_MAX, "fixed SRA");
        check(evaluate(0x0020a1b3, 0, UINT64_MAX, 0).value == 1, "fixed SLT negative");
        check(evaluate(0x0020b1b3, 0, UINT64_MAX, 0).value == 0, "fixed SLTU unsigned");
        check(!evaluate(0x00100013, 0, 123, 456).writes, "x0 write discarded");
        rejects([] { evaluate(0x02000033, 0, 1, 2); }, "MUL cannot silently execute as NOP");
        rejects([] { evaluate(0, 0, 0, 0); }, "invalid instruction rejected");
        for (unsigned n : {1u, 2u, 4u, 8u}) {
            Config x = c;
            x.lanes = n;
            Predictor p(x);
            auto cold = p.predict(0x100);
            check(!cold.hit && cold.taken, "cold WT miss");
            auto u = p.update({0x100, 0x200, true, false});
            check(u.before == 2 && u.after == 3 && p.history() == 1, "first update");
            check(p.predict(0x100).hit, "BTB install");
            p.update({0x140, 0x300, true, false});
            check(!p.predict(0x100).hit && p.predict(0x140).hit, "different tag replacement");
            p.update({0x140, 0x300, false, true});
            check(!p.predict(0x140).hit, "NT misprediction deletion");
            p.reset();
            check(p.history() == 0 && !p.predict(0x100).hit, "predictor reset");
            for (const auto &family :
                 {"sequential",        "loop-a",      "loop-b",    "phase",        "alternating",
                  "interacting",       "conflict",    "jal-loop",  "call",         "multi-caller",
                  "three-callers",     "nested",      "empty-ret", "indirect",     "wrong-call",
                  "wrong-return",      "lanes",       "stale-ras", "ordered-pair", "call-kind",
                  "multiple-jumps",    "mask-cutoff", "nt-call",   "jal-nt",       "caller-order",
                  "wrong-return-deep", "reset-loaded", "threshold-interacting", "branch-pressure", "history-pair"}) {
                auto program = make_program(x, family, 16, 3);
                program.validate();
                check(program.digest() == make_program(x, family, 16, 3).digest(),
                      "immutable program determinism");
            }
        }
        for (const auto &dist : {"uniform", "fixed", "triangular-early", "triangular-late", "triangular-mode",
                                 "truncated-geometric", "bimodal"}) {
            LatencyOptions o;
            o.distribution = dist;
            LatencySampler a(o, 73), b(o, 73);
            uint64_t sum = 0;
            for (unsigned k = 0; k < 10000; ++k) {
                auto x = a.sample();
                check(x == b.sample() && x >= 1 && x <= 64, "latency deterministic range");
                sum += x;
            }
            if (o.distribution == "triangular-early")
                check(sum < 280000, "early shape");
            if (o.distribution == "triangular-late")
                check(sum > 380000, "late shape");
            o.minimum = o.maximum = 7;
            LatencySampler f(o, 2);
            for (unsigned k = 0; k < 20; ++k)
                check(f.sample() == 7, "single-point latency");
        }
        LatencyOptions bad;
        bad.minimum = 0;
        rejects([&] { LatencySampler l(bad, 0); }, "zero latency invalid");
        bad = {};
        bad.mode = 65;
        rejects([&] { LatencySampler l(bad, 0); }, "invalid mode");
        LatencyOptions fixed;
        fixed.distribution = "fixed";
        fixed.fixed = 2;
        Backend be(c, fixed, 1);
        auto b = bundle(0, {immediate(0, 2, 0, 4), immediate(0, 2, 2, 3), immediate(0, 3, 2, -1)});
        be.dispatch(b, 0);
        check(be.speculative(2) == 7 && be.speculative(3) == 6, "ordered register versions");
        rejects([&] { be.dispatch(b, 0); }, "duplicate accepted bundle identity rejected");
        for (uint64_t cy = 0; cy < 12; ++cy) {
            be.consume_feedback(be.feedback(cy), cy);
            be.advance(cy);
        }
        check(be.committed(2) == 7 && be.committed(3) == 6 && be.pending() == 0,
              "operand availability and retirement");
        be.reset();
        be.dispatch(
            bundle(0, {len5::early::branch(0, 0, 0, 16), immediate(0, 2, 0, 99), immediate(0, 3, 2, 1)}), 0);
        uint64_t recovery = 0;
        for (uint64_t cy = 0; cy < 10; ++cy) {
            auto f = be.feedback(cy);
            if (f.flush)
                recovery = cy;
            be.consume_feedback(f, cy);
            be.advance(cy);
        }
        check(recovery == be.record(1).execute + 2 && be.speculative(2) == 0 && be.stats.canceled == 2,
              "wrong-path rollback and e+2 recovery");
        rejects(
            [&] {
                Feedback f;
                f.id = 2;
                f.train = true;
                be.validate_feedback(f, 20);
            },
            "canceled feedback rejected");
        be.dispatch(bundle(16, {immediate(0, 2, 0, 7)}), 10);
        for (uint64_t cy = 10; cy < 20; ++cy) {
            be.consume_feedback(be.feedback(cy), cy);
            be.advance(cy);
        }
        check(be.committed(2) == 7, "correct refetch executes after rollback");
        Backend ordered(c, fixed, 3);
        auto bs = bundle(0, {len5::early::branch(1, 0, 0, 16), len5::early::branch(1, 0, 0, 16)});
        ordered.dispatch(bs, 0);
        Feedback first;
        for (uint64_t cy = 0; cy < 20; ++cy) {
            auto f = ordered.feedback(cy);
            if (f.train && !first.id)
                first = f;
            ordered.consume_feedback(f, cy);
            ordered.advance(cy);
        }
        check(ordered.stats.updates == 2 && ordered.record(2).execute > ordered.record(1).execute,
              "branch cursor order");
        rejects([&] { ordered.validate_feedback(first, 30); }, "duplicate update rejected");
        // Find an actual deterministic stream with independently sampled 64/1.
        uint64_t blocking_seed = 0;
        for (; blocking_seed < 100000; ++blocking_seed) {
            LatencySampler sampler({}, blocking_seed);
            if (sampler.sample() == 64 && sampler.sample() == 1)
                break;
        }
        check(blocking_seed < 100000, "64/1 latency fixture exists");
        Backend blocking(c, {}, blocking_seed);
        blocking.dispatch(bs, 0);
        for (uint64_t cy = 0; cy < 80; ++cy) {
            blocking.consume_feedback(blocking.feedback(cy), cy);
            blocking.advance(cy);
        }
        check(blocking.record(1).latency == 64 && blocking.record(2).latency == 1 &&
                  blocking.record(2).execute > blocking.record(1).execute,
              "younger L1 waits for older L64 without resampling");
        check(blocking.record(2).order_delay > 0 && blocking.stats.updates == 2,
              "ordering delay separate from sampled delay");
        for (const std::string family : {"loop-a", "loop-b", "multi-caller", "nested"}) {
            auto program = make_program(c, family, 4, 4);
            Backend b(c, fixed, 8);
            std::array<uint64_t, 32> registers{};
            uint64_t pc = c.boot;
            bool stopped = false;
            for (uint64_t cy = 0; cy < 3000; ++cy) {
                b.consume_feedback(b.feedback(cy), cy);
                if (!stopped && b.ready()) {
                    auto w = program.word(pc);
                    auto d = len5::early::decode(w);
                    auto semantic = evaluate(w, pc, registers[d.rs1], registers[d.rs2]);
                    auto input = bundle(pc, {w});
                    input.lanes[0].prediction.hit = semantic.control;
                    input.lanes[0].prediction.taken = semantic.taken;
                    input.lanes[0].prediction.target = semantic.target;
                    b.dispatch(input, cy);
                    if (semantic.writes)
                        registers[semantic.rd] = semantic.value;
                    stopped = pc == program.marker;
                    pc = semantic.next;
                }
                b.advance(cy);
                if (stopped && b.pending() == 0)
                    break;
            }
            check(stopped && b.pending() == 0, "pure executable program completed");
            for (unsigned r = 0; r < 32; ++r)
                check(b.committed(r) == registers[r], "versioned engine versus in-order register fixture");
        }
        {
            // A changes history after younger B sampled H0. No speculative GHR.
            Predictor current(c);
            const auto b_lookup = current.index(4);
            check(b_lookup == 1 && current.counter(b_lookup) == 2, "B pre-edge H0 lookup");
            const auto a_update = current.update({0, 4, true, false});
            check(a_update.index == 0 && current.history() == 1, "A updates before B resolves");
            const auto b_update = current.update({4, 8, false, false});
            check(b_update.history == 1 && b_update.index == 0 && b_update.index != b_lookup,
                  "prediction-time and resolution-time histories cannot be conflated");
            check(current.counter(0) == 2 && current.counter(1) == 2,
                  "Policy A trains resolution index, leaving original lookup unchanged");
            std::array<unsigned, 16> saved;
            saved.fill(2);
            saved[0] = 3; // same eligible A update
            --saved[b_lookup];
            check(saved[0] == 3 && saved[1] == 1, "Policy B independent saved-index alternative");
            check(current.generation(0) == 2 && current.generation(1) == 0,
                  "same-index version accounting distinguishes intervening writes");
        }
        {
            // Source-sized IQ/ROB/RS envelope, not frontend-bundle ROB allocation.
            for (unsigned n : {1u, 2u, 4u, 8u}) {
                Config x = c;
                x.lanes = n;
                Backend capacity(x, fixed, 1);
                uint64_t pc = 0;
                auto feed = [&](uint64_t cycle) {
                    Bundle input;
                    static uint64_t id = 100000;
                    input.id = ++id;
                    input.mask = (1u << n) - 1;
                    for (unsigned k = 0; k < n; ++k) {
                        input.lanes[k].word = immediate(0, 0, 0, 0);
                        input.lanes[k].prediction.pc = pc + 4 * k;
                    }
                    capacity.dispatch(input, cycle);
                    pc += 4 * n;
                };
                for (uint64_t cycle = 0; cycle < 130; ++cycle) {
                    if (capacity.ready()) feed(cycle);
                    capacity.advance(cycle, false); // legitimate commit backpressure
                }
                check(capacity.resources().iq == x.iq && capacity.resources().rob == x.rob,
                      "BP01/02/05 IQ and ROB saturate without premature completed-entry release");
                check(capacity.stats.published >= x.rob && capacity.stats.retired == 0,
                      "completion/publication does not imply retirement");
                rejects([&] { feed(130); }, "illegal whole-bundle admission rejected");
                check(capacity.ready(0) && !capacity.ready(1), "actual valid mask capacity check");
                rejects([&] { capacity.advance(129); }, "excess per-edge issue/publication rejected");
                for (uint64_t cycle = 130; cycle < 400; ++cycle) {
                    capacity.consume_feedback(capacity.feedback(cycle), cycle);
                    capacity.advance(cycle);
                }
                check(capacity.pending() == 0 && capacity.stats.retired == capacity.stats.dispatched,
                      "BP08 natural drain and allocation/release conservation");
            }
            rejects([&] { validate_resources(c, {c.iq+1,0,0,0}); }, "IQ overflow validator");
            rejects([&] { validate_resources(c, {0,c.rob+1,0,0}); }, "ROB overflow validator");
            rejects([&] { validate_resources(c, {0,8,c.branch_capacity+1,0}); }, "branch RS overflow validator");
            rejects([&] { validate_resources(c, {0,16,0,c.alu_capacity+1}); }, "ALU RS overflow validator");
            rejects([&] { validate_resources(c, {0,0,1,0}); }, "premature ROB release validator");
            auto lifecycle = be.record(1);
            auto invalid = lifecycle;
            invalid.execute = invalid.start;
            rejects([&] { validate_lifecycle(invalid); }, "completion before execution service rejected");
            invalid = lifecycle; invalid.start = invalid.issue;
            rejects([&] { validate_lifecycle(invalid); }, "start before legal issue rejected");
            invalid = lifecycle; invalid.earliest = invalid.start+1;
            rejects([&] { validate_lifecycle(invalid); }, "sampled minimum delay cannot be bypassed");
            invalid = lifecycle; invalid.publication = invalid.execute;
            rejects([&] { validate_lifecycle(invalid); }, "result publication before capture rejected");
            invalid = lifecycle; invalid.retire = invalid.publication;
            rejects([&] { validate_lifecycle(invalid); }, "premature retirement rejected");
        }
        {
            auto valid = be.records();
            validate_backend_history(valid);
            check(!valid.empty(), "nonempty lifecycle fixture");
            auto duplicate = valid;
            duplicate.push_back(duplicate.front());
            rejects([&] { validate_backend_history(duplicate); }, "double completion/retirement record rejected");
            Backend ports(c, fixed, 1);
            ports.dispatch(bundle(0, {immediate(0,2,0,1), immediate(0,3,0,2)}), 0);
            for (uint64_t t=0; t<16; ++t) ports.advance(t);
            auto corrupted = ports.records();
            corrupted[1].issue = corrupted[0].issue;
            rejects([&] { validate_backend_history(corrupted); }, "excess scalar issue history rejected");
            corrupted = ports.records();
            corrupted[0].publication = corrupted[1].publication;
            corrupted[0].retire = corrupted[0].publication + 2;
            corrupted[1].retire = corrupted[0].publication + 3;
            {
                bool correct = false;
                try { validate_backend_history(corrupted); }
                catch (const std::logic_error &e) { correct = std::string(e.what()).find("excess CDB") != std::string::npos; }
                check(correct, "excess result publication detected by bandwidth validator");
            }
            corrupted = ports.records(); corrupted[0].retire = corrupted[1].retire;
            {
                bool correct = false;
                try { validate_backend_history(corrupted); }
                catch (const std::logic_error &e) { correct = std::string(e.what()).find("excess retirement") != std::string::npos; }
                check(correct, "double retirement detected by retirement bandwidth validator");
            }
            LatencyOptions long_delay; long_delay.distribution = "fixed"; long_delay.fixed = 64;
            Backend branches(c, long_delay, 1);
            uint64_t pc=0;
            for (uint64_t t=0; t<50; ++t) {
                if (branches.ready(1)) {
                    branches.dispatch(bundle(pc, {len5::early::branch(1,0,0,4)}), t);
                    pc += 4;
                }
                branches.advance(t);
            }
            check(branches.resources().branch == c.branch_capacity && branches.stats.branch_blocks,
                  "BP03 allocated branch RS remains full before ordered execution");
            for (uint64_t t=50; t<400; ++t) {
                branches.consume_feedback(branches.feedback(t),t);
                branches.advance(t);
            }
            check(branches.pending()==0, "BP03 bounded branch issue and natural retirement resume");
            validate_backend_history(branches.records());
        }
        {
            Backend held(c, fixed, 1);
            held.dispatch(bundle(0, {len5::early::branch(1,0,0,4)}), 0);
            for (uint64_t t=0; t<=3; ++t) held.advance(t);
            check(held.record(1).completed && held.resources().branch == 1 && held.resources().rob == 1,
                  "completed branch still owns RS and ROB before CDB publication");
            held.consume_feedback(held.feedback(4), 4); held.advance(4);
            check(held.resources().branch == 0 && held.resources().rob == 1 && !held.record(1).retired,
                  "CDB releases RS but not unretired ROB");
            held.advance(5);
            check(held.resources().rob == 0 && held.record(1).retired, "retirement releases ROB exactly once");
            Backend partial(c, fixed, 1);
            uint64_t pc=0;
            for (unsigned k=0; k<14; ++k) {
                partial.dispatch(bundle(pc, {immediate(0,0,0,0)}), 0); pc+=4;
            }
            check(partial.ready(3) && !partial.ready(15), "two free IQ slots admit two lanes, not four");
            rejects([&] { partial.ready(5); }, "holey whole-bundle admission rejected");
        }
        {
            Backend rejected(c, fixed, 9);
            auto input = bundle(0, {immediate(0,2,0,7), 0});
            rejects([&] { rejected.dispatch(input,0); }, "invalid later lane rejected before any allocation");
            check(rejected.records().empty() && rejected.stats.dispatched == 0,
                  "invalid bundle cannot partially allocate versions/identities");
            auto huge = bundle(0, {immediate(0,0,0,0)});
            rejects([&] { rejected.dispatch(huge,UINT64_MAX); }, "readiness cycle overflow rejected");
            Backend missed(c, fixed, 1);
            missed.dispatch(bundle(0, {len5::early::branch(1,0,0,4)}),0);
            for (uint64_t t=0;t<4;++t) missed.advance(t);
            rejects([&] { missed.advance(4); }, "missing required feedback consumption is a framework error");
        }
        {
            Backend old_head(c, {}, blocking_seed);
            old_head.dispatch(bundle(0, {len5::early::branch(1,0,0,4), immediate(0,2,0,7)}),0);
            for (uint64_t t=0;t<16;++t) old_head.advance(t);
            check(old_head.record(1).latency == 64 && old_head.record(2).latency == 1 &&
                  !old_head.record(1).completed && old_head.record(2).completed,
                  "older delayed branch permits independent younger completion");
            check(old_head.resources().rob == 2 && old_head.stats.retired == 0,
                  "completed younger instruction retains ROB behind old head");
            auto bad_start = old_head.records();
            for (unsigned k=0;k<2;++k) {
                auto &r=bad_start[k]; r.semantic.control=false; r.earliest=1; r.start=4;
                r.completed=true; r.execute=5; r.publication=6+k; r.retired=true; r.retire=8+k;
            }
            bool detected=false;
            try { validate_backend_history(bad_start); }
            catch (const std::logic_error &e) { detected=std::string(e.what()).find("excess per-unit")!=std::string::npos; }
            check(detected,"excess execution initiation rejected by per-unit bandwidth validator");
        }
        Composition composition(c);
        Inputs i;
        i.rst_n = false;
        composition.input_change(i);
        auto p = composition.plan(i, 0);
        check(p.expected.request.known && p.expected.request.value == 0, "async reset suppresses request");
        composition.edge(i, p);
        i.rst_n = true;
        composition.edge(i, composition.plan(i, 1));
        i.grant = true;
        p = composition.plan(i, 2);
        check(p.expected.address.value == 0 && p.mt.k, "composed boot request");
        composition.edge(i, p);
        i.grant = false;
        i.response_valid = true;
        i.response.words.fill(0x13);
        p = composition.plan(i, 3);
        check(p.mt.r && !p.a, "registered response cannot transfer on arrival edge");
        composition.edge(i, p);
        i.response_valid = false;
        p = composition.plan(i, 4);
        check(p.a && !p.d, "answer transfer distinct from public dispatch");
        composition.edge(i, p);
        p = composition.plan(i, 5);
        check(p.d && p.expected.lanes[0].word.value == 0x13, "composed tuple public output");
        i.flush = true;
        i.reason = "exception";
        composition.edge(i, composition.plan(i, 5));
        check(!composition.ras().predictive.known && !composition.ras().confirmed.known,
              "EQ08 uncertainty affects both histories");
        i.flush = false;
        p = composition.plan(i, 6);
        check(p.expected.write.known && p.expected.write.value == 0,
              "unrelated known check survives uncertainty");
        i.grant = true;
        composition.edge(i, composition.plan(i, 6));
        i.grant = false;
        i.response_valid = true;
        i.response.words.fill(0x13);
        i.response.words[0] = 0x00008067;
        composition.edge(i, composition.plan(i, 7));
        i.response_valid = false;
        p = composition.plan(i, 8);
        check(p.uncertain && !p.expected.early_flush.known && !p.expected.response_ready.known,
              "unknown return control propagates into cancellation-dependent "
              "memory readiness");
        check(p.expected.write.known && p.expected.address.known,
              "unknown correction keeps independent current-address and readonly "
              "checks");
        {
            Composition unknown(c);
            Inputs z;
            z.rst_n = false;
            unknown.input_change(z);
            unknown.edge(z, unknown.plan(z, 0));
            z.rst_n = true;
            unknown.edge(z, unknown.plan(z, 1));
            z.flush = true;
            z.reason = "exception";
            unknown.edge(z, unknown.plan(z, 2));
            z.flush = false;
            z.grant = true;
            unknown.edge(z, unknown.plan(z, 3));
            z.grant = false;
            z.response_valid = true;
            z.response.words.fill(0x13);
            z.response.words[0] = 0x0080006f;
            z.response.errors = 1;
            z.response.causes[0] = 0;
            unknown.edge(z, unknown.plan(z, 4));
            z.response_valid = false;
            auto a = unknown.plan(z, 5);
            check(a.a && !a.uncertain && a.ee.selection.target.known && a.ee.selection.target.value == 8,
                  "unknown P does not weaken independent direct-JAL arithmetic");
            unknown.edge(z, a);
            auto d = unknown.plan(z, 6);
            check(d.expected.lanes[0].error.known && d.expected.lanes[0].error.value == 1 &&
                      d.expected.lanes[0].cause.known && d.expected.lanes[0].cause.value == 0,
                  "unknown P does not weaken independently known raised cause zero");
            check(!unknown.ras().predictive.known,
                  "direct JAL did not repair unknown P from any observation");
        }
        std::cout << "PASS: frontend independent predictor/program/backend/latency, " << checks
                  << " checks\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "Test failed: frontend independent units: " << e.what() << " after " << checks
                  << " checks\n";
        return 1;
    }
}
