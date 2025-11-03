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
// File: bpu.sv
// Author: Marco Andorno
// Date: 7/8/2019

module bpu #(
  parameter int unsigned     HLEN     = 4,
  parameter int unsigned     BTB_BITS = 4,
  parameter fetch_pkg::c2b_t INIT_C2B = fetch_pkg::WNT
) (
  input logic                                        clk_i,
  input logic                                        rst_ni,
  input logic                                        flush_i,
  input logic                   [len5_pkg::XLEN-1:0] curr_pc_i,
  input logic                                        bu_res_valid_i,
  input fetch_pkg::resolution_t                      bu_res_i,

  output fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_o
);

  import len5_pkg::*;
  import fetch_pkg::*;
  import len5_config_pkg::*;
  // Signal definitions
  logic btb_del_entry;
  logic [LEN5_MULTIPLE_ISSUES-1:0] btb_hit;
  logic [LEN5_MULTIPLE_ISSUES-1:0] gshare_taken;
  logic [LEN5_MULTIPLE_ISSUES-1:0] [XLEN-OFFSET-1:0] btb_target;

  // Gshare branch predictor
  gshare #(
    .HLEN    (HLEN),
    .INIT_C2B(INIT_C2B)
  ) u_gshare (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .flush_i    (flush_i),
    .curr_hist_i(curr_pc_i[HLEN+OFFSET-1:OFFSET+LEN5_MULTIPLE_ISSUES_BITS]),
    .res_valid_i(bu_res_valid_i),
    .res_taken_i(bu_res_i.taken),
    .res_hist_i (bu_res_i.pc[HLEN+OFFSET-1:OFFSET]),
    .taken_o    (gshare_taken)
  );

  // Branch Target Buffer (BTB)
  assign btb_del_entry = bu_res_i.mispredict & ~bu_res_i.taken;
  btb #(
    .BTB_BITS(BTB_BITS)
  ) u_btb (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .flush_i     (flush_i),
    .curr_pc_i   (curr_pc_i),
    .valid_i     (bu_res_valid_i),
    .del_entry_i (btb_del_entry),
    .res_pc_i    (bu_res_i.pc),
    .res_target_i(bu_res_i.target),
    .hit_o       (btb_hit),
    .target_o    (btb_target)
  );

  // Output network
  // --------------
  for(genvar i = 0; i<LEN5_MULTIPLE_ISSUES; i++) begin : gen_outputs_pred
    if (LEN5_MULTIPLE_ISSUES==1)begin : gen_single 
      assign pred_o[i].pc     = curr_pc_i;
    end
    else begin : gen_multiple
      assign pred_o[i].pc     = {curr_pc_i[XLEN-1:LEN5_MULTIPLE_ISSUES_BITS], i[LEN5_MULTIPLE_ISSUES_BITS-1:0]};
    end
    assign pred_o[i].hit    = btb_hit[i];
    assign pred_o[i].taken  = gshare_taken[i];
    assign pred_o[i].target = {btb_target[i], 2'b00};
  end
endmodule
