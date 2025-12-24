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
// File: modn_counter.sv
// Author: Michele Caon
// Date: 17/10/2019

module modn_counter_special #(
  parameter int unsigned N = 16, //maximal value of the counter
  parameter int unsigned I = 4, //maximal number of bits to represend the increment
  parameter logic [$clog2(N)-1:0] INIT = '0  // initial value at reset and clear
) (
  // Input signals
  input logic clk_i,
  input logic rst_ni,  // Asynchronous reset
  input logic en_i,
  input logic clr_i,   // Synchronous clear
  input logic [I-1:0] increase_val,
  // Output signals
  output logic [$clog2(N)-1:0] count_o  // Counter value
);
  //INTERNAL SIGNALS
  //----------------
  logic [$clog2(N)-1:0] adder_res;

  assign adder_res = count_o + {{$clog2(N)-I{1'b0}},increase_val};

  // Main counting process. The counter clears when reaching the threshold
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_o <= INIT;  // Asynchronous reset
    end else if (clr_i) begin
      count_o <= INIT;  // Synchronous clear when requested
    end else if (en_i) begin
      count_o <= adder_res;
    end
  end

endmodule
