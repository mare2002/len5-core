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
  typedef struct packed {
    memory_backend_t MEMORY_BACKEND;
    // AXI clock/model phases use picoseconds; other backends keep their clock.
    int unsigned AXI_CLOCK_HALF_PERIOD_PS;
    logic [63:0] IMEM_BASE_ADDR;
    int unsigned IMEM_SIZE_BYTES;
    int unsigned IMEM_LATENCY;  // Read cycles; independent of frontend FIFO depth.
    logic [63:0] DMEM_BASE_ADDR;
    int unsigned DMEM_SIZE_BYTES;
    int unsigned DMEM_LATENCY;  // Read cycles; independent of IMEM latency.

    logic [63:0] SERIAL_ADDR;
    logic [63:0] EXIT_ADDR;
  } tb_user_cfg_t;

  typedef struct packed {
    memory_backend_t MEMORY_BACKEND;
    int unsigned AXI_CLOCK_HALF_PERIOD_PS;
    logic [63:0] IMEM_BASE_ADDR;
    int unsigned IMEM_SIZE_BYTES;
    int unsigned IMEM_LATENCY;
    logic [63:0] DMEM_BASE_ADDR;
    int unsigned DMEM_SIZE_BYTES;
    int unsigned DMEM_LATENCY;
    logic [63:0] SERIAL_ADDR;
    logic [63:0] EXIT_ADDR;
    int unsigned IMEM_DATA_WIDTH;
    int unsigned IMEM_WORD_BYTES;
    int unsigned IMEM_ADDR_WIDTH;
    int unsigned DMEM_ADDR_WIDTH;
    int unsigned SRAM_RESPONSE_DEPTH;
    int unsigned SRAM_COUNT_WIDTH;
  } tb_cfg_t;

  localparam tb_user_cfg_t DefaultTbUserCfg = '{
      MEMORY_BACKEND: MEM_BACKEND_AXI_SIM,
      AXI_CLOCK_HALF_PERIOD_PS: 1000,
      IMEM_BASE_ADDR: 64'h0001_0000,
      IMEM_SIZE_BYTES: 256 * 1024,
      IMEM_LATENCY: 10,
      DMEM_BASE_ADDR: 64'h0005_0000,
      DMEM_SIZE_BYTES: 768 * 1024,
      DMEM_LATENCY: 1,
      SERIAL_ADDR: 64'h2000_0000,
      EXIT_ADDR: 64'h2000_0100
  };

  function automatic tb_cfg_t build_config(tb_user_cfg_t user_cfg, int unsigned instr_data_width);
    tb_cfg_t cfg;
    cfg.MEMORY_BACKEND = user_cfg.MEMORY_BACKEND;
    cfg.AXI_CLOCK_HALF_PERIOD_PS = user_cfg.AXI_CLOCK_HALF_PERIOD_PS;
    cfg.IMEM_BASE_ADDR = user_cfg.IMEM_BASE_ADDR;
    cfg.IMEM_SIZE_BYTES = user_cfg.IMEM_SIZE_BYTES;
    cfg.IMEM_LATENCY = user_cfg.IMEM_LATENCY;
    cfg.DMEM_BASE_ADDR = user_cfg.DMEM_BASE_ADDR;
    cfg.DMEM_SIZE_BYTES = user_cfg.DMEM_SIZE_BYTES;
    cfg.DMEM_LATENCY = user_cfg.DMEM_LATENCY;
    cfg.SERIAL_ADDR = user_cfg.SERIAL_ADDR;
    cfg.EXIT_ADDR = user_cfg.EXIT_ADDR;
    cfg.IMEM_DATA_WIDTH = instr_data_width;
    cfg.IMEM_WORD_BYTES = instr_data_width / 8;
    cfg.IMEM_ADDR_WIDTH = user_cfg.IMEM_SIZE_BYTES / cfg.IMEM_WORD_BYTES > 1 ?
        $clog2(user_cfg.IMEM_SIZE_BYTES / cfg.IMEM_WORD_BYTES) : 1;
    cfg.DMEM_ADDR_WIDTH = user_cfg.DMEM_SIZE_BYTES / 8 > 1 ? $clog2(user_cfg.DMEM_SIZE_BYTES / 8) :
        1;
    cfg.SRAM_RESPONSE_DEPTH = (user_cfg.DMEM_LATENCY > 0 ? user_cfg.DMEM_LATENCY : 1) + 1;
    cfg.SRAM_COUNT_WIDTH = $clog2((cfg.SRAM_RESPONSE_DEPTH > user_cfg.IMEM_LATENCY ? cfg.SRAM_RESPONSE_DEPTH : user_cfg.IMEM_LATENCY) + 1
        );
    return cfg;
  endfunction
  localparam tb_cfg_t DefaultTbCfg = build_config(
      DefaultTbUserCfg, len5_config_pkg::DEFAULT_LEN5_CFG.IMEM_DATA_WIDTH
  );
  localparam string DefaultSramSimInit = "none";
endpackage
