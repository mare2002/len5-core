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
// File: issue_cu.sv
// Author: Michele Caon, Flavia Guella
// Date: 17/08/2022

module issue_cu (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // CU <--> others
  output logic mis_flush_o,  // flush issue and fetch stage

  // Preview of the next registered head after removal and refill.
  input  logic iq_valid_i,
  output logic iq_ready_o,
  input  logic iq_except_raised_i,

  // Issue stage <--> CU
  input  expipe_pkg::issue_type_t issue_type_i,  // next head classification
  input  logic                    issue_valid_i,  // current registered head
  input  expipe_pkg::issue_dispatch_t issue_dispatch_i,
  input  logic                    issue_rs1_ready_i,  // for CSR instructions
  output logic                    issue_res_ready_o,
  output logic                    issue_res_sel_rs1_o,

  // Execution stage <--> CU
  input  logic ex_ready_i,
  input  logic ex_mis_i,
  output logic ex_valid_o,
  output logic int_regstat_valid_o,
  output logic fp_regstat_valid_o,

  // Commit stage <--> CU
  input  logic comm_ready_i,
  output logic comm_valid_o,
  input  logic comm_resume_i
);

  import expipe_pkg::*;
  // INTERNAL SIGNALS
  // ----------------

  // CU states
  typedef enum logic [2:0] {
    S_RESET,        // reset state
    S_RUN,          // ordinary dispatch or wait for a registered head
    S_CSR_WAIT_OP,   // wait operand for CSR instructions
    S_ISSUE_CSR,     // issue CSR instr. and stall (disable speculation)
    S_ISSUE_EXCEPT,  // notify exception to commit and stall
    S_FLUSH,         // flush the issue stage (e.g., after mispred.)
    S_STALL,         // wait for the resume signal from commit
    S_WFI            // wait for interrupt (TODO)
  } cu_state_t;
  cu_state_t curr_state, v_next_state, next_state;

  logic dispatch_ready, rd_update;
  logic run_ready, run_comm_valid, run_ex_valid, run_res_ready;

  // ------------
  // CONTROL UNIT
  // ------------
  // Direct results allocate only the ROB; other ordinary instructions also need an RS.
  assign dispatch_ready = comm_ready_i && (issue_dispatch_i.direct_result || ex_ready_i);
  assign run_ready = !issue_valid_i || dispatch_ready;
  assign run_comm_valid = issue_valid_i && (issue_dispatch_i.direct_result || dispatch_ready);
  assign run_ex_valid = issue_valid_i && !issue_dispatch_i.direct_result && dispatch_ready;
  assign run_res_ready = issue_valid_i && issue_dispatch_i.direct_result;

  // Exceptions allocate the ROB without changing register status.
  assign rd_update = comm_valid_o && comm_ready_i &&
      (curr_state inside {S_RUN, S_ISSUE_CSR});
  assign int_regstat_valid_o = rd_update && issue_dispatch_i.int_rd_write;
  assign fp_regstat_valid_o = rd_update && issue_dispatch_i.fp_rd_write;

  // Next state decoder
  // NOTE: flush requests from the commit stage have priority
  always_comb begin : cu_v_next_state
    if (ex_mis_i) begin
      v_next_state = S_FLUSH;
    end else if (iq_except_raised_i) begin
      v_next_state = S_ISSUE_EXCEPT;
    end else begin
      unique case (issue_type_i)
        ISSUE_TYPE_NONE, ISSUE_TYPE_INT, ISSUE_TYPE_LUI, ISSUE_TYPE_STORE,
        ISSUE_TYPE_BRANCH, ISSUE_TYPE_JUMP, ISSUE_TYPE_FP: v_next_state = S_RUN;
        ISSUE_TYPE_CSR:    v_next_state = S_CSR_WAIT_OP;
        ISSUE_TYPE_STALL:  v_next_state = S_STALL;
        ISSUE_TYPE_WFI:    v_next_state = S_WFI;
        ISSUE_TYPE_EXCEPT: v_next_state = S_ISSUE_EXCEPT;
        default:           v_next_state = S_RESET;
      endcase
    end
  end

  // State progression
  always_comb begin : cu_state_prog
    case (curr_state)
      S_RESET: next_state = S_RUN;
      S_RUN: begin
        if (iq_ready_o && iq_valid_i) next_state = v_next_state;
        else next_state = S_RUN;
      end
      S_CSR_WAIT_OP: begin
        if (!issue_rs1_ready_i) next_state = S_CSR_WAIT_OP;
        else next_state = S_ISSUE_CSR;
      end
      S_ISSUE_CSR: begin
        if (!comm_ready_i) next_state = S_ISSUE_CSR;
        else next_state = S_STALL;
      end
      S_ISSUE_EXCEPT: begin
        if (!comm_ready_i) next_state = S_ISSUE_EXCEPT;
        else next_state = S_STALL;
      end
      S_FLUSH: next_state = S_STALL;
      S_STALL: begin
        if (comm_resume_i && iq_valid_i) next_state = v_next_state;
        else if (comm_resume_i) next_state = S_RUN;
        else next_state = S_STALL;
      end
      S_WFI:   next_state = S_WFI;  // TODO: implement interrupts

      default: next_state = S_RESET;
    endcase
  end

  // Ordinary dispatch uses only the registered head and downstream readiness.
  always_comb begin : cu_out_eval
    // Default values
    iq_ready_o          = 1'b0;
    mis_flush_o         = 1'b0;
    issue_res_ready_o   = 1'b0;
    issue_res_sel_rs1_o = 1'b0;
    ex_valid_o          = 1'b0;
    comm_valid_o        = 1'b0;

    case (curr_state)
      S_RESET:       ;  // use default values
      S_RUN: begin
        iq_ready_o        = run_ready;
        comm_valid_o      = run_comm_valid;
        ex_valid_o        = run_ex_valid;
        issue_res_ready_o = run_res_ready;
      end
      S_CSR_WAIT_OP: ;
      S_ISSUE_CSR: begin
        comm_valid_o        = 1'b1;
        issue_res_ready_o   = 1'b1;
        issue_res_sel_rs1_o = 1'b1;
      end
      S_ISSUE_EXCEPT: begin
        comm_valid_o = 1'b1;
        issue_res_ready_o = 1'b1;  // no execution unit will complete this instruction
      end
      S_FLUSH: begin
        mis_flush_o = 1'b1;
      end
      S_STALL: begin
        iq_ready_o = comm_resume_i;
      end
      S_WFI:         ;
      default:       ;  // use default values
    endcase
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : cu_state_upd
    if (!rst_ni) curr_state <= S_RESET;
    else if (flush_i) curr_state <= S_RUN;
    else if (ex_mis_i) curr_state <= S_FLUSH;
    else curr_state <= next_state;
  end

  // ----------
  // DEBUG CODE
  // ----------
`ifndef SYNTHESIS
`ifndef VERILATOR
  always @(posedge clk_i) begin
    $display("valid_i: %b | commit ready: %b | ex. ready: %d | type: %s | state: %s", iq_valid_i,
             comm_ready_i, ex_ready_i, issue_type_i.name(), curr_state.name());
  end
`endif  /* VERILATOR */
`endif  /* SYNTHESIS */
endmodule
