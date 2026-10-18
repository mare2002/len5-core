// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Simulation storage/initialization only. Protocol and MMIO live outside this module.
module tc_sram_storage #(
    parameter logic [63:0] BASE_ADDR = len5_config_pkg::SRAM_BASE_ADDR,
    parameter int unsigned SIZE_BYTES = len5_config_pkg::SRAM_SIZE_BYTES,
    parameter int unsigned LATENCY = len5_config_pkg::SRAM_LATENCY,
    parameter string SIM_INIT = len5_config_pkg::SRAM_SIM_INIT,
    parameter bit LOAD_FIRMWARE = 1,
    parameter int unsigned ADDR_WIDTH = SIZE_BYTES / 8 > 1 ? $clog2(SIZE_BYTES / 8) : 1
) (
    input logic clk_i,
    input logic [2:0] req_i,
    we_i,
    input logic [2:0][ADDR_WIDTH-1:0] addr_i,
    input logic [2:0][63:0] wdata_i,
    input logic [2:0][7:0] be_i,
    output logic [2:0][63:0] rdata_o,
    output bit initialized_o
);
  // A single power-on reset permits native SimInit, independently of CPU reset.
  bit storage_reset_n;
  initial begin
    storage_reset_n = 0;
    initialized_o   = 0;
  end
  always @(posedge clk_i) storage_reset_n <= 1;
  // Simulator compatibility: Verilator 5.040 converts a typed string passed to an untyped upstream
  // parameter to integer zero. Pass an explicitly packed ASCII constant.
  // verilog_lint: waive parameter-name-style
  localparam logic [47:0] NATIVE_SIM_INIT = SIM_INIT == "zeros" ? "zeros" :
      SIM_INIT == "ones" ? "ones" : SIM_INIT == "random" ? "random" : "none";
  tc_sram #(
      .NumWords (SIZE_BYTES / 8),
      .DataWidth(64),
      .ByteWidth(8),
      .NumPorts (3),
      .Latency  (LATENCY),
      .SimInit  (NATIVE_SIM_INIT)
  ) u_sram (
      .clk_i,
      .rst_ni(storage_reset_n),
      .req_i,
      .we_i,
      .addr_i,
      .wdata_i,
      .be_i,
      .rdata_o
  );
  `include "tc_sram_loader.svh"
  initial begin
    if (!(SIM_INIT == "none" || SIM_INIT == "zeros" || SIM_INIT == "ones" || SIM_INIT == "random"))
      $fatal(1, "Unsupported TC_SRAM SimInit: %s", SIM_INIT);
  end
  // No time-zero ordering dependency: SRAM reset completes before loading, and
  // the adapter cannot grant a request until initialized_o becomes true.
  always @(negedge clk_i) begin
    if (storage_reset_n && !initialized_o) begin
      if (LOAD_FIRMWARE) load_firmware();
      initialized_o <= 1;
    end
  end
endmodule
