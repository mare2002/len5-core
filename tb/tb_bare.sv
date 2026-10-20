// Copyright 2022 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: tb_bare.sv
// Author: Michele Caon
// Date: 17/08/2022


module tb_bare #(
  parameter string           MEM_DUMP_FILE = "mem_dump.txt",
  parameter string           TRACE_FILE    = "logs/sim-trace.log",
  parameter longint unsigned BOOT_PC       = tb_config_pkg::IMEM_BASE_ADDR + 64'h180,
  parameter longint unsigned SERIAL_ADDR   = tb_config_pkg::SERIAL_ADDR,
  parameter longint unsigned EXIT_ADDR     = tb_config_pkg::EXIT_ADDR,
  parameter int unsigned     EXIT_TIMEOUT  = 50                                        // cycles
) (
  input logic clk_i,      // simulation clock
  input logic rst_ni,     // simulation reset
  input bit   trace_en_i  // trace enable
);
  `include "len5_utils.svh"

  import len5_pkg::*;
  import expipe_pkg::*;
  import memory_pkg::*;
  import csr_pkg::*;
  import len5_config_pkg::*;
  import tb_config_pkg::*;

  // ----------------
  // TB CONFIGURATION
  // ----------------
  // Memory emulator configuration
  localparam int unsigned MemDumpT = 0;  // memory dump period (in cycles, 0 to disable)
  localparam int unsigned MemPipeNum = 0;  // memory latency

  localparam bit MemEmuSkipInstrOutReg = 1'b0;

  // INTERNAL SIGNALS
  // ----------------
  // Memory file path
  string                                                mem_file = "firmware.hex";

  // Number of cycles to simulate
  longint unsigned                                      curr_cycle;

  // Serial monitor
  bit                                                   serial_recv;
  byte                                                  serial_char;
  string                                                serial_str;

  // Exit monitor
  bit                                                   exit_code_recv;
  byte                                                  exit_code_q;
  bit                                                   exit_cnt_en;
  int unsigned                                          exit_cnt_q;

  // Trace logger
  int                                                   trace_fd;

  // Memory monitor
  longint unsigned                                      num_instr_loads;
  longint unsigned                                      num_data_loads;
  longint unsigned                                      num_data_stores;

  // LEN5 Interface
  len5_data_t                                           cpu_data;

  // Memory Emulator <--> Datapath
  logic                                                 dp2mem_flush;
  logic                                                 dp2mem_instr_valid;
  logic                                                 mem2dp_instr_ready;
  logic                                                 dp2mem_instr_ready;
  logic                                                 mem2dp_instr_valid;
  logic            [                XLEN-1:0]           dp2mem_instr_addr;
  logic            [LEN5_MULTIPLE_ISSUES-1:0][ILEN-1:0] mem2dp_instr_rdata;
  logic            [LEN5_MULTIPLE_ISSUES-1:0]           mem2dp_instr_except_raised;
  except_code_t    [LEN5_MULTIPLE_ISSUES-1:0]           mem2dp_instr_except_code;

  logic                                                 dp2mem_load_valid;
  logic                                                 dp2mem_load_flush;
  logic                                                 mem2dp_load_ready;
  logic                                                 mem2dp_load_valid;
  logic                                                 dp2mem_load_ready;
  logic            [                XLEN-1:0]           dp2mem_load_addr;
  logic            [                     7:0]           dp2mem_load_be;
  logic            [        BUFF_IDX_LEN-1:0]           dp2mem_load_tag;
  logic            [                XLEN-1:0]           mem2dp_load_rdata;
  logic            [        BUFF_IDX_LEN-1:0]           mem2dp_load_tag;
  logic                                                 mem2dp_load_except_raised;
  except_code_t                                         mem2dp_load_except_code;

  logic                                                 dp2mem_store_valid;
  logic                                                 mem2dp_store_ready;
  logic                                                 dp2mem_store_ready;
  logic                                                 mem2dp_store_valid;
  logic                                                 dp2mem_store_we;
  logic            [                XLEN-1:0]           dp2mem_store_addr;
  logic            [        BUFF_IDX_LEN-1:0]           dp2mem_store_tag;
  logic            [                     7:0]           dp2mem_store_be;
  logic            [                XLEN-1:0]           dp2mem_store_wdata;
  logic            [        BUFF_IDX_LEN-1:0]           mem2dp_store_tag;
  logic                                                 mem2dp_store_except_raised;
  except_code_t                                         mem2dp_store_except_code;

  logic sram_initialized, mmio_write;
  logic imem_initialized, dmem_initialized;
  logic                                           imem_req;
  logic [memory_backend_pkg::IMEM_ADDR_WIDTH-1:0] imem_addr;
  logic [memory_backend_pkg::IMEM_DATA_WIDTH-1:0] imem_rdata;
  logic [1:0] dmem_req, dmem_we;
  logic [1:0][memory_backend_pkg::DMEM_ADDR_WIDTH-1:0] dmem_addr;
  logic [1:0][63:0] dmem_wdata, dmem_rdata;
  logic [1:0][7:0] dmem_be;
  logic [2:0][memory_backend_pkg::SRAM_COUNT_WIDTH-1:0] memory_outstanding, memory_occupancy;
  logic                                 memory_load_flush;
  memory_backend_pkg::memory_response_t memory_response  /* verilator split_var */;
  logic                                 monitor_store;
  assign memory_load_flush = MEMORY_BACKEND == MEM_BACKEND_TC_SRAM && DMEM_LATENCY > 1 && dp2mem_load_flush;
  assign monitor_store = MEMORY_BACKEND == MEM_BACKEND_LEGACY ?
                         dp2mem_store_valid && mem2dp_store_ready : mmio_write;

  // ----
  // BODY
  // ----

  // Command-line options and configuration
  // --------------------------------------
  initial begin
    if (FETCH_MEMIF_FIFO_DEPTH == 0 || (FETCH_MEMIF_FIFO_DEPTH & (FETCH_MEMIF_FIFO_DEPTH - 1)) != 0)
      $fatal(1, "Fetch completion queue requires a positive power-of-two capacity");
    // Set the firmware file path
    $value$plusargs("firmware=%s", mem_file);

    // Print firmware file being used
    $display("[TB] Firmware: %s", mem_file);

    // Print boot program counter
    $display("[TB] Boot program counter: 0x%x", BOOT_PC);

    // Print memory file being used
    $display("[TB] Memory image: %s", mem_file);

    // Print the serial monitor base address
    $display("[TB] Serial regiter memory address: 0x%h", SERIAL_ADDR);

    // Print the exit monitor base address
    $display("[TB] Exit register memory address: 0x%h", EXIT_ADDR);

    // Print M extension information
    $display("[TB] M extension: %s", (LEN5_M_EN && LEN5_DIV_EN) ? "YES" : "NO");

    // Print FP extension information
    $display("[TB] F extension: %s", (LEN5_F_EN) ? "YES" : "NO");
    $display("[TB] D extension: %s", (LEN5_D_EN) ? "YES" : "NO");


  end

  // Watchdog
  // --------
  always_ff @(posedge clk_i) begin
    curr_cycle <= curr_cycle + 1;
  end

  // Memory monitor
  // --------------
  // Track the number of issued memory requests
  always_ff @(posedge clk_i) begin : mem_monitor
    if (dp2mem_load_valid && mem2dp_load_ready) begin
      num_data_loads <= num_data_loads + 1;
    end
    if (dp2mem_store_valid && mem2dp_store_ready) begin
      num_data_stores <= num_data_stores + 1;
    end
    if (dp2mem_instr_valid && mem2dp_instr_ready) begin
      num_instr_loads <= num_instr_loads + 1;
    end
  end

  // Serial monitor
  // --------------
  always_ff @(posedge clk_i) begin : serial_monitor
    // Sniff SERIAL ADDRESS and print content
    if (monitor_store && dp2mem_store_addr == SERIAL_ADDR) begin
      serial_recv <= 1'b1;
      serial_char <= dp2mem_store_wdata[7:0];
    end else begin
      serial_recv <= 1'b0;
    end

    if (serial_recv) begin
      // if (serial_char == "\n" || serial_char == "\r") begin
      //   $display("[%8t] SERIAL MONITOR > detected newline:         [0x%h]", $time, serial_char);
      // end else if (serial_char == 8'h0) begin
      //   $display("[%8t] SERIAL MONITOR > detected end of string:   [0x%h]", $time, serial_char);
      // end else begin
      //   $display("[%8t] SERIAL MONITOR > detected character:     %c [0x%h]", $time, serial_char,
      //            serial_char);
      // end

      // Check for end-of-string
      if ((serial_char == 8'h0 || serial_char == "\n" || serial_char == "\r") && serial_str.len() > 0) begin
        $display("\033[1m[%8t] SERIAL MONITOR > received string:\033[0m \"%s\"", $time, serial_str);
        serial_str <= "";
      end else begin
        serial_str <= {serial_str, serial_char};
      end
    end
  end

  // Exit monitor
  // ------------
  // Stop the simulation after a certain memory location is written
  always_ff @(posedge clk_i) begin : exit_monitor
    if ((MEMORY_BACKEND == MEM_BACKEND_LEGACY ? dp2mem_store_valid : monitor_store) && dp2mem_store_addr == EXIT_ADDR) begin
      exit_code_q    <= dp2mem_store_wdata[7:0];
      exit_code_recv <= 1'b1;
    end else begin
      exit_code_recv <= 1'b0;
    end

    if (exit_code_recv) begin
      // Get execution stats
      cpu_data    <= tb_len5_get_data(num_instr_loads, num_data_loads, num_data_stores);
      exit_cnt_en <= 1'b1;
    end
  end

  // Exit timer
  always_ff @(posedge clk_i or negedge rst_ni) begin : blockName
    if (!rst_ni) begin
      exit_cnt_q <= '0;
    end else if (exit_cnt_q >= EXIT_TIMEOUT) begin
      // Print end of execution message
      if (exit_code_q == 0) begin
        $display("\n\033[1;32m[%8t] TB > Program exit with code: 0x%h (SUCCESS)\033[0m\n", $time,
                 exit_code_q);
      end else begin
        $display("\n\033[1;31m[%8t] TB > Program exit with code: 0x%h (FAILURE)\033[0m\n", $time,
                 exit_code_q);
      end

      // Print execution report
      tb_len5_print_report(cpu_data);

      // Clean up and terminate simulation
      $fclose(trace_fd);
      $finish();
    end else if (exit_cnt_en) begin
      exit_cnt_q <= exit_cnt_q + 1;
    end
  end

  // Execution trace logger
  // ----------------------
  // Create trace dump file
  initial begin
    if (trace_en_i) trace_fd = $fopen(TRACE_FILE, "w");
  end

  // Print the currently committing instruction and its program counter
  always_ff @(posedge clk_i) begin : trace_logger
    // Check if an instruction is committing
    tb_len5_update_commit(trace_en_i, trace_fd);
  end

  // -------
  // MODULES
  // -------

  // LEN5 BAREMETAL DATAPATH
  // -----------------------
  datapath #(
    .FETCH_MEMIF_FIFO_DEPTH(FETCH_MEMIF_FIFO_DEPTH),
    .BOOT_PC               (BOOT_PC)
  ) u_datapath (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .mem_flush_o               (dp2mem_flush),
    .instr_req_o               (dp2mem_instr_valid),
    .instr_gnt_i               (mem2dp_instr_ready),
    .instr_rvalid_i            (mem2dp_instr_valid),
    .instr_rready_o            (dp2mem_instr_ready),
    .instr_we_o                (),
    .instr_addr_o              (dp2mem_instr_addr),
    .instr_rdata_i             (mem2dp_instr_rdata),
    .instr_except_raised_i     (mem2dp_instr_except_raised),
    .instr_except_code_i       (mem2dp_instr_except_code),
    .data_load_req_o           (dp2mem_load_valid),
    .data_load_flush_o         (dp2mem_load_flush),
    .data_load_gnt_i           (mem2dp_load_ready),
    .data_load_rvalid_i        (mem2dp_load_valid),
    .data_load_rready_o        (dp2mem_load_ready),
    .data_load_we_o            (),
    .data_load_addr_o          (dp2mem_load_addr),
    .data_load_be_o            (dp2mem_load_be),
    .data_load_tag_o           (dp2mem_load_tag),
    .data_load_rdata_i         (mem2dp_load_rdata),
    .data_load_tag_i           (mem2dp_load_tag),
    .data_load_except_raised_i (mem2dp_load_except_raised),
    .data_load_except_code_i   (mem2dp_load_except_code),
    .data_store_req_o          (dp2mem_store_valid),
    .data_store_gnt_i          (mem2dp_store_ready),
    .data_store_rvalid_i       (mem2dp_store_valid),
    .data_store_rready_o       (dp2mem_store_ready),
    .data_store_we_o           (dp2mem_store_we),
    .data_store_addr_o         (dp2mem_store_addr),
    .data_store_tag_o          (dp2mem_store_tag),
    .data_store_be_o           (dp2mem_store_be),
    .data_store_wdata_o        (dp2mem_store_wdata),
    .data_store_tag_i          (mem2dp_store_tag),
    .data_store_except_raised_i(mem2dp_store_except_raised),
    .data_store_except_code_i  (mem2dp_store_except_code),
    .irq_i                     (),
    .irq_ack_o                 (),
    .irq_id_o                  (),
    .fetch_enable_i            (),
    .core_sleep_o              ()
  );

  memory_protocol_monitor u_memory_monitor (
    .clk_i,
    .rst_ni,
    .flush_i(dp2mem_flush),
    .load_flush_i(memory_load_flush),
    .stop_i(exit_code_recv),
    .retire_i(tb_len5_get_committing()),
    .req_i({dp2mem_store_valid, dp2mem_load_valid, dp2mem_instr_valid}),
    .gnt_i({memory_response.store_gnt, memory_response.load_gnt, memory_response.instr_gnt}),
    .valid_i({
      memory_response.store_valid, memory_response.load_valid, memory_response.instr_valid
    }),
    .ready_i({dp2mem_store_ready, dp2mem_load_ready, dp2mem_instr_ready}),
    .occupancy_i(memory_occupancy)
  );

  // MEMORY EMULATOR
  // ---------------
  if (MEMORY_BACKEND == MEM_BACKEND_LEGACY) begin : gen_legacy
    wire unused_native = &{1'b0, sram_initialized, imem_initialized, dmem_initialized, imem_rdata, dmem_rdata,
    imem_req, imem_addr, dmem_req, dmem_we, dmem_addr, dmem_wdata, dmem_be, memory_outstanding, memory_response};
    assign sram_initialized             = 1'b0;
    assign imem_initialized             = 1'b0;
    assign dmem_initialized             = 1'b0;
    assign imem_rdata                   = '0;
    assign dmem_rdata                   = '0;
    assign imem_req                     = '0;
    assign imem_addr                    = '0;
    assign dmem_req                     = '0;
    assign dmem_we                      = '0;
    assign dmem_addr                    = '0;
    assign dmem_wdata                   = '0;
    assign dmem_be                      = '0;
    assign mmio_write                   = 1'b0;
    assign memory_outstanding           = '0;
    assign memory_occupancy             = '0;
    assign memory_response.instr_gnt    = mem2dp_instr_ready;
    assign memory_response.instr_valid  = mem2dp_instr_valid;
    assign memory_response.instr_data   = mem2dp_instr_rdata;
    assign memory_response.instr_except = mem2dp_instr_except_raised;
    assign memory_response.instr_code   = mem2dp_instr_except_code;
    assign memory_response.load_gnt     = mem2dp_load_ready;
    assign memory_response.load_valid   = mem2dp_load_valid;
    assign memory_response.load_data    = mem2dp_load_rdata;
    assign memory_response.load_tag     = mem2dp_load_tag;
    assign memory_response.load_except  = mem2dp_load_except_raised;
    assign memory_response.load_code    = mem2dp_load_except_code;
    assign memory_response.store_gnt    = mem2dp_store_ready;
    assign memory_response.store_valid  = mem2dp_store_valid;
    assign memory_response.store_tag    = mem2dp_store_tag;
    assign memory_response.store_except = mem2dp_store_except_raised;
    assign memory_response.store_code   = mem2dp_store_except_code;
    memory_bare_emu #(
      .DUMP_PERIOD      (MemDumpT),
      .PIPE_NUM         (MemPipeNum),
      .SKIP_INS_ANS_REG (MemEmuSkipInstrOutReg),
      .SKIP_DATA_ANS_REG(1'b1)
    ) u_memory_bare_emu (
      .clk_i                     (clk_i),
      .rst_ni                    (rst_ni),
      .instr_flush_i             (dp2mem_flush),
      .mem_file_i                (mem_file),
      .mem_dump_file_i           (MEM_DUMP_FILE),
      .instr_valid_i             (dp2mem_instr_valid),
      .instr_valid_o             (mem2dp_instr_valid),
      .instr_ready_o             (mem2dp_instr_ready),
      .instr_ready_i             (dp2mem_instr_ready),
      .instr_addr_i              (dp2mem_instr_addr),
      .instr_rdata_o             (mem2dp_instr_rdata),
      .instr_except_raised_o     (mem2dp_instr_except_raised),
      .instr_except_code_o       (mem2dp_instr_except_code),
      .data_load_valid_i         (dp2mem_load_valid),
      .data_load_ready_o         (mem2dp_load_ready),
      .data_load_valid_o         (mem2dp_load_valid),
      .data_load_ready_i         (dp2mem_load_ready),
      .data_load_addr_i          (dp2mem_load_addr),
      .data_load_be_i            (dp2mem_load_be),
      .data_load_tag_i           (dp2mem_load_tag),
      .data_load_rdata_o         (mem2dp_load_rdata),
      .data_load_tag_o           (mem2dp_load_tag),
      .data_load_except_raised_o (mem2dp_load_except_raised),
      .data_load_except_code_o   (mem2dp_load_except_code),
      .data_store_valid_i        (dp2mem_store_valid),
      .data_store_ready_o        (mem2dp_store_ready),
      .data_store_valid_o        (mem2dp_store_valid),
      .data_store_ready_i        (dp2mem_store_ready),
      .data_store_we_i           (dp2mem_store_we),
      .data_store_addr_i         (dp2mem_store_addr),
      .data_store_tag_i          (dp2mem_store_tag),
      .data_store_be_i           (dp2mem_store_be),
      .data_store_wdata_i        (dp2mem_store_wdata),
      .data_store_tag_o          (mem2dp_store_tag),
      .data_store_except_raised_o(mem2dp_store_except_raised),
      .data_store_except_code_o  (mem2dp_store_except_code)
    );
  end else begin : gen_native_memory
    wire unused_observation = &{1'b0, dp2mem_instr_addr, dp2mem_load_addr, dp2mem_load_be, dp2mem_load_tag,
      dp2mem_store_we, dp2mem_store_tag, dp2mem_store_be, dp2mem_store_wdata, memory_outstanding};
    assign mem2dp_instr_ready         = memory_response.instr_gnt;
    assign mem2dp_instr_valid         = memory_response.instr_valid;
    assign mem2dp_instr_rdata         = memory_response.instr_data;
    assign mem2dp_instr_except_raised = memory_response.instr_except;
    assign mem2dp_instr_except_code   = memory_response.instr_code;
    assign mem2dp_load_ready          = memory_response.load_gnt;
    assign mem2dp_load_valid          = memory_response.load_valid;
    assign mem2dp_load_rdata          = memory_response.load_data;
    assign mem2dp_load_tag            = memory_response.load_tag;
    assign mem2dp_load_except_raised  = memory_response.load_except;
    assign mem2dp_load_except_code    = memory_response.load_code;
    assign mem2dp_store_ready         = memory_response.store_gnt;
    assign mem2dp_store_valid         = memory_response.store_valid;
    assign mem2dp_store_tag           = memory_response.store_tag;
    assign mem2dp_store_except_raised = memory_response.store_except;
    assign mem2dp_store_except_code   = memory_response.store_code;
    if (MEMORY_BACKEND == MEM_BACKEND_TC_SRAM) begin : gen_storage
      tc_sram_adapter #(
        .SERIAL_ADDR(SERIAL_ADDR),
        .EXIT_ADDR  (EXIT_ADDR)
      ) u_adapter (
        .clk_i,
        .rst_ni,
        .instr_flush_i(dp2mem_flush),
        .load_flush_i (dp2mem_load_flush),
        .initialized_i(sram_initialized),
        .instr_req_i  (dp2mem_instr_valid),
        .instr_ready_i(dp2mem_instr_ready),
        .instr_addr_i (dp2mem_instr_addr),
        .load_req_i   (dp2mem_load_valid),
        .load_ready_i (dp2mem_load_ready),
        .load_addr_i  (dp2mem_load_addr),
        .load_be_i    (dp2mem_load_be),
        .load_tag_i   (dp2mem_load_tag),
        .store_req_i  (dp2mem_store_valid),
        .store_ready_i(dp2mem_store_ready),
        .store_we_i   (dp2mem_store_we),
        .store_addr_i (dp2mem_store_addr),
        .store_data_i (dp2mem_store_wdata),
        .store_be_i   (dp2mem_store_be),
        .store_tag_i  (dp2mem_store_tag),
        .response_o   (memory_response),
        .imem_req_o   (imem_req),
        .imem_addr_o  (imem_addr),
        .imem_rdata_i (imem_rdata),
        .dmem_req_o   (dmem_req),
        .dmem_we_o    (dmem_we),
        .dmem_addr_o  (dmem_addr),
        .dmem_wdata_o (dmem_wdata),
        .dmem_be_o    (dmem_be),
        .dmem_rdata_i (dmem_rdata),
        .mmio_write_o (mmio_write),
        .outstanding_o(memory_outstanding),
        .occupancy_o  (memory_occupancy)
      );
      assign sram_initialized = imem_initialized && dmem_initialized;
      tc_sram_storage #(
        .BASE_ADDR       (IMEM_BASE_ADDR),
        .SIZE_BYTES      (IMEM_SIZE_BYTES),
        .LATENCY         (IMEM_LATENCY),
        .DATA_WIDTH      (memory_backend_pkg::IMEM_DATA_WIDTH),
        .NUM_PORTS       (1),
        .OTHER_BASE_ADDR (DMEM_BASE_ADDR),
        .OTHER_SIZE_BYTES(DMEM_SIZE_BYTES)
      ) u_imem (
        .clk_i,
        .req_i        (imem_req),
        .we_i         (1'b0),
        .addr_i       (imem_addr),
        .wdata_i      ('0),
        .be_i         ('0),
        .rdata_o      (imem_rdata),
        .initialized_o(imem_initialized)
      );
      tc_sram_storage #(
        .BASE_ADDR       (DMEM_BASE_ADDR),
        .SIZE_BYTES      (DMEM_SIZE_BYTES),
        .LATENCY         (DMEM_LATENCY),
        .DATA_WIDTH      (64),
        .NUM_PORTS       (2),
        .OTHER_BASE_ADDR (IMEM_BASE_ADDR),
        .OTHER_SIZE_BYTES(IMEM_SIZE_BYTES)
      ) u_dmem (
        .clk_i,
        .req_i        (dmem_req),
        .we_i         (dmem_we),
        .addr_i       (dmem_addr),
        .wdata_i      (dmem_wdata),
        .be_i         (dmem_be),
        .rdata_o      (dmem_rdata),
        .initialized_o(dmem_initialized)
      );
    end else begin : gen_no_storage
      assign sram_initialized   = 1'b0;
      assign imem_initialized   = 1'b0;
      assign dmem_initialized   = 1'b0;
      assign imem_rdata         = '0;
      assign dmem_rdata         = '0;
      assign imem_req           = '0;
      assign imem_addr          = '0;
      assign dmem_req           = '0;
      assign dmem_we            = '0;
      assign dmem_addr          = '0;
      assign dmem_wdata         = '0;
      assign dmem_be            = '0;
      assign memory_response    = '0;
      assign mmio_write         = 1'b0;
      assign memory_outstanding = '0;
      assign memory_occupancy   = '0;
      if (MEMORY_BACKEND == MEM_BACKEND_AXI_SIM) begin : gen_axi_error
        $fatal(1, "MEM_BACKEND_AXI_SIM is reserved and not implemented");
      end else begin : gen_selection_error
        $fatal(1, "Invalid MEMORY_BACKEND selection");
      end
    end
  end
endmodule
