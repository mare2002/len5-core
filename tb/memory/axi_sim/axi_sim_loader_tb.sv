`include "tb_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "axi/typedef.svh"
module axi_sim_loader_tb #(
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
    localparam type dmem_axi_req_t =
    `AXI_DECL_REQ_T(dmem_axi_aw_chan_t, dmem_axi_w_chan_t, dmem_axi_ar_chan_t),
    localparam type id_t = `LEN5_AXI_ID_T(Len5Cfg),
    parameter int unsigned I_WIDTH = 128
);
  timeunit 1ps; timeprecision 1ps;
  import axi_memory_pkg::*;
  localparam int ISize = I_WIDTH / 8 * 3;
  typedef logic [I_WIDTH-1:0] instruction_word_t;
  typedef logic [I_WIDTH/8-1:0] instruction_strobe_t;
  `AXI_TYPEDEF_ALL(loader_axi, addr_t, id_t, instruction_word_t, instruction_strobe_t, user_t)
  bit clk = 0, reset_n = 0;
  logic initialized_i, initialized_d;
  loader_axi_req_t [0:0] ireq;
  dmem_axi_req_t   [1:0] dreq;
  assign ireq = '0;
  assign dreq = '0;
  axi_sim_storage #(
      .Len5Cfg         (Len5Cfg),
      .TbCfg           (TbCfg),
      .BASE_ADDR       (64'h4000),
      .SIZE_BYTES      (ISize),
      .OTHER_BASE_ADDR (64'h8000),
      .OTHER_SIZE_BYTES(24),
      .DATA_WIDTH      (I_WIDTH),
      .NUM_PORTS       (1),
      .AXI_REQ_T       (loader_axi_req_t),
      .AXI_RESP_T      (loader_axi_resp_t)
  ) imem (
      .clk_i        (clk),
      .rst_ni       (reset_n),
      .req_i        (ireq),
      .rsp_o        (),
      .initialized_o(initialized_i)
  );
  axi_sim_storage #(
      .Len5Cfg         (Len5Cfg),
      .TbCfg           (TbCfg),
      .BASE_ADDR       (64'h8000),
      .SIZE_BYTES      (24),
      .OTHER_BASE_ADDR (64'h4000),
      .OTHER_SIZE_BYTES(ISize),
      .DATA_WIDTH      (64),
      .NUM_PORTS       (2)
  ) dmem (
      .clk_i        (clk),
      .rst_ni       (reset_n),
      .req_i        (dreq),
      .rsp_o        (),
      .initialized_o(initialized_d)
  );
  task automatic tick;
    #(TbCfg.AXI_CLOCK_HALF_PERIOD_PS);
    clk = 1;
    #(TbCfg.AXI_CLOCK_HALF_PERIOD_PS);
    clk = 0;
  endtask
  initial begin
    bit binary_image;
    // verilog_lint: waive plusarg-assignment
    binary_image = $test$plusargs("binary_image");
    repeat (3) tick();
    reset_n = 1;
    repeat (3) tick();
    assert (initialized_i && initialized_d);
    for (int b = 0; b < 8; b++)
    assert (imem.u_mem.mem[64'h4000+64'(b)] === 8'(64'h8877665544332211 >> (8 * b)));
    if (!binary_image) begin
      for (int b = 0; b < 4; b++)
      assert (imem.u_mem.mem[64'h4010+64'(b)] === 8'(32'hddccbbaa >> (8 * b)));
      assert (imem.u_mem.mem[64'h4000+64'(ISize-1)] === 8'ha5);
      for (int b = 0; b < 8; b++)
      assert (dmem.u_mem.mem[64'h8000+64'(b)] === 8'(64'h1020304050607080 >> (8 * b)));
      assert (dmem.u_mem.mem[64'h8017] === 8'h5a);
    end else assert (dmem.u_mem.mem.num() == 0);
    // An untouched byte must remain absent from the native associative array.
    // Checking its value in a two-state simulator would hide accidental clearing.
    assert (imem.u_mem.mem.exists(64'h4008) == 0);
    assert (imem.u_mem.mem.exists(64'h8000) == 0);
    assert (dmem.u_mem.mem.exists(64'h4000) == 0);
    assert (dmem.u_mem.mem.exists(64'h8008) == 0);
    $display("PASS firmware AXI native deposits IWidth=%0d", I_WIDTH);
    $finish;
  end
endmodule
