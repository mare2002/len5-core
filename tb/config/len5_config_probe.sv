// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Export the values elaborated by SystemVerilog to existing verification/firmware tools.
module len5_config_probe #(
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
    parameter string SRAM_SIM_INIT = tb_config_pkg::DefaultSramSimInit,
    parameter logic [31:0] BOOT_PC_HI = 32'((IMEM_BASE_ADDR + len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(IMEM_BASE_ADDR + len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC),
    parameter longint unsigned BOOT_PC = {BOOT_PC_HI, BOOT_PC_LO},
    parameter int unsigned BOOT_VM_MODE = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_VM_MODE),
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
    parameter bit Dump = 1,
    parameter bit CheckBuild = 0
);
  if (CheckBuild) begin : gen_check_build
    if (!tb_config_pkg::check_build(Len5Cfg, TbCfg, SRAM_SIM_INIT)) begin : gen_invalid_configuration
      $fatal(1, "Invalid LEN5/TB configuration");
    end
  end
  initial begin
    if (Dump) begin
      $write("{\"rtl\":{");
      $write("\"BOOT_VM_MODE\":%0d", Len5Cfg.BOOT_VM_MODE);
      $write(",\"BOOT_PC\":%0d", Len5Cfg.BOOT_PC);
      $write(",\"LEN5_MULTIPLE_ISSUES\":%0d", Len5Cfg.LEN5_MULTIPLE_ISSUES);
      $write(",\"LEN5_M_EN\":%0d", Len5Cfg.LEN5_M_EN);
      $write(",\"LEN5_DIV_EN\":%0d", Len5Cfg.LEN5_DIV_EN);
      $write(",\"LEN5_F_EN\":%0d", Len5Cfg.LEN5_F_EN);
      $write(",\"LEN5_D_EN\":%0d", Len5Cfg.LEN5_D_EN);
      $write(",\"LEN5_C_EN\":%0d", Len5Cfg.LEN5_C_EN);
      $write(",\"LEN5_A_EN\":%0d", Len5Cfg.LEN5_A_EN);
      $write(",\"LEN5_STORE_LOAD_FWD_EN\":%0d", Len5Cfg.LEN5_STORE_LOAD_FWD_EN);
      $write(",\"MAX_EU_N\":%0d", Len5Cfg.MAX_EU_N);
      $write(",\"ONLY_DOUBLEWORD_MEM_ACCESSES\":%0d", Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES);
      $write(",\"LEN5_CSR_HPMCOUNTERS_EN\":%0d", Len5Cfg.LEN5_CSR_HPMCOUNTERS_EN);
      $write(",\"MMAP_MASK\":%0d", Len5Cfg.MMAP_MASK);
      $write(",\"BPU_HLEN\":%0d", Len5Cfg.BPU_HLEN);
      $write(",\"BPU_BTB_BITS\":%0d", Len5Cfg.BPU_BTB_BITS);
      $write(",\"RAS_DEPTH\":%0d", Len5Cfg.RAS_DEPTH);
      $write(",\"FETCH_MEMIF_FIFO_DEPTH\":%0d", Len5Cfg.FETCH_MEMIF_FIFO_DEPTH);
      $write(",\"FETCH_MEM_DRAIN_ON_FLUSH\":%0d", Len5Cfg.FETCH_MEM_DRAIN_ON_FLUSH);
      $write(",\"LOAD_BUFFER_DRAIN_ON_FLUSH\":%0d", Len5Cfg.LOAD_BUFFER_DRAIN_ON_FLUSH);
      $write(",\"FETCH_REQ_SPILL_SKIP\":%0d", Len5Cfg.FETCH_REQ_SPILL_SKIP);
      $write(",\"FETCH_ANS_SPILL_SKIP\":%0d", Len5Cfg.FETCH_ANS_SPILL_SKIP);
      $write(",\"IQ_DEPTH\":%0d", Len5Cfg.IQ_DEPTH);
      $write(",\"LDBUFF_DEPTH\":%0d", Len5Cfg.LDBUFF_DEPTH);
      $write(",\"STBUFF_DEPTH\":%0d", Len5Cfg.STBUFF_DEPTH);
      $write(",\"LSU_SPILL_SKIP\":%0d", Len5Cfg.LSU_SPILL_SKIP);
      $write(",\"ALU_RS_DEPTH\":%0d", Len5Cfg.ALU_RS_DEPTH);
      $write(",\"ALU_SPILL_SKIP\":%0d", Len5Cfg.ALU_SPILL_SKIP);
      $write(",\"ALU_RR_ARBITER\":%0d", Len5Cfg.ALU_RR_ARBITER);
      $write(",\"MULT_RS_DEPTH\":%0d", Len5Cfg.MULT_RS_DEPTH);
      $write(",\"LEN5_MULT_SERIAL\":%0d", Len5Cfg.LEN5_MULT_SERIAL);
      $write(",\"MULT_PIPE_DEPTH\":%0d", Len5Cfg.MULT_PIPE_DEPTH);
      $write(",\"MULT_RR_ARBITER\":%0d", Len5Cfg.MULT_RR_ARBITER);
      $write(",\"DIV_RS_DEPTH\":%0d", Len5Cfg.DIV_RS_DEPTH);
      $write(",\"DIV_RR_ARBITER\":%0d", Len5Cfg.DIV_RR_ARBITER);
      $write(",\"FPU_RS_DEPTH\":%0d", Len5Cfg.FPU_RS_DEPTH);
      $write(",\"FPU_RR_ARBITER\":%0d", Len5Cfg.FPU_RR_ARBITER);
      $write(",\"FPU_PIPE_DEPTH\":%0d", Len5Cfg.FPU_PIPE_DEPTH);
      $write(",\"FPU_SPILL_SKIP\":%0d", Len5Cfg.FPU_SPILL_SKIP);
      $write(",\"BU_RS_DEPTH\":%0d", Len5Cfg.BU_RS_DEPTH);
      $write(",\"BU_SPILL_SKIP\":%0d", Len5Cfg.BU_SPILL_SKIP);
      $write(",\"ROB_DEPTH\":%0d", Len5Cfg.ROB_DEPTH);
      $write(",\"COMMIT_SPILL_SKIP\":%0d", Len5Cfg.COMMIT_SPILL_SKIP);
      $write(",\"BPU_INIT_C2B\":%0d", Len5Cfg.BPU_INIT_C2B);
      $write(",\"LEN5_MULTIPLE_ISSUES_BITS\":%0d", Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS);
      $write(",\"LWIDTH\":%0d", Len5Cfg.LWIDTH);
      $write(",\"FLEN\":%0d", Len5Cfg.FLEN);
      $write(",\"LDBUFF_TAG_W\":%0d", Len5Cfg.LDBUFF_TAG_W);
      $write(",\"STBUFF_TAG_W\":%0d", Len5Cfg.STBUFF_TAG_W);
      $write(",\"BUFF_IDX_LEN\":%0d", Len5Cfg.BUFF_IDX_LEN);
      $write(",\"ROB_IDX_LEN\":%0d", Len5Cfg.ROB_IDX_LEN);
      $write(",\"COMMIT_UNIT_DEPTH\":%0d", Len5Cfg.COMMIT_UNIT_DEPTH);
      $write(",\"IQ_IDX_LEN\":%0d", Len5Cfg.IQ_IDX_LEN);
      $write(",\"MULT_EU_N\":%0d", Len5Cfg.MULT_EU_N);
      $write(",\"DIV_EU_N\":%0d", Len5Cfg.DIV_EU_N);
      $write(",\"FP_EU_N\":%0d", Len5Cfg.FP_EU_N);
      $write(",\"EU_N\":%0d", Len5Cfg.EU_N);
      $write(",\"REGSTAT_CNT_W\":%0d", Len5Cfg.REGSTAT_CNT_W);
      $write(",\"IMEM_DATA_WIDTH\":%0d", Len5Cfg.IMEM_DATA_WIDTH);
      $write(",\"TAG_COUNT\":%0d", Len5Cfg.TAG_COUNT);
      $write(",\"AXI_COUNT_WIDTH\":%0d", Len5Cfg.AXI_COUNT_WIDTH);
      $write("},\"tb\":{");
      $write("\"MEMORY_BACKEND\":%0d", TbCfg.MEMORY_BACKEND);
      $write(",\"AXI_CLOCK_HALF_PERIOD_PS\":%0d", TbCfg.AXI_CLOCK_HALF_PERIOD_PS);
      $write(",\"IMEM_BASE_ADDR\":%0d", TbCfg.IMEM_BASE_ADDR);
      $write(",\"IMEM_SIZE_BYTES\":%0d", TbCfg.IMEM_SIZE_BYTES);
      $write(",\"IMEM_LATENCY\":%0d", TbCfg.IMEM_LATENCY);
      $write(",\"DMEM_BASE_ADDR\":%0d", TbCfg.DMEM_BASE_ADDR);
      $write(",\"DMEM_SIZE_BYTES\":%0d", TbCfg.DMEM_SIZE_BYTES);
      $write(",\"DMEM_LATENCY\":%0d", TbCfg.DMEM_LATENCY);
      $write(",\"SERIAL_ADDR\":%0d", TbCfg.SERIAL_ADDR);
      $write(",\"EXIT_ADDR\":%0d", TbCfg.EXIT_ADDR);
      $write(",\"IMEM_DATA_WIDTH\":%0d", TbCfg.IMEM_DATA_WIDTH);
      $write(",\"IMEM_WORD_BYTES\":%0d", TbCfg.IMEM_WORD_BYTES);
      $write(",\"IMEM_ADDR_WIDTH\":%0d", TbCfg.IMEM_ADDR_WIDTH);
      $write(",\"DMEM_ADDR_WIDTH\":%0d", TbCfg.DMEM_ADDR_WIDTH);
      $write(",\"SRAM_RESPONSE_DEPTH\":%0d", TbCfg.SRAM_RESPONSE_DEPTH);
      $write(",\"SRAM_COUNT_WIDTH\":%0d", TbCfg.SRAM_COUNT_WIDTH);
      $write(",\"SRAM_SIM_INIT\":\"%s\"", SRAM_SIM_INIT);
      $write("},\"architecture\":{");
      $write("\"XLEN\":%0d", len5_pkg::XLEN);
      $write(",\"ALEN\":%0d", len5_pkg::ALEN);
      $write(",\"ILEN\":%0d", len5_pkg::ILEN);
      $write(",\"WWIDTH\":%0d", len5_pkg::WWIDTH);
      $write(",\"EXCEPT_TYPE_LEN\":%0d", len5_pkg::EXCEPT_TYPE_LEN);
      $write("}}\n");
    end
    $finish;
  end
endmodule
