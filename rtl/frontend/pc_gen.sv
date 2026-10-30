// Copyright 2019 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: pc_gen.sv
// Author: Marco Andorno
// Date: 03/10/2019




module pc_gen #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    parameter logic [len5_pkg::XLEN-1:0] BOOT_PC = Len5Cfg.BOOT_PC
) (
    input  logic                                        clk_i,
    input  logic                                        rst_ni,
    input  logic                                        comm_except_raised_i,
    input  logic                   [len5_pkg::XLEN-1:0] comm_except_pc_i,
    input  logic                                        bu_res_valid_i,
    input  fetch_pkg::resolution_t                      bu_res_i,
    input  logic                   [len5_pkg::XLEN-1:0] pred_target_i,
    input  logic                                        pred_taken_i,
    input  logic                                        mem_ready_i,
    output logic                                        valid_o,
    output logic                                        bu_ready_o,
    output logic                   [len5_pkg::XLEN-1:0] pc_o,
    input  logic                                        early_jump_valid_i,
    input  logic                   [len5_pkg::XLEN-1:0] early_jump_offs_i,
    input  logic                   [len5_pkg::XLEN-1:0] early_jump_base_i,
    output logic                   [len5_pkg::XLEN-1:0] early_jump_target_o
);

  import len5_pkg::*;
  import len5_config_pkg::*;
  import fetch_pkg::*;

  // INTERNAL SIGNALS
  // ----------------
  logic [len5_pkg::XLEN-1:0] next_pc, add_pc_base, adder_out, add_pc_offset, add_pc_early_jump;
  logic [Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS:0] pc_increase;

  // -------------------
  // PC GENERATION LOGIC
  // -------------------
  // Target address operands mux
  if (Len5Cfg.LEN5_MULTIPLE_ISSUES == 1) begin : gen_single_pc_increase
    assign pc_increase = -1'b1;
  end else begin : gen_multiple_pc_increase
    always_comb begin : pc_increase_mux
      if (bu_res_valid_i && bu_res_i.mispredict) begin
        pc_increase = {{Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS{1'b0}}, 1'b1};
      end else begin
        pc_increase = -{1'b1, pc_o[ILEN_BIT_SUFF+Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS-1:ILEN_BIT_SUFF]};
      end
    end
  end

  always_comb begin : tgt_addr_op_mux
    if (early_jump_valid_i && !(bu_res_valid_i && bu_res_i.mispredict)) begin
      add_pc_offset     = early_jump_base_i;
      add_pc_early_jump = early_jump_offs_i;
    end else begin
      add_pc_offset = {
        {{(64 - Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS - 1) {1'b0}}, pc_increase} << ILEN_BIT_SUFF
      };
      add_pc_early_jump = {pc_o[XLEN-1:ILEN_BIT_SUFF], {ILEN_BIT_SUFF{1'b0}}};
    end
  end

  // Mux + adder
  assign add_pc_base = (bu_res_valid_i && bu_res_i.mispredict) ? bu_res_i.pc : add_pc_early_jump;
  assign adder_out   = add_pc_base + add_pc_offset;

  // Priority list for choosing the next PC value:
  // 1) Exception
  // 2) Misprediction
  // 3) Default PC+jump immediate
  // 4) Branch prediction
  // 5) Default PC+4
  always_comb begin : pc_priority_enc
    if (comm_except_raised_i) begin
      next_pc = comm_except_pc_i;
    end else if (bu_res_valid_i && bu_res_i.mispredict) begin
      if (bu_res_i.taken) begin
        next_pc = bu_res_i.target;
      end else begin
        next_pc = adder_out;
      end
    end else if (pred_taken_i && !early_jump_valid_i) begin
      next_pc = pred_target_i;
    end else begin
      next_pc = adder_out;
    end
  end : pc_priority_enc

  // PC register
  always_ff @(posedge clk_i or negedge rst_ni) begin : pc_reg
    if (!rst_ni) begin
      pc_o <= BOOT_PC;
    end else if (comm_except_raised_i || (bu_res_valid_i && bu_res_i.mispredict) || mem_ready_i || early_jump_valid_i) begin
      pc_o <= next_pc;
    end
  end : pc_reg

  // Output valid and ready
  // A held early correction must not issue fetches that its completion will flush.
  assign valid_o = rst_ni & !(bu_res_valid_i & bu_res_i.mispredict) & !comm_except_raised_i & !early_jump_valid_i;
  assign bu_ready_o = 1'b1;
  assign early_jump_target_o = next_pc;
endmodule
