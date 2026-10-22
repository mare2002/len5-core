// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Each invalid configuration must stop before the adapter can grant any request.
module tc_sram_config_tb #(
  parameter int unsigned I_LATENCY = 1,
  parameter int unsigned D_LATENCY = 1,
  parameter logic [63:0] I_BASE = 64'h1000,
  parameter logic [63:0] D_BASE = 64'h2000,
  parameter int unsigned I_SIZE = 256,
  parameter int unsigned D_SIZE = 256,
  parameter logic [63:0] SERIAL = 64'h2000_0000,
  parameter logic [63:0] EXIT = 64'h2000_0100,
  parameter int unsigned CAPACITY = (D_LATENCY > 0 ? D_LATENCY : 1) + 1
);
  tc_sram_adapter #(
    .IMEM_LATENCY   (I_LATENCY),
    .DMEM_LATENCY   (D_LATENCY),
    .RESPONSE_DEPTH (CAPACITY),
    .IMEM_BASE_ADDR (I_BASE),
    .IMEM_SIZE_BYTES(I_SIZE),
    .DMEM_BASE_ADDR (D_BASE),
    .DMEM_SIZE_BYTES(D_SIZE),
    .SERIAL_ADDR    (SERIAL),
    .EXIT_ADDR      (EXIT)
  ) dut (
    .clk_i        (1'b0),
    .rst_ni       (1'b0),
    .load_flush_i (1'b0),
    .initialized_i(1'b0),
    .instr_req_i  (1'b0),
    .instr_ready_i(1'b0),
    .instr_addr_i ('0),
    .load_req_i   (1'b0),
    .load_ready_i (1'b0),
    .load_addr_i  ('0),
    .load_be_i    ('0),
    .load_tag_i   ('0),
    .store_req_i  (1'b0),
    .store_ready_i(1'b0),
    .store_we_i   (1'b0),
    .store_addr_i ('0),
    .store_data_i ('0),
    .store_be_i   ('0),
    .store_tag_i  ('0),
    .response_o   (),
    .imem_req_o   (),
    .imem_addr_o  (),
    .imem_rdata_i ('0),
    .dmem_req_o   (),
    .dmem_we_o    (),
    .dmem_addr_o  (),
    .dmem_wdata_o (),
    .dmem_be_o    (),
    .dmem_rdata_i ('0),
    .mmio_write_o (),
    .outstanding_o(),
    .occupancy_o  ()
  );
  initial begin
    #1;
    $display("PASS valid configuration");
    $finish;
  end
endmodule
