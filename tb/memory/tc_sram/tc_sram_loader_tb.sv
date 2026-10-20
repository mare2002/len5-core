// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_loader_tb #(
  parameter string SIM_INIT = "ones",
  parameter int unsigned I_WIDTH = 128,
  parameter int unsigned I_LATENCY = 1,
  parameter int unsigned D_LATENCY = 1
);
  localparam int IBytes = I_WIDTH / 8;
  localparam int ISize = IBytes * 3;
  localparam int IAddrWidth = $clog2(3);
  bit clk = 0;
  logic ireq, initialized_i, initialized_d;
  logic [IAddrWidth-1:0]       iaddr;
  logic [   I_WIDTH-1:0]       idata;
  logic [           1:0]       dreq;
  logic [           1:0][ 1:0] daddr;
  logic [           1:0][63:0] ddata;
  bit                          binary_image;
  tc_sram_storage #(
    .BASE_ADDR       (64'h4000),
    .SIZE_BYTES      (ISize),
    .DATA_WIDTH      (I_WIDTH),
    .NUM_PORTS       (1),
    .LATENCY         (I_LATENCY),
    .OTHER_BASE_ADDR (64'h8000),
    .OTHER_SIZE_BYTES(24),
    .SIM_INIT        (SIM_INIT)
  ) imem (
    .clk_i        (clk),
    .req_i        (ireq),
    .we_i         (1'b0),
    .addr_i       (iaddr),
    .wdata_i      ('0),
    .be_i         ('0),
    .rdata_o      (idata),
    .initialized_o(initialized_i)
  );
  tc_sram_storage #(
    .BASE_ADDR       (64'h8000),
    .SIZE_BYTES      (24),
    .DATA_WIDTH      (64),
    .NUM_PORTS       (2),
    .LATENCY         (D_LATENCY),
    .OTHER_BASE_ADDR (64'h4000),
    .OTHER_SIZE_BYTES(ISize),
    .SIM_INIT        (SIM_INIT)
  ) dmem (
    .clk_i        (clk),
    .req_i        (dreq),
    .we_i         (2'b0),
    .addr_i       (daddr),
    .wdata_i      ('0),
    .be_i         ('0),
    .rdata_o      (ddata),
    .initialized_o(initialized_d)
  );
  task automatic tick;
    #5;
    clk = 1;
    #5;
    clk = 0;
  endtask
  task automatic expect_instruction_byte(int offset, logic [7:0] expected_byte);
    ireq  = 1;
    iaddr = IAddrWidth'(offset / IBytes);
    repeat (I_LATENCY + 1) tick();
    assert (8'(idata >> (8 * (offset % IBytes))) === expected_byte)
    else $fatal(1, "IMEM byte mismatch offset %0d", offset);
  endtask
  initial begin
    ireq         = 0;
    iaddr        = 0;
    dreq         = 0;
    daddr        = 0;
    // verilog_lint: waive plusarg-assignment
    binary_image = $test$plusargs("binary_image");
    repeat (3) tick();
    assert (initialized_i && initialized_d)
    else $fatal(1, "Loader did not finish");
    for (int b = 0; b < 8; b++) expect_instruction_byte(b, 8'(64'h8877665544332211 >> (8 * b)));
    if (!binary_image) begin
      for (int b = 0; b < 4; b++) expect_instruction_byte(16 + b, 8'(32'hddccbbaa >> (8 * b)));
      expect_instruction_byte(ISize - 1, 8'ha5);
      dreq[0]  = 1;
      daddr[0] = 0;
      repeat (D_LATENCY + 1) tick();
      assert (ddata[0] === 64'h1020304050607080)
      else $fatal(1, "DMEM load/endian mismatch");
      daddr[0] = 2;
      repeat (D_LATENCY + 1) tick();
      assert (ddata[0][31:0] === 32'h12345678 && ddata[0][63:56] === 8'h5a)
      else $fatal(1, "DMEM sparse/boundary mismatch");
    end
    if (SIM_INIT == "ones") expect_instruction_byte(8, 8'hff);
    if (SIM_INIT == "zeros") expect_instruction_byte(8, 8'h00);
    $display("PASS firmware load SimInit=%s IWidth=%0d ILatency=%0d DLatency=%0d", SIM_INIT,
             I_WIDTH, I_LATENCY, D_LATENCY);
    $finish;
  end
endmodule
