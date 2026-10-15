// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Public-port adapter only. The production early_jump_unit instantiates its real RAS.
module early_jump_tb (
  input logic clk_i, rst_ni, flush_i, instr_valid_i, issue_ready_i,
  input logic call_confirm_i, ret_confirm_i,
  input logic [63:0] res_link_addr_i, early_jump_target_i,
  input logic [31:0] words_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [63:0] pred_pc_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [63:0] pred_target_i [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_hit_i, pred_taken_i, valid_instr_i,
  output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_o, issue_hit_o, issue_taken_o,
  output logic [63:0] issue_pc_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic [63:0] issue_target_o [len5_config_pkg::LEN5_MULTIPLE_ISSUES],
  output logic early_jump_valid_o, mem_flush_o,
  output logic [63:0] early_jump_base_o, early_jump_offs_o,
  output logic [31:0] config_issues_o, config_depth_o, config_xlen_o, config_alen_o, config_ilen_o
);
  len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instructions;
  fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] predictions, issue_predictions;
  for (genvar k = 0; k < len5_config_pkg::LEN5_MULTIPLE_ISSUES; k++) begin : gen_lanes
    assign instructions[k].raw = words_i[k];
    assign predictions[k].pc = pred_pc_i[k];
    assign predictions[k].target = pred_target_i[k];
    assign predictions[k].hit = pred_hit_i[k];
    assign predictions[k].taken = pred_taken_i[k];
    assign issue_pc_o[k] = issue_predictions[k].pc;
    assign issue_target_o[k] = issue_predictions[k].target;
    assign issue_hit_o[k] = issue_predictions[k].hit;
    assign issue_taken_o[k] = issue_predictions[k].taken;
  end
  assign config_issues_o = len5_config_pkg::LEN5_MULTIPLE_ISSUES;
  assign config_depth_o = len5_config_pkg::RAS_DEPTH;
  assign config_xlen_o = len5_pkg::XLEN;
  assign config_alen_o = len5_pkg::ALEN;
  assign config_ilen_o = len5_pkg::ILEN;
  early_jump_unit dut (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .instr_i(instructions), .instr_valid_i(instr_valid_i), .issue_ready_i(issue_ready_i),
    .mem_if_pred_i(predictions), .valid_instr_i(valid_instr_i), .valid_instr_o(valid_instr_o),
    .early_jump_target_i(early_jump_target_i), .call_confirm_i(call_confirm_i),
    .ret_confirm_i(ret_confirm_i), .res_link_addr_i(res_link_addr_i),
    .issue_pred_o(issue_predictions), .early_jump_valid_o(early_jump_valid_o),
    .mem_flush_o(mem_flush_o), .early_jump_base_o(early_jump_base_o), .early_jump_offs_o(early_jump_offs_o)
  );
endmodule
