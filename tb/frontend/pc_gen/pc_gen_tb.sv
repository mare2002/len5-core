// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Test-only flat port adapter. No behavioral logic or internal DUT exposure.
module pc_gen_tb #(
  // FuseSoC's integer parameter transport supplies unsized Verilog literals.
  // Two typed halves avoid truncation and implicit extension at the CLI boundary.
  parameter logic [31:0] BOOT_PC_HI = 32'h0,
  parameter logic [31:0] BOOT_PC_LO = 32'h0,
  parameter logic [63:0] BOOT_PC = {BOOT_PC_HI, BOOT_PC_LO}
) (
  input logic clk_i, rst_ni,
  input logic comm_except_raised_i,
  input logic [63:0] comm_except_pc_i,
  input logic bu_res_valid_i,
  input logic [63:0] bu_pc_i, bu_target_i,
  input logic bu_mispredict_i, bu_taken_i,
  input logic [63:0] pred_target_i,
  input logic pred_taken_i, mem_ready_i,
  input logic early_jump_valid_i,
  input logic [63:0] early_jump_base_i, early_jump_offs_i,
  output logic valid_o, bu_ready_o,
  output logic [63:0] pc_o, early_jump_target_o,
  // Configuration constants only: the model never reads DUT state to configure itself.
  output logic [63:0] config_boot_pc_o,
  output logic [31:0] config_xlen_o, config_ilen_bytes_o, config_bundle_instructions_o,
  output logic [31:0] config_alen_o, config_issue_bits_o, config_instruction_bits_o, config_lwidth_o
);
  fetch_pkg::resolution_t resolution;
  assign resolution.pc = bu_pc_i;
  assign resolution.target = bu_target_i;
  assign resolution.mispredict = bu_mispredict_i;
  assign resolution.taken = bu_taken_i;
  assign config_boot_pc_o = BOOT_PC;
  assign config_xlen_o = len5_pkg::XLEN;
  assign config_ilen_bytes_o = len5_pkg::ILEN / 8;
  assign config_bundle_instructions_o = len5_config_pkg::LEN5_MULTIPLE_ISSUES;
  assign config_alen_o = len5_pkg::ALEN;
  assign config_issue_bits_o = len5_pkg::LEN5_MULTIPLE_ISSUES_BITS;
  assign config_instruction_bits_o = len5_pkg::ILEN_BIT_SUFF;
  assign config_lwidth_o = len5_pkg::LWIDTH;
  pc_gen #(.BOOT_PC(BOOT_PC)) dut (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .comm_except_raised_i(comm_except_raised_i), .comm_except_pc_i(comm_except_pc_i),
    .bu_res_valid_i(bu_res_valid_i), .bu_res_i(resolution),
    .pred_target_i(pred_target_i), .pred_taken_i(pred_taken_i), .mem_ready_i(mem_ready_i),
    .early_jump_valid_i(early_jump_valid_i), .early_jump_base_i(early_jump_base_i),
    .early_jump_offs_i(early_jump_offs_i), .early_jump_target_o(early_jump_target_o),
    .valid_o(valid_o), .bu_ready_o(bu_ready_o), .pc_o(pc_o)
  );
endmodule
