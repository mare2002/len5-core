// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_adapter #(
  parameter int unsigned N = len5_config_pkg::LEN5_MULTIPLE_ISSUES,
  parameter logic [63:0] IMEM_BASE_ADDR = tb_config_pkg::IMEM_BASE_ADDR,
  parameter int unsigned IMEM_SIZE_BYTES = tb_config_pkg::IMEM_SIZE_BYTES,
  parameter int unsigned IMEM_LATENCY = tb_config_pkg::IMEM_LATENCY,
  parameter logic [63:0] DMEM_BASE_ADDR = tb_config_pkg::DMEM_BASE_ADDR,
  parameter int unsigned DMEM_SIZE_BYTES = tb_config_pkg::DMEM_SIZE_BYTES,
  parameter int unsigned DMEM_LATENCY = tb_config_pkg::DMEM_LATENCY,
  parameter logic [63:0] SERIAL_ADDR = tb_config_pkg::SERIAL_ADDR,
  parameter logic [63:0] EXIT_ADDR = tb_config_pkg::EXIT_ADDR,
  parameter int unsigned IMEM_DATA_WIDTH = N > 2 ? 32 * N : 64,
  parameter int unsigned IMEM_ADDR_WIDTH = IMEM_SIZE_BYTES / (IMEM_DATA_WIDTH / 8) > 1 ? $clog2(
      IMEM_SIZE_BYTES / (IMEM_DATA_WIDTH / 8)
  ) : 1,
  parameter int unsigned DMEM_ADDR_WIDTH = DMEM_SIZE_BYTES / 8 > 1 ? $clog2(
      DMEM_SIZE_BYTES / 8
  ) : 1,
  parameter int unsigned RESPONSE_DEPTH = (DMEM_LATENCY > 0 ? DMEM_LATENCY : 1) + 1,
  parameter int unsigned COUNT_WIDTH = $clog2(
      (RESPONSE_DEPTH > IMEM_LATENCY ? RESPONSE_DEPTH : IMEM_LATENCY) + 1
  )
) (
  input logic clk_i,
  input logic rst_ni,
  input logic initialized_i,
  input logic instr_req_i,
  input logic instr_ready_i,
  input logic [63:0] instr_addr_i,
  input logic load_req_i,
  input logic load_ready_i,
  input logic [63:0] load_addr_i,
  input logic [7:0] load_be_i,
  input logic [len5_pkg::BUFF_IDX_LEN-1:0] load_tag_i,
  input logic store_req_i,
  input logic store_ready_i,
  input logic store_we_i,
  input logic [63:0] store_addr_i,
  input logic [63:0] store_data_i,
  input logic [7:0] store_be_i,
  input logic [len5_pkg::BUFF_IDX_LEN-1:0] store_tag_i,
  output memory_backend_pkg::memory_response_t response_o  /* verilator split_var */,
  output logic imem_req_o,
  output logic [IMEM_ADDR_WIDTH-1:0] imem_addr_o,
  input logic [IMEM_DATA_WIDTH-1:0] imem_rdata_i,
  output logic [1:0] dmem_req_o,
  output logic [1:0] dmem_we_o,
  output logic [1:0][DMEM_ADDR_WIDTH-1:0] dmem_addr_o,
  output logic [1:0][63:0] dmem_wdata_o,
  output logic [1:0][7:0] dmem_be_o,
  input logic [1:0][63:0] dmem_rdata_i,
  output logic mmio_write_o,
  output logic [2:0][COUNT_WIDTH-1:0] outstanding_o,
  output logic [2:0][COUNT_WIDTH-1:0] occupancy_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;

  localparam int unsigned FetchWordBytes = IMEM_DATA_WIDTH / 8;
  localparam int unsigned DataCountWidth = $clog2(RESPONSE_DEPTH + 1);
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_ADDR_SHIFT = $clog2(FetchWordBytes);

  typedef struct packed {
    logic [63:0] data;
    logic [BUFF_IDX_LEN-1:0] tag;
    logic except;
    except_code_t code;
  } data_response_t;
  typedef struct packed {
    logic [N-1:0][31:0] data;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } instr_response_t;
  typedef struct packed {
    logic upper_half;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } fetch_metadata_t;
  typedef struct packed {
    logic [2:0] byte_offset;
    logic [7:0] byte_mask;
    data_response_t response;
  } load_metadata_t;

  logic instr_active, instr_accepted;
  logic        fetch_result_valid;
  logic [63:0] fetch_bundle_addr;
  logic        fetch_pc_misaligned;
  logic [N-1:0] fetch_lane_sram, fetch_lane_except;
  except_code_t [N-1:0] fetch_lane_code;
  logic         [N-1:0] unused_instr_mmio;
  fetch_metadata_t fetch_metadata, fetch_result_metadata;
  instr_response_t fetch_result;

  logic [1:0][DataCountWidth-1:0] data_outstanding, data_occupancy;

  logic load_accepted, load_credit;
  logic load_sram, load_except, unused_load_mmio;
  except_code_t load_code;
  logic         load_result_valid;
  load_metadata_t load_metadata, load_result_metadata;
  data_response_t load_result, load_response;

  logic store_accepted, store_credit;
  logic store_sram, store_mmio, store_except;
  except_code_t store_code;
  logic         store_result_valid_q;
  data_response_t store_result_q, store_response;

  wire unused_read_data = &{1'b0, instr_ready_i, dmem_rdata_i[1], store_response.data, fetch_lane_sram};

  // Each fetch accesses one IMEM word. N=1 selects one half of a 64-bit word.
  // Check the original PC before bundle alignment, then check every returned lane.
  assign fetch_bundle_addr   = N == 1 ? instr_addr_i : instr_addr_i & ~64'(N * 4 - 1);
  assign fetch_pc_misaligned = instr_addr_i[1:0] != 0;
  for (genvar lane = 0; lane < N; lane++) begin : gen_instr_decode
    memory_access_check #(
      .BASE_ADDR (IMEM_BASE_ADDR),
      .SIZE_BYTES(IMEM_SIZE_BYTES),
      .KIND      (0)
    ) u_decode (
      .addr_i  (fetch_bundle_addr + 64'(lane * 4)),
      .bytes_i (4),
      .sram_o  (fetch_lane_sram[lane]),
      .mmio_o  (unused_instr_mmio[lane]),
      .except_o(fetch_lane_except[lane]),
      .code_o  (fetch_lane_code[lane])
    );
  end
  assign fetch_metadata.upper_half = instr_addr_i[2];
  assign fetch_metadata.except = fetch_pc_misaligned ? '1 : fetch_lane_except;
  assign fetch_metadata.code = fetch_pc_misaligned ? {N{E_I_ADDR_MISALIGNED}} : fetch_lane_code;

  assign instr_active = initialized_i && rst_ni;
  assign instr_accepted = instr_req_i && response_o.instr_gnt;
  assign imem_req_o = instr_accepted && !fetch_pc_misaligned && fetch_lane_sram[0];
  assign imem_addr_o = IMEM_ADDR_WIDTH'((fetch_bundle_addr - IMEM_BASE_ADDR) >> IMEM_ADDR_SHIFT);

  // The frontend reserves a completion slot before issuing each request. Results
  // therefore always have a destination, even when downstream instruction issue stalls.
  // Keep grant independent of result-ready to permit same-cycle latency-zero returns.
  assign response_o.instr_gnt = instr_active;
  assign occupancy_o[0] = '0;
  if (IMEM_LATENCY == 0) begin : gen_async_fetch
    assign fetch_result_valid    = instr_accepted;
    assign fetch_result_metadata = fetch_metadata;
    assign outstanding_o[0]      = '0;
  end else begin : gen_sync_fetch
    logic            [IMEM_LATENCY-1:0] pending_q;
    fetch_metadata_t                    metadata_q[IMEM_LATENCY];
    assign fetch_result_valid    = pending_q[IMEM_LATENCY-1];
    assign fetch_result_metadata = metadata_q[IMEM_LATENCY-1];
    assign outstanding_o[0]      = COUNT_WIDTH'($countones(pending_q));
    always_ff @(posedge clk_i or negedge rst_ni) begin : update_fetch_latency
      if (!rst_ni) begin
        pending_q <= '0;
        foreach (metadata_q[stage]) metadata_q[stage] <= '0;
      end else begin
        pending_q[0] <= instr_accepted;
        if (instr_accepted) metadata_q[0] <= fetch_metadata;
        for (int stage = 1; stage < IMEM_LATENCY; stage++) begin
          pending_q[stage] <= pending_q[stage-1];
          if (pending_q[stage-1]) metadata_q[stage] <= metadata_q[stage-1];
        end
      end
    end
  end

  always_comb begin : select_instruction_lanes
    fetch_result        = '0;
    fetch_result.except = fetch_result_metadata.except;
    fetch_result.code   = fetch_result_metadata.code;
    for (int lane = 0; lane < N; lane++) begin
      if (!fetch_result_metadata.except[lane]) begin
        fetch_result.data[lane] = 32'(imem_rdata_i >> (32 * (lane + (N == 1 ? int'(fetch_result_metadata.upper_half) : 0))));
      end
    end
  end

  assign response_o.instr_valid = instr_active && fetch_result_valid;
  assign {response_o.instr_data, response_o.instr_except, response_o.instr_code} = fetch_result;

  // DMEM and MMIO retain size validation and misalignment-before-access-fault priority.
  memory_access_check #(
    .BASE_ADDR  (DMEM_BASE_ADDR),
    .SIZE_BYTES (DMEM_SIZE_BYTES),
    .SERIAL_ADDR(SERIAL_ADDR),
    .EXIT_ADDR  (EXIT_ADDR),
    .KIND       (1)
  ) u_load_decode (
    .addr_i  (load_addr_i),
    .bytes_i (access_bytes(load_be_i)),
    .sram_o  (load_sram),
    .mmio_o  (unused_load_mmio),
    .except_o(load_except),
    .code_o  (load_code)
  );
  memory_access_check #(
    .BASE_ADDR  (DMEM_BASE_ADDR),
    .SIZE_BYTES (DMEM_SIZE_BYTES),
    .SERIAL_ADDR(SERIAL_ADDR),
    .EXIT_ADDR  (EXIT_ADDR),
    .KIND       (2)
  ) u_store_decode (
    .addr_i  (store_addr_i),
    .bytes_i (access_bytes(store_be_i)),
    .sram_o  (store_sram),
    .mmio_o  (store_mmio),
    .except_o(store_except),
    .code_o  (store_code)
  );

  // Accepted loads retain their response ownership across CPU pipeline flushes.
  assign response_o.load_gnt = initialized_i && load_credit;
  assign response_o.store_gnt = initialized_i && store_credit;
  assign load_accepted = load_req_i && response_o.load_gnt;
  assign store_accepted = store_req_i && response_o.store_gnt;
  assign dmem_req_o[0] = load_accepted && load_sram;
  assign dmem_req_o[1] = store_accepted && store_sram && store_we_i;
  assign dmem_we_o = 2'b10;
  assign dmem_addr_o[0] = DMEM_ADDR_WIDTH'((load_addr_i - DMEM_BASE_ADDR) >> 3);
  assign dmem_addr_o[1] = DMEM_ADDR_WIDTH'((store_addr_i - DMEM_BASE_ADDR) >> 3);
  assign dmem_wdata_o[0] = '0;
  assign dmem_wdata_o[1] = store_data_i << (8 * store_addr_i[2:0]);
  assign dmem_be_o[0] = '0;
  assign dmem_be_o[1] = store_be_i << store_addr_i[2:0];
  assign mmio_write_o = store_accepted && store_we_i && store_mmio;

  assign load_metadata = '{
          byte_offset: load_addr_i[2:0],
          byte_mask: load_be_i,
          response: '{data: '0, tag: load_tag_i, except: load_except, code: load_code}
      };
  if (DMEM_LATENCY == 0) begin : gen_async_load
    assign load_result_valid    = load_accepted;
    assign load_result_metadata = load_metadata;
  end else begin : gen_sync_load
    logic           [DMEM_LATENCY-1:0] pending_q;
    load_metadata_t                    metadata_q[DMEM_LATENCY];
    assign load_result_valid    = pending_q[DMEM_LATENCY-1];
    assign load_result_metadata = metadata_q[DMEM_LATENCY-1];
    always_ff @(posedge clk_i or negedge rst_ni) begin : update_load_latency
      if (!rst_ni) begin
        pending_q <= '0;
        foreach (metadata_q[stage]) metadata_q[stage] <= '0;
      end else begin
        pending_q[0] <= load_accepted;
        if (load_accepted) metadata_q[0] <= load_metadata;
        for (int stage = 1; stage < DMEM_LATENCY; stage++) begin
          pending_q[stage] <= pending_q[stage-1];
          if (pending_q[stage-1]) metadata_q[stage] <= metadata_q[stage-1];
        end
      end
    end
  end

  // Byte selection zero-extends; sign extension remains in the LSU.
  always_comb begin : select_load_bytes
    load_result      = load_result_metadata.response;
    load_result.data = '0;
    for (int b = 0; b < 8; b++) begin
      if (load_result_metadata.byte_mask[b] && !load_result_metadata.response.except) begin
        load_result.data[b*8+:8] = 8'(dmem_rdata_i[0] >> (8 * (int'(load_result_metadata.byte_offset) + b)));
      end
    end
  end

  // Stores write at acceptance, irrespective of DMEM read latency. Acknowledge one cycle later.
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_store_response
    if (!rst_ni) begin
      store_result_valid_q <= 1'b0;
      store_result_q       <= '0;
    end else begin
      store_result_valid_q <= store_accepted;
      if (store_accepted) begin
        store_result_q <= '{
            data: '0,
            tag: store_tag_i,
            except: store_except || !store_we_i,
            code: store_we_i ? store_code : E_ST_ACCESS_FAULT
        };
      end
    end
  end

  memory_response_buffer #(
    .DATA_T(data_response_t),
    .DEPTH (RESPONSE_DEPTH)
  ) u_load_buffer (
    .clk_i,
    .rst_ni,
    .flush_i       (1'b0),
    .allocate_i    (load_accepted),
    .credit_o      (load_credit),
    .result_valid_i(load_result_valid),
    .result_i      (load_result),
    .valid_o       (response_o.load_valid),
    .ready_i       (load_ready_i),
    .data_o        (load_response),
    .outstanding_o (data_outstanding[0]),
    .occupancy_o   (data_occupancy[0])
  );
  memory_response_buffer #(
    .DATA_T(data_response_t),
    .DEPTH (RESPONSE_DEPTH)
  ) u_store_buffer (
    .clk_i,
    .rst_ni,
    .flush_i       (1'b0),
    .allocate_i    (store_accepted),
    .credit_o      (store_credit),
    .result_valid_i(store_result_valid_q),
    .result_i      (store_result_q),
    .valid_o       (response_o.store_valid),
    .ready_i       (store_ready_i),
    .data_o        (store_response),
    .outstanding_o (data_outstanding[1]),
    .occupancy_o   (data_occupancy[1])
  );
  assign outstanding_o[1]        = COUNT_WIDTH'(data_outstanding[0]);
  assign outstanding_o[2]        = COUNT_WIDTH'(data_outstanding[1]);
  assign occupancy_o[1]          = COUNT_WIDTH'(data_occupancy[0]);
  assign occupancy_o[2]          = COUNT_WIDTH'(data_occupancy[1]);
  assign response_o.load_data    = load_response.data;
  assign response_o.load_tag     = load_response.tag;
  assign response_o.load_except  = load_response.except;
  assign response_o.load_code    = load_response.code;
  assign response_o.store_tag    = store_response.tag;
  assign response_o.store_except = store_response.except;
  assign response_o.store_code   = store_response.code;

  initial begin : check_configuration
    if (!(N == 1 || N == 2 || N == 4 || N == 8) || N != len5_config_pkg::LEN5_MULTIPLE_ISSUES ||
        IMEM_DATA_WIDTH != (N > 2 ? 32 * N : 64))
      $fatal(1, "TC_SRAM requires N=1/2/4/8 and one full-width IMEM word per bundle");
    if (RESPONSE_DEPTH < (DMEM_LATENCY > 0 ? DMEM_LATENCY : 1) + 1 || COUNT_WIDTH < $clog2(
            RESPONSE_DEPTH + 1
        ) || COUNT_WIDTH < $clog2(
            IMEM_LATENCY + 1
        ))
      $fatal(1, "TC_SRAM response capacity must cover read latency and one-cycle store completion");
    if (IMEM_SIZE_BYTES < FetchWordBytes || IMEM_SIZE_BYTES % FetchWordBytes != 0 ||
        IMEM_BASE_ADDR % 64'(FetchWordBytes) != 0 ||
        IMEM_BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(IMEM_SIZE_BYTES-1)))
      $fatal(1, "Invalid IMEM address window");
    if (DMEM_SIZE_BYTES < 8 || DMEM_SIZE_BYTES % 8 != 0 || DMEM_BASE_ADDR[2:0] != 0 ||
        DMEM_BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(DMEM_SIZE_BYTES-1)))
      $fatal(1, "Invalid DMEM address window");
    if (regions_overlap(IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES), DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)))
      $fatal(1, "IMEM and DMEM regions overlap");
    if (SERIAL_ADDR[2:0] != 0 || EXIT_ADDR[2:0] != 0 || SERIAL_ADDR == EXIT_ADDR || regions_overlap(
            SERIAL_ADDR, 8, IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES)
        ) || regions_overlap(
            EXIT_ADDR, 8, IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES)
        ) || regions_overlap(
            SERIAL_ADDR, 8, DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)
        ) || regions_overlap(
            EXIT_ADDR, 8, DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)
        ))
      $fatal(1, "Invalid or overlapping SRAM/MMIO regions");
    if ((SERIAL_ADDR & len5_config_pkg::MMAP_MASK) == 0 || (EXIT_ADDR & len5_config_pkg::MMAP_MASK) == 0)
      $fatal(1, "MMIO addresses must be excluded by MMAP_MASK from store-to-load forwarding");
    if (len5_config_pkg::ONLY_DOUBLEWORD_MEM_ACCESSES || len5_config_pkg::LEN5_C_EN)
      $fatal(1, "TC_SRAM requires original load offsets and uncompressed instructions");
  end
endmodule
