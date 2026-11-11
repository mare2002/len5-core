`include "len5_typedef.svh"
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
// File: arith_rs_serial.sv
// Author: Flavia Guella
// Date: 22/02/2024

/* Reservation station for multicycle/serial units.
  Handshaking protocol is the same as all units.
  The reservation station execution index is sampled when the EU accepts the instruction,
  and it is held until the instruction is completed to guarantee stable data to the EU.
*/

module arith_rs_serial #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned DEPTH = Len5Cfg.MULT_RS_DEPTH,
  localparam int unsigned EU_CTL_LEN = expipe_pkg::MAX_EU_CTL_LEN,
  localparam bit RR_ARBITER = Len5Cfg.MULT_RR_ARBITER,
  localparam int unsigned NUM_UNITS = Len5Cfg.MULT_NUM_UNITS > 0 ? Len5Cfg.MULT_NUM_UNITS : 1,
  localparam int unsigned RsIdxLen = DEPTH > 1 ? $clog2(DEPTH) : 1,
  localparam type rs_idx_t = logic [RsIdxLen-1:0]
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,


  // Ordered insertion prefix; readiness reports the available free-entry prefix.
  input  logic     [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_valid_i,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_ready_o,
  input  logic     [Len5Cfg.ISSUE_WIDTH-1:0][EU_CTL_LEN-1:0] issue_eu_ctl_i,
  input  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_rs1_i,
  input  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_rs2_i,
  input  rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_dest_rob_idx_i,

  // CDB
  input  logic      cdb_ready_i,
  input  logic      cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic      cdb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_data_o,

  // Execution unit
  input  logic                   [NUM_UNITS-1:0]                     eu_ready_i,
  input  logic                   [NUM_UNITS-1:0]                     eu_valid_i,
  output logic                   [NUM_UNITS-1:0]                     eu_valid_o,
  output logic                   [NUM_UNITS-1:0]                     eu_ready_o,
  input  rs_idx_t                [NUM_UNITS-1:0]                     eu_rs_idx_i,
  input  logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_result_i,
  input  logic                   [NUM_UNITS-1:0]                     eu_except_raised_i,
  input  len5_pkg::except_code_t [NUM_UNITS-1:0]                     eu_except_code_i,
  output logic                   [NUM_UNITS-1:0][    EU_CTL_LEN-1:0] eu_ctl_o,
  output logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_rs1_o,
  output logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_rs2_o,
  output rs_idx_t                [NUM_UNITS-1:0]                     eu_rs_idx_o
);
  // arith_rs holds one independent instruction context per serial multiplier.
  arith_rs #(
    .Len5Cfg(Len5Cfg),
    .EU     (expipe_pkg::EU_INT_MULT)
  ) u_rs (
    .*
  );
endmodule
