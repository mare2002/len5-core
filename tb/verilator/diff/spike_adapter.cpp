#include "spike_adapter.hh"
#include "config.h"
#include "riscv/processor.h"
#include "riscv/simif.h"
#include <iostream>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>
#ifndef RISCV_ENABLE_COMMITLOG
#error Spike must be configured with --enable-commitlog
#endif
namespace len5::diff {
struct SpikeReference::Impl final : simif_t {
    std::map<uint64_t, uint8_t> memory;
    std::set<uint64_t> executed_bytes, written_bytes;
    std::unique_ptr<processor_t> cpu;
    FILE *sink = nullptr;
    uint64_t sequence = 0;
    MemoryMap map;
    std::string boundary, violation;
    explicit Impl(const std::string &hex, uint64_t pc, const std::string &isa,
                  const std::map<uint32_t, uint64_t> &csrs, MemoryMap memory_map) : map(memory_map) {
        std::ifstream in(hex);
        if (!in)
            throw std::runtime_error("cannot open identical Spike/RTL firmware: " + hex);
        std::ostringstream content;
        content << in.rdbuf();
        auto text =
            std::regex_replace(content.str(), std::regex("/\\*[\\s\\S]*?\\*/|//[^\\n]*"), " ");
        std::istringstream tokens(text);
        std::string word;
        uint64_t addr = 0;
        while (tokens >> word) {
            size_t used = 0;
            if (word[0] == '@') {
                addr = std::stoull(word.substr(1), &used, 16);
                if (used != word.size() - 1)
                    throw std::runtime_error("invalid readmemh address");
            } else {
                auto value = std::stoull(word, &used, 16);
                if (used != word.size() || value > 255)
                    throw std::runtime_error("firmware must use byte-wide readmemh HEX");
                memory[addr++] = value;
            }
        }
        if (memory.empty())
            throw std::runtime_error("empty firmware");
        sink = std::fopen("/dev/null", "w");
        if (!sink)
            throw std::runtime_error("cannot open Spike log sink");
        cpu = std::make_unique<processor_t>(isa.c_str(), "M", "vlen:128,elen:64", this, 0, false,
                                            sink, std::cerr);
        cpu->get_state()->pc = pc;
        for (auto [addr, value] : csrs) {
            // Spike's FP CSR write hook requires FS enabled, even for debugger
            // writes. Both machines reset fcsr to zero; check it without writing
            // or enabling FS behind the program's back.
            if (addr == 0x003) {
                if (cpu->get_csr(addr) != value)
                    throw std::runtime_error("initial fcsr differs from Spike reset state");
            } else
                cpu->set_csr(addr, value);
        }
        // Logging records are populated by the compiled hooks even with printing disabled.
        // No HTIF boot ROM, CLINT, host syscalls, or speculative RTL state enters this model.
    }
    ~Impl() {
        cpu.reset();
        if (sink)
            std::fclose(sink);
    }
    char *addr_to_mem(reg_t) override {
        return nullptr;
    } // sparse memory, no unchecked host pointers
    bool bounded_memory() const { return map.imem_size != 0 || map.dmem_size != 0; }
    static bool in_region(uint64_t addr, size_t len, uint64_t base, uint64_t size) {
        return len <= size && addr >= base && addr - base <= size - len;
    }
    bool mmio_load(reg_t addr, size_t len, uint8_t *bytes) override {
        if (addr == map.serial || addr == map.exit || (!bounded_memory() && (addr & map.mmio_mask))) {
            violation = "MMIO reads are unsupported (no deterministic input model)";
            return false;
        }
        // Spike shares this callback between instruction fetch and data reads.
        // The adapter regression independently checks IMEM/DMEM access permissions.
        if (bounded_memory() && !in_region(addr, len, map.imem_base, map.imem_size) &&
            !in_region(addr, len, map.dmem_base, map.dmem_size))
            return false;
        for (size_t i = 0; i < len; ++i) {
            auto it = memory.find(addr + i);
            if (it == memory.end())
                return false;
            bytes[i] = it->second;
        }
        return true;
    }
    bool mmio_store(reg_t addr, size_t len, const uint8_t *bytes) override {
        // These are the existing testbench's output-only serial and exit sinks.
        if (!bounded_memory() && (addr & map.mmio_mask) && addr != map.serial && addr != map.exit) {
            violation = "unsupported MMIO store";
            return false;
        }
        if (bounded_memory() && addr != map.serial && addr != map.exit &&
            !in_region(addr, len, map.dmem_base, map.dmem_size))
            return false;
        for (size_t i = 0; i < len; ++i)
            if (executed_bytes.count(addr + i)) {
                violation = "self-modifying code is unsupported";
                return false;
            }
        for (size_t i = 0; i < len; ++i) {
            memory[addr + i] = bytes[i];
            written_bytes.insert(addr + i);
        }
        return true;
    }
    void proc_reset(unsigned) override {}
    const char *get_symbol(uint64_t) override { return nullptr; }
};
SpikeReference::SpikeReference(const std::string &hex, uint64_t pc, const std::string &isa,
                               const std::map<uint32_t, uint64_t> &csrs, MemoryMap memory_map)
    : impl_(std::make_unique<Impl>(hex, pc, isa, csrs, memory_map)) {}
SpikeReference::~SpikeReference() = default;
ReferenceRecord SpikeReference::step() {
    auto &m = *impl_;
    if (!m.boundary.empty())
        throw std::runtime_error(m.boundary);
    auto *s = m.cpu->get_state();
    ReferenceRecord r;
    r.order = m.sequence++;
    r.pc = s->pc;
    r.privilege = s->prv;
    uint8_t bytes[4]{};
    if (!m.mmio_load(r.pc, 4, bytes))
        throw std::runtime_error(
            "reference instruction fetch from uninitialized or unsupported memory");
    for (unsigned k = 0; k < 4; ++k) {
        if (m.written_bytes.count(r.pc + k))
            throw std::runtime_error(
                "self-modifying code is unsupported: fetch from previously written bytes");
        r.instruction |= uint32_t(bytes[k]) << (8 * k);
        m.executed_bytes.insert(r.pc + k);
    }
    r.length = (r.instruction & 3) == 3 ? 4 : 2;
    r.decoded = decode(r.instruction);
    r.has_fp = m.cpu->extension_enabled('F');
    const uint64_t fp_mask = m.cpu->extension_enabled('D') ? ~uint64_t{0} : 0xffffffff;
    // Compare raw register bits, including NaN boxing, without host FP conversions.
    auto fp = [&](unsigned reg) { return s->FPR[reg].v[0] & fp_mask; };
    r.rs1_value = r.decoded.fp_rs1 ? fp(r.decoded.rs1) : s->XPR[r.decoded.rs1];
    r.rs2_value = r.decoded.fp_rs2 ? fp(r.decoded.rs2) : s->XPR[r.decoded.rs2];
    r.rs3_value = fp(r.decoded.rs3);
    auto retired = s->minstret->read();
    m.cpu->step(1);
    r.next_pc = s->pc;
    r.trap = s->minstret->read() == retired;
    if (r.trap) {
        r.cause = s->mcause->read();
        r.tval = s->mtval->read();
    }
    for (unsigned i = 0; i < 32; ++i)
        r.registers[i] = s->XPR[i];
    for (unsigned i = 0; i < 32; ++i)
        r.fp_registers[i] = fp(i);
    r.result = r.decoded.fp_rd ? fp(r.decoded.rd) : s->XPR[r.decoded.rd];
    for (const auto &[reg, val] : s->log_reg_write)
        if ((reg & 15) == 4)
            r.csr_changes[reg >> 4] = val.v[0];
    // get_csr(address) is Spike's side-effect-free debugger peek, so snapshots
    // may observe fcsr while FS=Off without executing an illegal CSR access.
    for (auto addr : {0x300u, 0x305u, 0x340u, 0x341u, 0x342u, 0x343u})
        r.csrs[addr] = m.cpu->get_csr(addr);
    if (m.cpu->extension_enabled('F'))
        r.csrs[0x003] = m.cpu->get_csr(0x003);
    const auto &log = r.decoded.store ? s->log_mem_write : s->log_mem_read;
    if (r.decoded.load || r.decoded.store) {
        if (log.size() == 1) {
            r.address = std::get<0>(log[0]);
            r.decoded.size = std::get<2>(log[0]);
            r.byte_mask = (1u << r.decoded.size) - 1;
            // Spike v1.1.0 read logs contain a zero placeholder. Reconstruct
            // raw bytes from independent reference memory, also for rd=x0.
            if (r.decoded.store)
                r.raw_data = std::get<1>(log[0]) & data_mask(r.decoded.size);
            else {
                r.raw_data = 0;
                for (unsigned i = 0; i < r.decoded.size; ++i)
                    r.raw_data |= uint64_t(m.memory.at(r.address + i)) << (8 * i);
            }
        } else if (!r.trap)
            r.unsupported = "unexpected Spike memory log cardinality";
    }
    if (!r.decoded.supported || r.length != 4)
        r.unsupported = "unsupported instruction class: supports RV64IMFD and "
                        "mstatus/fcsr/frm/fflags/mtvec/mscratch/mepc/mcause/mtval CSR operations; "
                        "other CSRs, fences, "
                        "compressed and atomic instructions are unsupported";
    const auto fs = (r.csrs.at(0x300) >> 13) & 3;
    if (fs == 1 || fs == 2)
        r.unsupported = "mstatus.FS=Initial/Clean is unsupported by the Off/Dirty-only RTL; "
                        "write FS=0 or FS=3";
    if (r.trap)
        r.unsupported = "Spike trap boundary (cause=" + std::to_string(r.cause) +
                        ", tval=" + std::to_string(r.tval) +
                        "): trap entry/interrupt synchronization is unsupported";
    if (!m.violation.empty())
        r.unsupported = m.violation;
    m.boundary = r.unsupported;
    return r;
}
} // namespace len5::diff
