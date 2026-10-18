// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Two reserved response slots, with fall-through from the SRAM output register.
// Allocation can precede result arrival by multiple cycles (fetch bundles).
module memory_response_buffer #(
    parameter type DATA_T = logic [63:0]
) (
    input logic clk_i,
    rst_ni,
    flush_i,
    input logic allocate_i,
    output logic credit_o,
    input logic result_valid_i,
    input DATA_T result_i,
    output logic valid_o,
    input logic ready_i,
    output DATA_T data_o,
    output logic [1:0] outstanding_o,
    output logic [1:0] occupancy_o
);
  // FIFO storage and head/tail counters, following rtl/common/fifo.sv.
  // The fixed two-entry FIFO needs one-bit counters, which wrap on each push/pop.
  DATA_T data_q[2];
  logic head_cnt_q, tail_cnt_q;
  logic [1:0] occupancy_q;

  // Includes in-flight operations as well as captured results, until response consumption.
  logic [1:0] reserved_q;
  logic fifo_empty, fifo_has_data;
  logic fifo_push, fifo_pop, response_consumed;

  // FIFO control. A result consumed directly from an empty FIFO needs no storage entry.
  assign fifo_empty        = occupancy_q == 2'd0;
  assign fifo_has_data     = occupancy_q != 2'd0;
  assign response_consumed = valid_o && ready_i;
  // Arriving results already own reserved slots, so insertion needs no ready/full gate.
  assign fifo_push         = result_valid_i && !(fifo_empty && response_consumed);
  assign fifo_pop          = fifo_has_data && response_consumed;

  // FIFO update. Reset and flush invalidate entries through occupancy; stored data is retained.
  always_ff @(posedge clk_i or negedge rst_ni) begin : fifo_update
    if (!rst_ni) begin
      occupancy_q <= '0;
    end else if (flush_i) begin
      occupancy_q <= '0;
    end else begin
      occupancy_q <= occupancy_q + 2'(fifo_push) - 2'(fifo_pop);

      if (fifo_push) begin
        data_q[tail_cnt_q] <= result_i;
      end
    end
  end

  // Output control. An empty FIFO falls through from the native result without an extra cycle.
  assign valid_o       = rst_ni && !flush_i && (fifo_has_data || result_valid_i);
  assign data_o        = fifo_has_data ? data_q[head_cnt_q] : result_i;
  assign occupancy_o   = occupancy_q;
  assign outstanding_o = reserved_q;

  // Head and tail counters advance independently on simultaneous insertion and removal.
  always_ff @(posedge clk_i or negedge rst_ni) begin : head_tail_update
    if (!rst_ni) begin
      head_cnt_q <= 1'b0;
      tail_cnt_q <= 1'b0;
    end else if (flush_i) begin
      head_cnt_q <= 1'b0;
      tail_cnt_q <= 1'b0;
    end else begin
      if (fifo_pop) begin
        head_cnt_q <= ~head_cnt_q;
      end
      if (fifo_push) begin
        tail_cnt_q <= ~tail_cnt_q;
      end
    end
  end

  // Reservation credit includes in-flight results. A full buffer regains credit after consumption.
  // Credit depends only on registered reservations, avoiding a response-ready -> request-grant path.
  assign credit_o = rst_ni && !flush_i && (reserved_q < 2'd2);

  always_ff @(posedge clk_i or negedge rst_ni) begin : reservation_update
    if (!rst_ni) begin
      reserved_q <= '0;
    end else if (flush_i) begin
      reserved_q <= '0;
    end else begin
      reserved_q <= reserved_q + 2'(allocate_i) - 2'(response_consumed);

      // These assertions sample the reservation and occupancy state before this edge's updates.
      assert (reserved_q <= 2 && occupancy_q <= reserved_q);
      assert (!allocate_i || credit_o);
      assert (!result_valid_i || reserved_q != 0);
    end
  end
endmodule
