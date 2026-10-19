// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Public dynamic ports and static elaboration constants only.
module fetch_stage_tb #(
  parameter longint unsigned BOOT_PC = 0,
  parameter int unsigned MEM_DEPTH = 2
) (
  input logic clk_i, rst_ni, flush_i, flush_bpu_i,
  input logic instr_ready_i, instr_valid_i, issue_ready_i,
  input logic bu_bpu_valid_i, bu_pcgen_valid_i, bu_call_confirm_i, bu_ret_confirm_i,
  input logic res_taken_i, res_mispredict_i, comm_except_raised_i,
  input logic [63:0] res_pc_i, res_target_i, bu_link_addr_i, comm_except_pc_i,
  input logic [31:0] instr_words_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [4:0] instr_causes_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_except_raised_i,
  output logic instr_valid_o, instr_ready_o, instr_we_o, issue_valid_o,
  output logic early_jump_mem_flush_o, bu_pcgen_ready_o,
  output logic [63:0] instr_addr_o,
  output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_valid_instr_o,
  output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_hit_o, issue_taken_o, issue_except_raised_o,
  output logic [63:0] issue_pc_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [63:0] issue_target_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [31:0] issue_words_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [4:0] issue_causes_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [31:0] config_issues_o, config_depth_o, config_xlen_o, config_ilen_o,
  output logic [31:0] config_hlen_o, config_btb_bits_o, config_initial_o, config_ras_depth_o,
  output logic [31:0] config_req_skip_o, config_ans_skip_o, config_cause_bits_o,
  output logic [63:0] config_boot_o
);
  initial begin : check_configuration
    if (MEM_DEPTH == 0 || (MEM_DEPTH & (MEM_DEPTH - 1)) != 0)
      $fatal(1, "Fetch completion queue requires a positive power-of-two capacity");
  end
  localparam int N=len5_config_pkg::LEN5_MULTIPLE_ISSUES;
  logic [N-1:0][31:0] words;
  len5_pkg::instr_t [N-1:0] instructions;
  fetch_pkg::prediction_t [N-1:0] predictions;
  len5_pkg::except_code_t [N-1:0] causes, output_causes;
  fetch_pkg::resolution_t resolution;
  assign resolution={res_pc_i,res_mispredict_i,res_taken_i,res_target_i};
  for(genvar k=0;k<N;k++) begin : gen_lanes
    assign words[k]=instr_words_i[k];
    assign causes[k]=len5_pkg::except_code_t'(instr_causes_i[k]);
    assign issue_pc_o[k]=predictions[k].pc;
    assign issue_target_o[k]=predictions[k].target;
    assign issue_hit_o[k]=predictions[k].hit;
    assign issue_taken_o[k]=predictions[k].taken;
    assign issue_words_o[k]=instructions[k].raw;
    assign issue_causes_o[k]=output_causes[k];
  end
  assign config_issues_o=N;
  assign config_depth_o=MEM_DEPTH;
  assign config_xlen_o=len5_pkg::XLEN;
  assign config_ilen_o=len5_pkg::ILEN;
  assign config_hlen_o=fetch_pkg::HLEN;
  assign config_btb_bits_o=fetch_pkg::BTB_BITS;
  assign config_initial_o=32'(fetch_pkg::INIT_C2B);
  assign config_ras_depth_o=len5_config_pkg::RAS_DEPTH;
  assign config_req_skip_o=32'(len5_config_pkg::FETCH_REQ_SPILL_SKIP);
  assign config_ans_skip_o=32'(len5_config_pkg::FETCH_ANS_SPILL_SKIP);
  assign config_cause_bits_o=len5_pkg::EXCEPT_TYPE_LEN;
  assign config_boot_o=BOOT_PC;
  fetch_stage #(.HLEN(fetch_pkg::HLEN),.BTB_BITS(fetch_pkg::BTB_BITS),
    .BOOT_PC(BOOT_PC),.MEMIF_FIFO_DEPTH(MEM_DEPTH)) dut (
    .clk_i,.rst_ni,.flush_i,.flush_bpu_i,.instr_valid_i,.instr_ready_i,.instr_ready_o,
    .instr_valid_o,.instr_we_o,.instr_rdata_i(words),.instr_addr_o,.early_jump_mem_flush_o,
    .instr_except_raised_i,.instr_except_code_i(causes),.issue_ready_i,.issue_valid_o,
    .issue_valid_instr_o,.issue_instr_o(instructions),.issue_pred_o(predictions),
    .issue_except_raised_o,.issue_except_code_o(output_causes),.bu_pcgen_ready_o,
    .bu_bpu_valid_i,.bu_pcgen_valid_i,.bu_res_i(resolution),.bu_call_confirm_i,
    .bu_ret_confirm_i,.bu_link_addr_i,.comm_except_raised_i,.comm_except_pc_i
  );
endmodule
