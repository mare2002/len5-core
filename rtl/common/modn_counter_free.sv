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

module modn_counter_free #(
  parameter int unsigned N = 16, //maximal value of the counter
  parameter int unsigned I = 4, //maximal number of bits to represend the increment
  parameter int unsigned D = 1, //maximal number of bits to represent the decrement
  parameter logic [$clog2(N)-1:0] INIT = '0  // initial value at reset and clear
) (
  // Input signals
  input logic clk_i,
  input logic rst_ni,  // Asynchronous reset
  input logic en_i,
  input logic clr_i,   // Synchronous clear
  input logic [I-1:0] increase_val_i, // free IQ entries
  input logic [D-1:0] decrease_val_i, // take IQ entries
  // Output signals
  output logic available_o,  // checks whether the is enough available entries
  output logic empty_no // checks whether the 
);
  //%TODO Check with Michele if this is OK assumption
  // This special counter assumes that the number of entries to the IQ is power of S2
  //INTERNAL SIGNALS
  //----------------
  logic [$clog2(N)-1:0] adder_res1;
  logic [$clog2(N)-1:0] adder_res2;
  logic [$clog2(N)-1:0] mux_res;
  logic carry;
  
  assign adder_res1 = count_o + {{$clog2(N)-I{1'b0}},increase_val};
  
  assign {carry, adder_res2} = adder_res1 - {{$clog2(N)-D{1'b0}},decrease_val};

  // In case there is not enough space in the fifo carry will be 1, meaning just free space
  assign mux_res = (carry) ? adder_res1 : adder_res2;

  // Main counting process. The counter clears when reaching the threshold
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      count_o <= INIT;  // Asynchronous reset
    end else if (clr_i) begin
      count_o <= INIT;  // Synchronous clear when requested
    end else if (en_i) begin
      count_o <= mux_res;
    end
  end

endmodule
