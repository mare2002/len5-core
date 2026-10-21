// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "axi/typedef.svh"
module axi_sim_loader_tb #(
  parameter int unsigned I_WIDTH = 128
);
  timeunit 1ps; timeprecision 1ps;
  import axi_memory_pkg::*;
  localparam int ISize = I_WIDTH / 8 * 3;
  typedef logic [I_WIDTH-1:0] instruction_word_t;
  typedef logic [I_WIDTH/8-1:0] instruction_strobe_t;
  `AXI_TYPEDEF_ALL(loader_axi, addr_t, id_t, instruction_word_t, instruction_strobe_t, user_t)
  bit clk = 0, reset_n = 0;
  logic initialized_i, initialized_d;
  loader_axi_req_t [0:0] ireq;
  dmem_axi_req_t   [1:0] dreq;
  assign ireq = '0;
  assign dreq = '0;
  axi_sim_storage #(
    .BASE_ADDR       (64'h4000),
    .SIZE_BYTES      (ISize),
    .OTHER_BASE_ADDR (64'h8000),
    .OTHER_SIZE_BYTES(24),
    .DATA_WIDTH      (I_WIDTH),
    .NUM_PORTS       (1),
    .AXI_REQ_T       (loader_axi_req_t),
    .AXI_RESP_T      (loader_axi_resp_t)
  ) imem (
    .clk_i        (clk),
    .rst_ni       (reset_n),
    .req_i        (ireq),
    .rsp_o        (),
    .initialized_o(initialized_i)
  );
  axi_sim_storage #(
    .BASE_ADDR       (64'h8000),
    .SIZE_BYTES      (24),
    .OTHER_BASE_ADDR (64'h4000),
    .OTHER_SIZE_BYTES(ISize),
    .DATA_WIDTH      (64),
    .NUM_PORTS       (2)
  ) dmem (
    .clk_i        (clk),
    .rst_ni       (reset_n),
    .req_i        (dreq),
    .rsp_o        (),
    .initialized_o(initialized_d)
  );
  task automatic tick;
    #(tb_config_pkg::AXI_CLOCK_HALF_PERIOD_PS);
    clk = 1;
    #(tb_config_pkg::AXI_CLOCK_HALF_PERIOD_PS);
    clk = 0;
  endtask
  initial begin
    bit binary_image;
    // verilog_lint: waive plusarg-assignment
    binary_image = $test$plusargs("binary_image");
    repeat (3) tick();
    reset_n = 1;
    repeat (3) tick();
    assert (initialized_i && initialized_d);
    for (int b = 0; b < 8; b++)
    assert (imem.u_mem.mem[64'h4000+64'(b)] === 8'(64'h8877665544332211 >> (8 * b)));
    if (!binary_image) begin
      for (int b = 0; b < 4; b++)
      assert (imem.u_mem.mem[64'h4010+64'(b)] === 8'(32'hddccbbaa >> (8 * b)));
      assert (imem.u_mem.mem[64'h4000+64'(ISize-1)] === 8'ha5);
      for (int b = 0; b < 8; b++)
      assert (dmem.u_mem.mem[64'h8000+64'(b)] === 8'(64'h1020304050607080 >> (8 * b)));
      assert (dmem.u_mem.mem[64'h8017] === 8'h5a);
    end else assert (dmem.u_mem.mem.num() == 0);
    // An untouched byte must remain absent from the native associative array.
    // Checking its value in a two-state simulator would hide accidental clearing.
    assert (imem.u_mem.mem.exists(64'h4008) == 0);
    assert (imem.u_mem.mem.exists(64'h8000) == 0);
    assert (dmem.u_mem.mem.exists(64'h4000) == 0);
    assert (dmem.u_mem.mem.exists(64'h8008) == 0);
    $display("PASS firmware AXI native deposits IWidth=%0d", I_WIDTH);
    $finish;
  end
endmodule
