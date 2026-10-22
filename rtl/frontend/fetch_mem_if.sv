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

module fetch_mem_if #(
    // Completion reservations include canceled requests until their entries retire.
    parameter int unsigned MAX_MEM_OUTSTANDING_REQUESTS = 2,
    parameter bit DRAIN_ON_FLUSH = len5_config_pkg::FETCH_MEM_DRAIN_ON_FLUSH
) (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Fetch unit (BPU and PC generator)
    input logic fetch_valid_i,
    output logic fetch_ready_o,
    input  fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fetch_pred_i,   // contains the current PC
    input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_i,
    output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_instr_o,

    // Issue stage
    output logic issue_valid_o,
    input logic issue_ready_i,
    output len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_instr_o,
    output fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_pred_o,           // contains the served PC
    output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_except_raised_o,
    output len5_pkg::except_code_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] issue_except_code_o,

    // Memory
    input logic instr_valid_i,
    input logic instr_ready_i,
    output logic instr_ready_o,
    output logic instr_valid_o,
    output logic instr_we_o,
    input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0][len5_pkg::ILEN-1:0] instr_rdata_i,
    output logic [len5_pkg::XLEN-1:0] instr_addr_o,
    input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_except_raised_i,
    input len5_pkg::except_code_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_except_code_i
);

  import fetch_pkg::mem_if_ans_reg_t;
  import fetch_pkg::prediction_t;
  import len5_pkg::ILEN;
  import len5_config_pkg::*;
  typedef struct packed {
    prediction_t [LEN5_MULTIPLE_ISSUES-1:0] pred_data;
    logic [LEN5_MULTIPLE_ISSUES-1:0] valid_instr;
  } fetch_metadata_t;

  typedef struct packed {
    logic [LEN5_MULTIPLE_ISSUES-1:0][ILEN-1:0] instr;
    logic [LEN5_MULTIPLE_ISSUES-1:0] except_raised;
    len5_pkg::except_code_t [LEN5_MULTIPLE_ISSUES-1:0] except_code;
  } fetch_result_t;

  fetch_metadata_t fetch_metadata, request_metadata, response_metadata;
  fetch_result_t memory_result, response_result;
  mem_if_ans_reg_t ans_reg_in, ans_reg_out;
  logic request_valid, request_ready, request_accepted;
  logic response_credit, response_valid, response_ready;

  assign fetch_metadata.pred_data = fetch_pred_i;
  assign fetch_metadata.valid_instr = valid_instr_i;

  // A memory request cannot escape before its metadata and result storage are reserved.
  assign instr_valid_o = request_valid && response_credit;
  assign request_ready = instr_ready_i && response_credit;
  assign request_accepted = instr_valid_o && instr_ready_i;

  spill_cell_flush #(
      .DATA_T(fetch_metadata_t),
      .SKIP  (FETCH_REQ_SPILL_SKIP)
  ) u_req_reg (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i(fetch_valid_i),
      .ready_i(request_ready),
      .valid_o(request_valid),
      .ready_o(fetch_ready_o),
      .data_i (fetch_metadata),
      .data_o (request_metadata)
  );

  assign memory_result.instr = instr_rdata_i;
  assign memory_result.except_raised = instr_except_raised_i;
  assign memory_result.except_code = instr_except_code_i;

  // Slots remain owned until their completed bundle enters the answer spill cell.
  // Ordered responses fill reserved slots even when the issue path is blocked.
  completion_fifo #(
      .META_T(fetch_metadata_t),
      .DATA_T(fetch_result_t),
      .DEPTH (MAX_MEM_OUTSTANDING_REQUESTS),
      .DRAIN_ON_FLUSH(DRAIN_ON_FLUSH)
  ) u_response_queue (
      .clk_i,
      .rst_ni,
      .flush_i,
      .allocate_i(request_accepted),
      .credit_o(response_credit),
      .metadata_i(request_metadata),
      .result_valid_i(instr_valid_i),
      .result_ready_o(instr_ready_o),
      .result_i(memory_result),
      .valid_o(response_valid),
      .ready_i(response_ready),
      .metadata_o(response_metadata),
      .data_o(response_result)
  );

  assign ans_reg_in.instr = response_result.instr;
  assign ans_reg_in.pred_data = response_metadata.pred_data;
  assign ans_reg_in.except_raised = response_result.except_raised;
  assign ans_reg_in.except_code = response_result.except_code;
  assign ans_reg_in.valid_instr = response_metadata.valid_instr;

  // Retain the registered issue timing; the queue bypass adds no response pipeline stage.
  spill_cell_flush #(
      .DATA_T(mem_if_ans_reg_t),
      .SKIP  (FETCH_ANS_SPILL_SKIP)
  ) u_ans_reg (
      .clk_i,
      .rst_ni,
      .flush_i,
      .valid_i(response_valid),
      .ready_i(issue_ready_i),
      .valid_o(issue_valid_o),
      .ready_o(response_ready),
      .data_i (ans_reg_in),
      .data_o (ans_reg_out)
  );

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Only read from mem
  assign instr_we_o   = 1'b0;

  assign instr_addr_o = request_metadata.pred_data[0].pc;

  // Fetched instruction
  //connect each of the output instructions to the answer instructions
  always_comb begin : comb_out
    for (int i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin : gen_out
      issue_instr_o[i].raw     = ans_reg_out.instr[i];
      issue_pred_o[i]          = ans_reg_out.pred_data[i];
      issue_except_raised_o[i] = ans_reg_out.except_raised[i];
      issue_except_code_o[i]   = ans_reg_out.except_code[i];
      valid_instr_o[i]         = ans_reg_out.valid_instr[i];
    end
  end


endmodule
