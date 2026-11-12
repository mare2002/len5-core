`include "len5_typedef.svh"
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
// File: branch_rs.sv
// Author: Michele Caon
// Date: 08/11/2019

module branch_rs #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned DEPTH = Len5Cfg.BU_RS_DEPTH,
  localparam int unsigned RsIdxLen = $clog2(DEPTH)
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Issue Stage
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,
  output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_ready_o,
  input expipe_pkg::branch_ctl_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_branch_type_i,
  input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_i,
  input op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_imm_value_i,
  input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_dest_rob_idx_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_curr_pc_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] issue_pred_target_i,
  input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_pred_taken_i,

  // Common Data Bus (CDB)
  input  logic      cdb_ready_i,
  input  logic      cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic      cdb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_data_o,

  // Branch unit
  input  logic                                         bu_valid_i,
  input  logic                                         bu_ready_i,
  output logic                                         bu_valid_o,
  output logic                                         bu_ready_o,
  input  rob_idx_t                                     bu_rob_idx_i,
  input  logic                                         bu_res_mis_i,        // mispredcition result
  input  logic                    [len5_pkg::XLEN-1:0] bu_link_addr_i,      // computed link address
  input  logic                                         bu_except_raised_i,
  output rob_idx_t                                     bu_rob_idx_o,
  output logic                    [len5_pkg::XLEN-1:0] bu_rs1_o,
  output logic                    [len5_pkg::XLEN-1:0] bu_rs2_o,
  output logic                    [len5_pkg::XLEN-1:0] bu_imm_o,
  output logic                    [len5_pkg::XLEN-1:0] bu_curr_pc_o,
  output logic                    [len5_pkg::XLEN-1:0] bu_pred_target_o,
  output logic                                         bu_pred_taken_o,
  output expipe_pkg::branch_ctl_t                      bu_branch_type_o
);

  // Allocation buffering does not change reservation-station scheduling.
  localparam int unsigned IssueWidth = Len5Cfg.BU_ISSUE_WIDTH;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_valid;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_ready;
  expipe_pkg::branch_ctl_t [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_branch_type;
  op_data_t                [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_rs1;
  op_data_t                [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_rs2;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] alloc_imm_value;
  rob_idx_t                [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_dest_rob_idx;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] alloc_curr_pc;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] alloc_pred_target;
  logic                    [Len5Cfg.ISSUE_WIDTH-1:0]                     alloc_pred_taken;
  typedef struct packed {
    expipe_pkg::branch_ctl_t   issue_branch_type;
    logic [len5_pkg::XLEN-1:0] issue_imm_value;
    rob_idx_t                  issue_dest_rob_idx;
    logic [len5_pkg::XLEN-1:0] issue_curr_pc;
    logic [len5_pkg::XLEN-1:0] issue_pred_target;
    logic                      issue_pred_taken;
  } alloc_payload_t;
  alloc_payload_t [IssueWidth-1:0] fifo_payload_in, fifo_payload_out;
  op_data_t [IssueWidth-1:0][2-1:0] fifo_operands_in, fifo_operands_out;
  for (genvar k = 0; k < IssueWidth; k++) begin : gen_fifo_payload
    assign fifo_payload_in[k].issue_branch_type  = issue_branch_type_i[k];
    assign alloc_branch_type[k]                  = fifo_payload_out[k].issue_branch_type;
    assign fifo_payload_in[k].issue_imm_value    = issue_imm_value_i[k];
    assign alloc_imm_value[k]                    = fifo_payload_out[k].issue_imm_value;
    assign fifo_payload_in[k].issue_dest_rob_idx = issue_dest_rob_idx_i[k];
    assign alloc_dest_rob_idx[k]                 = fifo_payload_out[k].issue_dest_rob_idx;
    assign fifo_payload_in[k].issue_curr_pc      = issue_curr_pc_i[k];
    assign alloc_curr_pc[k]                      = fifo_payload_out[k].issue_curr_pc;
    assign fifo_payload_in[k].issue_pred_target  = issue_pred_target_i[k];
    assign alloc_pred_target[k]                  = fifo_payload_out[k].issue_pred_target;
    assign fifo_payload_in[k].issue_pred_taken   = issue_pred_taken_i[k];
    assign alloc_pred_taken[k]                   = fifo_payload_out[k].issue_pred_taken;
    assign fifo_operands_in[k][0]                = issue_rs1_i[k];
    assign alloc_rs1[k]                          = fifo_operands_out[k][0];
    assign fifo_operands_in[k][1]                = issue_rs2_i[k];
    assign alloc_rs2[k]                          = fifo_operands_out[k][1];
  end
  for (genvar k = IssueWidth; k < Len5Cfg.ISSUE_WIDTH; k++) begin : gen_unused_allocation
    logic unused_inputs;
    assign unused_inputs = ^{issue_branch_type_i[k], issue_curr_pc_i[k], issue_dest_rob_idx_i[k],
                              issue_imm_value_i[k], issue_pred_taken_i[k], issue_pred_target_i[k],
                              issue_rs1_i[k], issue_rs2_i[k], issue_valid_i[k]};
    assign alloc_valid[k] = '0;
    assign issue_ready_o[k] = '0;
    assign alloc_branch_type[k] = expipe_pkg::branch_ctl_t'(0);
    assign alloc_imm_value[k] = '0;
    assign alloc_dest_rob_idx[k] = '0;
    assign alloc_curr_pc[k] = '0;
    assign alloc_pred_target[k] = '0;
    assign alloc_pred_taken[k] = '0;
    assign alloc_rs1[k] = '0;
    assign alloc_rs2[k] = '0;
  end
  rs_alloc_fifo #(
    .Len5Cfg(Len5Cfg),
    .EU     (expipe_pkg::EU_BRANCH_UNIT)
  ) u_alloc_fifo (
    .clk_i,
    .rst_ni,
    .flush_i,
    .cdb_valid_i,
    .cdb_data_i,
    .valid_i   (issue_valid_i[IssueWidth-1:0]),
    .ready_o   (issue_ready_o[IssueWidth-1:0]),
    .valid_o   (alloc_valid[IssueWidth-1:0]),
    .ready_i   (alloc_ready[IssueWidth-1:0]),
    .payload_i (fifo_payload_in),
    .payload_o (fifo_payload_out),
    .operands_i(fifo_operands_in),
    .operands_o(fifo_operands_out)
  );

  import len5_pkg::*;
  import expipe_pkg::*;

  // DATA TYPES
  // ----------
  // Branch unit status
  typedef enum logic [2:0] {
    BU_S_EMPTY,         // empty
    BU_S_RS1_PENDING,   // waiting for rs1 forwarding
    BU_S_RS2_PENDING,   // waiting for rs2 forwarding
    BU_S_RS12_PENDING,  // waiting for rs1 and rs2 forwarding
    BU_S_EX_REQ,        // requesting execution to BU logic
    BU_S_EX_WAIT,       // waiting for the BU result
    BU_S_COMPLETED,     // ready to write the result on the CDB
    BU_S_HALT           // for debug
  } bu_state_t;

  // Branch unit reservation station data
  typedef struct packed {
    branch_ctl_t     branch_type;    // Branch type for the branch unit
    logic [XLEN-1:0] curr_pc;
    rob_idx_t        rs1_rob_idx;    // The entry of the rob that will contain the required operand
    logic [XLEN-1:0] rs1_value;      // The value of the first operand
    rob_idx_t        rs2_rob_idx;    // The entry of the rob that will contain the required operand
    logic [XLEN-1:0] rs2_value;      // The value of the second operand
    logic [XLEN-1:0] imm_value;      // Immediate value
    rob_idx_t        dest_rob_idx;   // The entry of the ROB where the result will be stored
    logic [XLEN-1:0] target_link;    // predicted target, then link address
    logic            taken;
    logic            mispredicted;
    logic            except_raised;
  } bu_data_t;

  // Branch unit operations
  typedef enum logic [2:0] {
    BU_OP_NONE,
    BU_OP_INSERT,
    BU_OP_SAVE_RS12,
    BU_OP_SAVE_RS1,
    BU_OP_SAVE_RS2,
    BU_OP_SAVE_RES
  } bu_op_t;

  // INTERNAL SIGNALS
  // ----------------
  // Head, tail, and execution counters
  logic head_cnt_en, head_cnt_clr;

  logic ex_cnt_en, ex_cnt_clr;
  logic [RsIdxLen-1:0] tail_idx, ex_idx, head_idx;

  // Branch reservation station data
  bu_data_t data[DEPTH];
  bu_state_t curr_state[DEPTH], next_state[DEPTH];

  // Reservation station control
  logic pop, ex_accepted, save_res;
  logic        [DEPTH-1:0] insert;
  int unsigned             insert_lane[DEPTH];
  int unsigned             push_count;
  always_comb begin : p_alloc_ready
    alloc_ready = '0;
    for (int k = 0; k < Len5Cfg.ISSUE_WIDTH; k++) begin
      if (k < IssueWidth && k < DEPTH && !flush_i && curr_state[RsIdxLen'(tail_idx+k)] == BU_S_EMPTY)
        alloc_ready[k] = k == 0 ? 1'b1 : alloc_ready[k-1];
    end
  end
  always_comb begin : p_insert
    insert      = '0;
    insert_lane = '{default: '0};
    push_count  = 0;
    for (int k = 0; k < Len5Cfg.ISSUE_WIDTH; k++) begin
      if (alloc_valid[k] && alloc_ready[k]) begin
        insert[RsIdxLen'(tail_idx+push_count)]      = 1'b1;
        insert_lane[RsIdxLen'(tail_idx+push_count)] = k;
        push_count++;
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) tail_idx <= '0;
    else if (flush_i) tail_idx <= '0;
    else tail_idx <= RsIdxLen'(tail_idx + push_count);
  end
  logic fwd_rs1[DEPTH], fwd_rs2[DEPTH];
  bu_op_t bu_op[DEPTH];

  // -------------------------------
  // BRANCH UNIT BUFFER CONTROL UNIT
  // -------------------------------

  // Buffer control
  assign pop          = cdb_valid_o & cdb_ready_i;
  assign ex_accepted  = bu_valid_o & bu_ready_i;
  assign save_res     = bu_valid_i & bu_ready_o;

  // Counters control
  assign head_cnt_clr = flush_i;
  assign ex_cnt_clr   = flush_i;
  assign head_cnt_en  = pop;
  assign ex_cnt_en    = ex_accepted;

  // Operands forwarding control
  always_comb begin : p_fwd_rs
    foreach (data[i]) begin
      fwd_rs1[i] = cdb_valid_i & (cdb_data_i.rob_idx == data[i].rs1_rob_idx);
      fwd_rs2[i] = cdb_valid_i & (cdb_data_i.rob_idx == data[i].rs2_rob_idx);
    end
  end

  // State progression
  // NOTE: Mealy to avoid resampling data
  always_comb begin : p_state_prog
    // Default operation (no operation)
    foreach (bu_op[i]) bu_op[i] = BU_OP_NONE;

    foreach (curr_state[i]) begin
      case (curr_state[i])
        BU_S_EMPTY: begin  // push a new instruction
          if (insert[i]) begin
            if (alloc_rs1[insert_lane[i]].ready && alloc_rs2[insert_lane[i]].ready) begin
              next_state[i] = BU_S_EX_REQ;
              bu_op[i]      = BU_OP_INSERT;
            end else if (!alloc_rs1[insert_lane[i]].ready && alloc_rs2[insert_lane[i]].ready) begin
              next_state[i] = BU_S_RS1_PENDING;
              bu_op[i]      = BU_OP_INSERT;
            end else if (alloc_rs1[insert_lane[i]].ready && !alloc_rs2[insert_lane[i]].ready) begin
              next_state[i] = BU_S_RS2_PENDING;
              bu_op[i]      = BU_OP_INSERT;
            end else begin
              next_state[i] = BU_S_RS12_PENDING;
              bu_op[i]      = BU_OP_INSERT;
            end
          end else next_state[i] = BU_S_EMPTY;
        end
        BU_S_RS12_PENDING: begin  // save rs1 and/or rs2 value from CDB
          if (fwd_rs1[i] && fwd_rs2[i]) begin
            bu_op[i]      = BU_OP_SAVE_RS12;
            next_state[i] = BU_S_EX_REQ;
          end else if (fwd_rs1[i]) begin
            bu_op[i]      = BU_OP_SAVE_RS1;
            next_state[i] = BU_S_RS2_PENDING;
          end else if (fwd_rs2[i]) begin
            bu_op[i]      = BU_OP_SAVE_RS2;
            next_state[i] = BU_S_RS1_PENDING;
          end else next_state[i] = BU_S_RS12_PENDING;
        end
        BU_S_RS1_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs1[i]) begin
            bu_op[i]      = BU_OP_SAVE_RS1;
            next_state[i] = BU_S_EX_REQ;
          end else next_state[i] = BU_S_RS1_PENDING;
        end
        BU_S_RS2_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs2[i]) begin
            bu_op[i]      = BU_OP_SAVE_RS2;
            next_state[i] = BU_S_EX_REQ;
          end else next_state[i] = BU_S_RS2_PENDING;
        end
        BU_S_EX_REQ: begin  // request branch resolution to branch logic
          if (save_res && bu_rob_idx_i == data[i].dest_rob_idx) begin
            bu_op[i]      = BU_OP_SAVE_RES;
            next_state[i] = BU_S_COMPLETED;
          end else if (ex_accepted && ex_idx == i[RsIdxLen-1:0]) next_state[i] = BU_S_EX_WAIT;
          else next_state[i] = BU_S_EX_REQ;
        end
        BU_S_EX_WAIT: begin  // wait for execution completion
          if (save_res && bu_rob_idx_i == data[i].dest_rob_idx) begin
            bu_op[i]      = BU_OP_SAVE_RES;
            next_state[i] = BU_S_COMPLETED;
          end else next_state[i] = BU_S_EX_WAIT;
        end
        BU_S_COMPLETED: begin
          if (pop && head_idx == i[RsIdxLen-1:0]) next_state[i] = BU_S_EMPTY;
          else next_state[i] = BU_S_COMPLETED;
        end
        default: next_state[i] = BU_S_HALT;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) foreach (curr_state[i]) curr_state[i] <= BU_S_EMPTY;
    else if (flush_i) foreach (curr_state[i]) curr_state[i] <= BU_S_EMPTY;
    else curr_state <= next_state;
  end

  // ------------------
  // BRANCH UNIT BUFFER
  // ------------------
  // Branch buffer update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_bu_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data[i] <= '0;
      end
    end else begin
      // Performed the required action for each instruction
      foreach (bu_op[i]) begin
        case (bu_op[i])
          BU_OP_INSERT: begin
            data[i].branch_type  <= alloc_branch_type[insert_lane[i]];
            data[i].curr_pc      <= alloc_curr_pc[insert_lane[i]];
            data[i].rs1_rob_idx  <= alloc_rs1[insert_lane[i]].rob_idx;
            data[i].rs1_value    <= alloc_rs1[insert_lane[i]].value;
            data[i].rs2_rob_idx  <= alloc_rs2[insert_lane[i]].rob_idx;
            data[i].rs2_value    <= alloc_rs2[insert_lane[i]].value;
            data[i].imm_value    <= alloc_imm_value[insert_lane[i]];
            data[i].dest_rob_idx <= alloc_dest_rob_idx[insert_lane[i]];
            data[i].target_link  <= alloc_pred_target[insert_lane[i]];
            data[i].taken        <= alloc_pred_taken[insert_lane[i]];
          end
          BU_OP_SAVE_RS12: begin
            data[i].rs1_value <= cdb_data_i.res_value;
            data[i].rs2_value <= cdb_data_i.res_value;
          end
          BU_OP_SAVE_RS1: begin
            data[i].rs1_value <= cdb_data_i.res_value;
          end
          BU_OP_SAVE_RS2: begin
            data[i].rs2_value <= cdb_data_i.res_value;
          end
          BU_OP_SAVE_RES: begin
            data[i].target_link   <= bu_link_addr_i;
            data[i].mispredicted  <= bu_res_mis_i;
            data[i].except_raised <= bu_except_raised_i;
          end
          default: ;
        endcase
      end
    end
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Issue Stage

  // CDB
  assign cdb_valid_o = curr_state[head_idx] == BU_S_COMPLETED;
  assign cdb_data_o.rob_idx = data[head_idx].dest_rob_idx;
  assign cdb_data_o.res_value = data[head_idx].target_link;
  assign cdb_data_o.except_raised = !Len5Cfg.LEN5_C_EN && data[head_idx].except_raised;

  assign cdb_data_o.except_code = (data[head_idx].mispredicted) ? E_MISPREDICTION : E_I_ADDR_MISALIGNED;
  assign cdb_data_o.flags.raw = '0;  // no flags set

  // Branch Unit logic
  assign bu_valid_o = curr_state[ex_idx] == BU_S_EX_REQ;
  assign bu_ready_o = 1'b1;
  assign bu_rs1_o = data[ex_idx].rs1_value;
  assign bu_rs2_o = data[ex_idx].rs2_value;
  assign bu_imm_o = data[ex_idx].imm_value;
  assign bu_curr_pc_o = data[ex_idx].curr_pc;
  assign bu_pred_target_o = data[ex_idx].target_link;
  assign bu_pred_taken_o = data[ex_idx].taken;
  assign bu_branch_type_o = data[ex_idx].branch_type;
  assign bu_rob_idx_o = data[ex_idx].dest_rob_idx;

  // --------
  // COUNTERS
  // --------

  // Head counter pointing to the oldest branch/jump instruction
  modn_counter #(
    .N(DEPTH)
  ) u_head_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (head_cnt_en),
    .clr_i  (head_cnt_clr),
    .count_o(head_idx),
    .tc_o   ()               // not needed
  );


  // Execution counter pointing to the executing branch/jump instruction
  modn_counter #(
    .N(DEPTH)
  ) u_addr_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (ex_cnt_en),
    .clr_i  (ex_cnt_clr),
    .count_o(ex_idx),
    .tc_o   ()             // not needed
  );

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
`ifndef VERILATOR
  always @(posedge clk_i) begin
    foreach (curr_state[i]) begin
      assert property (@(posedge clk_i) disable iff (!rst_ni) curr_state[i] == BU_S_HALT |->
        ##1 curr_state[i] != BU_S_HALT);
    end
  end
`endif  // VERILATOR
`endif  // SYNTHESIS
endmodule
