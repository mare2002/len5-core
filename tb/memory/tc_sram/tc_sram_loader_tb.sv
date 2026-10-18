// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_loader_tb #(
    parameter string SIM_INIT = "ones"
);
  bit clk = 0;
  logic [2:0] req;
  logic [2:0][1:0] addr;
  logic [2:0][63:0] data;
  logic initialized;
  bit binary_image;
  tc_sram_storage #(
      .BASE_ADDR (64'h4000),
      .SIZE_BYTES(24),
      .SIM_INIT  (SIM_INIT)
  ) storage (
      .clk_i(clk),
      .req_i(req),
      .we_i(3'b0),
      .addr_i(addr),
      .wdata_i('0),
      .be_i('0),
      .rdata_o(data),
      .initialized_o(initialized)
  );
  task automatic tick;
    #5;
    clk = 1;
    #5;
    clk = 0;
  endtask
  initial begin
    req = 0;
    addr = 0;
    // Boolean presence flag; no plusarg value is expected.
    // verilog_lint: waive plusarg-assignment
    binary_image = $test$plusargs("binary_image");
    repeat (3) tick();
    assert (initialized)
    else $fatal(1, "Loader did not finish");
    req = 1;
    addr[0] = 0;
    repeat (len5_config_pkg::SRAM_LATENCY) tick();
    assert (data[0] === 64'h8877665544332211)
    else $fatal(1, "Loaded endian/address mismatch %h", data[0]);
    addr[0] = 2;
    repeat (len5_config_pkg::SRAM_LATENCY) tick();
    if (!binary_image)
      assert (data[0][31:0] === 32'hddccbbaa)
      else $fatal(1, "Sparse load mismatch");
    if (SIM_INIT == "ones")
      assert (data[0][63:32] === 32'hffffffff)
      else $fatal(1, "Untouched ones changed");
    if (SIM_INIT == "zeros")
      assert (data[0][63:32] === 32'h0)
      else $fatal(1, "Untouched zeros changed");
    $display("PASS firmware load SimInit=%s", SIM_INIT);
    $finish;
  end
endmodule
