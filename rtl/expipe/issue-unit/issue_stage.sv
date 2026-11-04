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
// File: issue_stage.sv
// Author: Michele Caon, Flavia Guella
// Date: 17/11/2021

module issue_stage #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
    localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
    localparam type issue_count_t = `LEN5_ISSUE_COUNT_T(Len5Cfg)
) (
    // Clock, reset, and flush
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Fetch unit
    input logic fetch_valid_i,
    output logic fetch_ready_o,
    input logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_valid_instr_i,
    input logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0][len5_pkg::ILEN-1:0] fetch_instr_i,
    input fetch_pkg::prediction_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_pred_i,
    input logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_except_raised_i,
    input len5_pkg::except_code_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_except_code_i,
    output logic fetch_mis_flush_o,

    // Integer register status register
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_valid_o,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_rs1_busy_i,  // rs1 value is in the ROB or has to be computed
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_rs1_rob_idx_i,  // the index of the ROB where the result is found
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_rs2_busy_i,  // rs1 value is in the ROB or has to be computed
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_rs2_rob_idx_i,  // the index of the ROB where the result is found
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] int_regstat_rd_idx_o,  // destination register of the issuing instruction
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] int_regstat_rob_idx_o,  // allocated ROB index
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] int_regstat_rs1_idx_o,  // first source register index
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] int_regstat_rs2_idx_o,  // second source register index

    // Integer register file
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] intrf_rs1_value_i,  // value of the first operand
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] intrf_rs2_value_i,  // value of the second operand
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] intrf_rs1_idx_o,  // RF address of the first operand
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] intrf_rs2_idx_o,  // RF address of the second operand

    // Floating-point register status register
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_valid_o,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs1_busy_i,  // rs1 value is in the ROB or has to be computed
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs1_rob_idx_i,  // the index of the ROB where the result is found
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs2_busy_i,  // rs2 value is in the ROB or has to be computed
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs2_rob_idx_i,  // the index of the ROB where the result is found
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs3_busy_i,  // rs3 value is in the ROB or has to be computed
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rs3_rob_idx_i,  // the index of the ROB where the result is found
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fp_regstat_rd_idx_o,  // destination register of the issuing instruction
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] fp_regstat_rob_idx_o,  // allocated ROB index
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fp_regstat_rs1_idx_o,  // first source register index
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fp_regstat_rs2_idx_o,  // second source register index
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fp_regstat_rs3_idx_o,  // third source register index

    // Floating-point register file data
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] fprf_rs1_value_i,  // value of the first operand
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] fprf_rs2_value_i,  // value of the second operand
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] fprf_rs3_value_i,  // value of the third operand
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fprf_rs1_idx_o,  // RF address of the first operand
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fprf_rs2_idx_o,  // RF address of the second operand
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] fprf_rs3_idx_o,  // RF address of the third operand

    // Execution pipeline
    input logic [Len5Cfg.MAX_EU_N-1:0] ex_ready_i,  // ready signal from each reservation station
    input logic ex_mis_i,  // misprediction from the branch unit
    output logic [Len5Cfg.MAX_EU_N-1:0] ex_valid_o,  // valid signal to each reservation station
    output expipe_pkg::eu_ctl_t ex_eu_ctl_o,  // controls for the associated EU
    output logic [csr_pkg::FCSR_FRM_LEN-1:0] ex_frm_o,  // rounding mode for the FPU
    output op_data_t ex_rs1_o,
    output op_data_t ex_rs2_o,
    output op_data_t ex_rs3_o,  //TODO: include this as an input in the exe stage and manage it
    output logic [len5_pkg::XLEN-1:0] ex_imm_value_o,  // the value of the immediate field (for st and branches)
    output rob_idx_t ex_rob_idx_o,  // the location of the ROB assigned to the instruction
    output logic [len5_pkg::XLEN-1:0] ex_curr_pc_o,  // the PC of the current issuing instr (branches only)
    output logic [len5_pkg::XLEN-1:0] ex_pred_target_o,  // predicted target of the current issuing branch instr
    output logic ex_pred_taken_o,  // predicted taken bit of the current issuing branch instr

    // Commit stage
    input logic comm_ready_i,  // the ROB has an empty entry available
    output logic comm_valid_o,  // a new instruction can be issued
    input logic comm_resume_i,  // resume after stall
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_tail_idx_i,  // the entry of the ROB allocated for the new instr
    output expipe_pkg::rob_entry_t comm_data_o,  // data to the ROB
    // Operand forwarding after same-bundle dependency resolution
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs1_rob_idx_o,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs1_ready_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] comm_rs1_value_i,
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs2_rob_idx_o,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs2_ready_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] comm_rs2_value_i,
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs3_rob_idx_o,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] comm_rs3_ready_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] comm_rs3_value_i,

    // CSRs
    input csr_pkg::csr_priv_t csr_priv_mode_i,  // current privilege mode
    input logic               csr_fp_enabled_i
);

  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  // INTERNAL SIGNALS
  // ----------------
  // Issue register data type
  typedef struct packed {
    logic [XLEN-1:0]                  curr_pc;
    instr_t                           instr;
    issue_type_t                      issue_type;
    issue_dispatch_t                  dispatch;
    logic                             skip_eu;
    issue_eu_t                        assigned_eu;
    rs1_sel_t                         rs1_sel;
    logic [REG_IDX_LEN-1:0]           rs1_idx;
    rs2_sel_t                         rs2_sel;
    logic [REG_IDX_LEN-1:0]           rs2_idx;
    rs3_sel_t                         rs3_sel;
    logic [REG_IDX_LEN-1:0]           rs3_idx;
    logic [XLEN-1:0]                  imm_value;
    logic [REG_IDX_LEN-1:0]           rd_idx;
    logic                             rd_upd;
    eu_ctl_t                          eu_ctl;
    logic [csr_pkg::FCSR_FRM_LEN-1:0] frm;
    logic                             mem_crit;
    logic                             order_crit;
    logic                             pred_taken;
    logic [XLEN-1:0]                  pred_target;
    logic                             except_raised;  // fetch exception; decode exceptions are in issue_type
    except_code_t                     except_code;
  } issue_reg_t;

  // Fetch stage <--> issue queue
  iq_entry_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] new_instr;

  // Issue queue <--> parallel decoders
  iq_entry_t [Len5Cfg.ISSUE_WIDTH-1:0] iq_data_out;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] iq_valid, iq_accepted;
  issue_count_t iq_pop_count;

  // Ordered decoded instructions; only lane zero dispatches in this stage.
  issue_reg_t [Len5Cfg.ISSUE_WIDTH-1:0] ireg_data_in, ireg_data_q, ireg_data_d;
  issue_reg_t ireg_data_out_unused;
  issue_count_t ireg_count_q, ireg_count_d, ireg_pop_count, retained_count;
  logic serialize_q, serialize_d, serialize_hold;
  issue_count_t refill_space;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] serializing, id_stall;

  // Issue queue <--> issue logic
  logic                                cu_iq_ready;
  logic                                iq_cu_except_raised;

  // Issue logic <--> CU
  logic                                iq_cu_valid;
  logic                                iq_flush;
  logic                                cu_mis_flush;
  logic                                cu_il_res_ready;
  logic                                cu_il_res_sel_rs1;
  logic                                cu_il_ex_valid;
  logic                                il_cu_ex_ready;

  // CU <--> execution stage
  logic         [Len5Cfg.MAX_EU_N-1:0] ex_valid;

  // Operand fetch
  rob_idx_t rs1_rob_idx, rs2_rob_idx, rs3_rob_idx;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_grant, ireg_valid;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] operand_csr, dependency_stall_unused;
  issue_dispatch_t [Len5Cfg.ISSUE_WIDTH-1:0] operand_dispatch;
  rs1_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] operand_rs1_sel;
  rs2_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] operand_rs2_sel;
  rs3_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] operand_rs3_sel;
  logic [Len5Cfg.ISSUE_WIDTH-1:0][XLEN-1:0] direct_result;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_base, rs2_base, rs3_base;
  // Forwarding queries use resolved tags; bundle producers bypass the old tag contents.
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_resolved, rs2_resolved, rs3_resolved;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_bundle, rs2_bundle, rs3_bundle;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_fwd_en, rs2_fwd_en, rs3_fwd_en;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_forwarded_unused, rs2_forwarded_unused, rs3_forwarded_unused;
  logic unused_int_regstat_valid, unused_fp_regstat_valid;
  logic rs1_ready, rs2_ready, rs3_ready;
  logic [XLEN-1:0] rs1_value, rs2_value, rs3_value;

  // -------
  // MODULES
  // -------
  //                              /  ISSUE REGISTER  \.
  // fetch stage > ISSUE QUEUE > {   ISSUE DECODER    } > execution/commit
  //                              \     ISSUE CU     /
  //                               \ OPERANDS FETCH /

  // ISSUE FIFO QUEUE
  // ----------------
  // Assemble new queue entry with the data from the fetch unit

  assign iq_flush = flush_i | cu_mis_flush;
  for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_new_instr_bundle
    assign new_instr[i].curr_pc       = fetch_pred_i[i].pc;
    assign new_instr[i].instruction   = fetch_instr_i[i];
    assign new_instr[i].pred_target   = fetch_pred_i[i].target;
    assign new_instr[i].pred_taken    = fetch_pred_i[i].hit & fetch_pred_i[i].taken;
    assign new_instr[i].except_raised = fetch_except_raised_i[i];
    assign new_instr[i].except_code   = fetch_except_code_i[i];
  end
  issue_queue #(
      .Len5Cfg(Len5Cfg)
  ) u_issue_queue (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (iq_flush),
      .fetch_valid_i      (fetch_valid_i),
      .fetch_valid_instr_i(fetch_valid_instr_i),
      .issue_accepted_i   (iq_accepted),
      .issue_pop_count_o  (iq_pop_count),
      .issue_valid_o      (iq_valid),
      .fetch_ready_o      (fetch_ready_o),
      .push_instr_i       (new_instr),
      .pop_instr_o        (iq_data_out)
  );

  // PARALLEL DECODERS
  // -----------------
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_decoders
    // Instruction data
    logic [REG_IDX_LEN-1:0] instr_rs1_idx, instr_rs2_idx, instr_rs3_idx, instr_rd_idx;
    logic      [                  FUNCT3_LEN-1:0] instr_frm;
    logic      [                        XLEN-1:0] instr_imm_i_value;
    logic      [                        XLEN-1:0] instr_imm_s_value;
    logic      [                        XLEN-1:0] instr_imm_b_value;
    logic      [                        XLEN-1:0] instr_imm_u_value;
    logic      [                        XLEN-1:0] instr_imm_j_value;
    logic      [                        XLEN-1:0] instr_imm_rs1_value;  // for CSR immediate instr.
    logic      [                        XLEN-1:0] imm_value;  // selected immediate

    // Decoder controls
    except_code_t                        id_except_code;
    imm_format_t                         id_imm_format;

    // Main instruction decoder
    issue_decoder #(
        .Len5Cfg(Len5Cfg)
    ) u_issue_decoder (
        .instruction_i(iq_data_out[i].instruction),
        .priv_mode_i  (csr_priv_mode_i),
        .fp_enabled_i (csr_fp_enabled_i),
        .issue_type_o (ireg_data_in[i].issue_type),
        .stall_o      (id_stall[i]),
        .dispatch_o   (ireg_data_in[i].dispatch),
        .except_code_o(id_except_code),
        .skip_eu_o    (ireg_data_in[i].skip_eu),
        .assigned_eu_o(ireg_data_in[i].assigned_eu),
        .eu_ctl_o     (ireg_data_in[i].eu_ctl),
        .mem_crit_o   (ireg_data_in[i].mem_crit),
        .order_crit_o (ireg_data_in[i].order_crit),
        .rs1_sel_o    (ireg_data_in[i].rs1_sel),
        .rs2_sel_o    (ireg_data_in[i].rs2_sel),
        .rs3_sel_o    (ireg_data_in[i].rs3_sel),
        .rd_upd_o     (ireg_data_in[i].rd_upd),
        .imm_format_o (id_imm_format)
    );

    // Instruction fields extraction
    assign instr_rs1_idx = iq_data_out[i].instruction.r.rs1;
    assign instr_rs2_idx = iq_data_out[i].instruction.r.rs2;
    assign instr_rd_idx = iq_data_out[i].instruction.r.rd;
    assign instr_imm_i_value = {
      {52{iq_data_out[i].instruction.i.imm11[31]}}, iq_data_out[i].instruction.i.imm11
    };
    assign instr_imm_s_value = {
      {52{iq_data_out[i].instruction.s.imm11[31]}},
      iq_data_out[i].instruction.s.imm11,
      iq_data_out[i].instruction.s.imm4
    };
    assign instr_imm_b_value = {
      {51{iq_data_out[i].instruction.b.imm12}},
      iq_data_out[i].instruction.b.imm12,
      iq_data_out[i].instruction.b.imm11,
      iq_data_out[i].instruction.b.imm10,
      iq_data_out[i].instruction.b.imm4,
      1'b0
    };
    assign instr_imm_u_value = {
      {32{iq_data_out[i].instruction.u.imm31[31]}}, iq_data_out[i].instruction.u.imm31, 12'b0
    };
    assign instr_imm_j_value = {
      {43{iq_data_out[i].instruction.j.imm20}},
      iq_data_out[i].instruction.j.imm20,
      iq_data_out[i].instruction.j.imm19,
      iq_data_out[i].instruction.j.imm11,
      iq_data_out[i].instruction.j.imm10,
      1'b0
    };
    assign instr_imm_rs1_value = {59'h0, iq_data_out[i].instruction.r.rs1};

    // RV64F-RV64D
    // rounding mode
    assign instr_frm = iq_data_out[i].instruction.r4.funct3;

    // rs3 idx, R4 format
    assign instr_rs3_idx = iq_data_out[i].instruction.r4.rs3;

    // Immediate MUX
    always_comb begin : imm_mux
      unique case (id_imm_format)
        IMM_TYPE_S:   imm_value = instr_imm_s_value;
        IMM_TYPE_B:   imm_value = instr_imm_b_value;
        IMM_TYPE_U:   imm_value = instr_imm_u_value;
        IMM_TYPE_J:   imm_value = instr_imm_j_value;
        IMM_TYPE_RS1: imm_value = instr_imm_rs1_value;
        default:      imm_value = instr_imm_i_value;
      endcase
    end

    assign ireg_data_in[i].curr_pc = iq_data_out[i].curr_pc;
    assign ireg_data_in[i].instr = iq_data_out[i].instruction;
    assign ireg_data_in[i].rs1_idx = instr_rs1_idx;
    assign ireg_data_in[i].rs2_idx = instr_rs2_idx;
    assign ireg_data_in[i].rs3_idx = instr_rs3_idx;
    assign ireg_data_in[i].imm_value = imm_value;
    assign ireg_data_in[i].rd_idx = instr_rd_idx;
    assign ireg_data_in[i].pred_taken = iq_data_out[i].pred_taken;
    assign ireg_data_in[i].pred_target = iq_data_out[i].pred_target;
    assign ireg_data_in[i].except_raised = iq_data_out[i].except_raised;
    assign ireg_data_in[i].except_code    = (iq_data_out[i].except_raised) ? iq_data_out[i].except_code : id_except_code;
    assign ireg_data_in[i].frm = instr_frm;

  end

  // ISSUE REGISTERS
  // ---------------
  assign ireg_data_out_unused = ireg_data_q[0];

  // Dispatch removes the head; FENCE/WFI also discard their stall token on resume.
  assign ireg_pop_count = issue_count_t'((comm_valid_o && comm_ready_i) ||
      (comm_resume_i && (ireg_count_q != '0) && (ireg_data_out_unused.issue_type == ISSUE_TYPE_STALL)));

  // Account for removal before admitting the next IQ entries.
  assign retained_count = ireg_count_q - ireg_pop_count;
  assign refill_space = issue_count_t'(Len5Cfg.ISSUE_WIDTH) - retained_count;
  assign ireg_count_d = retained_count + iq_pop_count;

  // A resume must not release a CSR that is still waiting for its operand.
  assign serialize_hold = serialize_q && !(comm_resume_i && cu_iq_ready &&
      ((ireg_count_q == '0) || (ireg_data_out_unused.issue_type == ISSUE_TYPE_STALL)));
  assign serialize_d = serialize_hold || (|(iq_accepted & serializing));

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_issue_registers
    logic older_serializing;

    assign serializing[i] = iq_valid[i] && (ireg_data_in[i].except_raised || id_stall[i]);

    // Accept the first serializing instruction, but none of its younger lanes.
    if (i == 0) begin : gen_first
      assign older_serializing = 1'b0;
    end else begin : gen_younger
      assign older_serializing = |serializing[i-1:0];
    end
    assign iq_accepted[i] = iq_valid[i] && (issue_count_t'(i) < refill_space) &&
        (cu_iq_ready || (ireg_count_q != '0)) && !serialize_hold && !older_serializing;

    // Retained instructions occupy the low lanes; refill follows them on the same edge.
    always_comb begin : data_mux
      ireg_data_d[i] = '0;
      if (issue_count_t'(i) < retained_count)
        ireg_data_d[i] = ireg_data_q[issue_count_t'(i) + ireg_pop_count];
      else if (issue_count_t'(i) < ireg_count_d)
        ireg_data_d[i] = ireg_data_in[issue_count_t'(i) - retained_count];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : issue_reg
    if (!rst_ni) begin
      ireg_data_q <= '0;
      ireg_count_q <= '0;
      serialize_q <= 1'b0;
    end else if (iq_flush) begin
      ireg_data_q <= '0;
      ireg_count_q <= '0;
      serialize_q <= 1'b0;
    end else begin
      ireg_data_q <= ireg_data_d;
      ireg_count_q <= ireg_count_d;
      serialize_q <= serialize_d;
    end
  end

  // The CU classifies the head that will be registered on this same edge.
  assign iq_cu_valid = |ireg_count_d;
  assign iq_cu_except_raised = ireg_data_d[0].except_raised;

  // ISSUE CU
  // --------
  // Handshaking signals arbiter
  assign il_cu_ex_ready = ex_ready_i[ireg_data_out_unused.assigned_eu] | ireg_data_out_unused.skip_eu;

  // CU
  issue_cu u_issue_cu (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .mis_flush_o        (cu_mis_flush),
      .iq_valid_i         (iq_cu_valid),
      .iq_ready_o         (cu_iq_ready),
      .iq_except_raised_i (iq_cu_except_raised),
      .issue_type_i       (ireg_data_d[0].issue_type),
      .issue_valid_i      (ireg_count_q != '0),
      .issue_dispatch_i   (ireg_data_out_unused.dispatch),
      .issue_rs1_ready_i  (rs1_ready),
      .issue_res_ready_o  (cu_il_res_ready),
      .issue_res_sel_rs1_o(cu_il_res_sel_rs1),
      .ex_ready_i         (il_cu_ex_ready),
      .ex_mis_i           (ex_mis_i),
      .ex_valid_o         (cu_il_ex_valid),
      .int_regstat_valid_o(unused_int_regstat_valid),
      .fp_regstat_valid_o (unused_fp_regstat_valid),
      .comm_ready_i       (comm_ready_i),
      .comm_valid_o       (comm_valid_o),
      .comm_resume_i      (comm_resume_i)
  );

  // Execution stage valid encoding
  always_comb begin : ex_valid_enc
    foreach (ex_valid[i]) ex_valid[i] = 1'b0;
    ex_valid[ireg_data_out_unused.assigned_eu] = cu_il_ex_valid;
  end

  // OPERANDS FETCH
  // --------------
  // Operand selection order:
  // 1) Special sources: PC or immediate (unused operands are ready/zero).
  // 2) Youngest older granted writer in the bundle (issue_dependencies).
  // 3) CDB.
  // 4) ROB.
  // 5) Commit input spill buffer (inreg_buff_data).
  // 6) Commit input register (inreg_data_out).
  // 7) Commit register (comm_reg_data).
  // 8) Architectural register file, only when the source is not busy.
  // Steps 3-7 are selected independently for each query in operand_forwarding.
  // A busy source without an available result remains unresolved for RS wakeup.
  // issue_dependencies selects step 2 before the remaining forwarding queries.

  // The scalar CU supplies the only actual grant until multi-lane arbitration is added.
  assign issue_grant = {{Len5Cfg.ISSUE_WIDTH-1{1'b0}}, comm_valid_o && comm_ready_i};

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_operand_lookup
    logic rs1_busy, rs2_busy, rs3_busy;
    op_data_t rs1_selected, rs2_selected, rs3_selected;

    assign ireg_valid[i] = issue_count_t'(i) < ireg_count_q;
    assign operand_rs1_sel[i] = ireg_data_q[i].rs1_sel;
    assign operand_rs2_sel[i] = ireg_data_q[i].rs2_sel;
    assign operand_rs3_sel[i] = ireg_data_q[i].rs3_sel;
    assign direct_result[i] = ireg_data_q[i].imm_value;
    assign operand_csr[i] = ireg_data_q[i].issue_type == ISSUE_TYPE_CSR;
    assign operand_dispatch[i].direct_result = ireg_data_q[i].dispatch.direct_result;
    assign operand_dispatch[i].int_rd_write = ireg_valid[i] && !ireg_data_q[i].except_raised &&
        ireg_data_q[i].dispatch.int_rd_write;
    assign operand_dispatch[i].fp_rd_write = ireg_valid[i] && !ireg_data_q[i].except_raised &&
        ireg_data_q[i].dispatch.fp_rd_write;
    assign int_regstat_valid_o[i] = issue_grant[i] && operand_dispatch[i].int_rd_write;
    assign fp_regstat_valid_o[i] = issue_grant[i] && operand_dispatch[i].fp_rd_write;
    assign int_regstat_rd_idx_o[i] = ireg_data_q[i].rd_idx;
    assign fp_regstat_rd_idx_o[i] = ireg_data_q[i].rd_idx;
    assign int_regstat_rob_idx_o[i] = comm_tail_idx_i[i];
    assign fp_regstat_rob_idx_o[i] = comm_tail_idx_i[i];
    assign int_regstat_rs1_idx_o[i] = ireg_data_q[i].rs1_idx;
    assign int_regstat_rs2_idx_o[i] = ireg_data_q[i].rs2_idx;
    assign intrf_rs1_idx_o[i] = ireg_data_q[i].rs1_idx;
    assign intrf_rs2_idx_o[i] = ireg_data_q[i].rs2_idx;
    assign fp_regstat_rs1_idx_o[i] = ireg_data_q[i].rs1_idx;
    assign fp_regstat_rs2_idx_o[i] = ireg_data_q[i].rs2_idx;
    assign fp_regstat_rs3_idx_o[i] = ireg_data_q[i].rs3_idx;
    assign fprf_rs1_idx_o[i] = ireg_data_q[i].rs1_idx;
    assign fprf_rs2_idx_o[i] = ireg_data_q[i].rs2_idx;
    assign fprf_rs3_idx_o[i] = ireg_data_q[i].rs3_idx;

    always_comb begin : lookup_rs1
      rs1_busy = 1'b0;
      rs1_selected = '0;
      rs1_selected.ready = 1'b1;
      rs1_selected.rob_idx = (ireg_data_q[i].rs1_sel == RS1_SEL_FP) ?
          fp_regstat_rs1_rob_idx_i[i] : int_regstat_rs1_rob_idx_i[i];
      case (ireg_data_q[i].rs1_sel)
        RS1_SEL_INT: begin
          rs1_busy = int_regstat_rs1_busy_i[i];
          rs1_selected.value = intrf_rs1_value_i[i];
        end
        RS1_SEL_FP: begin
          rs1_busy = fp_regstat_rs1_busy_i[i];
          rs1_selected.value = fprf_rs1_value_i[i];
        end
        RS1_SEL_PC: rs1_selected.value = ireg_data_q[i].curr_pc;
        default: ;
      endcase
    end

    always_comb begin : prepare_rs1
      rs1_base[i] = rs1_selected;
      if (rs1_busy) begin
        rs1_base[i].ready = 1'b0;
        rs1_base[i].value = '0;
      end
    end

    always_comb begin : lookup_rs2
      rs2_busy = 1'b0;
      rs2_selected = '0;
      rs2_selected.ready = 1'b1;
      rs2_selected.rob_idx = (ireg_data_q[i].rs2_sel == RS2_SEL_FP) ?
          fp_regstat_rs2_rob_idx_i[i] : int_regstat_rs2_rob_idx_i[i];
      case (ireg_data_q[i].rs2_sel)
        RS2_SEL_INT: begin
          rs2_busy = int_regstat_rs2_busy_i[i];
          rs2_selected.value = intrf_rs2_value_i[i];
        end
        RS2_SEL_FP: begin
          rs2_busy = fp_regstat_rs2_busy_i[i];
          rs2_selected.value = fprf_rs2_value_i[i];
        end
        RS2_SEL_IMM: rs2_selected.value = ireg_data_q[i].imm_value;
        default: ;
      endcase
    end

    always_comb begin : prepare_rs2
      rs2_base[i] = rs2_selected;
      if (rs2_busy) begin
        rs2_base[i].ready = 1'b0;
        rs2_base[i].value = '0;
      end
    end

    always_comb begin : lookup_rs3
      rs3_busy = 1'b0;
      rs3_selected = '0;
      rs3_selected.ready = 1'b1;
      rs3_selected.rob_idx = fp_regstat_rs3_rob_idx_i[i];
      case (ireg_data_q[i].rs3_sel)
        RS3_SEL_FP: begin
          rs3_busy = fp_regstat_rs3_busy_i[i];
          rs3_selected.value = fprf_rs3_value_i[i];
        end
        default: ;
      endcase
    end

    always_comb begin : prepare_rs3
      rs3_base[i] = rs3_selected;
      if (rs3_busy) begin
        rs3_base[i].ready = 1'b0;
        rs3_base[i].value = '0;
      end
    end
  end

  issue_dependencies #(.Len5Cfg(Len5Cfg)) u_issue_dependencies (
      .issue_valid_i(ireg_valid),
      .issue_grant_i(issue_grant),
      .issue_csr_i(operand_csr),
      .issue_dispatch_i(operand_dispatch),
      .issue_rd_idx_i(int_regstat_rd_idx_o),
      .issue_rob_idx_i(comm_tail_idx_i),
      .issue_result_i(direct_result),
      .rs1_sel_i(operand_rs1_sel),
      .rs2_sel_i(operand_rs2_sel),
      .rs3_sel_i(operand_rs3_sel),
      .rs1_idx_i(intrf_rs1_idx_o),
      .rs2_idx_i(intrf_rs2_idx_o),
      .rs3_idx_i(fprf_rs3_idx_o),
      .rs1_i(rs1_base),
      .rs2_i(rs2_base),
      .rs3_i(rs3_base),
      .rs1_o(rs1_resolved),
      .rs2_o(rs2_resolved),
      .rs3_o(rs3_resolved),
      .dependency_stall_o(dependency_stall_unused),
      .rs1_bundle_o(rs1_bundle),
      .rs2_bundle_o(rs2_bundle),
      .rs3_bundle_o(rs3_bundle)
  );
// %TODO check with Michele we don't need the value mux
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_forwarding
    // Same-bundle operands must not consume old ROB/CDB/buffer contents.
    assign comm_rs1_rob_idx_o[i] = rs1_resolved[i].rob_idx;
    assign rs1_fwd_en[i] = ireg_valid[i] && !iq_flush && !rs1_resolved[i].ready && !rs1_bundle[i];

    always_comb begin : forward_rs1
      rs1_forwarded_unused[i] = rs1_resolved[i];
      if (rs1_fwd_en[i]) begin
        rs1_forwarded_unused[i].ready = comm_rs1_ready_i[i];
        rs1_forwarded_unused[i].value = comm_rs1_ready_i[i] ? comm_rs1_value_i[i] : '0;
      end
    end

    assign comm_rs2_rob_idx_o[i] = rs2_resolved[i].rob_idx;
    assign rs2_fwd_en[i] = ireg_valid[i] && !iq_flush && !rs2_resolved[i].ready && !rs2_bundle[i];

    always_comb begin : forward_rs2
      rs2_forwarded_unused[i] = rs2_resolved[i];
      if (rs2_fwd_en[i]) begin
        rs2_forwarded_unused[i].ready = comm_rs2_ready_i[i];
        rs2_forwarded_unused[i].value = comm_rs2_ready_i[i] ? comm_rs2_value_i[i] : '0;
      end
    end

    assign comm_rs3_rob_idx_o[i] = rs3_resolved[i].rob_idx;
    assign rs3_fwd_en[i] = ireg_valid[i] && !iq_flush && !rs3_resolved[i].ready && !rs3_bundle[i];

    always_comb begin : forward_rs3
      rs3_forwarded_unused[i] = rs3_resolved[i];
      if (rs3_fwd_en[i]) begin
        rs3_forwarded_unused[i].ready = comm_rs3_ready_i[i];
        rs3_forwarded_unused[i].value = comm_rs3_ready_i[i] ? comm_rs3_value_i[i] : '0;
      end
    end

  end

  assign rs1_ready = rs1_forwarded_unused[0].ready;
  assign rs1_value = rs1_forwarded_unused[0].value;
  assign rs1_rob_idx = (ireg_data_out_unused.rs1_sel == RS1_SEL_FP) ?
      fp_regstat_rs1_rob_idx_i[0] : int_regstat_rs1_rob_idx_i[0];
  assign rs2_ready = rs2_forwarded_unused[0].ready;
  assign rs2_value = rs2_forwarded_unused[0].value;
  assign rs2_rob_idx = (ireg_data_out_unused.rs2_sel == RS2_SEL_FP) ?
      fp_regstat_rs2_rob_idx_i[0] : int_regstat_rs2_rob_idx_i[0];
  assign rs3_ready = rs3_forwarded_unused[0].ready;
  assign rs3_value = rs3_forwarded_unused[0].value;
  assign rs3_rob_idx = fp_regstat_rs3_rob_idx_i[0];

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Fetch stage
  assign fetch_mis_flush_o         = cu_mis_flush;

  // Data to the execution pipeline
  assign ex_valid_o                = ex_valid;
  assign ex_eu_ctl_o               = ireg_data_out_unused.eu_ctl;
  assign ex_frm_o                  = ireg_data_out_unused.frm;
  assign ex_rs1_o.ready            = rs1_ready;
  assign ex_rs1_o.rob_idx          = rs1_rob_idx;
  assign ex_rs1_o.value            = rs1_value;
  assign ex_rs2_o.ready            = rs2_ready;
  assign ex_rs2_o.rob_idx          = rs2_rob_idx;
  assign ex_rs2_o.value            = rs2_value;
  assign ex_rs3_o.ready            = rs3_ready;
  assign ex_rs3_o.rob_idx          = rs3_rob_idx;
  assign ex_rs3_o.value            = rs3_value;
  assign ex_imm_value_o            = ireg_data_out_unused.imm_value;
  assign ex_rob_idx_o              = comm_tail_idx_i[0];
  assign ex_curr_pc_o              = ireg_data_out_unused.curr_pc;
  assign ex_pred_target_o          = ireg_data_out_unused.pred_target;
  assign ex_pred_taken_o           = ireg_data_out_unused.pred_taken;

  // Data to commit stage
  assign comm_data_o.instruction   = ireg_data_out_unused.instr;
  assign comm_data_o.instr_pc      = ireg_data_out_unused.curr_pc;
  assign comm_data_o.res_ready     = cu_il_res_ready;
  assign comm_data_o.res_value     = (cu_il_res_sel_rs1) ? rs1_value : ireg_data_out_unused.imm_value;
  assign comm_data_o.rd_idx        = ireg_data_out_unused.rd_idx;
  assign comm_data_o.rd_upd        = ireg_data_out_unused.rd_upd;
  assign comm_data_o.mem_crit      = ireg_data_out_unused.mem_crit;
  assign comm_data_o.order_crit    = ireg_data_out_unused.order_crit;
  assign comm_data_o.except_raised = ireg_data_out_unused.except_raised ||
      (ireg_data_out_unused.issue_type == ISSUE_TYPE_EXCEPT);
  assign comm_data_o.except_code   = ireg_data_out_unused.except_code;
  assign comm_data_o.mem_clear     = 1'b0;
  assign comm_data_o.flags.raw     = '0;

  // ----------
  // DEBUG CODE
  // ----------
`ifndef SYNTHESIS
  always @(posedge clk_i) begin : check_issue_registers
    if (rst_ni && !iq_flush) begin
      assert (ireg_pop_count <= ireg_count_q)
      else $error("issue-register removal count is invalid");
      assert (!comm_valid_o || (ireg_count_q != '0))
      else $error("dispatch requires a registered instruction");
    end
  end
  if (Len5Cfg.ISSUE_WIDTH > 1) begin : gen_check_occupancy
    always @(posedge clk_i) begin
      if (rst_ni && !iq_flush) begin
        assert (int'(ireg_count_q) <= Len5Cfg.ISSUE_WIDTH)
        else $error("issue-register occupancy is invalid");
      end
    end
  end
`ifndef VERILATOR
  always @(posedge clk_i) begin
    if (comm_valid_o && comm_ready_i) begin
      $display(comm_data_o.instruction.raw);
    end
  end
  // Instruction sent to at most one execution unit
  property p_ex_valid;
    @(posedge clk_i) disable iff (!rst_ni) comm_valid_o |-> $onehot0(
        ex_valid_o
    );
  endproperty
  a_ex_valid :
  assert property (p_ex_valid);
`endif  /* VERILATOR */
`endif  /* SYNTHESIS */

endmodule
