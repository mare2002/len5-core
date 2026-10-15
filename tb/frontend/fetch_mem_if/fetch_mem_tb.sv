// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Public ports and static configuration only. No hierarchical DUT observations.
module fetch_mem_tb #(
  parameter int unsigned MEM_DEPTH = 2
) (
  input logic clk_i, rst_ni, flush_i, fetch_valid_i, instr_ready_i, instr_valid_i, issue_ready_i,
  input logic [63:0] pred_pc_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [63:0] pred_target_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_hit_i, pred_taken_i, valid_instr_i, instr_except_raised_i,
  input logic [31:0] instr_words_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [4:0] instr_causes_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic fetch_ready_o, instr_ready_o, instr_valid_o, instr_we_o, issue_valid_o,
  output logic [63:0] instr_addr_o,
  output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_o, issue_hit_o, issue_taken_o, issue_except_raised_o,
  output logic [63:0] issue_pc_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [63:0] issue_target_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [31:0] issue_words_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [4:0] issue_causes_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [31:0] config_issues_o, config_depth_o, config_xlen_o, config_ilen_o, config_cause_bits_o, config_req_skip_o, config_ans_skip_o
);
  localparam int N = len5_config_pkg::LEN5_MULTIPLE_ISSUES;
  fetch_pkg::prediction_t [N-1:0] predictions, issue_predictions;
  len5_pkg::instr_t [N-1:0] instructions;
  logic [N-1:0][31:0] words;
  len5_pkg::except_code_t [N-1:0] causes, issue_causes;
  for(genvar k=0;k<N;k++) begin : gen_lanes
    assign predictions[k].pc=pred_pc_i[k];
    assign predictions[k].target=pred_target_i[k];
    assign predictions[k].hit=pred_hit_i[k];
    assign predictions[k].taken=pred_taken_i[k];
    assign words[k]=instr_words_i[k];
    assign causes[k]=len5_pkg::except_code_t'(instr_causes_i[k]);
    assign issue_pc_o[k]=issue_predictions[k].pc;
    assign issue_target_o[k]=issue_predictions[k].target;
    assign issue_hit_o[k]=issue_predictions[k].hit;
    assign issue_taken_o[k]=issue_predictions[k].taken;
    assign issue_words_o[k]=instructions[k].raw;
    assign issue_causes_o[k]=issue_causes[k];
  end
  assign config_issues_o=N;
  assign config_depth_o=MEM_DEPTH;
  assign config_xlen_o=len5_pkg::XLEN;
  assign config_ilen_o=len5_pkg::ILEN;
  assign config_cause_bits_o=len5_pkg::EXCEPT_TYPE_LEN;
  assign config_req_skip_o=32'(len5_config_pkg::FETCH_REQ_SPILL_SKIP);
  assign config_ans_skip_o=32'(len5_config_pkg::FETCH_ANS_SPILL_SKIP);
  fetch_mem_if #(.MAX_MEM_OUTSTANDING_REQUESTS(MEM_DEPTH)) dut (
    .clk_i, .rst_ni, .flush_i, .fetch_valid_i, .fetch_ready_o,
    .fetch_pred_i(predictions), .valid_instr_i, .valid_instr_o,
    .issue_valid_o, .issue_ready_i, .issue_instr_o(instructions), .issue_pred_o(issue_predictions),
    .issue_except_raised_o, .issue_except_code_o(issue_causes),
    .instr_valid_i, .instr_ready_i, .instr_ready_o, .instr_valid_o, .instr_we_o,
    .instr_rdata_i(words), .instr_addr_o, .instr_except_raised_i, .instr_except_code_i(causes)
  );
endmodule
