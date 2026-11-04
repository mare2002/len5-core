`include "len5_typedef.svh"
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.

module issue_dependencies #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
    localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg)
) (
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_grant_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_csr_i,
    input expipe_pkg::issue_dispatch_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_dispatch_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] issue_rd_idx_i,
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rob_idx_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_result_i,
    input expipe_pkg::rs1_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_sel_i,
    input expipe_pkg::rs2_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_sel_i,
    input expipe_pkg::rs3_sel_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_sel_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] rs1_idx_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] rs2_idx_i,
    input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::REG_IDX_LEN-1:0] rs3_idx_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_i,
    input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_i,
    output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_o,
    output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_o,
    output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] dependency_stall_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_bundle_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs2_bundle_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs3_bundle_o
);
  import expipe_pkg::*;

  localparam int unsigned IssueIdxLen = Len5Cfg.ISSUE_WIDTH > 1 ? $clog2(Len5Cfg.ISSUE_WIDTH) : 1;

  logic [Len5Cfg.ISSUE_WIDTH-1:0] int_writer, fp_writer;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_int, rs2_int, rs1_fp, rs2_fp, rs3_fp;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] producer_data;

  for (genvar j = 0; j < Len5Cfg.ISSUE_WIDTH; j++) begin : gen_producers
    assign int_writer[j] = issue_valid_i[j] && issue_grant_i[j] && issue_dispatch_i[j].int_rd_write;
    assign fp_writer[j] = issue_valid_i[j] && issue_grant_i[j] && issue_dispatch_i[j].fp_rd_write;

    assign rs1_int[j] = (rs1_sel_i[j] == RS1_SEL_INT) && (|rs1_idx_i[j]);
    assign rs2_int[j] = (rs2_sel_i[j] == RS2_SEL_INT) && (|rs2_idx_i[j]);
    assign rs1_fp[j] = rs1_sel_i[j] == RS1_SEL_FP;
    assign rs2_fp[j] = rs2_sel_i[j] == RS2_SEL_FP;
    assign rs3_fp[j] = rs3_sel_i[j] == RS3_SEL_FP;

    assign producer_data[j].rob_idx = issue_rob_idx_i[j];
    assign producer_data[j].ready = issue_dispatch_i[j].direct_result;
    assign producer_data[j].value = issue_dispatch_i[j].direct_result ? issue_result_i[j] : '0;
  end

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_lanes
    logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_match, rs2_match, rs3_match;
    logic [IssueIdxLen-1:0] rs1_producer_idx, rs2_producer_idx, rs3_producer_idx;
    logic rs1_producer_valid, rs2_producer_valid, rs3_producer_valid;

    for (genvar j = 0; j < Len5Cfg.ISSUE_WIDTH; j++) begin : gen_matches
      assign rs1_match[j] = (j < i) && (rs1_idx_i[i] == issue_rd_idx_i[j]) && ((rs1_int[i] && int_writer[j]) || (rs1_fp[i] && fp_writer[j]));
      assign rs2_match[j] = (j < i) && (rs2_idx_i[i] == issue_rd_idx_i[j]) && ((rs2_int[i] && int_writer[j]) || (rs2_fp[i] && fp_writer[j]));
      assign rs3_match[j] = (j < i) && (rs3_idx_i[i] == issue_rd_idx_i[j]) && rs3_fp[i] && fp_writer[j];
    end

    // prio_enc uses $clog2(N) index bits, so handle a single issue lane directly.
    if (Len5Cfg.ISSUE_WIDTH == 1) begin : gen_single_lane
      assign rs1_producer_idx = '0;
      assign rs2_producer_idx = '0;
      assign rs3_producer_idx = '0;
      assign rs1_producer_valid = rs1_match[0];
      assign rs2_producer_valid = rs2_match[0];
      assign rs3_producer_valid = rs3_match[0];
    end else begin : gen_multiple_lanes
      // Highest matching lane is the youngest older writer.
      prio_enc #(
          .N  (Len5Cfg.ISSUE_WIDTH),
          .INV(1'b0)
      ) u_rs1_producer_select (
          .lines_i(rs1_match),
          .enc_o  (rs1_producer_idx),
          .valid_o(rs1_producer_valid)
      );

      prio_enc #(
          .N  (Len5Cfg.ISSUE_WIDTH),
          .INV(1'b0)
      ) u_rs2_producer_select (
          .lines_i(rs2_match),
          .enc_o  (rs2_producer_idx),
          .valid_o(rs2_producer_valid)
      );

      prio_enc #(
          .N  (Len5Cfg.ISSUE_WIDTH),
          .INV(1'b0)
      ) u_rs3_producer_select (
          .lines_i(rs3_match),
          .enc_o  (rs3_producer_idx),
          .valid_o(rs3_producer_valid)
      );
    end

    always_comb begin : rs1_mux
      case ({issue_valid_i[i], rs1_producer_valid})
        2'b10: rs1_o[i] = rs1_i[i];
        2'b11: rs1_o[i] = producer_data[rs1_producer_idx];
        default: rs1_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end

    always_comb begin : rs2_mux
      case ({issue_valid_i[i], rs2_producer_valid})
        2'b10: rs2_o[i] = rs2_i[i];
        2'b11: rs2_o[i] = producer_data[rs2_producer_idx];
        default: rs2_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end

    always_comb begin : rs3_mux
      case ({issue_valid_i[i], rs3_producer_valid})
        2'b10: rs3_o[i] = rs3_i[i];
        2'b11: rs3_o[i] = producer_data[rs3_producer_idx];
        default: rs3_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end

    // Mask invalid consumers; CSR producers return at commit without a CDB wakeup.
    assign rs1_bundle_o[i] = issue_valid_i[i] && rs1_producer_valid;
    assign rs2_bundle_o[i] = issue_valid_i[i] && rs2_producer_valid;
    assign rs3_bundle_o[i] = issue_valid_i[i] && rs3_producer_valid;
    assign dependency_stall_o[i] = issue_valid_i[i] && ((rs1_producer_valid && issue_csr_i[rs1_producer_idx]) || (rs2_producer_valid && issue_csr_i[rs2_producer_idx]) || (rs3_producer_valid && issue_csr_i[rs3_producer_idx]));
  end
endmodule
