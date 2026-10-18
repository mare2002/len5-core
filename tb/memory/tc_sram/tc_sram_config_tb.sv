// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Each invalid elaborated configuration must stop before any request is granted.
module tc_sram_config_tb #(
    parameter int TEST_CASE = 0
);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned TEST_LATENCY = TEST_CASE == 1 ? 0 : TEST_CASE == 2 ? 2 : TEST_CASE == 12 ? 8 : 1;
  tc_sram_adapter #(
      .LATENCY(TEST_LATENCY),
      .RESPONSE_DEPTH(TEST_CASE == 13 ? 1 : TEST_LATENCY + 1),
      .BASE_ADDR(TEST_CASE == 3 ? 64'h2000_0000 :
                 TEST_CASE == 4 ? 64'h1001 :
                 TEST_CASE == 5 ? 64'hffff_ffff_ffff_fff8 : 64'h1000),
      .SIZE_BYTES(TEST_CASE == 6 ? 9 : 256),
      .SERIAL_ADDR(TEST_CASE == 7 ? 64'h4000 : 64'h2000_0000),
      .EXIT_ADDR(TEST_CASE == 8 ? 64'h2000_0000 : TEST_CASE == 9 ? 64'h2000_0101 : 64'h2000_0100)
  ) dut (
      .clk_i(1'b0),
      .rst_ni(1'b0),
      .instr_flush_i(1'b0),
      .load_flush_i(1'b0),
      .initialized_i(1'b0),
      .instr_req_i(1'b0),
      .instr_ready_i(1'b0),
      .instr_addr_i('0),
      .load_req_i(1'b0),
      .load_ready_i(1'b0),
      .load_addr_i('0),
      .load_be_i('0),
      .load_tag_i('0),
      .store_req_i(1'b0),
      .store_ready_i(1'b0),
      .store_we_i(1'b0),
      .store_addr_i('0),
      .store_data_i('0),
      .store_be_i('0),
      .store_tag_i('0),
      .response_o(),
      .sram_req_o(),
      .sram_we_o(),
      .sram_addr_o(),
      .sram_wdata_o(),
      .sram_be_o(),
      .sram_rdata_i('0),
      .mmio_write_o(),
      .outstanding_o(),
      .occupancy_o()
  );
  initial begin
    #1;
    $display("PASS valid configuration");
    $finish;
  end
endmodule
