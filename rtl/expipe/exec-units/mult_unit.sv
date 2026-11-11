`include "len5_typedef.svh"
// Copyright 2021 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: mult_unit.sv
// Author: Flavia Guella, Michele Caon
// Date: 17/11/2021

module mult_unit #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned RsIdxLen = Len5Cfg.MULT_RS_DEPTH > 1 ? $clog2(Len5Cfg.MULT_RS_DEPTH) : 1,
  localparam type rs_idx_t = logic [RsIdxLen-1:0],
  localparam int unsigned NUM_UNITS = Len5Cfg.MULT_NUM_UNITS > 0 ? Len5Cfg.MULT_NUM_UNITS : 1,
  localparam int unsigned EU_CTL_LEN = expipe_pkg::MAX_EU_CTL_LEN
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,


  // Issue logic
  input  logic                  [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
  output logic                  [Len5Cfg.ISSUE_WIDTH-1:0] issue_ready_o,
  input  expipe_pkg::mult_ctl_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_eu_ctl_i,
  input  op_data_t              [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_i,
  input  op_data_t              [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_i,
  input  rob_idx_t              [Len5Cfg.ISSUE_WIDTH-1:0] issue_dest_rob_idx_i,

  // CDB
  input  logic      cdb_ready_i,
  input  logic      cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic      cdb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_data_o
);

  import len5_pkg::*;
  import len5_config_pkg::*;
  import expipe_pkg::*;

  // Handshake from/to the execution unit
  logic         [NUM_UNITS-1:0]                 rs_mult_valid;
  logic         [NUM_UNITS-1:0]                 rs_mult_ready;
  logic         [NUM_UNITS-1:0]                 mult_rs_valid;
  logic         [NUM_UNITS-1:0]                 mult_rs_ready;

  // Data from/to the execution unit
  rs_idx_t      [NUM_UNITS-1:0]                 rs_mult_idx;
  logic         [NUM_UNITS-1:0][EU_CTL_LEN-1:0] rs_mult_ctl;
  logic         [NUM_UNITS-1:0][      XLEN-1:0] rs_mult_rs1_value;
  logic         [NUM_UNITS-1:0][      XLEN-1:0] rs_mult_rs2_value;
  rs_idx_t      [NUM_UNITS-1:0]                 mult_rs_idx;
  logic         [NUM_UNITS-1:0][      XLEN-1:0] mult_rs_result;
  logic         [NUM_UNITS-1:0]                 mult_rs_except_raised;
  except_code_t [NUM_UNITS-1:0]                 mult_rs_except_code;


  generate
    if (Len5Cfg.LEN5_MULT_SERIAL) begin : gen_serial_mult_unit

      // serial multiplier
      // MULT reservation station
      // -----------------------
      arith_rs #(
        .Len5Cfg(Len5Cfg),
        .EU     (expipe_pkg::EU_INT_MULT)
      ) u_mult_rs (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .flush_i             (flush_i),
        .issue_valid_i       (issue_valid_i),
        .issue_ready_o       (issue_ready_o),
        .issue_eu_ctl_i      (issue_eu_ctl_i),
        .issue_rs1_i         (issue_rs1_i),
        .issue_rs2_i         (issue_rs2_i),
        .issue_dest_rob_idx_i(issue_dest_rob_idx_i),
        .cdb_ready_i         (cdb_ready_i),
        .cdb_valid_i         (cdb_valid_i),
        .cdb_valid_o         (cdb_valid_o),
        .cdb_data_i          (cdb_data_i),
        .cdb_data_o          (cdb_data_o),
        .eu_ready_i          (mult_rs_ready),
        .eu_valid_i          (mult_rs_valid),
        .eu_valid_o          (rs_mult_valid),
        .eu_ready_o          (rs_mult_ready),
        .eu_rs_idx_i         (mult_rs_idx),
        .eu_result_i         (mult_rs_result),
        .eu_except_raised_i  (mult_rs_except_raised),
        .eu_except_code_i    (mult_rs_except_code),
        .eu_ctl_o            (rs_mult_ctl),
        .eu_rs1_o            (rs_mult_rs1_value),
        .eu_rs2_o            (rs_mult_rs2_value),
        .eu_rs_idx_o         (rs_mult_idx)
      );
      for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_sermult

        sermult #(
          .Len5Cfg(Len5Cfg)
        ) u_mult (
          .clk_i          (clk_i),
          .rst_ni         (rst_ni),
          .flush_i        (flush_i),
          .valid_i        (rs_mult_valid[u] && mult_rs_ready[u]),
          .ready_i        (rs_mult_ready[u]),
          .valid_o        (mult_rs_valid[u]),
          .ready_o        (mult_rs_ready[u]),
          .ctl_i          (rs_mult_ctl[u]),
          .rs_idx_i       (rs_mult_idx[u]),
          .rs1_value_i    (rs_mult_rs1_value[u]),
          .rs2_value_i    (rs_mult_rs2_value[u]),
          .rs_idx_o       (mult_rs_idx[u]),
          .result_o       (mult_rs_result[u]),
          .except_raised_o(mult_rs_except_raised[u]),
          .except_code_o  (mult_rs_except_code[u])
        );
      end

    end else begin : gen_parallel_mult_unit

      // pipelined multiplier
      // MULT reservation station
      // -----------------------
      arith_rs #(
        .Len5Cfg(Len5Cfg),
        .EU     (expipe_pkg::EU_INT_MULT)
      ) u_mult_rs (
        .clk_i               (clk_i),
        .rst_ni              (rst_ni),
        .flush_i             (flush_i),
        .issue_valid_i       (issue_valid_i),
        .issue_ready_o       (issue_ready_o),
        .issue_eu_ctl_i      (issue_eu_ctl_i),
        .issue_rs1_i         (issue_rs1_i),
        .issue_rs2_i         (issue_rs2_i),
        .issue_dest_rob_idx_i(issue_dest_rob_idx_i),
        .cdb_ready_i         (cdb_ready_i),
        .cdb_valid_i         (cdb_valid_i),
        .cdb_valid_o         (cdb_valid_o),
        .cdb_data_i          (cdb_data_i),
        .cdb_data_o          (cdb_data_o),
        .eu_ready_i          (mult_rs_ready),
        .eu_valid_i          (mult_rs_valid),
        .eu_valid_o          (rs_mult_valid),
        .eu_ready_o          (rs_mult_ready),
        .eu_rs_idx_i         (mult_rs_idx),
        .eu_result_i         (mult_rs_result),
        .eu_except_raised_i  (mult_rs_except_raised),
        .eu_except_code_i    (mult_rs_except_code),
        .eu_ctl_o            (rs_mult_ctl),
        .eu_rs1_o            (rs_mult_rs1_value),
        .eu_rs2_o            (rs_mult_rs2_value),
        .eu_rs_idx_o         (rs_mult_idx)
      );
      for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_mult

        mult #(
          .Len5Cfg(Len5Cfg)
        ) u_mult (
          .clk_i          (clk_i),
          .rst_ni         (rst_ni),
          .flush_i        (flush_i),
          .valid_i        (rs_mult_valid[u]),
          .ready_i        (rs_mult_ready[u]),
          .valid_o        (mult_rs_valid[u]),
          .ready_o        (mult_rs_ready[u]),
          .ctl_i          (rs_mult_ctl[u]),
          .rs_idx_i       (rs_mult_idx[u]),
          .rs1_value_i    (rs_mult_rs1_value[u]),
          .rs2_value_i    (rs_mult_rs2_value[u]),
          .rs_idx_o       (mult_rs_idx[u]),
          .result_o       (mult_rs_result[u]),
          .except_raised_o(mult_rs_except_raised[u]),
          .except_code_o  (mult_rs_except_code[u])
        );
      end
    end
  endgenerate
endmodule
