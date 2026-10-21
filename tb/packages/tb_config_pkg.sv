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
// Simulation memory configuration; CPU configuration lives in len5_config_pkg.

package tb_config_pkg;
  // Select one memory implementation. AXI_SIM requires load-tag retention on flush.
  typedef enum logic [1:0] {
    MEM_BACKEND_LEGACY,
    MEM_BACKEND_TC_SRAM,
    MEM_BACKEND_AXI_SIM
  } memory_backend_t;
  // verilog_lint: waive parameter-name-style
  localparam memory_backend_t MEMORY_BACKEND = MEM_BACKEND_TC_SRAM;
  // AXI clock/model phases use picoseconds; other backends keep their clock.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned AXI_CLOCK_HALF_PERIOD_PS = 1000;
  // verilog_lint: waive parameter-name-style
  localparam logic [63:0] IMEM_BASE_ADDR = 64'h0001_0000;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_SIZE_BYTES = 256 * 1024;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_LATENCY = 4;  // Read cycles; independent of frontend FIFO depth.
  // verilog_lint: waive parameter-name-style
  localparam logic [63:0] DMEM_BASE_ADDR = 64'h0005_0000;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned DMEM_SIZE_BYTES = 768 * 1024;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned DMEM_LATENCY = 1;  // Read cycles; independent of IMEM latency.
  // verilog_lint: waive parameter-name-style
  localparam string SRAM_SIM_INIT = "none";
  // verilog_lint: waive parameter-name-style
  localparam logic [63:0] SERIAL_ADDR = 64'h2000_0000;
  // verilog_lint: waive parameter-name-style
  localparam logic [63:0] EXIT_ADDR = 64'h2000_0100;
endpackage
