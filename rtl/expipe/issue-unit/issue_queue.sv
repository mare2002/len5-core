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
  input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fetch_valid_instr_i,

  // Data from fetch unit
  input expipe_pkg::iq_entry_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] push_instr_i,

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
  iq_entry_t data  [IQ_DEPTH];
  logic  data_valid[IQ_DEPTH];

  // FIFO control
  logic fifo_push, fifo_pop;

  // Push logic FIFO
  logic [LEN5_MULTIPLE_ISSUES-1:0] alloc_nav;
  logic [IQ_DEPTH-1:0] write_instr_en;
  iq_entry_t [IQ_DEPTH-1:0] push_instr_demux;

  //Increase tail logic
  logic [$clog2(LEN5_MULTIPLE_ISSUES+1)-1:0] increase_tail;
  

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------

  // Push/pop control
  assign fifo_push    = fetch_valid_i && fetch_ready_o;
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
  // 1) pop
  // 2) push
  //Allows for the push and pop to the same address
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
        if (fifo_pop && head_cnt == i[$clog2(IQ_DEPTH)-1:0]) begin
          data_valid[i] <= 1'b0;
        end
        else if (fifo_push && write_instr_en[i]) begin
          data_valid[i] <= 1'b1;
          data[i]       <= push_instr_demux[i];
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
  // assign fetch_ready_o = !data_valid[tail_cnt];
  assign fetch_ready_o = |alloc_nav;
  assign pop_instr_o  = data[head_cnt];

  // ----------------------
  // HEAD AND TAIL COUNTERS
  // ----------------------

  modn_counter_special #(
    .N(IQ_DEPTH),
    .I(0) 
  ) u_head_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (head_cnt_en),
    .increase_val_i(head_cnt_en),
    .clr_i  (head_cnt_clr),
    .count_o(head_cnt)
  );

  modn_counter_special #(
    .N(IQ_DEPTH),
    .I(LEN5_MULTIPLE_ISSUES_BITS)
  ) u_tail_counter (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .en_i   (tail_cnt_en),
    .increase_val_i(increase_tail),
    .clr_i  (tail_cnt_clr),
    .count_o(tail_cnt)
  );

  always_comb begin : gen_ready_write
    logic [LEN5_MULTIPLE_ISSUES-1:0][$clog2(IQ_DEPTH)-1:0] counter_h;
    alloc_nav = '0;
    write_instr_en = '0;
    push_instr_demux = '0;
    for(int i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin
      counter_h[i] = tail_cnt+i[$clog2(IQ_DEPTH)-1:0];
      alloc_nav[i] = (~data_valid[counter_h[i]])&fetch_valid_instr_i[i];
      write_instr_en[counter_h[i]] = fetch_valid_instr_i[i];
      push_instr_demux[counter_h[i]] = push_instr_i[i];
    end
  end

  lzc #(
    .WIDTH(LEN5_MULTIPLE_ISSUES),
    .MODE(1)
  ) u_loc (
    .in_i(~fetch_valid_instr_i),
    .cnt_o(increase_tail),
    .empty_o()
  );

endmodule

