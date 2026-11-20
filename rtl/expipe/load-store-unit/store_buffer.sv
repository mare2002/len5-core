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
// File: store_buffer.sv
// Author: Michele Caon
// Date: 15/07/2022

// Circular, program-ordered store queue. Only the head may write memory, and
// it remains resident through the memory response and the completion handshake.
module store_buffer #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type adder_ans_t = `LEN5_ADDER_ANS_T(Len5Cfg),
  localparam type adder_req_t = `LEN5_ADDER_REQ_T(Len5Cfg),
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned DEPTH = Len5Cfg.STBUFF_DEPTH,
  localparam int unsigned WIDTH = Len5Cfg.STBUFF_ISSUE_WIDTH,
  localparam int unsigned IdxW = DEPTH > 1 ? $clog2(DEPTH) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Issue_stage
  input  logic                    [WIDTH-1:0]                     issue_valid_i,
  output logic                    [WIDTH-1:0]                     issue_ready_o,
  input  expipe_pkg::ldst_width_t [WIDTH-1:0]                     issue_type_i,
  input  op_data_t                [WIDTH-1:0]                     issue_rs1_i,
  input  op_data_t                [WIDTH-1:0]                     issue_rs2_i,
  input  logic                    [WIDTH-1:0][len5_pkg::XLEN-1:0] issue_imm_i,
  input  rob_idx_t                [WIDTH-1:0]                     issue_dest_rob_idx_i,

  // Commit_stage
  input  logic     comm_mem_clear_i,
  output rob_idx_t comm_mem_idx_o,

  // CDB
  input  logic      cdb_valid_i,
  input  logic      cdb_ready_i,
  output logic      cdb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_data_o,

  // Address_adder
  input  logic       adder_valid_i,
  input  logic       adder_ready_i,
  output logic       adder_valid_o,
  output logic       adder_ready_o,
  input  adder_ans_t adder_ans_i,
  output adder_req_t adder_req_o,

  // Load_buffer
  output logic                    [  IdxW-1:0]                     sq_head_o,
  output logic                    [WIDTH:0][IdxW-1:0]              issue_sq_tail_o,
  output logic                    [WIDTH:0]                        issue_older_stores_remain_o,
  output logic                                                     sq_removed_o,
  output logic                    [ DEPTH-1:0]                     sq_addr_ready_o,
  output logic                    [ DEPTH-1:0]                     sq_data_ready_o,
  output logic                    [ DEPTH-1:0][len5_pkg::XLEN-1:0] sq_addr_o,
  output logic                    [ DEPTH-1:0][len5_pkg::XLEN-1:0] sq_data_o,
  output expipe_pkg::ldst_width_t [ DEPTH-1:0]                     sq_type_o,

  // Memory_system
  output logic                                              mem_valid_o,
  input  logic                                              mem_ready_i,
  input  logic                                              mem_valid_i,
  output logic                                              mem_ready_o,
  output logic                                              mem_we_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_addr_o,
  output logic                   [                     7:0] mem_be_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_wdata_o,
  output logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_tag_o,
  input  logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_tag_i,
  input  logic                                              mem_except_raised_i,
  input  len5_pkg::except_code_t                            mem_except_code_i
);
  import len5_pkg::*;
  import expipe_pkg::*;

  // ----------
  // DATA TYPES
  // ----------
  typedef logic [IdxW-1:0] idx_t;
  typedef logic [(WIDTH > 1 ? $clog2(WIDTH) : 1)-1:0] issue_idx_t;

  // Store instruction status
  typedef enum logic [3:0] {
    STORE_S_EMPTY,
    STORE_S_RS12_PENDING,
    STORE_S_RS1_PENDING,
    STORE_S_RS2_PENDING,
    STORE_S_ADDR_REQ,
    STORE_S_ADDR_WAIT,
    STORE_S_ADDR_READY_RS2_PENDING,
    STORE_S_WAIT_ROB,
    STORE_S_MEM_REQ,
    STORE_S_MEM_WAIT,
    STORE_S_COMPLETED,
    STORE_S_ADDR_WAIT_RS2_PENDING
  } sb_state_t;

  // Store instruction data
  typedef struct packed {
    rob_idx_t        rs1_rob_idx;
    logic [XLEN-1:0] rs1_value;
    rob_idx_t        rs2_rob_idx;
    logic [XLEN-1:0] rs2_value;
    ldst_width_t     store_type;
    rob_idx_t        dest_rob_idx;
    logic [XLEN-1:0] imm_addr_value;             // immediate offset, then the calculated address
    logic            except_raised;
    except_code_t    except_code;
  } sb_data_t;

  // Store instruction command; address capture may also save a pending rs2.
  typedef enum logic [3:0] {
    STORE_OP_NONE,
    STORE_OP_PUSH,
    STORE_OP_POP,
    STORE_OP_SAVE_RS1,
    STORE_OP_SAVE_RS2,
    STORE_OP_SAVE_RS12,
    STORE_OP_SAVE_ADDR,
    STORE_OP_SAVE_ADDR_RS2,
    STORE_OP_SAVE_MEM
  } sb_op_t;

  // ----------------
  // INTERNAL SIGNALS
  // ----------------
  // Store buffer data
  sb_data_t [DEPTH-1:0] data, next_data;
  sb_state_t [DEPTH-1:0] curr_state, next_state;

  // Per-entry data update commands and operand wakeup controls
  sb_op_t     [DEPTH-1:0] sb_op;
  issue_idx_t [DEPTH-1:0] push_lane;  // accepted issue lane for PUSH
  logic [DEPTH-1:0] match_rs1, match_rs2;

  // Circular queue pointers and address selection indices
  idx_t head_idx, tail_idx, next_head, next_tail, addr_idx;

  // Address candidates in circular age order: head to end, then zero to head.
  logic [DEPTH-1:0] first_candidates, second_candidates;
  idx_t first_idx, second_idx;
  logic first_valid, second_valid;

  // Address request and memory response control
  logic addr_selected, addr_accepted, save_addr;
  logic mem_accepted, mem_done;

  // Multi-issue allocation count and insertion indices
  logic [$clog2(WIDTH+1)-1:0] push_count;
  logic [WIDTH-1:0] push_en;
  logic [WIDTH-1:0][IdxW-1:0] insert_idx;
  logic unused_push_empty;
  logic resident_stores_remain;

  // -----------------
  // OUTPUT EVALUATION
  // -----------------
  // Issue_stage
  for (genvar k = 0; k < WIDTH; k++) begin : gen_allocation
    assign insert_idx[k] = DEPTH == 1 ? '0 : tail_idx + idx_t'(k);
    if (k < DEPTH) begin : gen_slot
      assign issue_ready_o[k] = curr_state[insert_idx[k]] == STORE_S_EMPTY;
    end else begin : gen_blocked
      assign issue_ready_o[k] = 1'b0;
    end
  end

  // Load_buffer: retain forwarding metadata until the store is removed
  for (genvar i = 0; i < DEPTH; i++) begin : gen_forwarding
    assign sq_addr_ready_o[i] = curr_state[i] inside {
      STORE_S_ADDR_READY_RS2_PENDING, STORE_S_WAIT_ROB, STORE_S_MEM_REQ,
      STORE_S_MEM_WAIT, STORE_S_COMPLETED
    };
    // A completed address fault can supply speculative data until the ROB flushes.
    assign sq_data_ready_o[i] = curr_state[i] inside {
      STORE_S_RS1_PENDING, STORE_S_ADDR_REQ, STORE_S_ADDR_WAIT,
      STORE_S_WAIT_ROB, STORE_S_MEM_REQ, STORE_S_MEM_WAIT, STORE_S_COMPLETED
    };
    assign sq_addr_o[i] = data[i].imm_addr_value;
    assign sq_data_o[i] = data[i].rs2_value;
    assign sq_type_o[i] = data[i].store_type;
  end
  assign sq_head_o = head_idx;

  // Commit_stage
  assign comm_mem_idx_o = data[head_idx].dest_rob_idx;

  // CDB: report the memory address for exception handling
  assign cdb_valid_o = curr_state[head_idx] == STORE_S_COMPLETED && !flush_i;
  assign cdb_data_o.rob_idx = data[head_idx].dest_rob_idx;
  assign cdb_data_o.res_value = data[head_idx].imm_addr_value;
  assign cdb_data_o.except_raised = data[head_idx].except_raised;
  assign cdb_data_o.except_code = data[head_idx].except_code;
  assign cdb_data_o.flags.raw = '0;
  assign sq_removed_o = cdb_valid_o && cdb_ready_i;

  // Memory_system
  // Issue from WAIT_ROB as soon as permission arrives; MEM_REQ holds a stalled request.
  assign mem_valid_o = (curr_state[head_idx] inside {STORE_S_WAIT_ROB, STORE_S_MEM_REQ}) && comm_mem_clear_i;
  assign mem_ready_o = 1'b1;
  assign mem_we_o = 1'b1;
  assign mem_addr_o = data[head_idx].imm_addr_value;
  assign mem_wdata_o = data[head_idx].rs2_value;
  assign mem_tag_o = Len5Cfg.BUFF_IDX_LEN'(head_idx);
  assign mem_accepted = mem_valid_o && mem_ready_i;
  assign mem_done = mem_valid_i && mem_ready_o && mem_tag_i == mem_tag_o &&
      (curr_state[head_idx] == STORE_S_MEM_WAIT || mem_accepted);

  // Byte enable
  always_comb begin : mux_byte_en
    unique case (data[head_idx].store_type)
      S_BYTE:       mem_be_o = 8'b0000_0001;
      S_HALFWORD:   mem_be_o = 8'b0000_0011;
      S_WORD:       mem_be_o = 8'b0000_1111;
      S_DOUBLEWORD: mem_be_o = 8'b1111_1111;
      default:      mem_be_o = 8'b0000_0000;
    endcase
  end

  // -----------------
  // ADDRESS SELECTION
  // -----------------
  for (genvar i = 0; i < DEPTH; i++) begin : gen_addr_candidates
    // Store data may still be pending when its address is requested.
    assign first_candidates[i] = (curr_state[i] inside {STORE_S_RS2_PENDING, STORE_S_ADDR_REQ}) && i >= int'(head_idx);
    assign second_candidates[i] = (curr_state[i] inside {STORE_S_RS2_PENDING, STORE_S_ADDR_REQ}) && i < int'(head_idx);
  end

  if (DEPTH == 1) begin : gen_single_addr
    assign first_idx    = '0;
    assign second_idx   = '0;
    assign first_valid  = first_candidates[0];
    assign second_valid = second_candidates[0];
  end else begin : gen_addr_encoders
    prio_enc #(
      .N  (DEPTH),
      .INV(1'b1)
    ) u_first_addr (
      .lines_i(first_candidates),
      .enc_o  (first_idx),
      .valid_o(first_valid)
    );

    prio_enc #(
      .N  (DEPTH),
      .INV(1'b1)
    ) u_second_addr (
      .lines_i(second_candidates),
      .enc_o  (second_idx),
      .valid_o(second_valid)
    );
  end

  always_comb begin : select_address
    if (first_valid) begin
      addr_idx      = first_idx;
      addr_selected = 1'b1;
    end else begin
      addr_idx      = second_idx;
      addr_selected = second_valid;
    end
  end

  // Address_adder
  assign adder_valid_o = addr_selected;
  assign adder_ready_o = 1'b1;
  assign adder_req_o.tag = Len5Cfg.BUFF_IDX_LEN'(addr_idx);
  assign adder_req_o.ls_type = data[addr_idx].store_type;
  assign adder_req_o.base = data[addr_idx].rs1_value;
  assign adder_req_o.offs = data[addr_idx].imm_addr_value;
  assign addr_accepted = adder_valid_o && adder_ready_i;
  assign save_addr = adder_valid_i &&
      ((curr_state[adder_ans_i.tag] inside {STORE_S_ADDR_WAIT, STORE_S_ADDR_WAIT_RS2_PENDING}) ||
       (addr_accepted && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(addr_idx)));

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------
  // Pending states decide which matching operands are still needed.
  always_comb begin : p_operand_match
    foreach (curr_state[i]) begin
      match_rs1[i] = cdb_valid_i && data[i].rs1_rob_idx == cdb_data_i.rob_idx;
      match_rs2[i] = cdb_valid_i && data[i].rs2_rob_idx == cdb_data_i.rob_idx;
    end
  end

  // Circular pointer control; LSU supplies an oldest-first accepted store prefix.
  assign push_en = issue_valid_i & issue_ready_o;
  lzc #(
    .WIDTH(WIDTH + 1),
    .MODE (1'b0)
  ) u_push_count (
    .in_i   ({1'b1, ~push_en}),
    .cnt_o  (push_count),
    .empty_o(unused_push_empty)
  );

  assign next_head = DEPTH == 1 ? '0 : head_idx + idx_t'(sq_removed_o);
  assign next_tail = DEPTH == 1 ? '0 : tail_idx + idx_t'(push_count);
  assign resident_stores_remain = sq_removed_o ?
      (DEPTH > 1 && curr_state[next_head] != STORE_S_EMPTY) : curr_state[head_idx] != STORE_S_EMPTY;

  // The LSU selects the boundary using the number of stores before each load.
  for (genvar k = 0; k <= WIDTH; k++) begin : gen_issue_boundaries
    assign issue_sq_tail_o[k] = DEPTH == 1 ? '0 : tail_idx + idx_t'(k);
  end

  // An accepted prefix contains a new store exactly when lane zero is accepted.
  assign issue_older_stores_remain_o = {{WIDTH{resident_stores_remain || push_en[0]}}, resident_stores_remain};

  // State progression. Each state selects its own instruction-data command.
  always_comb begin : p_state_prog
    next_state = curr_state;
    push_lane  = '0;
    foreach (sb_op[i]) sb_op[i] = STORE_OP_NONE;

    foreach (curr_state[i]) begin
      case (curr_state[i])
        STORE_S_EMPTY: begin  // Allocate only accepted lanes targeting this free slot
          for (int k = 0; k < WIDTH; k++) begin
            if (push_en[k] && insert_idx[k] == idx_t'(i)) begin
              sb_op[i]     = STORE_OP_PUSH;
              push_lane[i] = issue_idx_t'(k);
              if (!issue_rs1_i[k].ready && !issue_rs2_i[k].ready) begin
                next_state[i] = STORE_S_RS12_PENDING;
              end else if (!issue_rs1_i[k].ready) begin
                next_state[i] = STORE_S_RS1_PENDING;
              end else if (!issue_rs2_i[k].ready) begin
                next_state[i] = STORE_S_RS2_PENDING;
              end else begin
                next_state[i] = STORE_S_ADDR_REQ;
              end
            end
          end
        end
        STORE_S_RS12_PENDING: begin  // Save either or both operands from CDB
          if (match_rs1[i] && match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS12;
            next_state[i] = STORE_S_ADDR_REQ;
          end else if (match_rs1[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS1;
            next_state[i] = STORE_S_RS2_PENDING;
          end else if (match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS2;
            next_state[i] = STORE_S_RS1_PENDING;
          end
        end
        STORE_S_RS1_PENDING: begin
          if (match_rs1[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS1;
            next_state[i] = STORE_S_ADDR_REQ;
          end
        end
        STORE_S_RS2_PENDING: begin  // Address calculation need not wait for store data
          if (save_addr && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            if (match_rs2[i]) begin
              sb_op[i]      = STORE_OP_SAVE_ADDR_RS2;
              next_state[i] = adder_ans_i.except_raised ? STORE_S_COMPLETED : STORE_S_WAIT_ROB;
            end else begin
              sb_op[i]      = STORE_OP_SAVE_ADDR;
              next_state[i] = adder_ans_i.except_raised ? STORE_S_COMPLETED : STORE_S_ADDR_READY_RS2_PENDING;
            end
          end else if (addr_accepted && addr_idx == idx_t'(i)) begin
            if (match_rs2[i]) begin
              sb_op[i]      = STORE_OP_SAVE_RS2;
              next_state[i] = STORE_S_ADDR_WAIT;
            end else begin
              next_state[i] = STORE_S_ADDR_WAIT_RS2_PENDING;
            end
          end else if (match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS2;
            next_state[i] = STORE_S_ADDR_REQ;
          end
        end
        STORE_S_ADDR_REQ, STORE_S_ADDR_WAIT: begin  // Both operands are ready
          if (save_addr && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            sb_op[i]      = STORE_OP_SAVE_ADDR;
            next_state[i] = adder_ans_i.except_raised ? STORE_S_COMPLETED : STORE_S_WAIT_ROB;
          end else if (addr_accepted && addr_idx == idx_t'(i)) begin
            next_state[i] = STORE_S_ADDR_WAIT;
          end
        end
        STORE_S_ADDR_WAIT_RS2_PENDING: begin  // Remember a data wakeup before the address response
          if (save_addr && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            if (match_rs2[i]) begin
              sb_op[i]      = STORE_OP_SAVE_ADDR_RS2;
              next_state[i] = adder_ans_i.except_raised ? STORE_S_COMPLETED : STORE_S_WAIT_ROB;
            end else begin
              sb_op[i]      = STORE_OP_SAVE_ADDR;
              next_state[i] = adder_ans_i.except_raised ? STORE_S_COMPLETED : STORE_S_ADDR_READY_RS2_PENDING;
            end
          end else if (match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS2;
            next_state[i] = STORE_S_ADDR_WAIT;
          end
        end
        STORE_S_ADDR_READY_RS2_PENDING: begin
          if (match_rs2[i]) begin
            sb_op[i]      = STORE_OP_SAVE_RS2;
            next_state[i] = STORE_S_WAIT_ROB;
          end
        end
        STORE_S_WAIT_ROB: begin  // Only the authorized head may request a write
          if (idx_t'(i) == head_idx && comm_mem_clear_i) begin
            if (mem_accepted && mem_done) begin
              sb_op[i]      = STORE_OP_SAVE_MEM;
              next_state[i] = STORE_S_COMPLETED;
            end else if (mem_accepted) begin
              next_state[i] = STORE_S_MEM_WAIT;
            end else begin
              next_state[i] = STORE_S_MEM_REQ;
            end
          end
        end
        STORE_S_MEM_REQ: begin
          if (mem_accepted && mem_done) begin
            sb_op[i]      = STORE_OP_SAVE_MEM;
            next_state[i] = STORE_S_COMPLETED;
          end else if (mem_accepted) begin
            next_state[i] = STORE_S_MEM_WAIT;
          end else if (!comm_mem_clear_i) begin
            next_state[i] = STORE_S_WAIT_ROB;
          end
        end
        STORE_S_MEM_WAIT: begin
          if (mem_done) begin
            sb_op[i]      = STORE_OP_SAVE_MEM;
            next_state[i] = STORE_S_COMPLETED;
          end
        end
        STORE_S_COMPLETED: begin
          if (sq_removed_o && head_idx == idx_t'(i)) begin
            sb_op[i]      = STORE_OP_POP;
            next_state[i] = STORE_S_EMPTY;
          end
        end
        default: ;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni || flush_i) curr_state <= '0;
    else curr_state <= next_state;
  end

  // -------------------
  // STORE BUFFER UPDATE
  // -------------------
  // Execute the selected instruction-data command.
  always_comb begin : p_data_update
    next_data = data;
    foreach (sb_op[i]) begin
      case (sb_op[i])
        STORE_OP_PUSH: begin
          next_data[i]                = '0;
          next_data[i].rs1_rob_idx    = issue_rs1_i[push_lane[i]].rob_idx;
          next_data[i].rs1_value      = issue_rs1_i[push_lane[i]].value;
          next_data[i].rs2_rob_idx    = issue_rs2_i[push_lane[i]].rob_idx;
          next_data[i].rs2_value      = issue_rs2_i[push_lane[i]].value;
          next_data[i].store_type     = issue_type_i[push_lane[i]];
          next_data[i].dest_rob_idx   = issue_dest_rob_idx_i[push_lane[i]];
          next_data[i].imm_addr_value = issue_imm_i[push_lane[i]];
        end
        STORE_OP_POP: next_data[i] = '0;
        STORE_OP_SAVE_RS1: begin

          next_data[i].rs1_value = cdb_data_i.res_value;
        end
        STORE_OP_SAVE_RS2: begin

          next_data[i].rs2_value = cdb_data_i.res_value;
        end
        STORE_OP_SAVE_RS12: begin

          next_data[i].rs1_value = cdb_data_i.res_value;

          next_data[i].rs2_value = cdb_data_i.res_value;
        end
        STORE_OP_SAVE_ADDR: begin
          next_data[i].imm_addr_value = adder_ans_i.result;
          next_data[i].except_raised  = adder_ans_i.except_raised;
          next_data[i].except_code    = adder_ans_i.except_code;
        end
        STORE_OP_SAVE_ADDR_RS2: begin
          next_data[i].imm_addr_value = adder_ans_i.result;
          next_data[i].except_raised  = adder_ans_i.except_raised;
          next_data[i].except_code    = adder_ans_i.except_code;
          next_data[i].rs2_value      = cdb_data_i.res_value;
        end
        STORE_OP_SAVE_MEM: begin
          next_data[i].except_raised = mem_except_raised_i;
          next_data[i].except_code   = mem_except_code_i;
        end
        default:      ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_sb_update
    if (!rst_ni || flush_i) begin
      foreach (data[i]) data[i] <= '0;
      head_idx      <= '0;
      tail_idx      <= '0;
    end else begin
      data          <= next_data;
      head_idx      <= next_head;
      tail_idx      <= next_tail;
    end
  end

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
  logic [DEPTH-1:0] occupied_slots;
  for (genvar i = 0; i < DEPTH; i++) begin : gen_occupancy_check
    assign occupied_slots[i] = curr_state[i] != STORE_S_EMPTY;
  end

  always @(posedge clk_i)
    if (rst_ni) begin
      int outstanding;
      outstanding = 0;
      foreach (curr_state[i]) if (curr_state[i] == STORE_S_MEM_WAIT) outstanding++;
      assert (outstanding <= 1)
      else $fatal(1, "multiple outstanding precise stores");
      assert (flush_i || (push_en & (push_en + 1'b1)) == '0)
      else $fatal(1, "SQ allocations must be an oldest prefix");
      // Commit authorization must make an accepted store irrevocable.
      assert (!flush_i || (outstanding == 0 && !mem_accepted))
      else $fatal(1, "flush interrupted an authorized store write");
      assert (tail_idx == (DEPTH == 1 ? '0 : head_idx + idx_t'($countones(occupied_slots))))
      else $fatal(1, "SQ tail does not follow its occupied prefix");
      for (int age = 0; age < DEPTH; age++)
      assert (occupied_slots[idx_t'(head_idx+idx_t'(age))] == (age < $countones(occupied_slots)))
      else $fatal(1, "SQ is not a circular prefix");
      foreach (data[i]) begin
        if (!flush_i && (curr_state[i] inside {STORE_S_RS12_PENDING, STORE_S_RS1_PENDING}) && (next_state[i] inside {STORE_S_RS2_PENDING, STORE_S_ADDR_REQ}))
          assert (match_rs1[i])
          else $fatal(1, "store advanced before rs1 wakeup");
        if (!flush_i && curr_state[i] == STORE_S_RS12_PENDING && (next_state[i] inside {STORE_S_RS1_PENDING, STORE_S_ADDR_REQ}))
          assert (match_rs2[i])
          else $fatal(1, "store advanced before rs2 wakeup");
        if (!flush_i && (curr_state[i] inside {STORE_S_RS2_PENDING, STORE_S_ADDR_WAIT_RS2_PENDING,
                                             STORE_S_ADDR_READY_RS2_PENDING}) &&
            (next_state[i] inside {STORE_S_ADDR_REQ, STORE_S_ADDR_WAIT, STORE_S_WAIT_ROB, STORE_S_COMPLETED}))
          assert (match_rs2[i] ||
                  (next_state[i] == STORE_S_COMPLETED && save_addr &&
                   adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i) && adder_ans_i.except_raised))
          else $fatal(1, "address-ready store advanced before rs2 wakeup");
      end
      if (mem_valid_i && mem_ready_o) begin
        assert ((curr_state[head_idx] == STORE_S_MEM_WAIT || mem_accepted) && mem_tag_i == mem_tag_o)
        else $fatal(1, "unowned store response");
      end
      if (!flush_i)
        for (int k = 0; k < WIDTH; k++)
        if (issue_valid_i[k] && issue_ready_o[k]) begin
          assert (!occupied_slots[insert_idx[k]])
          else $fatal(1, "SQ overwrite");
          for (int j = 0; j < k; j++)
          if (issue_valid_i[j] && issue_ready_o[j])
            assert (insert_idx[j] != insert_idx[k])
            else $fatal(1, "duplicate SQ allocation");
        end
    end
`endif
endmodule
