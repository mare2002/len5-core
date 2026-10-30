#include "monitor.hh"
#include "diff_layout.hh"
#include "vector_bits.hh"
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <utility>
#include <verilated_vpi.h>
namespace len5::diff {
namespace {
const std::string top = "TOP.tb_bare.", backend = top + "i_len5_datapath.u_backend.",
                  issue = backend + "u_issue_stage.", comm = backend + "u_commit_stage.",
                  lsu = backend + "u_exec_stage.u_load_store_unit.", lb = lsu + "u_load_buffer.",
                  sb = lsu + "u_store_buffer.";
const std::map<uint32_t, std::string> csr_signals = {
    {0x003, "fcsr"}, {0x300, "mstatus"}, {0x305, "mtvec"}, {0x340, "mscratch"},
    {0x341, "mepc"}, {0x342, "mcause"},  {0x343, "mtval"}};
// A group owns stable path/field bindings. Resolve XML metadata and VPI handles
// on first use, then read fresh values on every observation (never cache values
// across edges). Keys are views into the heap-owned Binding strings.
class Signals {
    struct Binding {
        std::string signal, field, path;
        const Layout &layout;
        BitField bits;
        std::vector<vpiHandle> handles;
        Binding(const std::string &prefix, std::string_view s, std::string_view f)
            : signal(s), field(f), path(prefix + signal), layout(find_layout(path)) {
            const auto it = layout.fields.find(field);
            if (it == layout.fields.end())
                throw std::runtime_error("no elaborated field: " + path + "." + field);
            bits = it->second;
            if (bits.width > 64)
                throw std::runtime_error("field wider than 64 bits: " + path + "." + field);
            handles.resize(layout.unpacked ? layout.high - layout.low + 1 : 1, nullptr);
        }
        static const Layout &find_layout(const std::string &path) {
            const auto it = layouts.find(path);
            if (it == layouts.end())
                throw std::runtime_error("no elaborated signal layout: " + path);
            return it->second;
        }
        ~Binding() {
            for (auto h : handles)
                if (h)
                    vpi_release_handle(h);
        }
        uint64_t read(int index) {
            auto f = bits;
            if (index != -1 || layout.unpacked) {
                if (index < layout.low || index > layout.high)
                    throw std::runtime_error("array index outside elaborated bounds: " + path);
                if (!layout.unpacked)
                    f.offset += (index - layout.low) * layout.stride;
            }
            auto &h = handles[layout.unpacked ? index - layout.low : 0];
            if (!h) {
                auto resolved = vpi_handle_by_name(const_cast<char *>(path.c_str()), nullptr);
                if (!resolved)
                    throw std::runtime_error("missing exposed Verilator signal: " + path);
                if (layout.unpacked) {
                    auto elem = vpi_handle_by_index(resolved, index);
                    vpi_release_handle(resolved);
                    resolved = elem;
                    if (!resolved)
                        throw std::runtime_error("missing exposed array element: " + path);
                }
                if (unsigned(vpi_get(vpiSize, resolved)) != layout.width) {
                    vpi_release_handle(resolved);
                    throw std::runtime_error("VPI/XML width mismatch: " + path);
                }
                h = resolved;
            }
            s_vpi_value value{};
            value.format = vpiVectorVal;
            vpi_get_value(h, &value);
            uint64_t result = 0;
            if (!vector_bits(value.value.vector, f.offset, f.width, result))
                throw std::runtime_error("unknown exposed bit: " + path);
            return result;
        }
    };
    using Key = std::pair<std::string_view, std::string_view>;
    std::map<Key, std::unique_ptr<Binding>> bindings_;

