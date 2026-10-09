#include "monitor.hh"
#include "diff_layout.hh"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <utility>
#include <verilated_vpi.h>
namespace len5::diff {
namespace {
const std::string top = "TOP.tb_bare.", backend = top + "u_datapath.u_backend.",
                  issue = backend + "u_issue_stage.", comm = backend + "u_commit_stage.",
                  lsu = backend + "u_exec_stage.u_load_store_unit.", lb = lsu + "u_load_buffer.",
                  sb = lsu + "u_store_buffer.";
const std::map<uint32_t, std::string> csr_signals = {
    {0x305, "mtvec"}, {0x340, "mscratch"}, {0x341, "mepc"}, {0x342, "mcause"}, {0x343, "mtval"}};
class Signals {
    std::map<std::pair<std::string, int>, vpiHandle> handles_;

  public:
    ~Signals() {
        for (auto &[k, h] : handles_)
            vpi_release_handle(h);
    }
    uint64_t get(const std::string &path, const std::string &field = "", int index = -1) {
        auto li = layouts.find(path);
        if (li == layouts.end())
            throw std::runtime_error("no elaborated signal layout: " + path);
        const auto &l = li->second;
        auto fi = l.fields.find(field);
        if (fi == l.fields.end())
            throw std::runtime_error("no elaborated field: " + path + "." + field);
        auto f = fi->second;
        if (f.width > 64)
            throw std::runtime_error("field wider than 64 bits: " + path + "." + field);
        if (index != -1) {
            if (index < l.low || index > l.high)
                throw std::runtime_error("array index outside elaborated bounds: " + path);
            if (!l.unpacked)
                f.offset += (index - l.low) * l.stride;
        }
        auto key = std::make_pair(path, l.unpacked ? index : -1);
        auto it = handles_.find(key);
        if (it == handles_.end()) {
            auto h = vpi_handle_by_name(const_cast<char *>(path.c_str()), nullptr);
            if (!h)
                throw std::runtime_error("missing exposed Verilator signal: " + path);
            if (l.unpacked) {
                auto elem = vpi_handle_by_index(h, index);
                vpi_release_handle(h);
                h = elem;
                if (!h)
                    throw std::runtime_error("missing exposed array element: " + path);
            }
            if (unsigned(vpi_get(vpiSize, h)) != l.width)
                throw std::runtime_error("VPI/XML width mismatch: " + path);
            it = handles_.emplace(key, h).first;
        }
        s_vpi_value value{};
        value.format = vpiVectorVal;
        vpi_get_value(it->second, &value);
        uint64_t result = 0;
        for (unsigned bit = 0; bit < f.width; ++bit) {
            unsigned pos = f.offset + bit;
            if (value.value.vector[pos / 32].bval & (1u << (pos % 32)))
                throw std::runtime_error("unknown exposed bit: " + path);
            result |= uint64_t((value.value.vector[pos / 32].aval >> (pos % 32)) & 1) << bit;
        }
        return result;
    }
};
unsigned access_size(uint64_t type) {
    if (type == enum_values.at("LS_BYTE") || type == enum_values.at("LS_BYTE_U"))
        return 1;
    if (type == enum_values.at("LS_HALFWORD") || type == enum_values.at("LS_HALFWORD_U"))
        return 2;
    if (type == enum_values.at("LS_WORD") || type == enum_values.at("LS_WORD_U"))
        return 4;
    if (type == enum_values.at("LS_DOUBLEWORD"))
        return 8;
    throw std::runtime_error("invalid LSU access type");
}
} // namespace
struct Monitor::Impl {
    Signals signals;
    SpikeReference spike;
    Checker checker;
    std::vector<std::string> stations;
    std::string fault;
    bool injected = false;
    std::string isa() {
        std::string value = "RV64I";
        if (constants.at("len5_config_pkg.LEN5_M_EN"))
            value += 'M';
        if (constants.at("len5_config_pkg.LEN5_F_EN"))
            value += 'F';
        if (constants.at("len5_config_pkg.LEN5_D_EN"))
            value += 'D';
        return value;
    }
    std::map<uint32_t, uint64_t> csr_state() {
        std::map<uint32_t, uint64_t> values;
        for (const auto &[addr, sig] : csr_signals)
            values[addr] = signals.get(backend + "u_csrs." + sig);
        return values;
    }
    Impl(const std::string &image, const std::string &output, Config cfg, const std::string &f)
        : spike(image, constants.at("tb_bare.BOOT_PC"), isa(), csr_state()),
          checker(spike, output, cfg), fault(f) {
        if (constants.at("len5_config_pkg.LEN5_C_EN") ||
            constants.at("len5_config_pkg.LEN5_A_EN") ||
            constants.at("len5_config_pkg.ONLY_DOUBLEWORD_MEM_ACCESSES"))
            throw std::runtime_error(
                "unsupported compressed/atomic/aligned-doubleword-memory configuration");
        if (constants.at("tb_bare.SERIAL_ADDR") != 0x20000000 ||
            constants.at("tb_bare.EXIT_ADDR") != 0x20000100)
            throw std::runtime_error("unsupported testbench MMIO map");
        if (!f.empty() && f != "operand" && f != "cdb" && f != "register" && f != "store")
            throw std::runtime_error("unknown --diff-fault");
        for (const auto &[path, l] : layouts)
            if (path.size() > 5 && path.substr(path.size() - 5) == ".data" &&
                l.fields.count("dest_rob_idx") &&
                layouts.count(path.substr(0, path.size() - 4) + "cdb_valid_o"))
                stations.push_back(path.substr(0, path.size() - 4));
        const auto count = 4 + constants.at("len5_config_pkg.LEN5_M_EN") +
                           constants.at("len5_config_pkg.LEN5_DIV_EN") +
                           bool(constants.at("len5_config_pkg.LEN5_F_EN") ||
                                constants.at("len5_config_pkg.LEN5_D_EN"));
        if (stations.size() != count)
            throw std::runtime_error("execution-unit observation/configuration mismatch");
    }
    uint64_t get(const std::string &p, const std::string &f = "", int i = -1) {
        return signals.get(p, f, i);
    }
    bool inject(const std::string &f) {
        if (!injected && fault == f) {
            injected = true;
            return true;
        }
        return false;
    }
    void rise(Stamp t) {
        // Commit outputs refer to the OLD commit register at this edge. Process before reuse/flush.
        if (get(comm + "csr_comm_insn_o") != enum_values.at("COMM_CSR_INSTR_TYPE_NONE")) {
            auto pc = get(comm + "comm_reg_data", "data.instr_pc");
            auto insn = get(comm + "comm_reg_data", "data.instruction.raw");
            auto rd = get(comm + "comm_reg_data", "data.rd_idx");
            auto value = get(comm + "rd_value_o");
            if (rd && get(comm + "int_rf_valid_o") && inject("register"))
                value ^= 1;
            checker.commit(get(comm + "comm_reg_data", "rob_idx"), pc, insn, rd,
                           get(comm + "int_rf_valid_o"), value,
                           get(comm + "comm_reg_data", "data.except_raised"), t);
        }
        const bool back_flush = get(comm + "cu_mis_flush"), front_flush = get(issue + "iq_flush");
        // The emulator also captures requests on a flush edge. Save identity
        // before invalidating the LQ so the later response drains a tombstone.
        if (get(top + "dp2mem_load_valid"))
            checker.load_request(get(top + "dp2mem_load_tag"), get(top + "dp2mem_load_addr"),
                                 get(top + "dp2mem_load_be"), t);
        if (back_flush)
            checker.flush_backend(t);
        if (front_flush)
            checker.flush_frontend(t);
        if (get(comm + "cu_except_flush")) {
            checker.stop("RTL trap/exception recovery is not yet synchronized with Spike", t, true);
            return;
        }
        if (get(top + "mem2dp_load_valid") && get(top + "dp2mem_load_ready"))
            checker.load_response(get(top + "mem2dp_load_tag"), get(top + "mem2dp_load_rdata"),
                                  get(top + "mem2dp_load_except_raised"), t);
        // Architectural identity passes through the IQ and issue register in FIFO order.
        if (!front_flush && !back_flush && get(issue + "comm_valid_o") &&
            get(issue + "comm_ready_i")) {
            checker.dispatch(
                get(issue + "ex_rob_idx_o"), get(issue + "comm_data_o", "instr_pc"),
                get(issue + "comm_data_o", "instruction.raw"),
                get(issue + "ireg_data_out", "rs1_idx"), get(issue + "ireg_data_out", "rs2_idx"),
                get(issue + "comm_data_o", "rd_idx"), get(issue + "comm_data_o", "rd_upd"), t);
            if (decode(get(issue + "comm_data_o", "instruction.raw")).csr)
                checker.source_at_dispatch(get(issue + "ex_rob_idx_o"),
                                           get(issue + "comm_data_o", "res_value"), t);
        }
        if (!back_flush) {
            for (auto p : {lb, sb})
                if (get(p + "push"))
                    checker.allocate(get(p + "issue_dest_rob_idx_i"), get(p + "tail_idx"), p == sb,
                                     t);
            const auto bu = backend + "u_exec_stage.u_branch_unit.";
            if (get(bu + "rs_bu_valid") && get(bu + "bu_rs_ready") && get(bu + "cu_res_reg_en")) {
                auto next = get(bu + "res_taken") ? get(bu + "res_target") : get(bu + "link_addr");
                checker.resolve_branch(get(bu + "rs_bu_rob_idx"), next,
                                       get(bu + "res_mispredicted"), t);
            }
            // Retained operands are read before the accepted CDB entry is removed.
            for (const auto &p : stations)
                if (get(p + "cdb_valid_o") && get(p + "cdb_ready_i")) {
                    auto idx = get(p + (layouts.count(p + "cdb_idx") ? "cdb_idx" : "head_idx"));
                    auto rs1 = get(p + "data", "rs1_value", idx);
                    auto rs2 = layouts.at(p + "data").fields.count("rs2_value")
                                   ? get(p + "data", "rs2_value", idx)
                                   : 0;
                    auto value = get(p + "cdb_data_o", "res_value");
                    // Observation faults deliberately affect checker inputs only; RTL is untouched.
                    if (p.find("u_arith_rs.") != std::string::npos) {
                        if (inject("operand"))
                            rs1 ^= 1;
                        if (inject("cdb"))
                            value ^= 1;
                    }
                    if (p == lb) {
                        auto size = access_size(get(p + "data", "load_type", idx));
                        checker.memory(idx, false, get(p + "data", "imm_addr_value", idx), size,
                                       (1u << size) - 1, get(p + "data", "value", idx), true, t);
                    }
                    checker.execute(get(p + "cdb_data_o", "rob_idx"), rs1, rs2, value,
                                    get(p + "cdb_data_o", "except_raised"),
                                    get(p + "cdb_data_o", "except_code") ==
                                        enum_values.at("E_MISPREDICTION"),
                                    t);
                }
            for (auto p : {lb, sb}) {
                if (get(p + "save_addr")) {
                    auto idx = get(p + "adder_ans_i", "tag");
                    auto size =
                        access_size(get(p + "data", p == sb ? "store_type" : "load_type", idx));
                    checker.memory(idx, p == sb, get(p + "adder_ans_i", "result"), size,
                                   (1u << size) - 1,
                                   p == sb ? get(p + "data", "rs2_value", idx) : 0, p == sb, t);
                }
            }
            auto sb_layout = layouts.at(sb + "curr_state");
            for (int idx = sb_layout.low; idx <= sb_layout.high; ++idx)
                if (get(sb + "curr_state", "", idx) != enum_values.at("STORE_S_MEM_REQ") &&
                    get(sb + "next_state", "", idx) == enum_values.at("STORE_S_MEM_REQ"))
                    checker.authorize(idx, get(sb + "data", "dest_rob_idx", idx), t);
            if (get(sb + "mem_done"))
                checker.store_response(get(sb + "mem_tag_i"), get(sb + "mem_except_raised_i"), t);
        }
        // This is the accepted, compacted fetch bundle entering the IQ, not a held memory response.
        if (!front_flush && get(issue + "fetch_valid_i") && get(issue + "fetch_ready_o")) {
            auto valid = get(issue + "fetch_valid_instr_i");
            const auto &layout = layouts.at(issue + "new_instr");
            for (int lane = layout.low; lane <= layout.high; ++lane)
                if (valid & (uint64_t{1} << lane))
                    checker.fetch(get(issue + "new_instr", "curr_pc", lane),
                                  get(issue + "new_instr", "instruction.raw", lane), t);
        }
        checker.tick(t);
    }
};
Monitor::Monitor(const std::string &f, const std::string &o, Config c, const std::string &fault)
    : impl_(std::make_unique<Impl>(f, o, c, fault)) {}
Monitor::~Monitor() = default;
void Monitor::before_rising(Stamp t) {
    try {
        impl_->rise(t);
    } catch (const std::exception &e) {
        impl_->checker.stop(e.what(), t, true);
    }
}
void Monitor::after_rising(Stamp t) {
    try {
        std::array<uint64_t, 32> regs{};
        for (unsigned r = 1; r < 32; ++r)
            regs[r] = impl_->get(backend + "u_int_rf.rf_data", "", r);
        impl_->checker.checkpoint(regs, t, impl_->csr_state());
    } catch (const std::exception &e) {
        impl_->checker.stop(e.what(), t, true);
    }
}
void Monitor::before_falling(Stamp t) {
    try {
        // memory_bare_emu writes on negedge(valid && we), independent of ready.
        if (impl_->get(top + "dp2mem_store_valid") && impl_->get(top + "dp2mem_store_we")) {
            auto tag = impl_->get(top + "dp2mem_store_tag");
            if (impl_->inject("store"))
                tag = no_index;
            impl_->checker.external_store(tag, impl_->get(top + "dp2mem_store_addr"),
                                          impl_->get(top + "dp2mem_store_be"),
                                          impl_->get(top + "dp2mem_store_wdata"), t);
        }
    } catch (const std::exception &e) {
        impl_->checker.stop(e.what(), t, true);
    }
}
bool Monitor::stopped() const { return impl_->checker.stopped(); }
int Monitor::finish(bool normal, Stamp t, const std::string &original) {
    impl_->checker.finish(normal, t);
    annotate(original, impl_->checker);
    std::cerr << "Differential verification: status " << impl_->checker.status() << "; "
              << impl_->checker.committed_count() << " commits; report "
              << impl_->checker.directory() << "/report.json\n";
    return impl_->checker.status();
}
} // namespace len5::diff
