// Copyright 2024 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: early_jump_unit.sv
// Author: Vincenzo Petrolo
//         Michele Caon
// Date: 28/02/2024

module early_jump_unit (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  input  len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_i,
  input  logic                                        instr_valid_i,
  input  logic                                        issue_ready_i,
  input  fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] mem_if_pred_i,
  input  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_i,
  output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_o,
  input  logic                   [len5_pkg::XLEN-1:0] early_jump_target_i,
  input  logic                                        call_confirm_i,
  input  logic                                        ret_confirm_i,
  input  logic [len5_pkg::ALEN-1:0]                   res_link_addr_i,
  output fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_pred_o,
  output logic                                        early_jump_valid_o,
  output logic                                        mem_flush_o,
  output logic                   [len5_pkg::XLEN-1:0] early_jump_base_o,
  output logic                   [len5_pkg::XLEN-1:0] early_jump_offs_o
);

  import len5_pkg::*;
  import len5_config_pkg::*;
  import instr_pkg::JAL;
  import instr_pkg::JALR;

  function int clamp(int x);
    if (x < 0) x = 0;
    return x;
  endfunction

  //TODO Check with Michele, here we need to check every instruction and it's prediction
  //One question is we don't need to propagate the all of the predictions in the memory fetch unit, because only one can happen in one isntruction bundle
  //this might lower the number of bits that we are transfering  

  // PARAMETERS
  localparam logic [ILEN-1:0] RET = {12'b0, 5'b00001, 3'b000, 5'b00000, JALR[OPCODE_LEN-1:0]};

  // INTERNAL SIGNALS
  // ----------------
  // JUMP type
  typedef enum logic [1:0] {
    JUMP_TYPE_JAL,
    JUMP_TYPE_CALL,
    JUMP_TYPE_RET,
    JUMP_TYPE_NONE
  } jump_type_t;
  jump_type_t jump_type;

  // FSM state
  typedef enum logic [1:0] {
    RESET,
    IDLE,
    WAIT_ISSUE
  } fsm_state_t;
  fsm_state_t curr_state, next_state;
  logic target_valid;  // For resource sharing, in case synopsys fails recognizing it

  // Target address
  logic [ALEN-1:0] early_jump_base, early_jump_offs, ras_addr;

  // Link address
  logic [ALEN-1:0] link_addr;

  // RAS control
  logic ras_push, ras_pop;
  logic ras_addr_valid;

  // --------------------
  // FINITE STATE MACHINE
  // --------------------
  
  // Jump instruction decoder and locator of jump instruction
  // Separated in two parts, one when the issue is 1 and the other where it's for more than one issue
  
  logic [LEN5_MULTIPLE_ISSUES-1:0] jump_valid;
  logic [clamp(LEN5_MULTIPLE_ISSUES_BITS-1):0]jump_location;
  
  generate
    if (LEN5_MULTIPLE_ISSUES == 32'd1) begin : gen_single_issue
      assign jump_location = '0;
      assign jump_valid = 1'b1;

      always_comb begin : jump_dec
        jump_type = JUMP_TYPE_NONE;

        if (valid_instr_i[0]) begin
          if (instr_i[0].raw == RET) jump_type = JUMP_TYPE_RET;
          else if (instr_i[0].j.opcode == JAL[OPCODE_LEN-1:0] && instr_i[0].j.rd == 5'b00001) jump_type = JUMP_TYPE_CALL;
          else if (instr_i[0].j.opcode == JAL[OPCODE_LEN-1:0]) jump_type = JUMP_TYPE_JAL;
        end
      end
    end else begin : gen_multiple_issues
      always_comb begin : jump_dec
        jump_type = JUMP_TYPE_NONE;
        jump_location = {LEN5_MULTIPLE_ISSUES_BITS{1'b1}};

        for(int i = LEN5_MULTIPLE_ISSUES; i >= 0; i--) begin : jump_type_of_oldest_instr
          if (valid_instr_i[i]) begin
            if (instr_i[i].raw == RET) begin
              jump_type = JUMP_TYPE_RET;
              jump_location = i[LEN5_MULTIPLE_ISSUES_BITS-1:0];
            end
            else if (instr_i[i].j.opcode == JAL[OPCODE_LEN-1:0] && instr_i[i].j.rd == 5'b00001) begin
              jump_type = JUMP_TYPE_CALL;
              jump_location = i[LEN5_MULTIPLE_ISSUES_BITS-1:0];
            end
            else if (instr_i[i].j.opcode == JAL[OPCODE_LEN-1:0]) begin
              jump_type = JUMP_TYPE_JAL;
              jump_location = i[LEN5_MULTIPLE_ISSUES_BITS-1:0];
            end
          end
        end
      end

      always_comb begin : gen_jump_valid
        logic n_jump_found = 1'b1;
        jump_valid = '0;
        for(int unsigned i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin
          jump_valid[i] = n_jump_found;
          if (jump_location == i[LEN5_MULTIPLE_ISSUES_BITS-1:0]) begin
            n_jump_found = 1'b0;
          end
        end
      end
    end
  endgenerate
  
  // jal instruction decoder
  always_comb begin : is_jump_dec
    unique case (jump_type)
      JUMP_TYPE_RET:  target_valid = ras_addr_valid;
      JUMP_TYPE_NONE: target_valid = 1'b0;
      default:        target_valid = ~mem_if_pred_i[jump_location].hit;  // JUMP_TYPE_JAL, JUMP_TYPE_CALL
    endcase
  end

  // State transition logic
  always_comb begin : fsm_state_net
    unique case (curr_state)
      RESET:   next_state = IDLE;
      IDLE: begin
        if (instr_valid_i && target_valid) begin
          if (!issue_ready_i) next_state = WAIT_ISSUE;
          else next_state = IDLE;
        end else next_state = IDLE;
      end
      WAIT_ISSUE: begin
        if (issue_ready_i) next_state = IDLE;
        else next_state = WAIT_ISSUE;
      end
      default: next_state = IDLE;
    endcase
  end

  // Output network
  always_comb begin : fsm_out_net
    // Default values
    early_jump_valid_o = 1'b0;
    mem_flush_o        = 1'b0;

    unique case (curr_state)
      IDLE: begin
        early_jump_valid_o = instr_valid_i & target_valid;
        mem_flush_o        = instr_valid_i & target_valid & issue_ready_i;
      end
      WAIT_ISSUE: begin
        early_jump_valid_o = 1'b1;
        mem_flush_o        = issue_ready_i;
      end
      default: ;  // use default values
    endcase
  end

  // State register
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) curr_state <= RESET;
    else if (flush_i) curr_state <= IDLE;
    else curr_state <= next_state;
  end

  // --------------------
  // RETURN ADDRESS STACK
  // --------------------
  // RAS control
  always_comb begin : ras_ctl
    unique case (jump_type)
      JUMP_TYPE_CALL: begin
        ras_push = instr_valid_i & issue_ready_i;
        ras_pop  = 1'b0;
      end
      JUMP_TYPE_RET: begin
        ras_push = 1'b0;
        ras_pop  = instr_valid_i & issue_ready_i;
      end
      default: begin
        ras_push = 1'b0;
        ras_pop  = 1'b0;
      end
    endcase
  end

  // Link address adder
  // TODO: can we share another adder, like the one in the branch unit?
  assign link_addr = mem_if_pred_i[jump_location].pc + {32'b0, (ILEN >> 3)};

  // RAS LIFO buffer
  ras #(
    .DEPTH(RAS_DEPTH)
  ) u_ras (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .flush_i       (flush_i),
    .push_i        (ras_push),
    .pop_i         (ras_pop),
    .link_addr_i    (link_addr),
    .valid_o       (ras_addr_valid),
    .ret_addr_o    (ras_addr),
    .call_confirm_i(call_confirm_i),
    .ret_confirm_i (ret_confirm_i),
    .res_link_addr_i   (res_link_addr_i)
  );

  // Output network
  // --------------
  // Target address multiplexer
  always_comb begin : target_addr_mux
    unique case (jump_type)
      JUMP_TYPE_RET: begin
        early_jump_base = '0;
        early_jump_offs = ras_addr;
      end
      default: begin
        early_jump_base = mem_if_pred_i[jump_location].pc;
        early_jump_offs = XLEN'(signed'({
          instr_i[jump_location].j.imm20, instr_i[jump_location].j.imm19, instr_i[jump_location].j.imm11, instr_i[jump_location].j.imm10, 1'b0
        }));
      end
    endcase
  end

  // Target address for the PC generation unit
  assign early_jump_base_o   = early_jump_base;
  assign early_jump_offs_o   = early_jump_offs;

  // Prediction for the execution stage
  always_comb begin : gen_out
    issue_pred_o = mem_if_pred_i;
    issue_pred_o[jump_location].pc     = mem_if_pred_i[jump_location].pc;
    issue_pred_o[jump_location].hit    = target_valid | mem_if_pred_i[jump_location].hit;
    issue_pred_o[jump_location].target = (target_valid) ? early_jump_target_i : mem_if_pred_i[jump_location].target;
    issue_pred_o[jump_location].taken  = target_valid | mem_if_pred_i[jump_location].taken;
  end
  assign valid_instr_o = valid_instr_i & jump_valid;
endmodule
