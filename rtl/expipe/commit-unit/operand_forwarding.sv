`include "len5_typedef.svh"
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.

module operand_forwarding #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg)
) (
  // Issue-stage operand requests and results
  input  rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs1_rob_idx_i,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs1_ready_o,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_rs1_value_o,
  input  rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs2_rob_idx_i,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs2_ready_o,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_rs2_value_o,
  input  rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs3_rob_idx_i,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0]                     issue_rs3_ready_o,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_rs3_value_o,

  // ROB operand lookups
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs1_valid_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs1_ready_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rob_opfwd_rs1_value_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs2_valid_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs2_ready_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rob_opfwd_rs2_value_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs3_valid_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0]                     rob_opfwd_rs3_ready_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] rob_opfwd_rs3_value_i,

  input logic                          cdb_valid_i,
  input rob_idx_t                      cdb_rob_idx_i,
  input logic     [len5_pkg::XLEN-1:0] cdb_value_i,
  input logic                          inreg_buff_full_i,
  input rob_idx_t                      inreg_buff_rob_idx_i,
  input logic     [len5_pkg::XLEN-1:0] inreg_buff_value_i,
  input logic                          inreg_cu_valid_i,
  input rob_idx_t                      inreg_rob_idx_i,
  input logic     [len5_pkg::XLEN-1:0] inreg_value_i,
  input logic                          comm_reg_valid_i,
  input rob_idx_t                      comm_reg_rob_idx_i,
  input logic     [len5_pkg::XLEN-1:0] comm_reg_value_i
);

  // Operands are searched for in the following priority order:
  // 1) Current CDB result.
  // 2) ROB entry (a valid unresolved entry blocks older buffer values).
  // 3) Commit input spill buffer (inreg_buff_data).
  // 4) Commit input register (inreg_data_out).
  // 5) Commit register (comm_reg_data).
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_lanes
    always_comb begin : rs1_forwarding
      issue_rs1_ready_o[i] = 1'b0;
      issue_rs1_value_o[i] = '0;
      if (cdb_valid_i && cdb_rob_idx_i == issue_rs1_rob_idx_i[i]) begin
        issue_rs1_ready_o[i] = 1'b1;
        issue_rs1_value_o[i] = cdb_value_i;
      end else if (rob_opfwd_rs1_valid_i[i]) begin
        issue_rs1_ready_o[i] = rob_opfwd_rs1_ready_i[i];
        issue_rs1_value_o[i] = rob_opfwd_rs1_value_i[i];
      end else if (inreg_buff_full_i && inreg_buff_rob_idx_i == issue_rs1_rob_idx_i[i]) begin
        issue_rs1_ready_o[i] = 1'b1;
        issue_rs1_value_o[i] = inreg_buff_value_i;
      end else if (inreg_cu_valid_i && inreg_rob_idx_i == issue_rs1_rob_idx_i[i]) begin
        issue_rs1_ready_o[i] = 1'b1;
        issue_rs1_value_o[i] = inreg_value_i;
      end else if (comm_reg_valid_i && comm_reg_rob_idx_i == issue_rs1_rob_idx_i[i]) begin
        issue_rs1_ready_o[i] = 1'b1;
        issue_rs1_value_o[i] = comm_reg_value_i;
      end
    end

    always_comb begin : rs2_forwarding
      issue_rs2_ready_o[i] = 1'b0;
      issue_rs2_value_o[i] = '0;
      if (cdb_valid_i && cdb_rob_idx_i == issue_rs2_rob_idx_i[i]) begin
        issue_rs2_ready_o[i] = 1'b1;
        issue_rs2_value_o[i] = cdb_value_i;
      end else if (rob_opfwd_rs2_valid_i[i]) begin
        issue_rs2_ready_o[i] = rob_opfwd_rs2_ready_i[i];
        issue_rs2_value_o[i] = rob_opfwd_rs2_value_i[i];
      end else if (inreg_buff_full_i && inreg_buff_rob_idx_i == issue_rs2_rob_idx_i[i]) begin
        issue_rs2_ready_o[i] = 1'b1;
        issue_rs2_value_o[i] = inreg_buff_value_i;
      end else if (inreg_cu_valid_i && inreg_rob_idx_i == issue_rs2_rob_idx_i[i]) begin
        issue_rs2_ready_o[i] = 1'b1;
        issue_rs2_value_o[i] = inreg_value_i;
      end else if (comm_reg_valid_i && comm_reg_rob_idx_i == issue_rs2_rob_idx_i[i]) begin
        issue_rs2_ready_o[i] = 1'b1;
        issue_rs2_value_o[i] = comm_reg_value_i;
      end
    end

    always_comb begin : rs3_forwarding
      issue_rs3_ready_o[i] = 1'b0;
      issue_rs3_value_o[i] = '0;
      if (cdb_valid_i && cdb_rob_idx_i == issue_rs3_rob_idx_i[i]) begin
        issue_rs3_ready_o[i] = 1'b1;
        issue_rs3_value_o[i] = cdb_value_i;
      end else if (rob_opfwd_rs3_valid_i[i]) begin
        issue_rs3_ready_o[i] = rob_opfwd_rs3_ready_i[i];
        issue_rs3_value_o[i] = rob_opfwd_rs3_value_i[i];
      end else if (inreg_buff_full_i && inreg_buff_rob_idx_i == issue_rs3_rob_idx_i[i]) begin
        issue_rs3_ready_o[i] = 1'b1;
        issue_rs3_value_o[i] = inreg_buff_value_i;
      end else if (inreg_cu_valid_i && inreg_rob_idx_i == issue_rs3_rob_idx_i[i]) begin
        issue_rs3_ready_o[i] = 1'b1;
        issue_rs3_value_o[i] = inreg_value_i;
      end else if (comm_reg_valid_i && comm_reg_rob_idx_i == issue_rs3_rob_idx_i[i]) begin
        issue_rs3_ready_o[i] = 1'b1;
        issue_rs3_value_o[i] = comm_reg_value_i;
      end
    end
  end
endmodule
