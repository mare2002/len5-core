// Copyright 2026 Politecnico di Torino.
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Reserve metadata in request order, fill results in response order, then consume.
module completion_fifo #(
  parameter type META_T = logic [63:0],
  parameter type DATA_T = logic [63:0],
  parameter int unsigned DEPTH = 2,
  parameter bit DRAIN_ON_FLUSH = 1'b0
) (
  input  logic  clk_i,
  input  logic  rst_ni,
  input  logic  flush_i,
  // Accepted reservation; the caller must qualify it with credit_o.
  input  logic  allocate_i,
  output logic  credit_o,
  input  META_T metadata_i,
  input  logic  result_valid_i,
  output logic  result_ready_o,
  input  DATA_T result_i,
  output logic  valid_o,
  input  logic  ready_i,
  output META_T metadata_o,
  output DATA_T data_o
);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned POINTER_WIDTH = $clog2(2 * DEPTH);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned ADDRESS_WIDTH = DEPTH > 1 ? $clog2(DEPTH) : 1;

  META_T metadata_q[DEPTH];
  DATA_T data_q    [DEPTH];
  logic [POINTER_WIDTH-1:0] head_q, fill_q, tail_q;
  logic [ADDRESS_WIDTH-1:0] head_addr, fill_addr, tail_addr;
  logic reserved_empty, reserved_full, head_complete, pending_result;
  logic active, clear_pointers, allocate_entry, result_accepted, response_consumed;
  logic head_has_result, head_live, discard_head, advance_head, store_result;

  // DEPTH must be a positive power of two. The MSB distinguishes the two laps;
  // the remaining bits select storage. A depth-one FIFO has only address zero.
  assign head_addr = DEPTH == 1 ? '0 : head_q[ADDRESS_WIDTH-1:0];
  assign fill_addr = DEPTH == 1 ? '0 : fill_q[ADDRESS_WIDTH-1:0];
  assign tail_addr = DEPTH == 1 ? '0 : tail_q[ADDRESS_WIDTH-1:0];
  assign reserved_full = (head_addr == tail_addr) && (head_q[POINTER_WIDTH-1] != tail_q[POINTER_WIDTH-1]);

  // Head consumes, fill completes, and tail reserves. Compare complete pointers,
  // since equal storage addresses can also describe a completely filled ring.
  assign reserved_empty    = tail_q == head_q;
  assign head_complete     = head_q != fill_q;
  assign pending_result    = fill_q != tail_q;

  assign active            = rst_ni && !flush_i;
  assign clear_pointers    = flush_i && !DRAIN_ON_FLUSH;
  assign allocate_entry    = active && allocate_i;
  // No pop lookahead: retain the full-queue recovery bubble.
  assign credit_o          = active && !reserved_full;
  assign result_accepted   = result_valid_i && result_ready_o;
  assign head_has_result   = head_complete || result_accepted;
  assign valid_o           = active && head_has_result && head_live;
  assign response_consumed = valid_o && ready_i;
  assign advance_head      = response_consumed || discard_head;

  if (DRAIN_ON_FLUSH) begin : gen_drain_entries
    logic [DEPTH-1:0] live_q;

    // Flush cancels publication, but each accepted request keeps its reservation.
    always_ff @(posedge clk_i or negedge rst_ni) begin : update_live
      if (!rst_ni) live_q <= '0;
      else if (flush_i) live_q <= '0;
      else if (allocate_entry) live_q[tail_addr] <= 1'b1;
    end

    // An empty-queue allocation can complete before its live bit is registered.
    assign head_live = reserved_empty ? allocate_entry : live_q[head_addr];
    assign result_ready_o = rst_ni && (pending_result || allocate_entry);
    assign discard_head = rst_ni && head_has_result && (flush_i || !head_live);
  end else begin : gen_cancel_entries
    assign head_live = 1'b1;
    assign result_ready_o = active && (pending_result || allocate_i);
    assign discard_head = 1'b0;
  end

  // An arriving head bypasses storage; older completed entries always take priority.
  assign metadata_o        = !reserved_empty ? metadata_q[head_addr] : metadata_i;
  assign data_o            = head_complete ? data_q[head_addr] : result_i;
  assign store_result      = result_accepted && !(!head_complete && advance_head);

  // Payload banks need no reset; pointer ownership qualifies every read.
  always_ff @(posedge clk_i) begin : write_entries
    if (allocate_entry) metadata_q[tail_addr] <= metadata_i;
    if (store_result) data_q[fill_addr] <= result_i;
  end

  modn_counter #(
    .N(2 * DEPTH)
  ) u_head_counter (
    .clk_i,
    .rst_ni,
    .clr_i  (clear_pointers),
    .en_i   (advance_head),
    .count_o(head_q),
    .tc_o   ()
  );
  modn_counter #(
    .N(2 * DEPTH)
  ) u_fill_counter (
    .clk_i,
    .rst_ni,
    .clr_i  (clear_pointers),
    .en_i   (result_accepted),
    .count_o(fill_q),
    .tc_o   ()
  );
  modn_counter #(
    .N(2 * DEPTH)
  ) u_tail_counter (
    .clk_i,
    .rst_ni,
    .clr_i  (clear_pointers),
    .en_i   (allocate_entry),
    .count_o(tail_q),
    .tc_o   ()
  );
endmodule
