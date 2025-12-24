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
// File: issue_queue.sv
// Author: Michele Caon
// Date: 17/10/2019

module issue_queue (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,

  // Handshake from/to fetch unit
  input  logic fetch_valid_i,
  output logic fetch_ready_o,

  // Data from fetch unit
  input expipe_pkg::iq_entry_t push_instr_i,

  // Handshake from/to the issue logic
  input  logic issue_ready_i,
  output logic issue_valid_o,

  // Data to the execution pipeline
  output expipe_pkg::iq_entry_t pop_instr_o
);
  import len5_pkg::*;
  import expipe_pkg::*;

  // ----------------
  // ISSUE QUEUE FIFO
  // ----------------
  // Assemble new queue entry with the data from the fetch unit

  fifo #(
    .DATA_T(iq_entry_t),
    .DEPTH (len5_config_pkg::IQ_DEPTH)
  ) u_issue_fifo (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .flush_i(flush_i),
    .valid_i(fetch_valid_i),
    .ready_i(issue_ready_i),
    .valid_o(issue_valid_o),
    .ready_o(fetch_ready_o),
    .data_i (push_instr_i),
    .data_o (pop_instr_o)
  );

  // Output instruction
  // ------------------


endmodule

