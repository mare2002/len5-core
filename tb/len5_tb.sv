// Copyright 2022 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: len5_tb.sv
// Author: Michele Caon
// Date: 30/01/2024

module len5_tb #(
    parameter int unsigned BOOT_VM_MODE = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_VM_MODE),
    parameter logic [31:0] BOOT_PC_HI = 32'((IMEM_BASE_ADDR + len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(IMEM_BASE_ADDR + len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC),
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
    parameter string SRAM_SIM_INIT = tb_config_pkg::DefaultSramSimInit
);
  // ----------------
  // TB CONFIGURATION
  // ----------------
  // Reset duration
  localparam int unsigned ResetCycles = 10;

  // Boot program counter
  localparam string MemDumpFile = "mem_dump.txt";

  // INTERNAL SIGNALS
  // ----------------
  // Clock and reset
  logic clk, rst_n;

  // ----
  // BODY
  // ----

  // Clock and reset generation
  // --------------------------
  initial begin
    clk   = 1'b1;
    rst_n = 1'b0;

    // De-assert reset after some cycles
    repeat (ResetCycles) @(posedge clk);
    rst_n = 1'b1;
  end
  always #5 clk = ~clk;

  // --------------
  // LEN5 TB SYSTEM
  // --------------
  tb_bare #(
      .SRAM_SIM_INIT(SRAM_SIM_INIT),
      .Len5Cfg      (Len5Cfg),
      .TbCfg        (TbCfg),
      .MEM_DUMP_FILE(MemDumpFile),
      .BOOT_PC      (Len5Cfg.BOOT_PC)
  ) u_tb (
      .clk_i (clk),   // simulation clock
      .rst_ni(rst_n)  // simulation reset
  );
endmodule
