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

  // Valid instructions from fetch unit
  input logic fetch_valid_instr_i,

  // Data from fetch unit
  input expipe_pkg::iq_entry_t push_instr_i,

  // Handshake from/to the issue logic
  input  logic issue_ready_i,
  output logic issue_valid_o,

  // Data to the execution pipeline
  output expipe_pkg::iq_entry_t pop_instr_o
);
  import len5_pkg::*;
  import len5_config_pkg::*;
  import expipe_pkg::*;

  // ----------------
  // ISSUE QUEUE FIFO
  // ----------------
  // Assemble new queue entry with the data from the fetch unit

    // INTERNAL SIGNALS
  // ----------------

  // Head and tail counters
  logic [$clog2(IQ_DEPTH)-1:0] head_cnt, tail_cnt;
  logic head_cnt_en, tail_cnt_en;
  logic head_cnt_clr, tail_cnt_clr;

  // FIFO data
  iq_entry_t data      [IQ_DEPTH];
  logic  data_valid[IQ_DEPTH];

  // FIFO control
  logic fifo_push, fifo_pop;

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------

  // Push/pop control
  assign fifo_push    = fetch_valid_i && fetch_ready_o && fetch_valid_instr_i;
  assign fifo_pop     = issue_valid_o && issue_ready_i;

  // Counters control
  assign head_cnt_clr = flush_i;
  assign tail_cnt_clr = flush_i;
  assign head_cnt_en  = fifo_pop;
  assign tail_cnt_en  = fifo_push;

  // -----------
  // FIFO UPDATE
  // -----------
  // NOTE: operations priority:
  // 1) push
  // 2) pop
  always_ff @(posedge clk_i or negedge rst_ni) begin : fifo_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data_valid[i] <= 1'b0;
        data[i]       <= '0;
      end
    end else if (flush_i) begin
      foreach (data[i]) begin
        data_valid[i] <= 1'b0;  // clearing valid is enough
      end
    end else begin
      foreach (data[i]) begin
        if (fifo_push && tail_cnt == i[$clog2(IQ_DEPTH)-1:0]) begin
          data_valid[i] <= 1'b1;
          data[i]       <= push_instr_i;
        end else if (fifo_pop && head_cnt == i[$clog2(IQ_DEPTH)-1:0]) begin
          data_valid[i] <= 1'b0;
        end
      end
    end
  end

  // --------------
  // OUTPUT CONTROL
  // --------------

  // NOTE: output valid when head entry is valid
  //       output ready when tail entry is empty
  assign issue_valid_o = data_valid[head_cnt];
  assign fetch_ready_o = !data_valid[tail_cnt];
  assign pop_instr_o  = data[head_cnt];

  // ----------------------
  // HEAD AND TAIL COUNTERS
  // ----------------------

  modn_counter_special #(
    .N(IQ_DEPTH),
    .I(1)
  ) u_head_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (head_cnt_en),
    .increase_val(head_cnt_en),
    .clr_i  (head_cnt_clr),
    .count_o(head_cnt)
  );

  modn_counter_special #(
    .N(IQ_DEPTH),
    .I(1)
  ) u_tail_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (tail_cnt_en),
    .increase_val(tail_cnt_en),
    .clr_i  (tail_cnt_clr),
    .count_o(tail_cnt)
  );


endmodule

