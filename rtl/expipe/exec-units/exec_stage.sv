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
// File: exec_stage.sv
// Author: Michele Caon, Walid Walid, Flavia Guella
// Date: 17/11/2021
module exec_stage #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
    localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
    localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg)
) (
    // Clock, reset, and flush
    input logic clk_i,
    input logic rst_ni,
    input logic mis_flush_i,
    input logic except_flush_i,

    // Fetch stage
    input  logic                                        fe_pcgen_ready_i,
    output logic                                        fe_bpu_valid_o,
    output logic                                        fe_pcgen_valid_o,
    output fetch_pkg::resolution_t                      fe_res_o,
    output logic                                        fe_call_confirm_o,
    output logic                                        fe_ret_confirm_o,
    output logic                   [len5_pkg::ALEN-1:0] fe_link_addr_o,

    // Candidate requests determine routing/readiness; valid lanes are final grants.
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_req_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
    input expipe_pkg::issue_eu_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_assigned_eu_i,
    input expipe_pkg::eu_ctl_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_eu_ctl_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][csr_pkg::FCSR_FRM_LEN-1:0] issue_frm_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs3_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_imm_value_i,
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rob_idx_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_curr_pc_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_pred_target_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_pred_taken_i,
    // RS readiness mapped back to the original issue lanes, independently of grants.
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_ready_o,
    output logic issue_mis_o,

    // COMMON DATA BUS (CDB)
    input  logic      [Len5Cfg.MAX_EU_N-1:0] cdb_ready_i,  // from the CDB arbiter
    input  logic                             cdb_valid_i,  // CDB data is valid
    output logic      [Len5Cfg.MAX_EU_N-1:0] cdb_valid_o,  // to the CDB arbiter
    input  cdb_data_t                        cdb_data_i,
    output cdb_data_t [Len5Cfg.MAX_EU_N-1:0] cdb_data_o,

    // ROB AND CSRs
    input  logic     comm_sb_mem_clear_i,  // store is clear to execute
    output rob_idx_t comm_sb_mem_idx_o,    // executing store ROB index

    input logic [csr_pkg::FCSR_FRM_LEN-1:0] csr_frm_i,  // global rounding mode for the FPU

    // MEMORY SYSTEM
    // -------------
    output logic mem_load_valid_o,
    input logic mem_load_ready_i,
    input logic mem_load_valid_i,
    output logic mem_load_ready_o,
    output logic mem_load_we_o,
    output logic [len5_pkg::XLEN-1:0] mem_load_addr_o,
    output logic [7:0] mem_load_be_o,
    output logic [Len5Cfg.BUFF_IDX_LEN-1:0] mem_load_tag_o,
    input logic [len5_pkg::XLEN-1:0] mem_load_rdata_i,
    input logic [Len5Cfg.BUFF_IDX_LEN-1:0] mem_load_tag_i,
    input logic mem_load_except_raised_i,
    input len5_pkg::except_code_t mem_load_except_code_i,

    output logic mem_store_valid_o,
    input logic mem_store_ready_i,
    input logic mem_store_valid_i,
    output logic mem_store_ready_o,
    output logic mem_store_we_o,
    output logic [len5_pkg::XLEN-1:0] mem_store_addr_o,
    output logic [7:0] mem_store_be_o,
    output logic [len5_pkg::XLEN-1:0] mem_store_wdata_o,
    output logic [Len5Cfg.BUFF_IDX_LEN-1:0] mem_store_tag_o,
    input logic [Len5Cfg.BUFF_IDX_LEN-1:0] mem_store_tag_i,
    input logic mem_store_except_raised_i,
    input len5_pkg::except_code_t mem_store_except_code_i
);

  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  import fetch_pkg::*;
  import memory_pkg::*;

  localparam int unsigned IssueIdxLen = Len5Cfg.ISSUE_WIDTH > 1 ? $clog2(Len5Cfg.ISSUE_WIDTH) : 1;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs_valid, rs_ready, mapped_ready;
  expipe_pkg::eu_ctl_t [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs_eu_ctl;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0][csr_pkg::FCSR_FRM_LEN-1:0] rs_frm;
  op_data_t [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs1;
  op_data_t [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs2;
  op_data_t [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs3;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rs_imm_value;
  rob_idx_t [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs_rob_idx;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rs_curr_pc;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rs_pred_target;
  logic [Len5Cfg.MAX_EU_N-1:0][Len5Cfg.ISSUE_WIDTH-1:0] rs_pred_taken;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] memory_lane, older_memory;
  logic lb_ready, sb_ready, branch_ready;
  expipe_pkg::ldst_width_t memory_type;
  op_data_t memory_rs1;
  op_data_t memory_rs2;
  logic [len5_pkg::XLEN-1:0] memory_imm;
  rob_idx_t memory_rob_idx;

//%TODO remove when redoing the LSU(LOAD AND STORE UNIT)
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_memory_order
    assign memory_lane[i] = issue_req_i[i] &&
        (issue_assigned_eu_i[i] inside {EU_LOAD_BUFFER, EU_STORE_BUFFER});
    if (i == 0) begin : gen_first
      assign older_memory[i] = 1'b0;
    end else begin : gen_younger
      assign older_memory[i] = |memory_lane[i-1:0];
    end
  end

  // Rank candidates before granting so readiness cannot feed back through grants.
  for (genvar u = 0; u < Len5Cfg.MAX_EU_N; u++) begin : gen_route
    logic [Len5Cfg.ISSUE_WIDTH-1:0] request, route_valid;
    logic [Len5Cfg.ISSUE_WIDTH-1:0][IssueIdxLen-1:0] lane_idx;

    for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_requests
      assign request[i] = issue_req_i[i] && !mis_flush_i && int'(issue_assigned_eu_i[i]) == u;
    end

    // Lane zero is oldest, so select the lowest matching lane indices first.
    prio_enc_multi #(
        .N(Len5Cfg.ISSUE_WIDTH),
        .NUM_RESULTS(Len5Cfg.ISSUE_WIDTH),
        .INV(1'b1)
    ) u_lane_sel (
        .lines_i(request),
        .enc_o(lane_idx),
        .valid_o(route_valid)
    );

    always_comb begin : ready_demux
      mapped_ready[u] = '0;
      foreach (lane_idx[k]) begin
        if (route_valid[k]) mapped_ready[u][lane_idx[k]] = rs_ready[u][k];
      end
    end

    // Ordered grants preserve candidate slots for every accepted instruction.
    for (genvar k = 0; k < Len5Cfg.ISSUE_WIDTH; k++) begin : gen_payload
      assign rs_valid[u][k] = route_valid[k] && issue_valid_i[lane_idx[k]] &&
          (!memory_lane[lane_idx[k]] || !older_memory[lane_idx[k]]);
      assign rs_eu_ctl[u][k] = issue_eu_ctl_i[lane_idx[k]];
      assign rs_frm[u][k] = issue_frm_i[lane_idx[k]];
      assign rs1[u][k] = issue_rs1_i[lane_idx[k]];
      assign rs2[u][k] = issue_rs2_i[lane_idx[k]];
      assign rs3[u][k] = issue_rs3_i[lane_idx[k]];
      assign rs_imm_value[u][k] = issue_imm_value_i[lane_idx[k]];
      assign rs_rob_idx[u][k] = issue_rob_idx_i[lane_idx[k]];
      assign rs_curr_pc[u][k] = issue_curr_pc_i[lane_idx[k]];
      assign rs_pred_target[u][k] = issue_pred_target_i[lane_idx[k]];
      assign rs_pred_taken[u][k] = issue_pred_taken_i[lane_idx[k]];
    end
  end

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_issue_ready
    assign issue_ready_o[i] = mapped_ready[issue_assigned_eu_i[i]][i] &&
        (!memory_lane[i] || !older_memory[i]);
  end

  // Loads and stores share one insertion slot: their dependency snapshots
  // must not observe simultaneous insertion of another memory instruction.
  assign rs_ready[EU_LOAD_BUFFER] = {{Len5Cfg.ISSUE_WIDTH-1{1'b0}}, lb_ready && !mis_flush_i};
  assign rs_ready[EU_STORE_BUFFER] = {{Len5Cfg.ISSUE_WIDTH-1{1'b0}}, sb_ready && !mis_flush_i};
  assign memory_type = rs_valid[EU_STORE_BUFFER][0] ? rs_eu_ctl[EU_STORE_BUFFER][0].lsu : rs_eu_ctl[EU_LOAD_BUFFER][0].lsu;
  assign memory_rs1 = rs_valid[EU_STORE_BUFFER][0] ? rs1[EU_STORE_BUFFER][0] : rs1[EU_LOAD_BUFFER][0];
  assign memory_rs2 = rs_valid[EU_STORE_BUFFER][0] ? rs2[EU_STORE_BUFFER][0] : rs2[EU_LOAD_BUFFER][0];
  assign memory_imm = rs_valid[EU_STORE_BUFFER][0] ? rs_imm_value[EU_STORE_BUFFER][0] : rs_imm_value[EU_LOAD_BUFFER][0];
  assign memory_rob_idx = rs_valid[EU_STORE_BUFFER][0] ? rs_rob_idx[EU_STORE_BUFFER][0] : rs_rob_idx[EU_LOAD_BUFFER][0];

  // ---------------
  // LOAD/STORE UNIT
  // ---------------
  load_store_unit #(
      .Len5Cfg(Len5Cfg)
  ) u_load_store_unit (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .mis_flush_i         (mis_flush_i),
      .except_flush_i      (except_flush_i),
      .issue_lb_valid_i    (rs_valid[EU_LOAD_BUFFER][0]),
      .issue_sb_valid_i    (rs_valid[EU_STORE_BUFFER][0]),
      .issue_lb_ready_o    (lb_ready),
      .issue_sb_ready_o    (sb_ready),
      .issue_type_i        (memory_type),
      .issue_rs1_i         (memory_rs1),
      .issue_rs2_i         (memory_rs2),
      .issue_imm_i         (memory_imm),
      .issue_dest_rob_idx_i (memory_rob_idx),
      .comm_sb_mem_clear_i (comm_sb_mem_clear_i),
      .comm_sb_mem_idx_o   (comm_sb_mem_idx_o),
      .cdb_valid_i         (cdb_valid_i),
      .cdb_lb_ready_i      (cdb_ready_i[EU_LOAD_BUFFER]),
      .cdb_sb_ready_i      (cdb_ready_i[EU_STORE_BUFFER]),
      .cdb_lb_valid_o      (cdb_valid_o[EU_LOAD_BUFFER]),
      .cdb_sb_valid_o      (cdb_valid_o[EU_STORE_BUFFER]),
      .cdb_data_i          (cdb_data_i),
      .cdb_lb_data_o       (cdb_data_o[EU_LOAD_BUFFER]),
      .cdb_sb_data_o       (cdb_data_o[EU_STORE_BUFFER]),

      .mem_load_valid_o        (mem_load_valid_o),
      .mem_load_ready_i        (mem_load_ready_i),
      .mem_load_valid_i        (mem_load_valid_i),
      .mem_load_ready_o        (mem_load_ready_o),
      .mem_load_we_o           (mem_load_we_o),
      .mem_load_be_o           (mem_load_be_o),
      .mem_load_addr_o         (mem_load_addr_o),
      .mem_load_rdata_i        (mem_load_rdata_i),
      .mem_load_tag_o          (mem_load_tag_o),
      .mem_load_tag_i          (mem_load_tag_i),
      .mem_load_except_raised_i(mem_load_except_raised_i),
      .mem_load_except_code_i  (mem_load_except_code_i),

      .mem_store_valid_o        (mem_store_valid_o),
      .mem_store_ready_i        (mem_store_ready_i),
      .mem_store_valid_i        (mem_store_valid_i),
      .mem_store_ready_o        (mem_store_ready_o),
      .mem_store_be_o           (mem_store_be_o),
      .mem_store_we_o           (mem_store_we_o),
      .mem_store_addr_o         (mem_store_addr_o),
      .mem_store_tag_o          (mem_store_tag_o),
      .mem_store_wdata_o        (mem_store_wdata_o),
      .mem_store_tag_i          (mem_store_tag_i),
      .mem_store_except_raised_i(mem_store_except_raised_i),
      .mem_store_except_code_i  (mem_store_except_code_i)
  );

  // -----------
  // BRANCH UNIT
  // -----------
  assign rs_ready[EU_BRANCH_UNIT] = {{Len5Cfg.ISSUE_WIDTH-1{1'b0}}, branch_ready && !mis_flush_i};

  branch_unit #(
      .Len5Cfg(Len5Cfg)
  ) u_branch_unit (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .flush_i             (mis_flush_i),
      .fe_pcgen_ready_i    (fe_pcgen_ready_i),
      .fe_bpu_valid_o      (fe_bpu_valid_o),
      .fe_pcgen_valid_o    (fe_pcgen_valid_o),
      .fe_res_o            (fe_res_o),
      .fe_call_confirm_o   (fe_call_confirm_o),
      .fe_ret_confirm_o    (fe_ret_confirm_o),
      .fe_link_addr_o      (fe_link_addr_o),
      .issue_valid_i       (rs_valid[EU_BRANCH_UNIT][0]),
      .issue_ready_o       (branch_ready),
      .issue_branch_type_i (rs_eu_ctl[EU_BRANCH_UNIT][0].bu),
      .issue_rs1_i         (rs1[EU_BRANCH_UNIT][0]),
      .issue_rs2_i         (rs2[EU_BRANCH_UNIT][0]),
      .issue_imm_value_i   (rs_imm_value[EU_BRANCH_UNIT][0]),
      .issue_dest_rob_idx_i (rs_rob_idx[EU_BRANCH_UNIT][0]),
      .issue_curr_pc_i     (rs_curr_pc[EU_BRANCH_UNIT][0]),
      .issue_pred_target_i (rs_pred_target[EU_BRANCH_UNIT][0]),
      .issue_pred_taken_i  (rs_pred_taken[EU_BRANCH_UNIT][0]),
      .issue_mis_o         (issue_mis_o),
      .cdb_ready_i         (cdb_ready_i[EU_BRANCH_UNIT]),
      .cdb_valid_i         (cdb_valid_i),
      .cdb_valid_o         (cdb_valid_o[EU_BRANCH_UNIT]),
      .cdb_data_i          (cdb_data_i),
      .cdb_data_o          (cdb_data_o[EU_BRANCH_UNIT])
  );

  // ------------------------
  // INTEGER ARITHMETIC UNITS
  // ------------------------

  // Integer ALU
  // -----------
  alu_unit #(
      .Len5Cfg(Len5Cfg)
  ) u_alu_unit (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .flush_i             (mis_flush_i),
      .issue_valid_i       (rs_valid[EU_INT_ALU]),
      .issue_ready_o       (rs_ready[EU_INT_ALU]),
      .issue_eu_ctl_i      (rs_eu_ctl[EU_INT_ALU]),
      .issue_rs1_i         (rs1[EU_INT_ALU]),
      .issue_rs2_i         (rs2[EU_INT_ALU]),
      .issue_dest_rob_idx_i (rs_rob_idx[EU_INT_ALU]),
      .cdb_ready_i         (cdb_ready_i[EU_INT_ALU]),
      .cdb_valid_i         (cdb_valid_i),
      .cdb_valid_o         (cdb_valid_o[EU_INT_ALU]),
      .cdb_data_i          (cdb_data_i),
      .cdb_data_o          (cdb_data_o[EU_INT_ALU])
  );

  // Integer multiplier and divider
  // ------------------------------
  // Multiplier
  generate
    if (Len5Cfg.LEN5_M_EN) begin : gen_mult_unit  // TODO: unify flags and units
      mult_unit #(
          .Len5Cfg(Len5Cfg)
      ) u_mult_unit (
          .clk_i               (clk_i),
          .rst_ni              (rst_ni),
          .flush_i             (mis_flush_i),
          .issue_valid_i       (rs_valid[EU_INT_MULT]),
          .issue_ready_o       (rs_ready[EU_INT_MULT]),
          .issue_eu_ctl_i      (rs_eu_ctl[EU_INT_MULT]),
          .issue_rs1_i         (rs1[EU_INT_MULT]),
          .issue_rs2_i         (rs2[EU_INT_MULT]),
          .issue_dest_rob_idx_i (rs_rob_idx[EU_INT_MULT]),
          .cdb_ready_i         (cdb_ready_i[EU_INT_MULT]),
          .cdb_valid_i         (cdb_valid_i),
          .cdb_valid_o         (cdb_valid_o[EU_INT_MULT]),
          .cdb_data_i          (cdb_data_i),
          .cdb_data_o          (cdb_data_o[EU_INT_MULT])
      );
    end else begin : gen_no_mult_unit
      assign rs_ready[EU_INT_MULT] = '0;
      assign cdb_valid_o[EU_INT_MULT]   = 1'b0;
      assign cdb_data_o[EU_INT_MULT]    = '0;
    end
  endgenerate

  // Divider
  generate
    if (Len5Cfg.LEN5_DIV_EN) begin : gen_div_unit
      div_unit #(
          .Len5Cfg(Len5Cfg)
      ) u_div_unit (
          .clk_i               (clk_i),
          .rst_ni              (rst_ni),
          .flush_i             (mis_flush_i),
          .issue_valid_i       (rs_valid[EU_INT_DIV]),
          .issue_ready_o       (rs_ready[EU_INT_DIV]),
          .issue_eu_ctl_i      (rs_eu_ctl[EU_INT_DIV]),
          .issue_rs1_i         (rs1[EU_INT_DIV]),
          .issue_rs2_i         (rs2[EU_INT_DIV]),
          .issue_dest_rob_idx_i (rs_rob_idx[EU_INT_DIV]),
          .cdb_ready_i         (cdb_ready_i[EU_INT_DIV]),
          .cdb_valid_i         (cdb_valid_i),
          .cdb_valid_o         (cdb_valid_o[EU_INT_DIV]),
          .cdb_data_i          (cdb_data_i),
          .cdb_data_o          (cdb_data_o[EU_INT_DIV])
      );
    end else begin : gen_no_div_unit
      assign rs_ready[EU_INT_DIV] = '0;
      assign cdb_valid_o[EU_INT_DIV]   = 1'b0;
      assign cdb_data_o[EU_INT_DIV]    = '0;
    end
  endgenerate

  // -------------------
  // FLOATING-POINT UNIT
  // -------------------
  generate
    if (Len5Cfg.LEN5_D_EN | Len5Cfg.LEN5_F_EN) begin : gen_fp_unit
      fpu_unit #(
          .Len5Cfg(Len5Cfg)
      ) u_fpu_unit (
          .clk_i               (clk_i),
          .rst_ni              (rst_ni),
          .flush_i             (mis_flush_i),
          .issue_valid_i       (rs_valid[EU_FPU]),
          .issue_ready_o       (rs_ready[EU_FPU]),
          .issue_eu_ctl_i      (rs_eu_ctl[EU_FPU]),
          .issue_frm_i         (rs_frm[EU_FPU]),
          .issue_rs1_i         (rs1[EU_FPU]),
          .issue_rs2_i         (rs2[EU_FPU]),
          .issue_rs3_i         (rs3[EU_FPU]),
          .issue_dest_rob_idx_i (rs_rob_idx[EU_FPU]),
          .cdb_ready_i         (cdb_ready_i[EU_FPU]),
          .cdb_valid_i         (cdb_valid_i),
          .cdb_valid_o         (cdb_valid_o[EU_FPU]),
          .cdb_data_i          (cdb_data_i),
          .cdb_data_o          (cdb_data_o[EU_FPU]),
          .csr_frm_i           (csr_frm_i)
      );
    end else begin : gen_no_fpu_unit
      assign rs_ready[EU_FPU] = '0;
      assign cdb_valid_o[EU_FPU]   = 1'b0;
      assign cdb_data_o[EU_FPU]    = '0;
    end
  endgenerate

endmodule
