`include "len5_typedef.svh"
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
// File: fp_regstat.sv
// Author: Michele Caon, Flavia Guella
// Date: 12/11/2019

module fp_regstat #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned REG_NUM = len5_pkg::FREG_NUM,
  localparam int unsigned RegIdxLen = len5_pkg::FREG_IDX_LEN
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Issue Logic (valid lanes are accepted destination writes)
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][RegIdxLen-1:0] issue_rd_idx_i,  // destination register of the issuing instruction
  input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rob_idx_i,  // allocated ROB index
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][RegIdxLen-1:0] issue_rs1_idx_i,  // first source register index
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][RegIdxLen-1:0] issue_rs2_idx_i,  // second source register index
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][RegIdxLen-1:0] issue_rs3_idx_i,  // third source register index
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_busy_o,  // rs1 value is in the ROB or has to be computed
  output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_rob_idx_o,  // the index of the ROB where the result is found
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_busy_o,  // rs1 value is in the ROB or has to be computed
  output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_rob_idx_o,  // the index of the ROB where the result is found
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs3_busy_o,  // rs3 value is in the ROB or has to be computed
  output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs3_rob_idx_o,  // the index of the ROB where the result is found

  // Commit Logic
  input logic                     comm_valid_i,
  input logic     [RegIdxLen-1:0] comm_rd_idx_i,  // destination register of the committing instr.
  input rob_idx_t                 comm_rob_idx_i
);

  import expipe_pkg::*;

  logic busy_q[REG_NUM], busy_d[REG_NUM];
  rob_idx_t rob_idx_q[REG_NUM], rob_idx_d[REG_NUM];

  for (genvar r = 0; r < REG_NUM; r++) begin : gen_status
    logic                           commit_match;
    logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_match;

    assign commit_match = comm_valid_i && comm_rd_idx_i == r[RegIdxLen-1:0] && comm_rob_idx_i == rob_idx_q[r];

    // A new writer keeps the register busy even when the old writer commits.
    assign busy_d[r] = (|issue_match) || (busy_q[r] && !commit_match);

    always_comb begin : status_next
      // The tag mux gives the youngest matching issue lane priority.
      rob_idx_d[r] = rob_idx_q[r];
      for (int i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin
        issue_match[i] = issue_valid_i[i] && issue_rd_idx_i[i] == r[RegIdxLen-1:0];
        if (issue_match[i]) rob_idx_d[r] = issue_rob_idx_i[i];
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : busy_update
      if (!rst_ni) busy_q[r] <= 1'b0;
      else if (flush_i) busy_q[r] <= 1'b0;
      else busy_q[r] <= busy_d[r];
    end

    // Tags need no reset or flush value: consumers ignore them when not busy.
    always_ff @(posedge clk_i) begin : tag_update
      if (rst_ni && !flush_i) rob_idx_q[r] <= rob_idx_d[r];
    end
  end

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_read_ports
    assign issue_rs1_busy_o[i]    = busy_q[issue_rs1_idx_i[i]];
    assign issue_rs1_rob_idx_o[i] = rob_idx_q[issue_rs1_idx_i[i]];
    assign issue_rs2_busy_o[i]    = busy_q[issue_rs2_idx_i[i]];
    assign issue_rs2_rob_idx_o[i] = rob_idx_q[issue_rs2_idx_i[i]];
    assign issue_rs3_busy_o[i]    = busy_q[issue_rs3_idx_i[i]];
    assign issue_rs3_rob_idx_o[i] = rob_idx_q[issue_rs3_idx_i[i]];
  end
endmodule
