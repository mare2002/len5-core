// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Reserved response slots, with fall-through from each completed memory operation.
// Allocation reserves space before the corresponding load/store result is available.
module memory_response_buffer #(
  parameter type DATA_T = logic [63:0],
  parameter int unsigned DEPTH = 2,
  parameter int unsigned COUNT_WIDTH = $clog2(DEPTH + 1)
) (
  input  logic                    clk_i,
  rst_ni,
  flush_i,
  input  logic                    allocate_i,
  output logic                    credit_o,
  input  logic                    result_valid_i,
  input  DATA_T                   result_i,
  output logic                    valid_o,
  input  logic                    ready_i,
  output DATA_T                   data_o,
  output logic  [COUNT_WIDTH-1:0] outstanding_o,
  output logic  [COUNT_WIDTH-1:0] occupancy_o
);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned POINTER_WIDTH = DEPTH > 1 ? $clog2(DEPTH) : 1;

  // FIFO storage and head/tail counters, following rtl/common/fifo.sv.
  DATA_T data_q[DEPTH];
  logic [POINTER_WIDTH-1:0] head_cnt_q, tail_cnt_q;
  logic [COUNT_WIDTH-1:0] occupancy_q;

  // Includes in-flight operations as well as captured results, until response consumption.
  logic [COUNT_WIDTH-1:0] reserved_q;
  logic fifo_empty, fifo_has_data;
  logic fifo_push, fifo_pop, response_consumed;

  // FIFO control. A result consumed directly from an empty FIFO needs no storage entry.
  assign fifo_empty        = occupancy_q == 0;
  assign fifo_has_data     = occupancy_q != 0;
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
      occupancy_q <= occupancy_q + COUNT_WIDTH'(fifo_push) - COUNT_WIDTH'(fifo_pop);

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
      head_cnt_q <= '0;
      tail_cnt_q <= '0;
    end else if (flush_i) begin
      head_cnt_q <= '0;
      tail_cnt_q <= '0;
    end else begin
      if (fifo_pop) begin
        head_cnt_q <= head_cnt_q == POINTER_WIDTH'(DEPTH - 1) ? '0 : head_cnt_q + 1'b1;
      end
      if (fifo_push) begin
        tail_cnt_q <= tail_cnt_q == POINTER_WIDTH'(DEPTH - 1) ? '0 : tail_cnt_q + 1'b1;
      end
    end
  end

  // Reservation credit includes in-flight results. A full buffer regains credit after consumption.
  // Credit depends only on registered reservations, avoiding a response-ready -> request-grant path.
  assign credit_o = rst_ni && !flush_i && (reserved_q < COUNT_WIDTH'(DEPTH));

  always_ff @(posedge clk_i or negedge rst_ni) begin : reservation_update
    if (!rst_ni) begin
      reserved_q <= '0;
    end else if (flush_i) begin
      reserved_q <= '0;
    end else begin
      reserved_q <= reserved_q + COUNT_WIDTH'(allocate_i) - COUNT_WIDTH'(response_consumed);

      // Widen the reservation check so overflow/underflow cannot wrap at the counter width.
      assert ((COUNT_WIDTH + 1)'(reserved_q) + (COUNT_WIDTH + 1)'(allocate_i) -
              (COUNT_WIDTH + 1)'(response_consumed) <= (COUNT_WIDTH + 1)'(DEPTH));
      assert (occupancy_q <= reserved_q);
      assert (!allocate_i || credit_o);
      // An asynchronous read may complete on the same edge as its reservation.
      assert (!result_valid_i || reserved_q != 0 || allocate_i);
    end
  end

  initial begin
    if (DEPTH == 0 || COUNT_WIDTH < $clog2(DEPTH + 1))
      $fatal(1, "Invalid memory response buffer capacity");
  end
endmodule
