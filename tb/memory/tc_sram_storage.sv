// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Simulation storage/initialization only. Protocol and MMIO live outside this module.
module tc_sram_storage #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    parameter tb_config_pkg::tb_cfg_t TbCfg = tb_config_pkg::build_config(
        tb_config_pkg::DefaultTbUserCfg, Len5Cfg.IMEM_DATA_WIDTH
    ),
    parameter string SRAM_SIM_INIT = tb_config_pkg::DefaultSramSimInit,
    parameter logic [63:0] BASE_ADDR = TbCfg.IMEM_BASE_ADDR,
    parameter int unsigned SIZE_BYTES = TbCfg.IMEM_SIZE_BYTES,
    parameter int unsigned LATENCY = TbCfg.IMEM_LATENCY,
    parameter int unsigned DATA_WIDTH = Len5Cfg.IMEM_DATA_WIDTH,
    parameter int unsigned NUM_PORTS = 1,
    parameter logic [63:0] OTHER_BASE_ADDR = '0,
    parameter int unsigned OTHER_SIZE_BYTES = 0,
    parameter string SIM_INIT = SRAM_SIM_INIT,
    parameter bit LOAD_FIRMWARE = 1,
    parameter int unsigned ADDR_WIDTH = SIZE_BYTES / (DATA_WIDTH / 8) > 1 ? $clog2(
        SIZE_BYTES / (DATA_WIDTH / 8)
    ) : 1
) (
    input  logic                                   clk_i,
    input  logic [NUM_PORTS-1:0]                   req_i,
    we_i,
    input  logic [NUM_PORTS-1:0][  ADDR_WIDTH-1:0] addr_i,
    input  logic [NUM_PORTS-1:0][  DATA_WIDTH-1:0] wdata_i,
    input  logic [NUM_PORTS-1:0][DATA_WIDTH/8-1:0] be_i,
    output logic [NUM_PORTS-1:0][  DATA_WIDTH-1:0] rdata_o,
    output bit                                     initialized_o
);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned WORD_BYTES = DATA_WIDTH / 8;

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
      .NumWords (SIZE_BYTES / WORD_BYTES),
      .DataWidth(DATA_WIDTH),
      .ByteWidth(8),
      .NumPorts (NUM_PORTS),
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
  localparam string FirmwareBackend = "TC_SRAM";
  localparam string FirmwareStorage = "SRAM";
  `include "tc_sram_loader.svh"
  initial begin
    if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0 || NUM_PORTS == 0 ||
        SIZE_BYTES < WORD_BYTES || SIZE_BYTES % WORD_BYTES != 0 || BASE_ADDR % 64'(WORD_BYTES) != 0 ||
        BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(SIZE_BYTES-1)))
      $fatal(1, "Invalid TC_SRAM storage geometry");
    if (OTHER_SIZE_BYTES != 0 &&
        (OTHER_BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(OTHER_SIZE_BYTES-1)) ||
         memory_backend_pkg::regions_overlap(
            BASE_ADDR, 64'(SIZE_BYTES), OTHER_BASE_ADDR, 64'(OTHER_SIZE_BYTES)
        )))
      $fatal(1, "Invalid firmware memory regions");
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
