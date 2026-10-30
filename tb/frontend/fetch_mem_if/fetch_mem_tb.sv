// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Public ports and static configuration only. No hierarchical DUT observations.
module fetch_mem_tb #(
    parameter logic [31:0] BOOT_PC_HI = 32'((0) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(0),
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
            FETCH_MEMIF_FIFO_DEPTH: MEM_DEPTH,
            FETCH_MEM_DRAIN_ON_FLUSH: 1'b0,
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
    parameter int unsigned MEM_DEPTH = 2
) (
    input  logic                                    clk_i,
    rst_ni,
    flush_i,
    fetch_valid_i,
    instr_ready_i,
    instr_valid_i,
    issue_ready_i,
    input  logic [                            63:0] pred_pc_i      [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    input  logic [                            63:0] pred_target_i  [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    input  logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] pred_hit_i,
    pred_taken_i,
    valid_instr_i,
    instr_except_raised_i,
    input  logic [                            31:0] instr_words_i  [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    input  logic [                             4:0] instr_causes_i [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    output logic                                    fetch_ready_o,
    instr_ready_o,
    instr_valid_o,
    instr_we_o,
    issue_valid_o,
    output logic [                            63:0] instr_addr_o,
    output logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] valid_instr_o,
    issue_hit_o,
    issue_taken_o,
    issue_except_raised_o,
    output logic [                            63:0] issue_pc_o     [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    output logic [                            63:0] issue_target_o [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    output logic [                            31:0] issue_words_o  [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    output logic [                             4:0] issue_causes_o [Len5Cfg.LEN5_MULTIPLE_ISSUES],
    output logic [                            31:0] config_issues_o,
    config_depth_o,
    config_xlen_o,
    config_ilen_o,
    config_cause_bits_o,
    config_req_skip_o,
    config_ans_skip_o
);
  initial begin : check_configuration
    if (MEM_DEPTH == 0 || (MEM_DEPTH & (MEM_DEPTH - 1)) != 0)
      $fatal(1, "Fetch completion queue requires a positive power-of-two capacity");
  end
  localparam int N = Len5Cfg.LEN5_MULTIPLE_ISSUES;
  fetch_pkg::prediction_t [N-1:0] predictions, issue_predictions;
  len5_pkg::instr_t [N-1:0]       instructions;
  logic             [N-1:0][31:0] words;
  len5_pkg::except_code_t [N-1:0] causes, issue_causes;
  for (genvar k = 0; k < N; k++) begin : gen_lanes
    assign predictions[k].pc     = pred_pc_i[k];
    assign predictions[k].target = pred_target_i[k];
    assign predictions[k].hit    = pred_hit_i[k];
    assign predictions[k].taken  = pred_taken_i[k];
    assign words[k]              = instr_words_i[k];
    assign causes[k]             = len5_pkg::except_code_t'(instr_causes_i[k]);
    assign issue_pc_o[k]         = issue_predictions[k].pc;
    assign issue_target_o[k]     = issue_predictions[k].target;
    assign issue_hit_o[k]        = issue_predictions[k].hit;
    assign issue_taken_o[k]      = issue_predictions[k].taken;
    assign issue_words_o[k]      = instructions[k].raw;
    assign issue_causes_o[k]     = issue_causes[k];
  end
  assign config_issues_o     = N;
  assign config_depth_o      = MEM_DEPTH;
  assign config_xlen_o       = len5_pkg::XLEN;
  assign config_ilen_o       = len5_pkg::ILEN;
  assign config_cause_bits_o = len5_pkg::EXCEPT_TYPE_LEN;
  assign config_req_skip_o   = 32'(Len5Cfg.FETCH_REQ_SPILL_SKIP);
  assign config_ans_skip_o   = 32'(Len5Cfg.FETCH_ANS_SPILL_SKIP);
  // This existing oracle models a memory that cancels requests on flush.
  fetch_mem_if #(
      .Len5Cfg(Len5Cfg)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .fetch_valid_i,
      .fetch_ready_o,
      .fetch_pred_i       (predictions),
      .valid_instr_i,
      .valid_instr_o,
      .issue_valid_o,
      .issue_ready_i,
      .issue_instr_o      (instructions),
      .issue_pred_o       (issue_predictions),
      .issue_except_raised_o,
      .issue_except_code_o(issue_causes),
      .instr_valid_i,
      .instr_ready_i,
      .instr_ready_o,
      .instr_valid_o,
      .instr_we_o,
      .instr_rdata_i      (words),
      .instr_addr_o,
      .instr_except_raised_i,
      .instr_except_code_i(causes)
  );
endmodule
