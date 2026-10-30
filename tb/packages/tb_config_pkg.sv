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

  function automatic bit check_build(len5_config_pkg::len5_cfg cpu, tb_cfg_t cfg,
                                     string sram_sim_init);
    tb_user_cfg_t user_cfg;
    logic [63:0] imem_last, dmem_last;
    logic [63:0] mmio          [2];
    bit          native_memory;
    if (!len5_config_pkg::check_build(cpu)) return 1'b0;
    if ($isunknown(cfg)) $fatal(1, "check_build: TB configuration contains unknown bits");
    if (!(cfg.MEMORY_BACKEND inside {MEM_BACKEND_LEGACY, MEM_BACKEND_TC_SRAM, MEM_BACKEND_AXI_SIM}))
      $fatal(1, "check_build: Invalid MEMORY_BACKEND selection");
    native_memory = cfg.MEMORY_BACKEND != MEM_BACKEND_LEGACY;
    if (cpu.LOAD_BUFFER_DRAIN_ON_FLUSH != native_memory)
      $fatal(
          1,
          "check_build: LOAD_BUFFER_DRAIN_ON_FLUSH must be 1 for TC_SRAM/AXI_SIM (loads cannot be cancelled), 0 for LEGACY"
      );
    if (cpu.FETCH_MEM_DRAIN_ON_FLUSH != native_memory)
      $fatal(
          1,
          "check_build: FETCH_MEM_DRAIN_ON_FLUSH must be 1 for TC_SRAM/AXI_SIM (fetches cannot be cancelled), 0 for LEGACY"
      );
    if (cfg.MEMORY_BACKEND == MEM_BACKEND_AXI_SIM && cfg.AXI_CLOCK_HALF_PERIOD_PS == 0)
      $fatal(1, "check_build: AXI_CLOCK_HALF_PERIOD_PS must be positive for AXI_SIM");
    if (sram_sim_init != "none" && sram_sim_init != "zeros" && sram_sim_init != "ones" && sram_sim_init != "random")
      $fatal(1, "check_build: SRAM_SIM_INIT must be none, zeros, ones or random");
    if (cfg.IMEM_SIZE_BYTES < 8 || cfg.IMEM_SIZE_BYTES % 8 != 0 || cfg.IMEM_BASE_ADDR[2:0] != 0 ||
        cfg.IMEM_BASE_ADDR > 64'hffff_ffff_ffff_ffff - 64'(cfg.IMEM_SIZE_BYTES - 1))
      $fatal(1, "check_build: Invalid IMEM alignment, size or address overflow");
    if (cfg.DMEM_SIZE_BYTES < 8 || cfg.DMEM_SIZE_BYTES % 8 != 0 || cfg.DMEM_BASE_ADDR[2:0] != 0 ||
        cfg.DMEM_BASE_ADDR > 64'hffff_ffff_ffff_ffff - 64'(cfg.DMEM_SIZE_BYTES - 1))
      $fatal(1, "check_build: Invalid DMEM alignment, size or address overflow");
    imem_last = cfg.IMEM_BASE_ADDR + 64'(cfg.IMEM_SIZE_BYTES - 1);
    dmem_last = cfg.DMEM_BASE_ADDR + 64'(cfg.DMEM_SIZE_BYTES - 1);
    if (cfg.IMEM_BASE_ADDR <= dmem_last && cfg.DMEM_BASE_ADDR <= imem_last)
      $fatal(1, "check_build: IMEM and DMEM regions overlap");
    if (native_memory && (cfg.IMEM_SIZE_BYTES < cpu.IMEM_DATA_WIDTH / 8 ||
        cfg.IMEM_SIZE_BYTES % (cpu.IMEM_DATA_WIDTH / 8) != 0 ||
        cfg.IMEM_BASE_ADDR % 64'(cpu.IMEM_DATA_WIDTH / 8) != 0))
      $fatal(1, "check_build: native IMEM must contain aligned, complete instruction-memory beats");
    if (native_memory && cpu.ONLY_DOUBLEWORD_MEM_ACCESSES)
      $fatal(
          1,
          "check_build: TC_SRAM/AXI_SIM require original load offsets (ONLY_DOUBLEWORD_MEM_ACCESSES=0)"
      );
    mmio = '{cfg.SERIAL_ADDR, cfg.EXIT_ADDR};
    if (cfg.SERIAL_ADDR == cfg.EXIT_ADDR)
      $fatal(1, "check_build: SERIAL_ADDR and EXIT_ADDR must be distinct");
    foreach (mmio[i]) begin
      if (mmio[i][2:0] != 0 || (mmio[i] >= cfg.IMEM_BASE_ADDR && mmio[i] <= imem_last) ||
          (mmio[i] >= cfg.DMEM_BASE_ADDR && mmio[i] <= dmem_last))
        $fatal(1, "check_build: MMIO addresses must be eight-byte aligned and outside IMEM/DMEM");
      if (native_memory && (mmio[i] & cpu.MMAP_MASK) == 0)
        $fatal(1, "check_build: MMAP_MASK must exclude MMIO from store-to-load forwarding");
    end
    user_cfg = '{
        MEMORY_BACKEND: cfg.MEMORY_BACKEND,
        AXI_CLOCK_HALF_PERIOD_PS: cfg.AXI_CLOCK_HALF_PERIOD_PS,
        IMEM_BASE_ADDR: cfg.IMEM_BASE_ADDR,
        IMEM_SIZE_BYTES: cfg.IMEM_SIZE_BYTES,
        IMEM_LATENCY: cfg.IMEM_LATENCY,
        DMEM_BASE_ADDR: cfg.DMEM_BASE_ADDR,
        DMEM_SIZE_BYTES: cfg.DMEM_SIZE_BYTES,
        DMEM_LATENCY: cfg.DMEM_LATENCY,
        SERIAL_ADDR: cfg.SERIAL_ADDR,
        EXIT_ADDR: cfg.EXIT_ADDR
    };
    if (cfg !== build_config(user_cfg, cpu.IMEM_DATA_WIDTH))
      $fatal(1, "check_build: inconsistent derived TB fields; construct TbCfg with build_config()");
    return 1'b1;
  endfunction
endpackage
