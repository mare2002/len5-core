// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_loader_tb #(
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
    parameter string SIM_INIT = "ones",
    parameter int unsigned I_WIDTH = 128,
    parameter int unsigned I_LATENCY = 1,
    parameter int unsigned D_LATENCY = 1
);
  localparam int IBytes = I_WIDTH / 8;
  localparam int ISize = IBytes * 3;
  localparam int IAddrWidth = $clog2(3);
  bit clk = 0;
  logic ireq, initialized_i, initialized_d;
  logic [IAddrWidth-1:0]       iaddr;
  logic [   I_WIDTH-1:0]       idata;
  logic [           1:0]       dreq;
  logic [           1:0][ 1:0] daddr;
  logic [           1:0][63:0] ddata;
  bit                          binary_image;
  tc_sram_storage #(
      .Len5Cfg         (Len5Cfg),
      .TbCfg           (TbCfg),
      .BASE_ADDR       (64'h4000),
      .SIZE_BYTES      (ISize),
      .DATA_WIDTH      (I_WIDTH),
      .NUM_PORTS       (1),
      .LATENCY         (I_LATENCY),
      .OTHER_BASE_ADDR (64'h8000),
      .OTHER_SIZE_BYTES(24),
      .SIM_INIT        (SIM_INIT)
  ) imem (
      .clk_i        (clk),
      .req_i        (ireq),
      .we_i         (1'b0),
      .addr_i       (iaddr),
      .wdata_i      ('0),
      .be_i         ('0),
      .rdata_o      (idata),
      .initialized_o(initialized_i)
  );
  tc_sram_storage #(
      .Len5Cfg         (Len5Cfg),
      .TbCfg           (TbCfg),
      .BASE_ADDR       (64'h8000),
      .SIZE_BYTES      (24),
      .DATA_WIDTH      (64),
      .NUM_PORTS       (2),
      .LATENCY         (D_LATENCY),
      .OTHER_BASE_ADDR (64'h4000),
      .OTHER_SIZE_BYTES(ISize),
      .SIM_INIT        (SIM_INIT)
  ) dmem (
      .clk_i        (clk),
      .req_i        (dreq),
      .we_i         (2'b0),
      .addr_i       (daddr),
      .wdata_i      ('0),
      .be_i         ('0),
      .rdata_o      (ddata),
      .initialized_o(initialized_d)
  );
  task automatic tick;
    #5;
    clk = 1;
    #5;
    clk = 0;
  endtask
  task automatic expect_instruction_byte(int offset, logic [7:0] expected_byte);
    ireq  = 1;
    iaddr = IAddrWidth'(offset / IBytes);
    repeat (I_LATENCY + 1) tick();
    assert (8'(idata >> (8 * (offset % IBytes))) === expected_byte)
    else $fatal(1, "IMEM byte mismatch offset %0d", offset);
  endtask
  initial begin
    ireq         = 0;
    iaddr        = 0;
    dreq         = 0;
    daddr        = 0;
    // verilog_lint: waive plusarg-assignment
    binary_image = $test$plusargs("binary_image");
    repeat (3) tick();
    assert (initialized_i && initialized_d)
    else $fatal(1, "Loader did not finish");
    for (int b = 0; b < 8; b++) expect_instruction_byte(b, 8'(64'h8877665544332211 >> (8 * b)));
    if (!binary_image) begin
      for (int b = 0; b < 4; b++) expect_instruction_byte(16 + b, 8'(32'hddccbbaa >> (8 * b)));
      expect_instruction_byte(ISize - 1, 8'ha5);
      dreq[0]  = 1;
      daddr[0] = 0;
      repeat (D_LATENCY + 1) tick();
      assert (ddata[0] === 64'h1020304050607080)
      else $fatal(1, "DMEM load/endian mismatch");
      daddr[0] = 2;
      repeat (D_LATENCY + 1) tick();
      assert (ddata[0][31:0] === 32'h12345678 && ddata[0][63:56] === 8'h5a)
      else $fatal(1, "DMEM sparse/boundary mismatch");
    end
    if (SIM_INIT == "ones") expect_instruction_byte(8, 8'hff);
    if (SIM_INIT == "zeros") expect_instruction_byte(8, 8'h00);
    $display("PASS firmware load SimInit=%s IWidth=%0d ILatency=%0d DLatency=%0d", SIM_INIT,
             I_WIDTH, I_LATENCY, D_LATENCY);
    $finish;
  end
endmodule