  public:
    const std::string prefix;
    explicit Signals(std::string p) : prefix(std::move(p)) {}
    uint64_t get(std::string_view signal, std::string_view field = "", int index = -1) {
        auto it = bindings_.find({signal, field});
        if (it == bindings_.end()) {
            auto binding = std::make_unique<Binding>(prefix, signal, field);
            const Key key{binding->signal, binding->field};
            it = bindings_.emplace(key, std::move(binding)).first;
        }
        return it->second->read(index);
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
    Signals top_signals{top}, issue_signals{issue}, comm_signals{comm}, lb_signals{lb},
        sb_signals{sb}, branch_signals{backend + "u_exec_stage.u_branch_unit."},
        csr_signals_{backend + "u_csrs."}, int_rf_signals{backend + "u_int_rf."},
        fp_rf_signals{backend + "gen_fp_rf.u_fp_rf."};
    SpikeReference spike;
    Checker checker;
    std::vector<std::unique_ptr<Signals>> stations;
    std::string fault;
    bool injected = false;
    std::string isa() {
        std::string value = "RV64I";
        if (constants.at("tb_bare.Len5Cfg.LEN5_M_EN"))
            value += 'M';
        if (constants.at("tb_bare.Len5Cfg.LEN5_F_EN"))
            value += 'F';
        if (constants.at("tb_bare.Len5Cfg.LEN5_D_EN"))
            value += 'D';
        return value;
    }
    std::map<uint32_t, uint64_t> csr_state() {
        std::map<uint32_t, uint64_t> values;
        for (const auto &[addr, sig] : csr_signals) {
            if (addr == 3 && !constants.at("tb_bare.Len5Cfg.LEN5_F_EN") &&
                !constants.at("tb_bare.Len5Cfg.LEN5_D_EN"))
                continue;
            values[addr] = csr_signals_.get(sig);
        }
        return values;
    }
    Impl(const std::string &image, const std::string &output, Config cfg, const std::string &f)
        : spike(image, constants.at("tb_bare.Len5Cfg.BOOT_PC"), isa(), csr_state(),
                MemoryMap{constants.at("tb_bare.TbCfg.SERIAL_ADDR"), constants.at("tb_bare.TbCfg.EXIT_ADDR"),
                          constants.at("tb_bare.TbCfg.IMEM_BASE_ADDR"),
                          constants.at("tb_bare.TbCfg.MEMORY_BACKEND") != 0 ? constants.at("tb_bare.TbCfg.IMEM_SIZE_BYTES") : 0,
                          constants.at("tb_bare.TbCfg.DMEM_BASE_ADDR"),
                          constants.at("tb_bare.TbCfg.MEMORY_BACKEND") != 0 ? constants.at("tb_bare.TbCfg.DMEM_SIZE_BYTES") : 0,
                          constants.at("tb_bare.Len5Cfg.MMAP_MASK")} ),
          checker(spike, output, cfg), fault(f) {
        if (constants.at("tb_bare.Len5Cfg.LEN5_C_EN") ||
            constants.at("tb_bare.Len5Cfg.LEN5_A_EN") ||
            constants.at("tb_bare.Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES"))
            throw std::runtime_error(
                "unsupported compressed/atomic/aligned-doubleword-memory configuration");
        if (!f.empty() && f != "operand" && f != "cdb" && f != "register" && f != "store")
            throw std::runtime_error("unknown --diff-fault");
        for (const auto &[path, l] : layouts)
            if (path.size() > 5 && path.substr(path.size() - 5) == ".data" &&
                l.fields.count("dest_rob_idx") &&
                layouts.count(path.substr(0, path.size() - 4) + "cdb_valid_o"))
                stations.push_back(std::make_unique<Signals>(path.substr(0, path.size() - 4)));
        const auto count = 4 + constants.at("tb_bare.Len5Cfg.LEN5_M_EN") +
                           constants.at("tb_bare.Len5Cfg.LEN5_DIV_EN") +
                           bool(constants.at("tb_bare.Len5Cfg.LEN5_F_EN") ||
                                constants.at("tb_bare.Len5Cfg.LEN5_D_EN"));
        if (stations.size() != count)
            throw std::runtime_error("execution-unit observation/configuration mismatch");
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
        if (comm_signals.get("csr_comm_insn_o") != enum_values.at("COMM_CSR_INSTR_TYPE_NONE")) {
            auto pc = comm_signals.get("comm_reg_data", "data.instr_pc");
            auto insn = comm_signals.get("comm_reg_data", "data.instruction.raw");
            auto rd = comm_signals.get("comm_reg_data", "data.rd_idx");
            auto value = comm_signals.get("rd_value_o");
            if (((rd && comm_signals.get("int_rf_valid_o")) || comm_signals.get("fp_rf_valid_o")) &&
                inject("register"))
                value ^= 1;
            checker.commit(comm_signals.get("comm_reg_data", "rob_idx"), pc, insn, rd,
                           comm_signals.get("int_rf_valid_o"), value,
                           comm_signals.get("comm_reg_data", "data.except_raised"), t,
                           comm_signals.get("fp_rf_valid_o"));
        }
        const bool back_flush = comm_signals.get("cu_mis_flush"),
                   front_flush = issue_signals.get("iq_flush");
        // The emulator also captures requests on a flush edge. Save identity
        // before invalidating the LQ so the later response drains a tombstone.
        if (top_signals.get("dp2mem_load_valid") && top_signals.get("mem2dp_load_ready"))
            checker.load_request(top_signals.get("dp2mem_load_tag"),
                                 top_signals.get("dp2mem_load_addr"),
                                 top_signals.get("dp2mem_load_be"), t);
        if (back_flush)
            checker.flush_backend(t);
        if (front_flush)
            checker.flush_frontend(t);
        if (comm_signals.get("cu_except_flush")) {
            checker.stop("RTL trap/exception recovery is not yet synchronized with Spike", t, true);
            return;
        }
        if (top_signals.get("mem2dp_load_valid") && top_signals.get("dp2mem_load_ready"))
            checker.load_response(top_signals.get("mem2dp_load_tag"),
                                  top_signals.get("mem2dp_load_rdata"),
                                  top_signals.get("mem2dp_load_except_raised"), t);
        // Architectural identity passes through the IQ and issue register in FIFO order.
        if (!front_flush && !back_flush && issue_signals.get("comm_valid_o") &&
            issue_signals.get("comm_ready_i")) {
            checker.dispatch(issue_signals.get("ex_rob_idx_o"),
                             issue_signals.get("comm_data_o", "instr_pc"),
                             issue_signals.get("comm_data_o", "instruction.raw"),
                             issue_signals.get("ireg_data_out", "rs1_idx"),
                             issue_signals.get("ireg_data_out", "rs2_idx"),
                             issue_signals.get("comm_data_o", "rd_idx"),
                             issue_signals.get("comm_data_o", "rd_upd"), t,
                             issue_signals.get("ireg_data_out", "rs3_idx"));
            if (decode(issue_signals.get("comm_data_o", "instruction.raw")).csr)
                checker.source_at_dispatch(issue_signals.get("ex_rob_idx_o"),
                                           issue_signals.get("comm_data_o", "res_value"), t);
        }
        if (!back_flush) {
            for (auto *p : {&lb_signals, &sb_signals})
                if (p->get("push"))
                    checker.allocate(p->get("issue_dest_rob_idx_i"), p->get("tail_idx"),
                                     p == &sb_signals, t);
            if (branch_signals.get("rs_bu_valid") && branch_signals.get("bu_rs_ready") &&
                branch_signals.get("cu_res_reg_en")) {
                auto next = branch_signals.get("res_taken") ? branch_signals.get("res_target")
                                                            : branch_signals.get("link_addr");
                checker.resolve_branch(branch_signals.get("rs_bu_rob_idx"), next,
                                       branch_signals.get("res_mispredicted"), t);
            }
            // Retained operands are read before the accepted CDB entry is removed.
            for (const auto &station : stations) {
                auto *p = station.get();
                if (p->get("cdb_valid_o") && p->get("cdb_ready_i")) {
                    auto idx =
                        p->get(layouts.count(p->prefix + "cdb_idx") ? "cdb_idx" : "head_idx");
                    auto rs1 = p->get("data", "rs1_value", idx);
                    auto rs2 = layouts.at(p->prefix + "data").fields.count("rs2_value")
                                   ? p->get("data", "rs2_value", idx)
                                   : 0;
                    auto rs3 = layouts.at(p->prefix + "data").fields.count("rs3_value")
                                   ? p->get("data", "rs3_value", idx)
                                   : 0;
                    auto value = p->get("cdb_data_o", "res_value");
                    // Observation faults deliberately affect checker inputs only; RTL is untouched.
                    if (p->prefix.find("u_arith_rs.") != std::string::npos) {
                        if (inject("operand"))
                            rs1 ^= 1;
                        if (inject("cdb"))
                            value ^= 1;
                    }
                    if (p->prefix == lb) {
                        auto size = access_size(p->get("data", "load_type", idx));
                        checker.memory(idx, false, p->get("data", "imm_addr_value", idx), size,
                                       (1u << size) - 1, p->get("data", "value", idx), true, t);
                    }
                    checker.execute(p->get("cdb_data_o", "rob_idx"), rs1, rs2, value,
                                    p->get("cdb_data_o", "except_raised"),
                                    p->get("cdb_data_o", "except_code") ==
                                        enum_values.at("E_MISPREDICTION"),
                                    t, rs3);
                }
            }
            for (auto *p : {&lb_signals, &sb_signals}) {
                if (p->get("save_addr")) {
                    auto idx = p->get("adder_ans_i", "tag");
                    auto size = access_size(
                        p->get("data", p == &sb_signals ? "store_type" : "load_type", idx));
                    checker.memory(idx, p == &sb_signals, p->get("adder_ans_i", "result"), size,
                                   (1u << size) - 1,
                                   p == &sb_signals ? p->get("data", "rs2_value", idx) : 0,
                                   p == &sb_signals, t, p->get("adder_ans_i", "except_raised"));
                }
            }
            // Forwarded loads capture a value without an external response.
            // Observe that capture before any store can write on the falling edge.
            const auto &lb_layout = layouts.at(lb + "lb_op");
            for (int idx = lb_layout.low; idx <= lb_layout.high; ++idx)
                if (lb_signals.get("lb_op", "", idx) == enum_values.at("LOAD_OP_SAVE_CACHED"))
                    checker.load_capture(idx, lb_signals.get("l0_value_i"), false, t);
            const auto &sb_layout = layouts.at(sb + "curr_state");
            for (int idx = sb_layout.low; idx <= sb_layout.high; ++idx)
                if (sb_signals.get("curr_state", "", idx) != enum_values.at("STORE_S_MEM_REQ") &&
                    sb_signals.get("next_state", "", idx) == enum_values.at("STORE_S_MEM_REQ"))
                    checker.authorize(idx, sb_signals.get("data", "dest_rob_idx", idx), t);
            if (sb_signals.get("mem_done"))
                checker.store_response(sb_signals.get("mem_tag_i"),
                                       sb_signals.get("mem_except_raised_i"), t);
        }
        // This is the accepted, compacted fetch bundle entering the IQ, not a held memory response.
        if (!front_flush && issue_signals.get("fetch_valid_i") &&
            issue_signals.get("fetch_ready_o")) {
            auto valid = issue_signals.get("fetch_valid_instr_i");
            const auto &layout = layouts.at(issue + "new_instr");
            for (int lane = layout.low; lane <= layout.high; ++lane)
                if (valid & (uint64_t{1} << lane))
                    checker.fetch(issue_signals.get("new_instr", "curr_pc", lane),
                                  issue_signals.get("new_instr", "instruction.raw", lane), t);
        }
        if (constants.at("tb_bare.TbCfg.MEMORY_BACKEND") != 0 &&
            top_signals.get("dp2mem_store_valid") && top_signals.get("mem2dp_store_ready") &&
            top_signals.get("dp2mem_store_we")) {
            auto tag = top_signals.get("dp2mem_store_tag");
            if (inject("store")) tag = no_index;
            checker.external_store(tag, top_signals.get("dp2mem_store_addr"),
                                   top_signals.get("dp2mem_store_be"),
                                   top_signals.get("dp2mem_store_wdata"), t);
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
        if (!impl_->checker.checkpoint_due())
            return;
        std::array<uint64_t, 32> regs{};
        for (unsigned r = 1; r < 32; ++r)
            regs[r] = impl_->int_rf_signals.get("rf_data", "", r);
        std::array<uint64_t, 32> fp_regs{};
        const bool has_fp =
            constants.at("tb_bare.Len5Cfg.LEN5_F_EN") || constants.at("tb_bare.Len5Cfg.LEN5_D_EN");
        if (has_fp)
            for (unsigned r = 0; r < 32; ++r)
                fp_regs[r] = impl_->fp_rf_signals.get("rf_data", "", r);
        impl_->checker.checkpoint(regs, t, impl_->csr_state(), has_fp ? &fp_regs : nullptr);
    } catch (const std::exception &e) {
        impl_->checker.stop(e.what(), t, true);
    }
}
void Monitor::before_falling(Stamp t) {
    try {
        // memory_bare_emu writes on negedge(valid && we), independent of ready.
        if (constants.at("tb_bare.TbCfg.MEMORY_BACKEND") == 0 &&
            impl_->top_signals.get("dp2mem_store_valid") &&
            impl_->top_signals.get("dp2mem_store_we")) {
            auto tag = impl_->top_signals.get("dp2mem_store_tag");
            if (impl_->inject("store"))
                tag = no_index;
            impl_->checker.external_store(tag, impl_->top_signals.get("dp2mem_store_addr"),
                                          impl_->top_signals.get("dp2mem_store_be"),
                                          impl_->top_signals.get("dp2mem_store_wdata"), t);
        }
    } catch (const std::exception &e) {
        impl_->checker.stop(e.what(), t, true);
    }
}
bool Monitor::stopped() const { return impl_->checker.stopped(); }
int Monitor::finish(bool normal, Stamp t, const std::string &original) {
    impl_->checker.finish(normal, t);
    if (!original.empty())
        annotate(original, impl_->checker);
    std::cerr << "Differential verification: status " << impl_->checker.status() << "; "
              << impl_->checker.committed_count() << " commits; report "
              << impl_->checker.directory() << "/report.json\n";
    return impl_->checker.status();
}
} // namespace len5::diff
