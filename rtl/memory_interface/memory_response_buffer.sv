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
  DATA_T data_q[2];
  logic rd_q, wr_q, push, pop, consume;
  logic [1:0] count_q, reserved_q;
  assign valid_o = rst_ni && !flush_i && ((count_q != 0) || result_valid_i);
  assign data_o = count_q != 0 ? data_q[rd_q] : result_i;
  assign consume = valid_o && ready_i;
  // Registered reservation credit avoids a response-ready -> request-grant path.
  // Full buffers regain credit on the cycle after a response is consumed.
  assign credit_o = rst_ni && !flush_i && (reserved_q < 2);
  assign push = result_valid_i && !((count_q == 0) && consume);
  assign pop = count_q != 0 && consume;
  assign outstanding_o = reserved_q;
  assign occupancy_o = count_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_q <= 0;
      wr_q <= 0;
      count_q <= 0;
      reserved_q <= 0;
    end else if (flush_i) begin
      rd_q <= 0;
      wr_q <= 0;
      count_q <= 0;
      reserved_q <= 0;
    end else begin
      reserved_q <= reserved_q + 2'(allocate_i) - 2'(consume);
      count_q <= count_q + 2'(push) - 2'(pop);
      if (push) begin
        data_q[wr_q] <= result_i;
        wr_q <= ~wr_q;
      end
      if (pop) rd_q <= ~rd_q;
      assert (reserved_q <= 2 && count_q <= reserved_q);
      assert (!allocate_i || credit_o);
      assert (!result_valid_i || reserved_q != 0);
    end
  end
endmodule
