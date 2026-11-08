`include "len5_typedef.svh"
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.

module issue_dependencies #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type iq_idx_t = `LEN5_IQ_IDX_T(Len5Cfg),
  localparam type iq_dep_t = `LEN5_IQ_DEP_T(Len5Cfg)
) (
  input iq_idx_t head_idx_i,
  input iq_dep_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_dep_i,
  input iq_dep_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_dep_i,
  input iq_dep_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_dep_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_grant_i,
  input expipe_pkg::issue_dispatch_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_dispatch_i,
  input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rob_idx_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_result_i,
  input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_i,
  input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_i,
  input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_i,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs1_o,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs2_o,
  output op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] rs3_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs1_bundle_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs2_bundle_o,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] rs3_bundle_o
);
  localparam int unsigned IssueIdxLen = Len5Cfg.ISSUE_WIDTH > 1 ? $clog2(Len5Cfg.ISSUE_WIDTH) : 1;
  typedef logic [IssueIdxLen-1:0] issue_idx_t;

  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] producer_data;

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_producers
    assign producer_data[i].rob_idx = issue_rob_idx_i[i];
    assign producer_data[i].ready   = issue_dispatch_i[i].direct_result;
    assign producer_data[i].value   = issue_dispatch_i[i].direct_result ? issue_result_i[i] : '0;
  end

  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_lanes
    issue_idx_t rs1_producer, rs2_producer, rs3_producer;

    // Translate physical queue references directly into issue-lane indices.
    assign rs1_producer = issue_idx_t'(rs1_dep_i[i].idx >= head_idx_i ?
        rs1_dep_i[i].idx - head_idx_i : rs1_dep_i[i].idx - head_idx_i + iq_idx_t'(Len5Cfg.IQ_DEPTH));
    assign rs2_producer = issue_idx_t'(rs2_dep_i[i].idx >= head_idx_i ?
        rs2_dep_i[i].idx - head_idx_i : rs2_dep_i[i].idx - head_idx_i + iq_idx_t'(Len5Cfg.IQ_DEPTH));
    assign rs3_producer = issue_idx_t'(rs3_dep_i[i].idx >= head_idx_i ?
        rs3_dep_i[i].idx - head_idx_i : rs3_dep_i[i].idx - head_idx_i + iq_idx_t'(Len5Cfg.IQ_DEPTH));

    if (i == 0) begin : gen_head
      // The oldest lane has no same-cycle producer; this also handles ISSUE_WIDTH=1.
      assign rs1_bundle_o[i] = 1'b0;
      assign rs2_bundle_o[i] = 1'b0;
      assign rs3_bundle_o[i] = 1'b0;
    end else begin : gen_consumer
      logic [Len5Cfg.ISSUE_WIDTH-1:0] older_grant;

      assign older_grant = {{(Len5Cfg.ISSUE_WIDTH - i) {1'b0}}, issue_grant_i[i-1:0]};
      // Only valid, granted older lanes can replace the base operand.
      assign rs1_bundle_o[i] = issue_valid_i[i] && rs1_dep_i[i].valid &&
          issue_valid_i[rs1_producer] && older_grant[rs1_producer];
      assign rs2_bundle_o[i] = issue_valid_i[i] && rs2_dep_i[i].valid &&
          issue_valid_i[rs2_producer] && older_grant[rs2_producer];
      assign rs3_bundle_o[i] = issue_valid_i[i] && rs3_dep_i[i].valid &&
          issue_valid_i[rs3_producer] && older_grant[rs3_producer];
    end

    always_comb begin : rs1_mux
      case ({
        issue_valid_i[i], rs1_bundle_o[i]
      })
        2'b10:   rs1_o[i] = rs1_i[i];
        2'b11:   rs1_o[i] = producer_data[rs1_producer];
        default: rs1_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end

    always_comb begin : rs2_mux
      case ({
        issue_valid_i[i], rs2_bundle_o[i]
      })
        2'b10:   rs2_o[i] = rs2_i[i];
        2'b11:   rs2_o[i] = producer_data[rs2_producer];
        default: rs2_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end

    always_comb begin : rs3_mux
      case ({
        issue_valid_i[i], rs3_bundle_o[i]
      })
        2'b10:   rs3_o[i] = rs3_i[i];
        2'b11:   rs3_o[i] = producer_data[rs3_producer];
        default: rs3_o[i] = '{ready: 1'b1, default: '0};
      endcase
    end
  end
`ifndef SYNTHESIS
  // Check the grant interface even when ISSUE_WIDTH=1 has no same-cycle dependencies.
  always_comb begin : check_issue_grants
    assert final ((issue_grant_i & ~issue_valid_i) == '0)
    else $error("Issue grants must target valid issue slots");
  end
`endif
endmodule
