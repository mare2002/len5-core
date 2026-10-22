// Copyright 2026 Politecnico di Torino.
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Modulo-N up/down counter. Reset and clear take priority over synchronous load.
module modn_counter_updown #(
    parameter int unsigned N = 16
) (
    input logic clk_i,
    input logic rst_ni,
    input logic en_i,
    input logic clr_i,
    input logic dn_i,
    input logic ld_i,
    input logic [(N > 1 ? $clog2(N) : 1)-1:0] ld_val_i,
    output logic [(N > 1 ? $clog2(N) : 1)-1:0] count_o,
    output logic tc_o
);
  localparam int unsigned CountWidth = N > 1 ? $clog2(N) : 1;
  localparam logic [CountWidth-1:0] MaxCount = CountWidth'(N - 1);

  assign tc_o = count_o == MaxCount;

  always_ff @(posedge clk_i or negedge rst_ni) begin : update_count
    if (!rst_ni) count_o <= '0;
    else if (clr_i) count_o <= '0;
    else if (ld_i) count_o <= ld_val_i;
    else if (en_i) begin
      if (dn_i) count_o <= count_o == '0 ? MaxCount : count_o - CountWidth'(1);
      else count_o <= tc_o ? '0 : count_o + CountWidth'(1);
    end
  end
endmodule
