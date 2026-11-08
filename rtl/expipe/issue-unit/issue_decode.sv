// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.
module issue_decode #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG
) (
  input  logic                                                          clk_i,
  input  logic                                                          rst_ni,
  input  logic                                                          flush_i,
  input  logic                                                          fetch_valid_i,
  output logic                                                          fetch_ready_o,
  input  logic                       [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_valid_instr_i,
  input  len5_pkg::instr_t           [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_instr_i,
  input  fetch_pkg::prediction_t     [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_pred_i,
  input  logic                       [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_except_raised_i,
  input  len5_pkg::except_code_t     [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_except_code_i,
  output logic                                                          decoded_valid_o,
  input  logic                                                          decoded_ready_i,
  output logic                       [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] decoded_valid_instr_o,
  output expipe_pkg::decoded_instr_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] decoded_instr_o
);
  import len5_pkg::*;
  import expipe_pkg::*;

  typedef struct packed {
    logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] valid;
    fetch_entry_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] instr;
  } fetch_bundle_t;
  typedef struct packed {
    logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] valid;
    decoded_instr_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] instr;
  } decoded_bundle_t;

  fetch_bundle_t fetch_data, input_data;
  decoded_bundle_t decoded_data, output_data;
  logic input_valid, input_ready, fetch_ready, output_valid;

  assign fetch_data.valid = fetch_valid_instr_i;
  for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_fetch_data
    assign fetch_data.instr[i] = '{
            instruction: fetch_instr_i[i],
            prediction: fetch_pred_i[i],
            except_raised: fetch_except_raised_i[i],
            except_code: fetch_except_code_i[i]
        };
  end

  spill_cell_flush #(
    .DATA_T(fetch_bundle_t)
  ) u_input_spill (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_i),
    .valid_i(fetch_valid_i && !flush_i),
    .ready_o(fetch_ready),
    .valid_o(input_valid),
    .ready_i(input_ready && !flush_i),
    .data_i (fetch_data),
    .data_o (input_data)
  );

  assign decoded_data.valid = input_data.valid;

  for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_decoders
    // Instruction data
    logic [REG_IDX_LEN-1:0] instr_rs1_idx, instr_rs2_idx, instr_rs3_idx, instr_rd_idx;
    logic         [FUNCT3_LEN-1:0] instr_frm;
    logic         [      XLEN-1:0] instr_imm_i_value;
    logic         [      XLEN-1:0] instr_imm_s_value;
    logic         [      XLEN-1:0] instr_imm_b_value;
    logic         [      XLEN-1:0] instr_imm_u_value;
    logic         [      XLEN-1:0] instr_imm_j_value;
    logic         [      XLEN-1:0] instr_imm_rs1_value;  // for CSR immediate instr.
    logic         [      XLEN-1:0] imm_value;  // selected immediate

    // Decoder controls
    except_code_t                  id_except_code;
    issue_type_t                   id_issue_type;
    imm_format_t                   id_imm_format;
    logic                          ecall;

    // Main instruction decoder
    issue_decoder #(
      .Len5Cfg(Len5Cfg)
    ) u_issue_decoder (
      .instruction_i  (input_data.instr[i].instruction),
      .requires_fp_o  (decoded_data.instr[i].requires_fp),
      .required_priv_o(decoded_data.instr[i].required_priv),
      .ecall_o        (ecall),
      .issue_type_o   (id_issue_type),
      .dispatch_o     (decoded_data.instr[i].dispatch),
      .except_code_o  (id_except_code),
      .skip_eu_o      (decoded_data.instr[i].skip_eu),
      .assigned_eu_o  (decoded_data.instr[i].assigned_eu),
      .eu_ctl_o       (decoded_data.instr[i].eu_ctl),
      .mem_crit_o     (decoded_data.instr[i].mem_crit),
      .order_crit_o   (decoded_data.instr[i].order_crit),
      .rs1_sel_o      (decoded_data.instr[i].rs1_sel),
      .rs2_sel_o      (decoded_data.instr[i].rs2_sel),
      .rs3_sel_o      (decoded_data.instr[i].rs3_sel),
      .rd_upd_o       (decoded_data.instr[i].rd_upd),
      .imm_format_o   (id_imm_format)
    );

    // Instruction fields extraction
    assign instr_rs1_idx = input_data.instr[i].instruction.r.rs1;
    assign instr_rs2_idx = input_data.instr[i].instruction.r.rs2;
    assign instr_rd_idx = input_data.instr[i].instruction.r.rd;
    assign instr_imm_i_value = {
      {52{input_data.instr[i].instruction.i.imm11[31]}}, input_data.instr[i].instruction.i.imm11
    };
    assign instr_imm_s_value = {
      {52{input_data.instr[i].instruction.s.imm11[31]}},
      input_data.instr[i].instruction.s.imm11,
      input_data.instr[i].instruction.s.imm4
    };
    assign instr_imm_b_value = {
      {51{input_data.instr[i].instruction.b.imm12}},
      input_data.instr[i].instruction.b.imm12,
      input_data.instr[i].instruction.b.imm11,
      input_data.instr[i].instruction.b.imm10,
      input_data.instr[i].instruction.b.imm4,
      1'b0
    };
    assign instr_imm_u_value = {
      {32{input_data.instr[i].instruction.u.imm31[31]}},
      input_data.instr[i].instruction.u.imm31,
      12'b0
    };
    assign instr_imm_j_value = {
      {43{input_data.instr[i].instruction.j.imm20}},
      input_data.instr[i].instruction.j.imm20,
      input_data.instr[i].instruction.j.imm19,
      input_data.instr[i].instruction.j.imm11,
      input_data.instr[i].instruction.j.imm10,
      1'b0
    };
    assign instr_imm_rs1_value = {59'h0, input_data.instr[i].instruction.r.rs1};

    // RV64F-RV64D
    // rounding mode
    assign instr_frm = input_data.instr[i].instruction.r4.funct3;

    // rs3 idx, R4 format
    assign instr_rs3_idx = input_data.instr[i].instruction.r4.rs3;

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

    assign decoded_data.instr[i].issue_type = id_issue_type;
    assign decoded_data.instr[i].ecall = ecall && !input_data.instr[i].except_raised;
    assign decoded_data.instr[i].curr_pc = input_data.instr[i].prediction.pc;
    assign decoded_data.instr[i].instr = input_data.instr[i].instruction;
    assign decoded_data.instr[i].rs1_idx = instr_rs1_idx;
    assign decoded_data.instr[i].rs2_idx = instr_rs2_idx;
    assign decoded_data.instr[i].rs3_idx = instr_rs3_idx;
    assign decoded_data.instr[i].imm_value = imm_value;
    assign decoded_data.instr[i].rd_idx = instr_rd_idx;
    assign decoded_data.instr[i].pred_taken = (input_data.instr[i].prediction.hit && input_data.instr[i].prediction.taken);
    assign decoded_data.instr[i].pred_target = input_data.instr[i].prediction.target;
    assign decoded_data.instr[i].except_raised = input_data.instr[i].except_raised ||
        (id_issue_type == ISSUE_TYPE_EXCEPT);
    assign decoded_data.instr[i].except_code    = (input_data.instr[i].except_raised) ? input_data.instr[i].except_code : id_except_code;
    assign decoded_data.instr[i].frm = instr_frm;

  end

  spill_cell_flush #(
    .DATA_T(decoded_bundle_t),
    .SKIP  (!Len5Cfg.ISSUE_DECODE_SPILL_EN)
  ) u_decoded_spill (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_i),
    .valid_i(input_valid && !flush_i),
    .ready_o(input_ready),
    .valid_o(output_valid),
    .ready_i(decoded_ready_i && !flush_i),
    .data_i (decoded_data),
    .data_o (output_data)
  );

  assign fetch_ready_o         = fetch_ready && !flush_i;

  assign decoded_valid_o       = output_valid && !flush_i;
  assign decoded_valid_instr_o = output_data.valid;
  assign decoded_instr_o       = output_data.instr;
endmodule
