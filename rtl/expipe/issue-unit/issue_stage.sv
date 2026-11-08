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
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg)
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

  // Execution pipeline: candidate requests, per-lane readiness and granted payloads.
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] ex_ready_i,
  input logic ex_mis_i,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] ex_req_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] ex_valid_o,
  output expipe_pkg::issue_eu_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_assigned_eu_o,
  output expipe_pkg::eu_ctl_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_eu_ctl_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0][csr_pkg::FCSR_FRM_LEN-1:0] ex_frm_o,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_rs1_o,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_rs2_o,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_rs3_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] ex_imm_value_o,
  output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] ex_rob_idx_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] ex_curr_pc_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] ex_pred_target_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] ex_pred_taken_o,

  // Commit stage
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] comm_ready_i,  // the ROB has an empty entry available
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] comm_valid_o,  // a new instruction can be issued
  input logic comm_resume_i,  // resume after stall
  input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_tail_idx_i,  // the entry of the ROB allocated for the new instr
  output expipe_pkg::rob_entry_t [Len5Cfg.ISSUE_WIDTH-1:0] comm_data_o,  // data to the ROB
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

  localparam type iq_idx_t = `LEN5_IQ_IDX_T(Len5Cfg);
  localparam type iq_dep_t = `LEN5_IQ_DEP_T(Len5Cfg);
  localparam type iq_entry_t = `LEN5_IQ_ENTRY_T(Len5Cfg);

  decoded_instr_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] decoded_instr;
  logic           [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] decoded_valid_instr;
  logic decoded_valid, decoded_ready;
  iq_entry_t      [Len5Cfg.ISSUE_WIDTH-1:0] iq_data_out;
  decoded_instr_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_data;
  iq_dep_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_dep, rs2_dep, rs3_dep;
  iq_idx_t iq_head_idx;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] iq_valid, iq_accepted;
  logic iq_flush, cu_mis_flush, cu_issue_enable, cu_issue_special, cu_stall_pop;
  logic special_grant, cu_il_res_sel_rs1;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] operand_serializing, operand_skip_eu;
  // Operand fetch
  logic            [Len5Cfg.ISSUE_WIDTH-1:0]           issue_grant;
  issue_dispatch_t [Len5Cfg.ISSUE_WIDTH-1:0]           operand_dispatch;
  logic            [Len5Cfg.ISSUE_WIDTH-1:0][XLEN-1:0] direct_result;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_base, rs2_base, rs3_base;
  // Forwarding queries use resolved tags; bundle producers bypass the old tag contents.
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_resolved, rs2_resolved, rs3_resolved;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_bundle, rs2_bundle, rs3_bundle;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_fwd_en, rs2_fwd_en, rs3_fwd_en;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_forwarded, rs2_forwarded, rs3_forwarded;
  logic            rs1_ready;
  logic [XLEN-1:0] rs1_value;

  // FRONTEND -> INPUT SPILL -> DECODE -> OPTIONAL SPILL -> DECODED ISSUE QUEUE
  assign iq_flush = flush_i | cu_mis_flush;
  issue_decode #(
    .Len5Cfg(Len5Cfg)
  ) u_issue_decode (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .flush_i              (iq_flush),
    .fetch_valid_i        (fetch_valid_i),
    .fetch_ready_o        (fetch_ready_o),
    .fetch_valid_instr_i  (fetch_valid_instr_i),
    .fetch_instr_i        (fetch_instr_i),
    .fetch_pred_i         (fetch_pred_i),
    .fetch_except_raised_i(fetch_except_raised_i),
    .fetch_except_code_i  (fetch_except_code_i),
    .decoded_valid_o      (decoded_valid),
    .decoded_ready_i      (decoded_ready),
    .decoded_valid_instr_o(decoded_valid_instr),
    .decoded_instr_o      (decoded_instr)
  );
  issue_queue #(
    .Len5Cfg(Len5Cfg)
  ) u_issue_queue (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .flush_i            (iq_flush),
    .fetch_valid_i      (decoded_valid),
    .fetch_ready_o      (decoded_ready),
    .fetch_valid_instr_i(decoded_valid_instr),
    .push_instr_i       (decoded_instr),
    .issue_accepted_i   (iq_accepted),
    .issue_valid_o      (iq_valid),
    .pop_instr_o        (iq_data_out),
    .head_idx_o         (iq_head_idx)
  );

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_issue_checks
    logic privilege_illegal, fp_illegal;
    assign rs1_dep[i] = iq_data_out[i].rs1_dep;
    assign rs2_dep[i] = iq_data_out[i].rs2_dep;
    assign rs3_dep[i] = iq_data_out[i].rs3_dep;
    assign fp_illegal = iq_data_out[i].data.requires_fp && !csr_fp_enabled_i;

    // U < S < M; the reserved encoding is never a legal privilege level.
    always_comb begin : privilege_check
      case (csr_priv_mode_i)
        csr_pkg::PRIV_MODE_U, csr_pkg::PRIV_MODE_S, csr_pkg::PRIV_MODE_M:
        privilege_illegal = !(csr_priv_mode_i >= iq_data_out[i].data.required_priv) ||
            (iq_data_out[i].data.required_priv == csr_pkg::PRIV_MODE_R);
        default: privilege_illegal = 1'b1;
      endcase
    end

    always_comb begin : effective_instruction
      // Apply shared exception controls; the legal path restores the queued instruction.
      issue_data[i]               = iq_data_out[i].data;
      issue_data[i].except_raised = 1'b1;
      issue_data[i].issue_type    = ISSUE_TYPE_EXCEPT;
      issue_data[i].dispatch      = '0;
      issue_data[i].rd_upd        = 1'b0;
      issue_data[i].skip_eu       = 1'b1;
      issue_data[i].mem_crit      = 1'b1;
      issue_data[i].order_crit    = 1'b1;

      if (iq_data_out[i].data.except_raised && !iq_data_out[i].data.ecall) begin
        issue_data[i].except_code = iq_data_out[i].data.except_code;
      end else if (fp_illegal || privilege_illegal) begin
        issue_data[i].except_code = E_ILLEGAL_INSTRUCTION;
      end else if (iq_data_out[i].data.ecall) begin
        case (csr_priv_mode_i)
          csr_pkg::PRIV_MODE_U: issue_data[i].except_code = E_ENV_CALL_UMODE;
          csr_pkg::PRIV_MODE_S: issue_data[i].except_code = E_ENV_CALL_SMODE;
          default:              issue_data[i].except_code = E_ENV_CALL_MMODE;
        endcase
      end else begin
        issue_data[i] = iq_data_out[i].data;
      end
    end
  end

  // The CU observes the registered queue head, never a next-head preview.
  issue_cu u_issue_cu (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .flush_i            (flush_i),
    .mis_flush_o        (cu_mis_flush),
    .issue_type_i       (issue_data[0].issue_type),
    .issue_valid_i      (iq_valid[0]),
    .issue_accepted_i   (issue_grant[0]),
    .issue_rs1_ready_i  (rs1_ready),
    .issue_enable_o     (cu_issue_enable),
    .issue_special_o    (cu_issue_special),
    .issue_stall_pop_o  (cu_stall_pop),
    .issue_res_sel_rs1_o(cu_il_res_sel_rs1),
    .ex_mis_i           (ex_mis_i),
    .comm_resume_i      (comm_resume_i)
  );

  // A non-allocating stall token is consumed only by its own resume event.
  assign iq_accepted = issue_grant | {{(Len5Cfg.ISSUE_WIDTH-1){1'b0}}, cu_stall_pop && iq_valid[0]};
  // ISSUE GRANTS
  // ------------
  // Only the head can use the CU's serialized dispatch path.
  assign special_grant = cu_issue_special && iq_valid[0] && comm_ready_i[0];

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_grants
    logic lane_ready, granted;

    assign lane_ready = iq_valid[i] && comm_ready_i[i] && !operand_serializing[i] &&
        (operand_dispatch[i].direct_result || operand_skip_eu[i] || ex_ready_i[i]);

    // A blocked older lane prevents every younger grant.
    if (i == 0) begin : gen_head
      assign granted = (cu_issue_enable && lane_ready) || special_grant;
    end else begin : gen_younger
      assign granted = cu_issue_enable && gen_grants[i-1].granted && lane_ready;
    end
    assign issue_grant[i] = granted;
    assign ex_valid_o[i] = granted && cu_issue_enable &&
        !operand_dispatch[i].direct_result && !operand_skip_eu[i];
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

  assign comm_valid_o = issue_grant;

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_operand_lookup
    logic rs1_busy, rs2_busy, rs3_busy;
    op_data_t rs1_selected, rs2_selected, rs3_selected;

    assign operand_serializing[i] = issue_data[i].except_raised ||
        (issue_data[i].issue_type inside {ISSUE_TYPE_CSR, ISSUE_TYPE_STALL, ISSUE_TYPE_WFI, ISSUE_TYPE_EXCEPT});
    assign operand_skip_eu[i] = issue_data[i].skip_eu;
    assign ex_req_o[i] = iq_valid[i] && !operand_serializing[i] &&
        !operand_dispatch[i].direct_result && !operand_skip_eu[i];
    assign direct_result[i] = issue_data[i].imm_value;
    assign operand_dispatch[i].direct_result = issue_data[i].dispatch.direct_result;
    assign operand_dispatch[i].int_rd_write = iq_valid[i] && !issue_data[i].except_raised &&
        issue_data[i].dispatch.int_rd_write;
    assign operand_dispatch[i].fp_rd_write = iq_valid[i] && !issue_data[i].except_raised &&
        issue_data[i].dispatch.fp_rd_write;
    assign int_regstat_valid_o[i] = issue_grant[i] && operand_dispatch[i].int_rd_write;
    assign fp_regstat_valid_o[i] = issue_grant[i] && operand_dispatch[i].fp_rd_write;
    assign int_regstat_rd_idx_o[i] = issue_data[i].rd_idx;
    assign fp_regstat_rd_idx_o[i] = issue_data[i].rd_idx;
    assign int_regstat_rob_idx_o[i] = comm_tail_idx_i[i];
    assign fp_regstat_rob_idx_o[i] = comm_tail_idx_i[i];
    assign int_regstat_rs1_idx_o[i] = issue_data[i].rs1_idx;
    assign int_regstat_rs2_idx_o[i] = issue_data[i].rs2_idx;
    assign intrf_rs1_idx_o[i] = issue_data[i].rs1_idx;
    assign intrf_rs2_idx_o[i] = issue_data[i].rs2_idx;
    assign fp_regstat_rs1_idx_o[i] = issue_data[i].rs1_idx;
    assign fp_regstat_rs2_idx_o[i] = issue_data[i].rs2_idx;
    assign fp_regstat_rs3_idx_o[i] = issue_data[i].rs3_idx;
    assign fprf_rs1_idx_o[i] = issue_data[i].rs1_idx;
    assign fprf_rs2_idx_o[i] = issue_data[i].rs2_idx;
    assign fprf_rs3_idx_o[i] = issue_data[i].rs3_idx;

    always_comb begin : lookup_rs1
      rs1_busy = 1'b0;
      rs1_selected = '0;
      rs1_selected.ready = 1'b1;
      rs1_selected.rob_idx = (issue_data[i].rs1_sel == RS1_SEL_FP) ?
          fp_regstat_rs1_rob_idx_i[i] : int_regstat_rs1_rob_idx_i[i];
      case (issue_data[i].rs1_sel)
        RS1_SEL_INT: begin
          rs1_busy           = int_regstat_rs1_busy_i[i];
          rs1_selected.value = intrf_rs1_value_i[i];
        end
        RS1_SEL_FP: begin
          rs1_busy           = fp_regstat_rs1_busy_i[i];
          rs1_selected.value = fprf_rs1_value_i[i];
        end
        RS1_SEL_PC: rs1_selected.value = issue_data[i].curr_pc;
        default:    ;
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
      rs2_selected.rob_idx = (issue_data[i].rs2_sel == RS2_SEL_FP) ?
          fp_regstat_rs2_rob_idx_i[i] : int_regstat_rs2_rob_idx_i[i];
      case (issue_data[i].rs2_sel)
        RS2_SEL_INT: begin
          rs2_busy           = int_regstat_rs2_busy_i[i];
          rs2_selected.value = intrf_rs2_value_i[i];
        end
        RS2_SEL_FP: begin
          rs2_busy           = fp_regstat_rs2_busy_i[i];
          rs2_selected.value = fprf_rs2_value_i[i];
        end
        RS2_SEL_IMM: rs2_selected.value = issue_data[i].imm_value;
        default:     ;
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
      rs3_busy             = 1'b0;
      rs3_selected         = '0;
      rs3_selected.ready   = 1'b1;
      rs3_selected.rob_idx = fp_regstat_rs3_rob_idx_i[i];
      case (issue_data[i].rs3_sel)
        RS3_SEL_FP: begin
          rs3_busy           = fp_regstat_rs3_busy_i[i];
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

  issue_dependencies #(
    .Len5Cfg(Len5Cfg)
  ) u_issue_dependencies (
    .head_idx_i      (iq_head_idx),
    .rs1_dep_i       (rs1_dep),
    .rs2_dep_i       (rs2_dep),
    .rs3_dep_i       (rs3_dep),
    .issue_valid_i   (iq_valid),
    .issue_grant_i   (issue_grant),
    .issue_dispatch_i(operand_dispatch),
    .issue_rob_idx_i (comm_tail_idx_i),
    .issue_result_i  (direct_result),
    .rs1_i           (rs1_base),
    .rs2_i           (rs2_base),
    .rs3_i           (rs3_base),
    .rs1_o           (rs1_resolved),
    .rs2_o           (rs2_resolved),
    .rs3_o           (rs3_resolved),
    .rs1_bundle_o    (rs1_bundle),
    .rs2_bundle_o    (rs2_bundle),
    .rs3_bundle_o    (rs3_bundle)
  );
  // %TODO check with Michele we don't need the value mux
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_forwarding
    // Same-bundle operands must not consume old ROB/CDB/buffer contents.
    assign comm_rs1_rob_idx_o[i] = rs1_resolved[i].rob_idx;
    assign rs1_fwd_en[i] = iq_valid[i] && !iq_flush && !rs1_resolved[i].ready && !rs1_bundle[i];

    always_comb begin : forward_rs1
      rs1_forwarded[i] = rs1_resolved[i];
      if (rs1_fwd_en[i]) begin
        rs1_forwarded[i].ready = comm_rs1_ready_i[i];
        rs1_forwarded[i].value = comm_rs1_ready_i[i] ? comm_rs1_value_i[i] : '0;
      end
    end

    assign comm_rs2_rob_idx_o[i] = rs2_resolved[i].rob_idx;
    assign rs2_fwd_en[i] = iq_valid[i] && !iq_flush && !rs2_resolved[i].ready && !rs2_bundle[i];

    always_comb begin : forward_rs2
      rs2_forwarded[i] = rs2_resolved[i];
      if (rs2_fwd_en[i]) begin
        rs2_forwarded[i].ready = comm_rs2_ready_i[i];
        rs2_forwarded[i].value = comm_rs2_ready_i[i] ? comm_rs2_value_i[i] : '0;
      end
    end

    assign comm_rs3_rob_idx_o[i] = rs3_resolved[i].rob_idx;
    assign rs3_fwd_en[i] = iq_valid[i] && !iq_flush && !rs3_resolved[i].ready && !rs3_bundle[i];

    always_comb begin : forward_rs3
      rs3_forwarded[i] = rs3_resolved[i];
      if (rs3_fwd_en[i]) begin
        rs3_forwarded[i].ready = comm_rs3_ready_i[i];
        rs3_forwarded[i].value = comm_rs3_ready_i[i] ? comm_rs3_value_i[i] : '0;
      end
    end

  end

  assign rs1_ready         = rs1_forwarded[0].ready;
  assign rs1_value         = rs1_forwarded[0].value;
  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Fetch stage
  assign fetch_mis_flush_o = cu_mis_flush;

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_dispatch_data
    assign ex_assigned_eu_o[i] = issue_data[i].assigned_eu;
    assign ex_eu_ctl_o[i]      = issue_data[i].eu_ctl;
    assign ex_frm_o[i]         = issue_data[i].frm;
    assign ex_rs1_o[i]         = rs1_forwarded[i];
    assign ex_rs2_o[i]         = rs2_forwarded[i];
    assign ex_rs3_o[i]         = rs3_forwarded[i];
    assign ex_imm_value_o[i]   = issue_data[i].imm_value;
    assign ex_rob_idx_o[i]     = comm_tail_idx_i[i];
    assign ex_curr_pc_o[i]     = issue_data[i].curr_pc;
    assign ex_pred_target_o[i] = issue_data[i].pred_target;
    assign ex_pred_taken_o[i]  = issue_data[i].pred_taken;
  end

  // Each accepted lane initializes its own ROB entry. Only the head can be a CSR.
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_commit_data
    assign comm_data_o[i].instruction = issue_data[i].instr;
    assign comm_data_o[i].instr_pc = issue_data[i].curr_pc;
    assign comm_data_o[i].res_ready     = operand_dispatch[i].direct_result || ((i == 0) && special_grant);
    assign comm_data_o[i].res_value     = ((i == 0) && cu_il_res_sel_rs1) ? rs1_value : issue_data[i].imm_value;
    assign comm_data_o[i].rd_idx = issue_data[i].rd_idx;
    assign comm_data_o[i].rd_upd = issue_data[i].rd_upd;
    assign comm_data_o[i].mem_crit = issue_data[i].mem_crit;
    assign comm_data_o[i].order_crit = issue_data[i].order_crit;
    assign comm_data_o[i].except_raised = issue_data[i].except_raised ||
        (issue_data[i].issue_type == ISSUE_TYPE_EXCEPT);
    assign comm_data_o[i].except_code = issue_data[i].except_code;
    assign comm_data_o[i].mem_clear = 1'b0;
    assign comm_data_o[i].flags.raw = '0;
  end

  // ----------
  // DEBUG CODE
  // ----------
`ifndef SYNTHESIS
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_check_dispatch
    always @(posedge clk_i) begin
      if (rst_ni) begin
        assert (!issue_grant[i] || (comm_ready_i[i] && !iq_flush && !ex_mis_i))
        else $error("dispatch without ROB capacity or during recovery");
        assert (!issue_grant[i] || ((!rs1_dep[i].valid || rs1_bundle[i]) &&
            (!rs2_dep[i].valid || rs2_bundle[i]) && (!rs3_dep[i].valid || rs3_bundle[i])))
        else $error("accepted queue dependency requires an older granted producer");
        assert (!ex_valid_o[i] || issue_grant[i])
        else $error("execution insertion without ROB allocation");
      end
    end
    if (i > 0) begin : gen_check_prefix
      always @(posedge clk_i) begin
        if (rst_ni) begin
          assert (!issue_grant[i] || issue_grant[i-1])
          else $error("younger instruction bypassed a blocked issue lane");
        end
      end
    end
  end
`endif  /* SYNTHESIS */

endmodule
