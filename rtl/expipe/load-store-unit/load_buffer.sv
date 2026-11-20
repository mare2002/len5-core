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
// File: load_buffer.sv
// Author: Michele Caon
// Date: 15/07/2022

// Reservation-station load queue. A killed transaction owns its slot until its
// response drains; a recycled ROB tag can never capture an old response.
module load_buffer #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type adder_req_t = `LEN5_ADDER_REQ_T(Len5Cfg),
  localparam type adder_ans_t = `LEN5_ADDER_ANS_T(Len5Cfg),
  localparam int unsigned DEPTH = Len5Cfg.LDBUFF_DEPTH,
  localparam int unsigned SQ_DEPTH = Len5Cfg.STBUFF_DEPTH,
  localparam int unsigned WIDTH = Len5Cfg.LDBUFF_ISSUE_WIDTH,
  localparam int unsigned IdxW = DEPTH > 1 ? $clog2(DEPTH) : 1,
  localparam int unsigned SqIdxW = SQ_DEPTH > 1 ? $clog2(SQ_DEPTH) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Issue_stage
  input  logic                    [WIDTH-1:0]                     issue_valid_i,
  output logic                    [WIDTH-1:0]                     issue_ready_o,
  input  expipe_pkg::ldst_width_t [WIDTH-1:0]                     issue_type_i,
  input  op_data_t                [WIDTH-1:0]                     issue_rs1_i,
  input  logic                    [WIDTH-1:0][len5_pkg::XLEN-1:0] issue_imm_i,
  input  rob_idx_t                [WIDTH-1:0]                     issue_dest_rob_idx_i,
  input  logic                    [WIDTH-1:0][        SqIdxW-1:0] issue_sq_tail_i,
  input  logic                    [WIDTH-1:0]                     issue_older_stores_remain_i,

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

  // Store_buffer
  input  logic                    [  SqIdxW-1:0]                     sq_head_i,
  input  logic                                                       sq_removed_i,
  input  logic                    [SQ_DEPTH-1:0]                     sq_addr_ready_i,
  input  logic                    [SQ_DEPTH-1:0]                     sq_data_ready_i,
  input  logic                    [SQ_DEPTH-1:0][len5_pkg::XLEN-1:0] sq_addr_i,
  input  logic                    [SQ_DEPTH-1:0][len5_pkg::XLEN-1:0] sq_data_i,
  input  expipe_pkg::ldst_width_t [SQ_DEPTH-1:0]                     sq_type_i,

  // Memory_system
  output logic                                              mem_valid_o,
  input  logic                                              mem_ready_i,
  input  logic                                              mem_valid_i,
  output logic                                              mem_ready_o,
  output logic                                              mem_we_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_addr_o,
  output logic                   [                     7:0] mem_be_o,
  output logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_tag_o,
  input  logic                   [      len5_pkg::XLEN-1:0] mem_rdata_i,
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
  typedef logic [SqIdxW-1:0] sq_idx_t;
  typedef logic [(WIDTH > 1 ? $clog2(WIDTH) : 1)-1:0] issue_idx_t;

  // Load instruction status
  typedef enum logic [3:0] {
    LOAD_S_EMPTY,
    LOAD_S_RS1_PENDING,
    LOAD_S_ADDR_REQ,
    LOAD_S_ADDR_WAIT,
    LOAD_S_DEP_WAIT,
    LOAD_S_MEM_WAIT,
    LOAD_S_COMPLETED,
    LOAD_S_KILLED
  } lb_state_t;

  // Load instruction data
  typedef struct packed {
    ldst_width_t       load_type;
    rob_idx_t          rs1_rob_idx;
    logic [XLEN-1:0]   rs1_value;            // base operand, then raw load result
    logic [2:0]        byte_offset;          // position within the raw load result
    rob_idx_t          dest_rob_idx;
    logic [XLEN-1:0]   imm_addr_value;      // immediate offset, then the calculated address
    // Exclusive SQ boundary; the flag distinguishes a full prefix from a drained one.
    logic [SqIdxW-1:0] saved_tail_idx;
    logic              older_stores_remain;
    logic              except_raised;
    except_code_t      except_code;
  } lb_data_t;

  // Load instruction command
  typedef enum logic [2:0] {
    LOAD_OP_NONE,
    LOAD_OP_PUSH,
    LOAD_OP_SAVE_RS1,
    LOAD_OP_SAVE_ADDR,
    LOAD_OP_SAVE_FORWARD,
    LOAD_OP_SAVE_MEM
  } lb_op_t;

  // ----------------
  // INTERNAL SIGNALS
  // ----------------
  // Load buffer data
  lb_data_t [DEPTH-1:0] data, next_data;
  lb_state_t [DEPTH-1:0] curr_state, next_state;

  // Per-entry data update commands
  lb_op_t     [DEPTH-1:0] lb_op;
  issue_idx_t [DEPTH-1:0] push_lane;  // accepted issue lane for PUSH

  // Free entries and execution candidates
  logic [DEPTH-1:0] free_slots, addr_candidates, mem_candidates, result_candidates;

  // Store dependencies and forwarded values
  logic [DEPTH-1:0] dep_blocked, forward_valid;
  logic [DEPTH-1:0][XLEN-1:0] forward_value;
  logic [DEPTH-1:0][2:0] forward_offset;
  logic [SqIdxW-1:0] sq_next_head;
  logic [SQ_DEPTH-1:0][2:0] store_offset_mask;

  // Multi-issue allocation indices and availability
  logic [WIDTH-1:0][IdxW-1:0] new_idx;
  logic [WIDTH-1:0]           new_valid;

  // Selected address, memory, and result entries
  idx_t addr_idx, mem_idx, result_idx;
  logic addr_selected, mem_selected, result_selected;
  logic addr_accepted, mem_accepted, result_fire, save_mem;

  // Selected and extended load result
  logic [XLEN-1:0] result_value;

  // -----------------------
  // LOAD ALLOCATION CONTROL
  // -----------------------
  prio_enc_multi #(
    .N          (DEPTH),
    .NUM_RESULTS(WIDTH),
    .INV        (1'b1)
  ) u_free_slots (
    .lines_i(free_slots),
    .enc_o  (new_idx),
    .valid_o(new_valid)
  );
  assign issue_ready_o = new_valid;
  for (genvar i = 0; i < DEPTH; i++) begin : gen_candidates
    assign free_slots[i]        = curr_state[i] == LOAD_S_EMPTY;
    assign addr_candidates[i]   = curr_state[i] == LOAD_S_ADDR_REQ;
    assign mem_candidates[i]    = curr_state[i] == LOAD_S_DEP_WAIT && !dep_blocked[i];
    assign result_candidates[i] = curr_state[i] == LOAD_S_COMPLETED;
  end

  // ----------------------
  // LOAD-AFTER-STORE CONTROL
  // ----------------------
  assign sq_next_head = SQ_DEPTH == 1 ? '0 : sq_head_i + 1'b1;

  for (genvar s = 0; s < SQ_DEPTH; s++) begin : gen_store_size
    always_comb begin : size_decode
      unique case (sq_type_i[s])
        S_BYTE:       store_offset_mask[s] = 3'b000;
        S_HALFWORD:   store_offset_mask[s] = 3'b001;
        S_WORD:       store_offset_mask[s] = 3'b011;
        S_DOUBLEWORD: store_offset_mask[s] = 3'b111;
        default:      store_offset_mask[s] = '0;
      endcase
    end
  end

  for (genvar l = 0; l < DEPTH; l++) begin : gen_dependencies
    logic [2:0] load_offset_mask;
    logic [SQ_DEPTH-1:0] older_stores, unresolved_stores, overlapping_stores, can_forward;
    logic [SQ_DEPTH-1:0] wrapped_matches, linear_matches;
    sq_idx_t youngest_idx;
    logic overlap_valid, unresolved, forward_allowed;

    always_comb begin : size_decode
      unique case (data[l].load_type)
        L_BYTE, L_BYTE_U:         load_offset_mask = 3'b000;
        L_HALFWORD, L_HALFWORD_U: load_offset_mask = 3'b001;
        L_WORD, L_WORD_U:         load_offset_mask = 3'b011;
        L_DOUBLEWORD:            load_offset_mask = 3'b111;
        default:                 load_offset_mask = '0;
      endcase
    end

    for (genvar s = 0; s < SQ_DEPTH; s++) begin : gen_store_match
      logic same_block, overlap, complete_match;
      logic [2:0] offset_diff;

      // The saved exclusive boundary limits the circular prefix of older stores.
      always_comb begin : older_store_mask
        if (!data[l].older_stores_remain) begin
          older_stores[s] = 1'b0;
        end else if (sq_head_i < data[l].saved_tail_idx) begin
          older_stores[s] = s >= int'(sq_head_i) && s < int'(data[l].saved_tail_idx);
        end else if (sq_head_i > data[l].saved_tail_idx) begin
          older_stores[s] = s >= int'(sq_head_i) || s < int'(data[l].saved_tail_idx);
        end else begin
          older_stores[s] = 1'b1;  // Equal boundaries with the flag set mean a full prefix.
        end
      end

      // Naturally aligned accesses overlap when they share the larger access's block.
      assign same_block = data[l].imm_addr_value[XLEN-1:3] == sq_addr_i[s][XLEN-1:3];
      assign offset_diff = data[l].imm_addr_value[2:0] ^ sq_addr_i[s][2:0];
      assign overlap = same_block && (offset_diff & ~(load_offset_mask | store_offset_mask[s])) == '0;
      assign complete_match = overlap && load_offset_mask <= store_offset_mask[s];
      assign unresolved_stores[s] = older_stores[s] && !sq_addr_ready_i[s];
      assign overlapping_stores[s] = older_stores[s] && sq_addr_ready_i[s] && overlap;
      assign can_forward[s] = Len5Cfg.LEN5_STORE_LOAD_FWD_EN && complete_match &&
          sq_data_ready_i[s] &&
          (sq_addr_i[s] & Len5Cfg.MMAP_MASK) == '0 &&
          (data[l].imm_addr_value & Len5Cfg.MMAP_MASK) == '0;

      // Wrapped entries are younger than entries at or above the SQ head.
      assign wrapped_matches[s] = overlapping_stores[s] && s < int'(sq_head_i);
      assign linear_matches[s] = overlapping_stores[s] && s >= int'(sq_head_i);
    end

    if (SQ_DEPTH == 1) begin : gen_single_store
      assign youngest_idx = '0;
      assign overlap_valid = overlapping_stores[0];
    end else begin : gen_youngest_store
      sq_idx_t wrapped_idx, linear_idx;
      logic wrapped_valid, linear_valid;

      prio_enc #(
        .N  (SQ_DEPTH),
        .INV(1'b0)
      ) u_wrapped_match (
        .lines_i(wrapped_matches),
        .enc_o  (wrapped_idx),
        .valid_o(wrapped_valid)
      );
      prio_enc #(
        .N  (SQ_DEPTH),
        .INV(1'b0)
      ) u_linear_match (
        .lines_i(linear_matches),
        .enc_o  (linear_idx),
        .valid_o(linear_valid)
      );
      assign youngest_idx = wrapped_valid ? wrapped_idx : linear_idx;
      assign overlap_valid = wrapped_valid || linear_valid;
    end

    // A younger partial match must block an older full match; bytes are not merged.
    assign unresolved = |unresolved_stores;
    assign forward_allowed = !unresolved && overlap_valid && can_forward[youngest_idx];
    assign forward_valid[l] = forward_allowed;
    assign dep_blocked[l] = unresolved || (overlap_valid && !forward_allowed);
    // A naturally aligned store has zeroes in the address bits covered by its mask.
    assign forward_offset[l] = data[l].imm_addr_value[2:0] & store_offset_mask[youngest_idx];
    assign forward_value[l] = sq_data_i[youngest_idx];
  end

  // ---------------
  // ENTRY SELECTION
  // ---------------
  if (!Len5Cfg.LDBUFF_RR_ARBITER) begin : gen_addr_prio
    prio_enc #(
      .N  (DEPTH),
      .INV(1'b1)
    ) u_addr_arbiter (
      .lines_i(addr_candidates),
      .enc_o  (addr_idx),
      .valid_o(addr_selected)
    );
  end else begin : gen_addr_rr
    rr_arbiter_multi #(
      .N          (DEPTH),
      .NUM_OUTPUTS(1)
    ) u_addr_arbiter (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i (addr_candidates),
      .ready_o (),
      .valid_o (addr_selected),
      .ready_i (addr_accepted),
      .served_o(addr_idx)
    );
  end

  if (!Len5Cfg.LDBUFF_RR_ARBITER) begin : gen_mem_prio
    prio_enc #(
      .N  (DEPTH),
      .INV(1'b1)
    ) u_mem_arbiter (
      .lines_i(mem_candidates),
      .enc_o  (mem_idx),
      .valid_o(mem_selected)
    );
  end else begin : gen_mem_rr
    rr_arbiter_multi #(
      .N          (DEPTH),
      .NUM_OUTPUTS(1)
    ) u_mem_arbiter (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i (mem_candidates),
      .ready_o (),
      .valid_o (mem_selected),
      .ready_i (mem_accepted || (mem_selected && forward_valid[mem_idx])),
      .served_o(mem_idx)
    );
  end

  if (!Len5Cfg.LDBUFF_RR_ARBITER) begin : gen_result_prio
    prio_enc #(
      .N  (DEPTH),
      .INV(1'b1)
    ) u_result_arbiter (
      .lines_i(result_candidates),
      .enc_o  (result_idx),
      .valid_o(result_selected)
    );
  end else begin : gen_result_rr
    rr_arbiter_multi #(
      .N          (DEPTH),
      .NUM_OUTPUTS(1)
    ) u_result_arbiter (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i (result_candidates),
      .ready_o (),
      .valid_o (result_selected),
      .ready_i (result_fire),
      .served_o(result_idx)
    );
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------
  // Address_adder
  assign adder_valid_o = addr_selected;
  assign adder_ready_o = 1'b1;
  assign adder_req_o.tag = Len5Cfg.BUFF_IDX_LEN'(addr_idx);
  assign adder_req_o.ls_type = data[addr_idx].load_type;
  assign adder_req_o.base = data[addr_idx].rs1_value;
  assign adder_req_o.offs = data[addr_idx].imm_addr_value;
  assign addr_accepted = adder_valid_o && adder_ready_i;

  // Memory_system
  assign mem_valid_o   = mem_selected && !forward_valid[mem_idx] && (!flush_i || Len5Cfg.LOAD_BUFFER_DRAIN_ON_FLUSH);
  assign mem_ready_o   = 1'b1;
  assign mem_we_o      = 1'b0;
  assign mem_addr_o    = Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES ? {data[mem_idx].imm_addr_value[XLEN-1:3], 3'b000} : data[mem_idx].imm_addr_value;
  assign mem_tag_o     = Len5Cfg.BUFF_IDX_LEN'(mem_idx);
  assign mem_accepted  = mem_valid_o && mem_ready_i;
  assign save_mem      = mem_valid_i && mem_ready_o;

  // Byte enable
  always_comb begin : mux_byte_en
    unique case (data[mem_idx].load_type)
      L_BYTE, L_BYTE_U:         mem_be_o = 8'b0000_0001;
      L_HALFWORD, L_HALFWORD_U: mem_be_o = 8'b0000_0011;
      L_WORD, L_WORD_U:         mem_be_o = 8'b0000_1111;
      L_DOUBLEWORD:            mem_be_o = 8'b1111_1111;
      default:                 mem_be_o = 8'b0000_0000;
    endcase
  end

  // Forwarded data can need byte selection even when memory returns aligned load data.
  if (Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES || Len5Cfg.LEN5_STORE_LOAD_FWD_EN) begin : gen_byte_selector
    byte_selector u_byte_selector (
      .type_i  (data[result_idx].load_type),
      .byte_off(data[result_idx].byte_offset),
      .data_i  (data[result_idx].rs1_value),
      .data_o  (result_value)
    );
  end else begin : gen_sign_extender
    sign_extender u_sign_extender (
      .type_i(data[result_idx].load_type),
      .data_i(data[result_idx].rs1_value),
      .data_o(result_value)
    );
  end

  // CDB
  assign cdb_valid_o              = result_selected && !flush_i;
  assign cdb_data_o.rob_idx       = data[result_idx].dest_rob_idx;
  assign cdb_data_o.res_value     = data[result_idx].except_raised ? data[result_idx].imm_addr_value : result_value;
  assign cdb_data_o.except_raised = data[result_idx].except_raised;
  assign cdb_data_o.except_code   = data[result_idx].except_code;
  assign cdb_data_o.flags.raw     = '0;
  assign result_fire              = cdb_valid_o && cdb_ready_i;

  // -----------------
  // LOAD CONTROL UNIT
  // -----------------
  // State progression. Mealy operations capture responses without an extra cycle.
  always_comb begin : p_state_prog
    next_state = curr_state;
    push_lane  = '0;
    foreach (lb_op[i]) lb_op[i] = LOAD_OP_NONE;

    foreach (curr_state[i]) begin
      case (curr_state[i])
        LOAD_S_EMPTY: begin  // Allocate accepted lanes to their selected free slots
          for (int k = 0; k < WIDTH; k++) begin
            if (issue_valid_i[k] && issue_ready_o[k] && new_idx[k] == idx_t'(i)) begin
              lb_op[i]      = LOAD_OP_PUSH;
              push_lane[i]  = issue_idx_t'(k);
              if (issue_rs1_i[k].ready) begin
                next_state[i] = LOAD_S_ADDR_REQ;
              end else begin
                next_state[i] = LOAD_S_RS1_PENDING;
              end
            end
          end
        end
        LOAD_S_RS1_PENDING: begin  // Save rs1 from CDB
          if (cdb_valid_i && data[i].rs1_rob_idx == cdb_data_i.rob_idx) begin
            lb_op[i]      = LOAD_OP_SAVE_RS1;
            next_state[i] = LOAD_S_ADDR_REQ;
          end
        end
        LOAD_S_ADDR_REQ: begin  // Accept the request and any immediate response
          if (addr_accepted && addr_idx == idx_t'(i) &&
              adder_valid_i && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            lb_op[i]      = LOAD_OP_SAVE_ADDR;
            if (adder_ans_i.except_raised) begin
              next_state[i] = LOAD_S_COMPLETED;
            end else begin
              next_state[i] = LOAD_S_DEP_WAIT;
            end
          end else if (addr_accepted && addr_idx == idx_t'(i)) begin
            next_state[i] = LOAD_S_ADDR_WAIT;
          end
        end
        LOAD_S_ADDR_WAIT: begin  // Save the response belonging to this entry
          if (adder_valid_i && adder_ans_i.tag == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            lb_op[i] = LOAD_OP_SAVE_ADDR;
            if (adder_ans_i.except_raised) begin
              next_state[i] = LOAD_S_COMPLETED;
            end else begin
              next_state[i] = LOAD_S_DEP_WAIT;
            end
          end
        end
        LOAD_S_DEP_WAIT: begin  // Forward or request memory, including an immediate response
          if (mem_accepted && mem_idx == idx_t'(i) && save_mem && mem_tag_i == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            lb_op[i]      = LOAD_OP_SAVE_MEM;
            next_state[i] = LOAD_S_COMPLETED;
          end else if (mem_accepted && mem_idx == idx_t'(i)) begin
            next_state[i] = LOAD_S_MEM_WAIT;
          end else if (mem_selected && mem_idx == idx_t'(i) && forward_valid[i]) begin
            lb_op[i]      = LOAD_OP_SAVE_FORWARD;
            next_state[i] = LOAD_S_COMPLETED;
          end
        end
        LOAD_S_MEM_WAIT: begin  // Save memory data or exception
          if (save_mem && mem_tag_i == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            lb_op[i]      = LOAD_OP_SAVE_MEM;
            next_state[i] = LOAD_S_COMPLETED;
          end
        end
        LOAD_S_COMPLETED: begin  // Release after the completion handshake
          if (result_fire && result_idx == idx_t'(i)) begin
            next_state[i] = LOAD_S_EMPTY;
          end
        end
        LOAD_S_KILLED: begin  // Drain the old response before reusing its tag
          if (save_mem && mem_tag_i == Len5Cfg.BUFF_IDX_LEN'(i)) begin
            next_state[i] = LOAD_S_EMPTY;
          end
        end
        default: ;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) curr_state <= '0;
    else if (flush_i) begin
      // Non-cancelable reads retain their tags until the original response drains.
      foreach (curr_state[i]) begin
        if (Len5Cfg.LOAD_BUFFER_DRAIN_ON_FLUSH &&
            (curr_state[i] inside {LOAD_S_MEM_WAIT, LOAD_S_KILLED} || (mem_accepted && mem_idx == idx_t'(i))) &&
            !(save_mem && mem_tag_i == Len5Cfg.BUFF_IDX_LEN'(i)))
          curr_state[i] <= LOAD_S_KILLED;
        else curr_state[i] <= LOAD_S_EMPTY;
      end
    end else curr_state <= next_state;
  end

  // ------------------
  // LOAD BUFFER UPDATE
  // ------------------
  // Execute the selected instruction-data command; boundary bookkeeping is independent.
  always_comb begin : p_data_update
    next_data = data;
    foreach (lb_op[i]) begin
      if (sq_removed_i && data[i].older_stores_remain && sq_next_head == data[i].saved_tail_idx) next_data[i].older_stores_remain = 1'b0;

      case (lb_op[i])
        LOAD_OP_PUSH: begin
          next_data[i]                     = '0;
          next_data[i].load_type           = issue_type_i[push_lane[i]];
          next_data[i].rs1_rob_idx         = issue_rs1_i[push_lane[i]].rob_idx;
          next_data[i].rs1_value           = issue_rs1_i[push_lane[i]].value;
          next_data[i].dest_rob_idx        = issue_dest_rob_idx_i[push_lane[i]];
          next_data[i].imm_addr_value      = issue_imm_i[push_lane[i]];
          next_data[i].saved_tail_idx      = issue_sq_tail_i[push_lane[i]];
          next_data[i].older_stores_remain = issue_older_stores_remain_i[push_lane[i]];
        end
        LOAD_OP_SAVE_RS1: begin

          next_data[i].rs1_value = cdb_data_i.res_value;
        end
        LOAD_OP_SAVE_ADDR: begin
          next_data[i].imm_addr_value = adder_ans_i.result;
          next_data[i].except_raised  = adder_ans_i.except_raised;
          next_data[i].except_code    = adder_ans_i.except_code;
        end
        LOAD_OP_SAVE_FORWARD: begin
          next_data[i].rs1_value   = forward_value[i];
          next_data[i].byte_offset = forward_offset[i];
        end
        LOAD_OP_SAVE_MEM: begin
          next_data[i].rs1_value     = mem_rdata_i;
          next_data[i].byte_offset   = Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES ? data[i].imm_addr_value[2:0] : '0;
          next_data[i].except_raised = mem_except_raised_i;
          next_data[i].except_code   = mem_except_code_i;
        end
        default:              ;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_lb_update
    if (!rst_ni) begin
      foreach (data[i]) data[i] <= '0;
    end else begin
      data            <= next_data;
      if (flush_i) begin
        foreach (data[i]) data[i].older_stores_remain <= 1'b0;
      end
    end
  end

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
  always_ff @(posedge clk_i)
    if (rst_ni && !flush_i) begin
      for (int k = 0; k < WIDTH; k++)
      if (issue_valid_i[k] && issue_ready_o[k]) begin
        assert (free_slots[new_idx[k]])
        else $fatal(1, "LQ overwrite");
        for (int j = 0; j < k; j++)
        if (issue_valid_i[j] && issue_ready_o[j])
          assert (new_idx[j] != new_idx[k])
          else $fatal(1, "duplicate LQ allocation");
      end
      if (save_mem) begin
        assert (int'(mem_tag_i) < DEPTH)
        else $fatal(1, "invalid load response tag");
        assert (curr_state[mem_tag_i] inside {LOAD_S_MEM_WAIT, LOAD_S_KILLED} || (mem_accepted && mem_tag_i == mem_tag_o))
        else $fatal(1, "unowned load response");
      end
    end
`endif
endmodule
