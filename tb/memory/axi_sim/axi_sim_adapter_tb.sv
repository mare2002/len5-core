`include "tb_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module axi_sim_adapter_tb #(
    parameter int unsigned BOOT_VM_MODE = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_VM_MODE),
    parameter logic [31:0] BOOT_PC_HI = 32'((len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC),
    parameter logic [63:0] BOOT_PC = {BOOT_PC_HI, BOOT_PC_LO},
    parameter int unsigned LEN5_MULTIPLE_ISSUES = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULTIPLE_ISSUES,
    parameter bit LEN5_M_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_M_EN,
    parameter bit LEN5_DIV_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_DIV_EN,
    parameter bit LEN5_F_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_F_EN,
    parameter bit LEN5_D_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_D_EN,
    parameter bit LEN5_C_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_C_EN,
    parameter bit LEN5_A_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_A_EN,
    parameter bit LEN5_STORE_LOAD_FWD_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_STORE_LOAD_FWD_EN,
    parameter int unsigned MAX_EU_N = len5_config_pkg::DEFAULT_LEN5_CFG.MAX_EU_N,
    parameter bit ONLY_DOUBLEWORD_MEM_ACCESSES = len5_config_pkg::DEFAULT_LEN5_CFG.ONLY_DOUBLEWORD_MEM_ACCESSES,
    parameter bit LEN5_CSR_HPMCOUNTERS_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_CSR_HPMCOUNTERS_EN,
    parameter logic [31:0] MMAP_MASK_HI = 32'((len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK) >> 32),
    parameter logic [31:0] MMAP_MASK_LO = 32'(len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK),
    parameter logic [63:0] MMAP_MASK = {MMAP_MASK_HI, MMAP_MASK_LO},
    parameter int unsigned BPU_HLEN = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_HLEN,
    parameter int unsigned BPU_BTB_BITS = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_BTB_BITS,
    parameter int unsigned RAS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.RAS_DEPTH,
    parameter int unsigned FETCH_MEMIF_FIFO_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEMIF_FIFO_DEPTH,
    parameter bit FETCH_MEM_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEM_DRAIN_ON_FLUSH,
    parameter bit LOAD_BUFFER_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.LOAD_BUFFER_DRAIN_ON_FLUSH,
    parameter bit FETCH_REQ_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_REQ_SPILL_SKIP,
    parameter bit FETCH_ANS_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_ANS_SPILL_SKIP,
    parameter int unsigned IQ_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.IQ_DEPTH,
    parameter int unsigned LDBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.LDBUFF_DEPTH,
    parameter int unsigned STBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.STBUFF_DEPTH,
    parameter bit LSU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.LSU_SPILL_SKIP,
    parameter int unsigned ALU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RS_DEPTH,
    parameter bit ALU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_SPILL_SKIP,
    parameter bit ALU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RR_ARBITER,
    parameter int unsigned MULT_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RS_DEPTH,
    parameter bit LEN5_MULT_SERIAL = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULT_SERIAL,
    parameter int unsigned MULT_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_PIPE_DEPTH,
    parameter bit MULT_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RR_ARBITER,
    parameter int unsigned DIV_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RS_DEPTH,
    parameter bit DIV_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RR_ARBITER,
    parameter int unsigned FPU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RS_DEPTH,
    parameter bit FPU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RR_ARBITER,
    parameter int unsigned FPU_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_PIPE_DEPTH,
    parameter bit FPU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_SPILL_SKIP,
    parameter int unsigned BU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.BU_RS_DEPTH,
    parameter bit BU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.BU_SPILL_SKIP,
    parameter int unsigned ROB_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ROB_DEPTH,
    parameter bit COMMIT_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.COMMIT_SPILL_SKIP,
    parameter int unsigned BPU_INIT_C2B = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BPU_INIT_C2B),
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::build_config(
        '{
            BOOT_VM_MODE: len5_config_pkg::boot_mode_t'(BOOT_VM_MODE),
            BOOT_PC: BOOT_PC,
            LEN5_MULTIPLE_ISSUES: LEN5_MULTIPLE_ISSUES,
            LEN5_M_EN: LEN5_M_EN,
            LEN5_DIV_EN: LEN5_DIV_EN,
            LEN5_F_EN: LEN5_F_EN,
            LEN5_D_EN: LEN5_D_EN,
            LEN5_C_EN: LEN5_C_EN,
            LEN5_A_EN: LEN5_A_EN,
            LEN5_STORE_LOAD_FWD_EN: LEN5_STORE_LOAD_FWD_EN,
            MAX_EU_N: MAX_EU_N,
            ONLY_DOUBLEWORD_MEM_ACCESSES: ONLY_DOUBLEWORD_MEM_ACCESSES,
            LEN5_CSR_HPMCOUNTERS_EN: LEN5_CSR_HPMCOUNTERS_EN,
            MMAP_MASK: MMAP_MASK,
            BPU_HLEN: BPU_HLEN,
            BPU_BTB_BITS: BPU_BTB_BITS,
            RAS_DEPTH: RAS_DEPTH,
            FETCH_MEMIF_FIFO_DEPTH: FETCH_MEMIF_FIFO_DEPTH,
            FETCH_MEM_DRAIN_ON_FLUSH: FETCH_MEM_DRAIN_ON_FLUSH,
            LOAD_BUFFER_DRAIN_ON_FLUSH: LOAD_BUFFER_DRAIN_ON_FLUSH,
            FETCH_REQ_SPILL_SKIP: FETCH_REQ_SPILL_SKIP,
            FETCH_ANS_SPILL_SKIP: FETCH_ANS_SPILL_SKIP,
            IQ_DEPTH: IQ_DEPTH,
            LDBUFF_DEPTH: LDBUFF_DEPTH,
            STBUFF_DEPTH: STBUFF_DEPTH,
            LSU_SPILL_SKIP: LSU_SPILL_SKIP,
            ALU_RS_DEPTH: ALU_RS_DEPTH,
            ALU_SPILL_SKIP: ALU_SPILL_SKIP,
            ALU_RR_ARBITER: ALU_RR_ARBITER,
            MULT_RS_DEPTH: MULT_RS_DEPTH,
            LEN5_MULT_SERIAL: LEN5_MULT_SERIAL,
            MULT_PIPE_DEPTH: MULT_PIPE_DEPTH,
            MULT_RR_ARBITER: MULT_RR_ARBITER,
            DIV_RS_DEPTH: DIV_RS_DEPTH,
            DIV_RR_ARBITER: DIV_RR_ARBITER,
            FPU_RS_DEPTH: FPU_RS_DEPTH,
            FPU_RR_ARBITER: FPU_RR_ARBITER,
            FPU_PIPE_DEPTH: FPU_PIPE_DEPTH,
            FPU_SPILL_SKIP: FPU_SPILL_SKIP,
            BU_RS_DEPTH: BU_RS_DEPTH,
            BU_SPILL_SKIP: BU_SPILL_SKIP,
            ROB_DEPTH: ROB_DEPTH,
            COMMIT_SPILL_SKIP: COMMIT_SPILL_SKIP,
            BPU_INIT_C2B: 2'(BPU_INIT_C2B)
        }
    ),
    parameter int unsigned MEMORY_BACKEND = int'(tb_config_pkg::DefaultTbCfg.MEMORY_BACKEND),
    parameter int unsigned AXI_CLOCK_HALF_PERIOD_PS = tb_config_pkg::DefaultTbCfg.AXI_CLOCK_HALF_PERIOD_PS,
    parameter logic [31:0] IMEM_BASE_ADDR_HI = 32'((tb_config_pkg::DefaultTbCfg.IMEM_BASE_ADDR) >> 32),
    parameter logic [31:0] IMEM_BASE_ADDR_LO = 32'(tb_config_pkg::DefaultTbCfg.IMEM_BASE_ADDR),
    parameter logic [63:0] IMEM_BASE_ADDR = {IMEM_BASE_ADDR_HI, IMEM_BASE_ADDR_LO},
    parameter int unsigned IMEM_SIZE_BYTES = tb_config_pkg::DefaultTbCfg.IMEM_SIZE_BYTES,
    parameter int unsigned IMEM_LATENCY = tb_config_pkg::DefaultTbCfg.IMEM_LATENCY,
    parameter logic [31:0] DMEM_BASE_ADDR_HI = 32'((tb_config_pkg::DefaultTbCfg.DMEM_BASE_ADDR) >> 32),
    parameter logic [31:0] DMEM_BASE_ADDR_LO = 32'(tb_config_pkg::DefaultTbCfg.DMEM_BASE_ADDR),
    parameter logic [63:0] DMEM_BASE_ADDR = {DMEM_BASE_ADDR_HI, DMEM_BASE_ADDR_LO},
    parameter int unsigned DMEM_SIZE_BYTES = tb_config_pkg::DefaultTbCfg.DMEM_SIZE_BYTES,
    parameter int unsigned DMEM_LATENCY = tb_config_pkg::DefaultTbCfg.DMEM_LATENCY,
    parameter logic [31:0] SERIAL_ADDR_HI = 32'((tb_config_pkg::DefaultTbCfg.SERIAL_ADDR) >> 32),
    parameter logic [31:0] SERIAL_ADDR_LO = 32'(tb_config_pkg::DefaultTbCfg.SERIAL_ADDR),
    parameter logic [63:0] SERIAL_ADDR = {SERIAL_ADDR_HI, SERIAL_ADDR_LO},
    parameter logic [31:0] EXIT_ADDR_HI = 32'((tb_config_pkg::DefaultTbCfg.EXIT_ADDR) >> 32),
    parameter logic [31:0] EXIT_ADDR_LO = 32'(tb_config_pkg::DefaultTbCfg.EXIT_ADDR),
    parameter logic [63:0] EXIT_ADDR = {EXIT_ADDR_HI, EXIT_ADDR_LO},
    parameter tb_config_pkg::tb_cfg_t TbCfg = tb_config_pkg::build_config(
        '{
            MEMORY_BACKEND: tb_config_pkg::memory_backend_t'(MEMORY_BACKEND),
            AXI_CLOCK_HALF_PERIOD_PS: AXI_CLOCK_HALF_PERIOD_PS,
            IMEM_BASE_ADDR: IMEM_BASE_ADDR,
            IMEM_SIZE_BYTES: IMEM_SIZE_BYTES,
            IMEM_LATENCY: IMEM_LATENCY,
            DMEM_BASE_ADDR: DMEM_BASE_ADDR,
            DMEM_SIZE_BYTES: DMEM_SIZE_BYTES,
            DMEM_LATENCY: DMEM_LATENCY,
            SERIAL_ADDR: SERIAL_ADDR,
            EXIT_ADDR: EXIT_ADDR
        },
        Len5Cfg.IMEM_DATA_WIDTH
    ),
    localparam type dmem_axi_aw_chan_t = `LEN5_DMEM_AXI_AW_CHAN_T(Len5Cfg),
    localparam type dmem_axi_w_chan_t = `LEN5_DMEM_AXI_W_CHAN_T(Len5Cfg),
    localparam type dmem_axi_ar_chan_t = `LEN5_DMEM_AXI_AR_CHAN_T(Len5Cfg),
    localparam type dmem_axi_b_chan_t = `LEN5_DMEM_AXI_B_CHAN_T(Len5Cfg),
    localparam type dmem_axi_r_chan_t = `LEN5_DMEM_AXI_R_CHAN_T(Len5Cfg),
    localparam type imem_axi_aw_chan_t = `LEN5_IMEM_AXI_AW_CHAN_T(Len5Cfg),
    localparam type imem_axi_w_chan_t = `LEN5_IMEM_AXI_W_CHAN_T(Len5Cfg),
    localparam type imem_axi_ar_chan_t = `LEN5_IMEM_AXI_AR_CHAN_T(Len5Cfg),
    localparam type imem_axi_b_chan_t = `LEN5_IMEM_AXI_B_CHAN_T(Len5Cfg),
    localparam type imem_axi_r_chan_t = `LEN5_IMEM_AXI_R_CHAN_T(Len5Cfg),
    localparam type dmem_axi_req_t =
    `AXI_DECL_REQ_T(dmem_axi_aw_chan_t, dmem_axi_w_chan_t, dmem_axi_ar_chan_t),
    localparam type dmem_axi_resp_t = `AXI_DECL_RESP_T(dmem_axi_b_chan_t, dmem_axi_r_chan_t),
    localparam type id_t = `LEN5_AXI_ID_T(Len5Cfg),
    localparam type imem_axi_req_t =
    `AXI_DECL_REQ_T(imem_axi_aw_chan_t, imem_axi_w_chan_t, imem_axi_ar_chan_t),
    localparam type imem_axi_resp_t = `AXI_DECL_RESP_T(imem_axi_b_chan_t, imem_axi_r_chan_t),
    localparam type memory_response_t = `LEN5_MEMORY_RESPONSE_T(Len5Cfg),
    parameter bit NATIVE = 0
);
  timeunit 1ps; timeprecision 1ps;
  /* verilator lint_off BLKSEQ */
  import len5_pkg::*;
  import len5_config_pkg::*;
  import tb_config_pkg::*;
  import memory_backend_pkg::*;
  import axi_memory_pkg::*;
  localparam int N = Len5Cfg.LEN5_MULTIPLE_ISSUES;
  localparam int Size = 256;
  localparam int FetchDepth = Len5Cfg.FETCH_MEMIF_FIFO_DEPTH;
  localparam logic [63:0] IBase = TbCfg.IMEM_BASE_ADDR, DBase = TbCfg.DMEM_BASE_ADDR;
  typedef struct packed {
    logic [N-1:0][31:0] data;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } instruction_t;
  typedef struct packed {
    logic [63:0]  data;
    except_code_t code;
  } data_expected_t;
  /* verilator lint_off SYNCASYNCNET */
  bit clk;
  bit rst_n = 0, instr_flush = 0, data_flush = 0;
  /* verilator lint_on SYNCASYNCNET */
  bit [2:0] req = '0, ready = '1;
  bit [6:0] block_channels = '0;
  bit allow_instruction = 1, store_we = 1;
  logic [2:0][63:0] addr, wdata;
  logic [2:0][7:0] be;
  id_t load_tag, store_tag;
  logic instr_credit, instr_result_ready, buffered_instr_valid;
  instruction_t instr_result, buffered_instr;
  memory_response_t       rsp;
  imem_axi_req_t          imem_req;
  imem_axi_resp_t         imem_rsp;
  dmem_axi_req_t    [1:0] dmem_req;
  dmem_axi_resp_t   [1:0] dmem_rsp;
  logic                   mmio;
  logic [2:0][Len5Cfg.AXI_COUNT_WIDTH-1:0] outstanding, occupancy;
  logic imem_initialized, dmem_initialized;
  typedef struct packed {
    logic [63:0] addr;
    logic [63:0] data;
    logic [7:0] mask;
    id_t tag;
  } transaction_t;
  transaction_t expected_iar[$], expected_lar[$], expected_aw[$], expected_w[$];
  imem_axi_req_t        previous_imem_req;
  imem_axi_resp_t       previous_imem_rsp;
  dmem_axi_req_t  [1:0] previous_dmem_req;
  dmem_axi_resp_t [1:0] previous_dmem_rsp;
  bit                   history_valid = 0;
  instruction_t expected_fetches[$], expected_buffered[$];
  bit fetch_live[$];
  logic [63:0] expected_pcs[$];
  int stale_returns = 0;
  data_expected_t expected_loads[Len5Cfg.TAG_COUNT];
  except_code_t expected_stores[Len5Cfg.TAG_COUNT];
  bit [Len5Cfg.TAG_COUNT-1:0] load_pending = '0, store_pending = '0;
  byte unsigned reference_mem[Size];
  int accepted[3], completed[3], faults[3], native_count[5];
  int expected_native_writes = 0;
  int max_fetch = 0, flushes = 0, resets = 0, mmios = 0, cycle_no = 0, seed = 1, cycles = 10000;
  int          load_order          [$];
  int          reordered_loads = 0;
  int unsigned random_state;
  logic        instr_request;
  initial clk = 0;
  fetch_pkg::prediction_t [N-1:0] fetch_prediction, returned_prediction;
  instr_t [N-1:0] returned_instruction;
  logic   [ 63:0] instr_address;
  for (genvar lane = 0; lane < N; lane++) begin : gen_fetch_lanes
    assign fetch_prediction[lane] = '{
            pc: addr[0] + 64'(4 * lane),
            hit: 1'b0,
            target: '0,
            taken: 1'b0
        };
    assign buffered_instr.data[lane] = returned_instruction[lane].raw;
  end
  assign instr_result = '{data: rsp.instr_data, except: rsp.instr_except, code: rsp.instr_code};
  fetch_mem_if #(
      .Len5Cfg                     (Len5Cfg),
      .MAX_MEM_OUTSTANDING_REQUESTS(FetchDepth),
      .DRAIN_ON_FLUSH              (1'b1)
  ) u_frontend (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .flush_i              (instr_flush),
      .fetch_valid_i        (req[0]),
      .fetch_ready_o        (instr_credit),
      .fetch_pred_i         (fetch_prediction),
      .valid_instr_i        ('1),
      .valid_instr_o        (),
      .issue_valid_o        (buffered_instr_valid),
      .issue_ready_i        (ready[0]),
      .issue_instr_o        (returned_instruction),
      .issue_pred_o         (returned_prediction),
      .issue_except_raised_o(buffered_instr.except),
      .issue_except_code_o  (buffered_instr.code),
      .instr_valid_i        (rsp.instr_valid && allow_instruction),
      .instr_ready_i        (rsp.instr_gnt),
      .instr_ready_o        (instr_result_ready),
      .instr_valid_o        (instr_request),
      .instr_we_o           (),
      .instr_rdata_i        (rsp.instr_data),
      .instr_addr_o         (instr_address),
      .instr_except_raised_i(rsp.instr_except),
      .instr_except_code_i  (rsp.instr_code)
  );
  axi_sim_adapter #(
      .Len5Cfg        (Len5Cfg),
      .TbCfg          (TbCfg),
      .IMEM_SIZE_BYTES(Size),
      .DMEM_SIZE_BYTES(Size)
  ) dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .data_flush_i (data_flush),
      .initialized_i(imem_initialized && dmem_initialized),
      .instr_req_i  (instr_request),
      .instr_ready_i(instr_result_ready && allow_instruction),
      .instr_addr_i (instr_address),
      .load_req_i   (req[1]),
      .load_ready_i (ready[1]),
      .load_addr_i  (addr[1]),
      .load_be_i    (be[1]),
      .load_tag_i   (load_tag),
      .store_req_i  (req[2]),
      .store_ready_i(ready[2]),
      .store_we_i   (store_we),
      .store_addr_i (addr[2]),
      .store_data_i (wdata[2]),
      .store_be_i   (be[2]),
      .store_tag_i  (store_tag),
      .response_o   (rsp),
      .imem_req_o   (imem_req),
      .imem_rsp_i   (imem_rsp),
      .dmem_req_o   (dmem_req),
      .dmem_rsp_i   (dmem_rsp),
      .mmio_write_o (mmio),
      .outstanding_o(outstanding),
      .occupancy_o  (occupancy)
  );
  if (NATIVE) begin : gen_native
    axi_sim_storage #(
        .Len5Cfg         (Len5Cfg),
        .TbCfg           (TbCfg),
        .BASE_ADDR       (IBase),
        .SIZE_BYTES      (Size),
        .OTHER_BASE_ADDR (DBase),
        .OTHER_SIZE_BYTES(Size),
        .DATA_WIDTH      (Len5Cfg.IMEM_DATA_WIDTH),
        .NUM_PORTS       (1),
        .AXI_REQ_T       (imem_axi_req_t),
        .AXI_RESP_T      (imem_axi_resp_t)
    ) imem (
        .clk_i        (clk),
        .rst_ni       (rst_n),
        .req_i        (imem_req),
        .rsp_o        (imem_rsp),
        .initialized_o(imem_initialized)
    );
    axi_sim_storage #(
        .Len5Cfg         (Len5Cfg),
        .TbCfg           (TbCfg),
        .BASE_ADDR       (DBase),
        .SIZE_BYTES      (Size),
        .OTHER_BASE_ADDR (IBase),
        .OTHER_SIZE_BYTES(Size),
        .DATA_WIDTH      (64),
        .NUM_PORTS       (2)
    ) dmem (
        .clk_i        (clk),
        .rst_ni       (rst_n),
        .req_i        (dmem_req),
        .rsp_o        (dmem_rsp),
        .initialized_o(dmem_initialized)
    );
    initial begin
      #1;
      imem.u_mem.rerr[IBase+64]  = axi_pkg::RESP_SLVERR;
      dmem.u_mem.rerr[DBase+112] = axi_pkg::RESP_SLVERR;
      dmem.u_mem.werr[DBase+248] = axi_pkg::RESP_SLVERR;
    end
  end else begin : gen_variable
    assign imem_initialized = 1'b1;
    assign dmem_initialized = 1'b1;
    axi_variable_slave #(
        .Len5Cfg(Len5Cfg),
        .TbCfg  (TbCfg),
        .I_BASE (IBase),
        .D_BASE (DBase),
        .SIZE   (Size)
    ) slave (
        .clk_i     (clk),
        .rst_ni    (rst_n),
        .block_i   (block_channels),
        .imem_req_i(imem_req),
        .imem_rsp_o(imem_rsp),
        .dmem_req_i(dmem_req),
        .dmem_rsp_o(dmem_rsp)
    );
  end

  function automatic int unsigned random32;
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  function automatic int bytes_for(logic [7:0] mask);
    case (mask)
      1:       return 1;
      3:       return 2;
      15:      return 4;
      255:     return 8;
      default: return 0;
    endcase
  endfunction
  function automatic except_code_t fault(logic [63:0] a, int bytes, int port_id);
    logic [63:0] base;
    base = port_id == 0 ? IBase : DBase;
    if (bytes != 0 && a % 64'(bytes) != 0)
      return port_id==0?E_I_ADDR_MISALIGNED:port_id==1?E_LD_ADDR_MISALIGNED:E_ST_ADDR_MISALIGNED;
    if (port_id == 2 && bytes != 0 && (a == TbCfg.SERIAL_ADDR || a == TbCfg.EXIT_ADDR))
      return E_UNKNOWN;
    if (bytes == 0 || a < base || a - base > 64'(Size - bytes))
      return port_id == 0 ? E_I_ACCESS_FAULT : port_id == 1 ? E_LD_ACCESS_FAULT : E_ST_ACCESS_FAULT;
    return E_UNKNOWN;
  endfunction
  function automatic instruction_t fetch_expected(logic [63:0] pc);
    instruction_t result;
    logic [63:0] base, word_base;
    int index;
    result = '0;
    base = N == 1 ? pc : (pc / 64'(4 * N)) * 64'(4 * N);
    word_base = base / 64'(Len5Cfg.IMEM_DATA_WIDTH / 8) * 64'(Len5Cfg.IMEM_DATA_WIDTH / 8);
    for (int lane = 0; lane < N; lane++) begin
      result.code[lane] = pc % 4 != 0 ? E_I_ADDR_MISALIGNED : fault(base + 64'(4 * lane), 4, 0);
      if (result.code[lane] == E_UNKNOWN && word_base == IBase + 64)
        result.code[lane] = E_I_ACCESS_FAULT;
      result.except[lane] = result.code[lane] != E_UNKNOWN;
      if (!result.except[lane])
        for (int b = 0; b < 4; b++) begin
          index                     = int'(base - IBase) + 4 * lane + b;
          result.data[lane][b*8+:8] = 8'((index * 37) ^ ((index / 4) * 13) ^ 8'h5a);
        end
    end
    return result;
  endfunction

  task automatic tick;
    instruction_t          expected_i;
    data_expected_t        expected_d;
    except_code_t          code;
    int                    count;
    transaction_t          transaction;
    logic           [63:0] bundle_base;
    bit             [ 2:0] accepted_now;
    #(TbCfg.AXI_CLOCK_HALF_PERIOD_PS);
    if (history_valid && rst_n) begin
      if (previous_imem_req.ar_valid && !previous_imem_rsp.ar_ready)
        assert (imem_req.ar_valid && imem_req.ar === previous_imem_req.ar)
        else $fatal(1, "Instruction AR changed under backpressure");
      if (previous_dmem_req[0].ar_valid && !previous_dmem_rsp[0].ar_ready)
        assert (dmem_req[0].ar_valid && dmem_req[0].ar === previous_dmem_req[0].ar)
        else $fatal(1, "Load AR changed under backpressure");
      if (previous_dmem_req[1].aw_valid && !previous_dmem_rsp[1].aw_ready)
        assert (dmem_req[1].aw_valid && dmem_req[1].aw === previous_dmem_req[1].aw)
        else $fatal(1, "AW changed under backpressure");
      if (previous_dmem_req[1].w_valid && !previous_dmem_rsp[1].w_ready)
        assert (dmem_req[1].w_valid && dmem_req[1].w === previous_dmem_req[1].w)
        else $fatal(1, "W changed under backpressure");
      if (previous_imem_rsp.r_valid && !previous_imem_req.r_ready)
        assert (imem_rsp.r_valid && imem_rsp.r === previous_imem_rsp.r);
      if (previous_dmem_rsp[0].r_valid && !previous_dmem_req[0].r_ready)
        assert (dmem_rsp[0].r_valid && dmem_rsp[0].r === previous_dmem_rsp[0].r);
      if (previous_dmem_rsp[1].b_valid && !previous_dmem_req[1].b_ready)
        assert (dmem_rsp[1].b_valid && dmem_rsp[1].b === previous_dmem_rsp[1].b);
    end
    previous_imem_req = imem_req;
    previous_imem_rsp = imem_rsp;
    previous_dmem_req = dmem_req;
    previous_dmem_rsp = dmem_rsp;
    history_valid = rst_n;
    accepted_now = {
      req[2] && rsp.store_gnt, req[1] && rsp.load_gnt, instr_request && rsp.instr_gnt
    };
    if (!rst_n) begin
      expected_buffered.delete();
      expected_pcs.delete();
      expected_fetches.delete();
      fetch_live.delete();
      expected_iar.delete();
      expected_lar.delete();
      expected_aw.delete();
      expected_w.delete();
      load_order.delete();
      load_pending  = '0;
      store_pending = '0;
      assert (!(buffered_instr_valid || rsp.load_valid || rsp.store_valid || (|accepted_now) || mmio));
      assert (outstanding == '0 && occupancy == '0)
      else $fatal(1, "Reset retained memory transaction state");
    end else begin
      if (instr_flush) begin
        expected_buffered.delete();
        expected_pcs.delete();
        foreach (fetch_live[i]) fetch_live[i] = 0;
        flushes++;
        assert (!instr_request);
      end
      if (data_flush) store_pending = '0;
      if (accepted_now[0]) begin
        expected_i = fetch_expected(addr[0]);
        expected_fetches.push_back(expected_i);
        expected_buffered.push_back(expected_i);
        expected_pcs.push_back(addr[0]);
        fetch_live.push_back(1);
        if (|expected_i.except) faults[0]++;
        bundle_base = N == 1 ? addr[0] : (addr[0] / 64'(4 * N)) * 64'(4 * N);
        if (addr[0] % 4 == 0 && fault(bundle_base, 4, 0) == E_UNKNOWN)
          expected_iar.push_back('{
                                 addr:
                                 (
                                 bundle_base / 64'(Len5Cfg.IMEM_DATA_WIDTH / 8)
                                 ) * 64'(
                                 Len5Cfg.IMEM_DATA_WIDTH / 8
                                 ),
                                 data: '0, mask: '0, tag: '0});
      end
      if (accepted_now[1]) begin
        assert (!load_pending[load_tag])
        else $fatal(1, "Load tag reused by adapter");
        count      = bytes_for(be[1]);
        code       = fault(addr[1], count, 1);
        expected_d = '{data: '0, code: code};
        if (code == E_UNKNOWN && addr[1] == DBase + 112) expected_d.code = E_LD_ACCESS_FAULT;
        if (expected_d.code == E_UNKNOWN)
          for (int b = 0; b < count; b++)
          expected_d.data[b*8+:8] = reference_mem[int'(addr[1]-DBase)+b];
        expected_loads[load_tag] = expected_d;
        load_pending[load_tag]   = 1;
        load_order.push_back(int'(load_tag));
        if (expected_d.code != E_UNKNOWN) faults[1]++;
        if (fault(addr[1], count, 1) == E_UNKNOWN)
          expected_lar.push_back('{addr: addr[1], data: '0, mask: be[1], tag: load_tag});
      end
      if (accepted_now[2]) begin
        assert (!store_pending[store_tag]);
        count = bytes_for(be[2]);
        code  = store_we ? fault(addr[2], count, 2) : E_ST_ACCESS_FAULT;
        if (code == E_UNKNOWN && addr[2] == DBase + 248) code = E_ST_ACCESS_FAULT;
        expected_stores[store_tag] = code;
        store_pending[store_tag]   = !data_flush;
        if (code != E_UNKNOWN) faults[2]++;
        if (store_we && fault(
                addr[2], count, 2
            ) == E_UNKNOWN && addr[2] != TbCfg.SERIAL_ADDR && addr[2] != TbCfg.EXIT_ADDR) begin
          expected_native_writes++;
          transaction = '{addr: addr[2], data: wdata[2], mask: be[2], tag: store_tag};
          expected_aw.push_back(transaction);
          expected_w.push_back(transaction);
          for (int b = 0; b < count; b++) reference_mem[int'(addr[2]-DBase)+b] = wdata[2][b*8+:8];
        end
      end
      assert (mmio == (accepted_now[2] && store_we && fault(
          addr[2], bytes_for(be[2]), 2
      ) == E_UNKNOWN && (addr[2] == TbCfg.SERIAL_ADDR || addr[2] == TbCfg.EXIT_ADDR)));
      if (mmio) mmios++;
      if (buffered_instr_valid && ready[0] && !instr_flush) begin
        assert (expected_buffered.size() != 0);
        expected_i = expected_buffered.pop_front();
        assert (buffered_instr === expected_i && returned_prediction[0].pc == expected_pcs.pop_front());
        completed[0]++;
      end
      if (rsp.load_valid && ready[1]) begin
        assert (load_pending[rsp.load_tag])
        else $fatal(1, "Canceled or duplicate load completion");
        expected_d = expected_loads[rsp.load_tag];
        assert(rsp.load_data===expected_d.data && rsp.load_code==expected_d.code &&
               rsp.load_except==(expected_d.code!=E_UNKNOWN))
        else $fatal(1, "Load response mismatch tag %0d at cycle %0d", rsp.load_tag, cycle_no);
        if (load_order.size() != 0 && load_order[0] != int'(rsp.load_tag)) reordered_loads++;
        for (int i = 0; i < load_order.size(); i++)
        if (load_order[i] == int'(rsp.load_tag)) begin
          load_order.delete(i);
          break;
        end
        load_pending[rsp.load_tag] = 0;
        completed[1]++;
      end
      if (rsp.store_valid && ready[2]) begin
        assert (store_pending[rsp.store_tag])
        else $fatal(1, "Canceled or duplicate store completion");
        assert(rsp.store_code==expected_stores[rsp.store_tag] && rsp.store_except==(expected_stores[rsp.store_tag]!=E_UNKNOWN));
        store_pending[rsp.store_tag] = 0;
        completed[2]++;
      end
      for (int p = 0; p < 3; p++) accepted[p] += int'(accepted_now[p]);
    end
    if (rsp.instr_valid && instr_result_ready && allow_instruction) begin
      assert (expected_fetches.size() != 0)
      else $fatal(1, "Unsolicited instruction response");
      expected_i = expected_fetches.pop_front();
      if (!fetch_live.pop_front()) stale_returns++;
      assert (instr_result === expected_i)
      else $fatal(1, "Instruction data/exception/order mismatch at cycle %0d", cycle_no);
    end
    assert(!imem_req.aw_valid && !imem_req.w_valid && !dmem_req[0].aw_valid && !dmem_req[0].w_valid && !dmem_req[1].ar_valid);
    if (imem_req.ar_valid && imem_rsp.ar_ready) begin
      native_count[0]++;
      assert (expected_iar.size() != 0);
      transaction = expected_iar.pop_front();
      assert(imem_req.ar.id==0 && imem_req.ar.addr==transaction.addr && imem_req.ar.len==0 &&
             imem_req.ar.size==3'($clog2(
          Len5Cfg.IMEM_DATA_WIDTH / 8
      )));
    end
    if (dmem_req[0].ar_valid && dmem_rsp[0].ar_ready) begin
      native_count[1]++;
      assert (expected_lar.size() != 0);
      transaction = expected_lar.pop_front();
      assert(dmem_req[0].ar.id==transaction.tag && dmem_req[0].ar.addr==transaction.addr &&
             dmem_req[0].ar.len==0 && dmem_req[0].ar.size==3'($clog2(
          bytes_for(transaction.mask)
      )));
    end
    if (dmem_req[1].aw_valid && dmem_rsp[1].aw_ready) begin
      native_count[2]++;
      assert (expected_aw.size() != 0);
      transaction = expected_aw.pop_front();
      assert(dmem_req[1].aw.id==transaction.tag && dmem_req[1].aw.addr==transaction.addr &&
             dmem_req[1].aw.len==0 && dmem_req[1].aw.size==3'($clog2(
          bytes_for(transaction.mask)
      )));
    end
    if (dmem_req[1].w_valid && dmem_rsp[1].w_ready) begin
      native_count[3]++;
      assert (expected_w.size() != 0);
      transaction = expected_w.pop_front();
      assert(dmem_req[1].w.last && dmem_req[1].w.strb==(transaction.mask<<transaction.addr[2:0]) &&
             dmem_req[1].w.data==(transaction.data<<(8*transaction.addr[2:0])));
    end
    if (dmem_rsp[1].b_valid && dmem_req[1].b_ready) native_count[4]++;
    if (int'(outstanding[0]) > max_fetch) max_fetch = int'(outstanding[0]);
    clk = 1;
    #(TbCfg.AXI_CLOCK_HALF_PERIOD_PS);
    clk = 0;
    cycle_no++;
  endtask
  task automatic drain;
    req               = '0;
    ready             = '1;
    block_channels    = '0;
    allow_instruction = 1;
    instr_flush       = 0;
    data_flush        = 0;
    repeat (300) tick();
    assert(load_pending==0 && store_pending==0 && expected_fetches.size()==0 && expected_buffered.size()==0 && outstanding=='0 &&
           expected_iar.size()==0 && expected_lar.size()==0 && expected_aw.size()==0 && expected_w.size()==0)
    else $fatal(1, "AXI drain failed at cycle %0d", cycle_no);
  endtask
  task automatic request_once(int port_id);
    req = 3'(1 << port_id);
    for (int tries = 0; tries < 200; tries++) begin
      int before_count;
      before_count = accepted[port_id];
      tick();
      if (accepted[port_id] != before_count) begin
        req = '0;
        return;
      end
    end
    $fatal(1, "Request did not receive grant");
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    random_state = 32'(seed) ^ 32'h13579bdf;
    addr         = '0;
    wdata        = '0;
    be           = '1;
    load_tag     = '0;
    store_tag    = '0;
    foreach (reference_mem[b]) reference_mem[b] = 8'(b ^ 8'ha5);
    repeat (3) tick();
    rst_n = 1;
    repeat (3) tick();
    // Every supported size and byte lane; writes are read back only after B.
    for (int size = 1; size <= 8; size *= 2)
    for (int off = 0; off < 8; off += size) begin
      addr[1] = DBase + 64'(off);
      be[1]   = 8'((1 << size) - 1);
      request_once(1);
      drain();
      addr[2]  = DBase + 128 + 64'(off);
      be[2]    = be[1];
      wdata[2] = 64'h8877665544332211;
      request_once(2);
      drain();
    end
    for (int p = 0; p < 3; p++) begin
      // Last valid location and the address immediately below each region.
      addr[p] = (p == 0 ? IBase : DBase) + 64'(Size - (p == 0 ? 4 : 1));
      be[p]   = 1;
      request_once(p);
      drain();
      addr[p] = (p == 0 ? IBase : DBase) - 64'(p == 0 ? 4 : 1);
      request_once(p);
      drain();
      addr[p] = (p == 0 ? IBase : DBase) + 1;
      be[p]   = 255;
      request_once(p);
      drain();
      addr[p] = p == 0 ? DBase : IBase;
      request_once(p);
      drain();
      addr[p] = (p == 0 ? IBase : DBase) + 64'(Size);
      request_once(p);
      drain();
    end
    for (int p = 1; p < 3; p++) begin
      addr[p] = DBase;
      be[p]   = 8'h05;
      request_once(p);
      drain();
      be[p] = 0;
      request_once(p);
      drain();
    end
    addr[0] = IBase + 64;
    request_once(0);
    drain();
    addr[1] = DBase + 112;
    be[1]   = 255;
    request_once(1);
    drain();
    addr[2] = DBase + 248;
    be[2]   = 255;
    request_once(2);
    drain();
    addr[2] = TbCfg.SERIAL_ADDR;
    be[2]   = 1;
    request_once(2);
    drain();
    addr[2] = TbCfg.EXIT_ADDR;
    request_once(2);
    drain();
    store_we = 0;
    addr[2]  = DBase;
    request_once(2);
    drain();
    store_we          = 1;

    // System reset cancels frontend reservations and memory transactions together.
    // The native PULP model only observes its first reset release, so reset it
    // while quiescent; the reset-capable slave also covers pending transactions.
    ready             = '0;
    allow_instruction = 0;
    block_channels    = 7'b0001010;
    addr[0]           = IBase;
    request_once(0);
    addr[1] = DBase + 8;
    be[1]   = 255;
    request_once(1);
    repeat (40) tick();
    if (NATIVE) drain();
    rst_n = 0;
    req   = '0;
    repeat (3) tick();
    assert (outstanding == '0 && !instr_request && !buffered_instr_valid);
    rst_n = 1;
    resets++;
    ready             = '1;
    allow_instruction = 1;
    block_channels    = '0;
    addr[0]           = IBase + 32;
    request_once(0);
    drain();

    // Fill the frontend, then repeatedly flush with native reads outstanding.
    req               = 1;
    ready[0]          = 0;
    block_channels[1] = 1;
    addr[0]           = IBase;
    repeat (40) tick();
    instr_flush = 1;
    tick();
    instr_flush = 0;
    addr[0]     = IBase + 32;
    repeat (5) tick();
    instr_flush = 1;
    tick();
    instr_flush    = 0;
    ready[0]       = 1;
    block_channels = '0;
    repeat (80) tick();
    drain();
    if (!NATIVE) begin
      // An AR offered before flush must remain valid and become stale on acceptance.
      block_channels[0] = 1;
      addr[0]           = IBase;
      request_once(0);
      repeat (3) tick();
      instr_flush = 1;
      tick();
      instr_flush = 0;
      repeat (2) tick();
      instr_flush = 1;
      tick();
      instr_flush    = 0;
      block_channels = '0;
      addr[0]        = IBase + 32;
      request_once(0);
      drain();
      // Delay load AR across flush. Every accepted load must still complete.
      block_channels[2] = 1;
      addr[1]           = DBase;
      request_once(1);
      data_flush = 1;
      tick();
      data_flush = 0;
      repeat (5) tick();
      block_channels = '0;
      drain();
      // AW and W must execute exactly once even when either channel accepts first.
      for (int which = 0; which < 2; which++) begin
        block_channels          = '0;
        block_channels[4+which] = 1;
        addr[2]                 = DBase + 160;
        be[2]                   = 255;
        wdata[2]                = 64'h123456789abcdef0;
        request_once(2);
        repeat (8) tick();
        data_flush = 1;
        tick();
        data_flush = 0;
        repeat (3) tick();
        block_channels = '0;
        drain();
      end
    end

    for (int step = 0; step < cycles; step++) begin
      instr_flush = random32() % 23 == 0;
      data_flush = random32() % 41 == 0;
      ready = 3'(random32());
      allow_instruction = random32() % 5 != 0;
      req = 3'(random32());
      load_tag = id_t'(random32() % Len5Cfg.TAG_COUNT);
      store_tag = id_t'(random32() % Len5Cfg.TAG_COUNT);
      if (load_pending[load_tag]) req[1] = 0;
      if (store_pending[store_tag]) req[2] = 0;
      addr[0] = IBase + 64'(int'(random32() % 32) * 4);
      if (random32() % 9 == 0) addr[0] = IBase + 64'(Size) + 2;
      be[1]   = 8'((1 << (1 << (random32() % 4))) - 1);
      addr[1] = DBase + 64'(random32() % 112);
      addr[1] &= ~64'(bytes_for(be[1]) - 1);
      if (random32() % 11 == 0) addr[1] = DBase + 1;
      be[2]   = 8'((1 << (1 << (random32() % 4))) - 1);
      addr[2] = DBase + 128 + 64'(random32() % 128);
      addr[2] &= ~64'(bytes_for(be[2]) - 1);
      wdata[2] = {random32(), random32()};
      if (random32() % 101 == 0) begin
        addr[2] = TbCfg.SERIAL_ADDR;
        be[2]   = 1;
      end
      if (random32() % 103 == 0) begin
        be[2] = 8'h05;
      end
      tick();
      if (step == cycles / 2) begin
        // Finish stores before reset so the byte oracle keeps committed writes.
        drain();
        ready[0]          = 0;
        block_channels[1] = 1;
        addr[0]           = IBase;
        request_once(0);
        if (NATIVE) drain();
        rst_n = 0;
        req   = '0;
        repeat (3) tick();
        rst_n = 1;
        resets++;
        drain();
      end
    end
    drain();
    // All accepted writes, including those whose acknowledgments were squashed,
    // must have executed exactly once before the final memory readback.
    assert(native_count[2]==expected_native_writes && native_count[2]==native_count[3] && native_count[3]==native_count[4]);
    for (int off = 128; off < Size; off += 8) begin
      addr[1] = DBase + 64'(off);
      be[1]   = 255;
      request_once(1);
      drain();
    end
    assert (max_fetch > 1 && mmios > 0 && flushes > 1 && resets == 2 && stale_returns > 0);
    $display("FETCH_DRAIN stale_returns=%0d", stale_returns);
    for (int p = 0; p < 3; p++) assert (accepted[p] > 0 && completed[p] > 0 && faults[p] > 0);
    if (!NATIVE)
      assert (reordered_loads > 0)
      else $fatal(1, "No out-of-order load response observed");
    $display(
        "PASS AXI native=%0d N=%0d seed=%0d cycles=%0d max_fetch=%0d reordered=%0d AW=%0d W=%0d B=%0d",
        NATIVE, N, seed, cycle_no, max_fetch, reordered_loads, native_count[2], native_count[3],
        native_count[4]);
    $finish;
  end
endmodule
