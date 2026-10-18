// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_adapter #(
    parameter int unsigned N = len5_config_pkg::LEN5_MULTIPLE_ISSUES,
    parameter logic [63:0] BASE_ADDR = tb_config_pkg::SRAM_BASE_ADDR,
    parameter int unsigned SIZE_BYTES = tb_config_pkg::SRAM_SIZE_BYTES,
    parameter int unsigned LATENCY = tb_config_pkg::SRAM_LATENCY,
    parameter logic [63:0] SERIAL_ADDR = tb_config_pkg::SERIAL_ADDR,
    parameter logic [63:0] EXIT_ADDR = tb_config_pkg::EXIT_ADDR,
    parameter int unsigned ADDR_WIDTH = SIZE_BYTES / 8 > 1 ? $clog2(SIZE_BYTES / 8) : 1,
    parameter int unsigned RESPONSE_DEPTH = LATENCY + 1,
    parameter int unsigned COUNT_WIDTH = $clog2(RESPONSE_DEPTH + 1)
) (
    input logic clk_i,
    rst_ni,
    instr_flush_i,
    load_flush_i,
    initialized_i,
    input logic instr_req_i,
    instr_ready_i,
    input logic [63:0] instr_addr_i,
    input logic load_req_i,
    load_ready_i,
    input logic [63:0] load_addr_i,
    input logic [7:0] load_be_i,
    input logic [len5_pkg::BUFF_IDX_LEN-1:0] load_tag_i,
    input logic store_req_i,
    store_ready_i,
    store_we_i,
    input logic [63:0] store_addr_i,
    store_data_i,
    input logic [7:0] store_be_i,
    input logic [len5_pkg::BUFF_IDX_LEN-1:0] store_tag_i,
    output memory_backend_pkg::memory_response_t response_o  /* verilator split_var */,
    output logic [2:0] sram_req_o,
    sram_we_o,
    output logic [2:0][ADDR_WIDTH-1:0] sram_addr_o,
    output logic [2:0][63:0] sram_wdata_o,
    output logic [2:0][7:0] sram_be_o,
    input logic [2:0][63:0] sram_rdata_i,
    output logic mmio_write_o,
    output logic [2:0][COUNT_WIDTH-1:0] outstanding_o,
    occupancy_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;

  // Port mapping and fetch geometry.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned INSTR_PORT = 0;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned LOAD_PORT = 1;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned STORE_PORT = 2;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned FETCH_BEATS = (N + 1) / 2;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned FETCH_BEAT_WIDTH = FETCH_BEATS > 1 ? $clog2(FETCH_BEATS) : 1;
  // Keep invalid latency-zero configurations well formed until the configuration diagnostic.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned READ_STAGES = LATENCY > 0 ? LATENCY : 1;

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
    logic [2:0] byte_offset;
    logic [7:0] byte_mask;
    data_response_t response;
  } load_metadata_t;
  typedef struct packed {
    logic [FETCH_BEAT_WIDTH-1:0] beat;
    logic last;
    logic upper_half;
    logic [1:0] except;
    except_code_t [1:0] code;
  } fetch_metadata_t;

  // Each accepted CPU transaction reserves one response slot in its own channel.
  logic [2:0] request_accepted;
  logic [2:0] response_credit;
  logic [2:0] result_valid_q;

  // Load metadata follows the native read pipeline, including requests which return faults.
  logic load_sram, load_except;
  except_code_t load_code;
  logic unused_load_mmio;
  logic [2:0] load_byte_offset_q;
  logic [7:0] load_byte_mask_q;
  data_response_t load_response_q;
  data_response_t load_result, load_response;
  load_metadata_t load_metadata_q[READ_STAGES];
  logic [READ_STAGES-1:0] load_pending_q;
  logic load_flush;

  // Store side effects occur at acceptance; the registered response carries completion.
  logic store_sram, store_mmio, store_except;
  except_code_t store_code;
  data_response_t store_response_q;
  data_response_t store_response;

  // Fetch request state: retain the bundle address and original PC alignment across beats.
  logic fetch_busy_q;
  logic [FETCH_BEAT_WIDTH-1:0] fetch_next_beat_q;
  logic [63:0] fetch_bundle_addr_q;
  logic fetch_pc_misaligned_q;
  logic fetch_beat_issue;
  logic [FETCH_BEAT_WIDTH-1:0] fetch_beat;
  logic [63:0] fetch_request_base, fetch_bundle_addr, fetch_read_addr;
  logic fetch_pc_misaligned;
  logic [1:0][63:0] fetch_lane_addr;
  logic [1:0] fetch_lane_sram, fetch_lane_except;
  except_code_t [1:0] fetch_lane_code;
  logic [1:0] unused_instr_mmio;

  // Returning-beat metadata is registered with port 0's read; earlier beats stay in the bundle.
  logic [FETCH_BEAT_WIDTH-1:0] fetch_result_beat_q;
  logic fetch_last_beat_q, fetch_upper_half_q;
  logic [1:0] fetch_lane_except_q;
  except_code_t [1:0] fetch_lane_code_q;
  instr_response_t fetch_bundle_q;
  instr_response_t fetch_result, fetch_response;
  fetch_metadata_t fetch_metadata_q[READ_STAGES];
  logic [READ_STAGES-1:0] fetch_pending_q;

  // Long-latency loads must be canceled before a flushed LSU entry can reuse their tags.
  // Preserve the original drain-on-flush behavior at latency one.
  assign load_flush = LATENCY > 1 && load_flush_i;
  assign result_valid_q[LOAD_PORT] = load_pending_q[READ_STAGES-1];
  assign load_response_q = load_metadata_q[READ_STAGES-1].response;
  assign load_byte_offset_q = load_metadata_q[READ_STAGES-1].byte_offset;
  assign load_byte_mask_q = load_metadata_q[READ_STAGES-1].byte_mask;
  assign result_valid_q[INSTR_PORT] = fetch_pending_q[READ_STAGES-1];
  assign fetch_result_beat_q = fetch_metadata_q[READ_STAGES-1].beat;
  assign fetch_last_beat_q = fetch_metadata_q[READ_STAGES-1].last;
  assign fetch_upper_half_q = fetch_metadata_q[READ_STAGES-1].upper_half;
  assign fetch_lane_except_q = fetch_metadata_q[READ_STAGES-1].except;
  assign fetch_lane_code_q = fetch_metadata_q[READ_STAGES-1].code;

  wire unused_read_ports = &{1'b0, sram_rdata_i[STORE_PORT], store_response.data, fetch_lane_sram[1]};

  // Data request decoding.
  memory_access_check #(
    .BASE_ADDR  (BASE_ADDR),
    .SIZE_BYTES (SIZE_BYTES),
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
    .BASE_ADDR  (BASE_ADDR),
    .SIZE_BYTES (SIZE_BYTES),
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

  // Request acceptance. Credit includes reset/flush gating from each response buffer.
  assign response_o.load_gnt = initialized_i && response_credit[LOAD_PORT];
  assign response_o.store_gnt = initialized_i && response_credit[STORE_PORT];
  assign response_o.instr_gnt = initialized_i && response_credit[INSTR_PORT] && !fetch_busy_q;
  assign request_accepted[INSTR_PORT] = instr_req_i && response_o.instr_gnt;
  assign request_accepted[LOAD_PORT] = load_req_i && response_o.load_gnt;
  assign request_accepted[STORE_PORT] = store_req_i && response_o.store_gnt;

  // Fetch beat addressing. A new bundle starts at beat zero; busy cycles issue its remaining beats.
  assign fetch_beat_issue = initialized_i && rst_ni && !instr_flush_i &&
                            (fetch_busy_q || request_accepted[INSTR_PORT]);
  assign fetch_beat = fetch_busy_q ? fetch_next_beat_q : '0;
  assign fetch_request_base = N == 1 ? instr_addr_i : instr_addr_i & ~64'(N * 4 - 1);
  assign fetch_bundle_addr = fetch_busy_q ? fetch_bundle_addr_q : fetch_request_base;
  assign fetch_pc_misaligned = fetch_busy_q ? fetch_pc_misaligned_q : (instr_addr_i[1:0] != 0);
  assign fetch_read_addr = fetch_bundle_addr + 64'(fetch_beat) * 8;

  // Keep both lane checks: each returned instruction carries its own address exception.
  // The original-PC alignment check above precedes bundle alignment and applies to every lane.
  for (genvar j = 0; j < 2; j++) begin : gen_instr_decode
    assign fetch_lane_addr[j] = fetch_read_addr + 64'(j * 4);
    memory_access_check #(
      .BASE_ADDR (BASE_ADDR),
      .SIZE_BYTES(SIZE_BYTES),
      .KIND      (0)
    ) u_decode (
      .addr_i  (fetch_lane_addr[j]),
      .bytes_i (4),
      .sram_o  (fetch_lane_sram[j]),
      .mmio_o  (unused_instr_mmio[j]),
      .except_o(fetch_lane_except[j]),
      .code_o  (fetch_lane_code[j])
    );
  end

  // Native SRAM operations. Decode gates requests before word-index truncation can alias an address.
  always_comb begin : drive_sram_ports
    sram_req_o              = '0;
    sram_we_o               = 3'b100;
    sram_addr_o[INSTR_PORT]  = ADDR_WIDTH'((fetch_read_addr - BASE_ADDR) >> 3);
    sram_addr_o[LOAD_PORT]   = ADDR_WIDTH'((load_addr_i - BASE_ADDR) >> 3);
    sram_addr_o[STORE_PORT]  = ADDR_WIDTH'((store_addr_i - BASE_ADDR) >> 3);
    sram_wdata_o            = '0;
    sram_wdata_o[STORE_PORT] = store_data_i << (8 * store_addr_i[2:0]);
    sram_be_o               = '0;
    sram_be_o[STORE_PORT]    = store_be_i << store_addr_i[2:0];
    sram_req_o[INSTR_PORT]   = fetch_beat_issue && !fetch_pc_misaligned && fetch_lane_sram[0];
    sram_req_o[LOAD_PORT]    = request_accepted[LOAD_PORT] && load_sram;
    sram_req_o[STORE_PORT]   = request_accepted[STORE_PORT] && store_sram && store_we_i;
  end

  // MMIO has the same accepted-store event, but never issues a native SRAM write.
  assign mmio_write_o = request_accepted[STORE_PORT] && store_we_i && store_mmio;

  // Load return: select bytes using the accepted request's offset and mask. The LSU sign-extends.
  always_comb begin : select_load_bytes
    load_result      = load_response_q;
    load_result.data = '0;
    for (int b = 0; b < 8; b++) begin
      if (load_byte_mask_q[b] && !load_response_q.except) begin
        load_result.data[b*8+:8] = 8'(sram_rdata_i[LOAD_PORT] >> (8 * (int'(load_byte_offset_q) + b)));
      end
    end
  end

  // Fetch return: merge this beat with earlier lanes; N=1 selects one 32-bit half of the SRAM word.
  always_comb begin : assemble_fetch_result
    fetch_result = fetch_bundle_q;
    for (int lane = 0; lane < 2; lane++) begin
      int bundle_lane;
      int word_lane;

      bundle_lane = int'(fetch_result_beat_q) * 2 + lane;
      word_lane   = N == 1 ? int'(fetch_upper_half_q) : lane;
      if (bundle_lane < N) begin
        fetch_result.data[bundle_lane] = fetch_lane_except_q[lane] ? '0 :
            32'(sram_rdata_i[INSTR_PORT] >> (32 * word_lane));
        fetch_result.except[bundle_lane] = fetch_lane_except_q[lane];
        fetch_result.code[bundle_lane] = fetch_lane_code_q[lane];
      end
    end
  end

  // Load pipeline. Validity, tag, offset and fault status advance with port 1's SRAM data.
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_load_pipeline
    if (!rst_ni) begin
      load_pending_q <= '0;
      foreach (load_metadata_q[stage]) load_metadata_q[stage] <= '0;
    end else if (load_flush) begin
      load_pending_q <= '0;
    end else begin
      load_pending_q[0] <= request_accepted[LOAD_PORT];
      if (request_accepted[LOAD_PORT]) begin
        load_metadata_q[0].response <= '{data: '0, tag: load_tag_i, except: load_except, code: load_code};
        load_metadata_q[0].byte_offset <= load_addr_i[2:0];
        load_metadata_q[0].byte_mask <= load_be_i;
      end
      for (int stage = 1; stage < READ_STAGES; stage++) begin
        load_pending_q[stage] <= load_pending_q[stage-1];
        if (load_pending_q[stage-1]) load_metadata_q[stage] <= load_metadata_q[stage-1];
      end
    end
  end

  // Store pipeline. Port 2 writes at acceptance; completion retains the original tag and exception.
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_store_pipeline
    if (!rst_ni) begin
      result_valid_q[STORE_PORT] <= 1'b0;
      store_response_q           <= '0;
    end else begin
      result_valid_q[STORE_PORT] <= request_accepted[STORE_PORT];
      if (request_accepted[STORE_PORT]) begin
        store_response_q <= '{
            data: '0,
            tag: store_tag_i,
            except: store_except || !store_we_i,
            code: store_we_i ? store_code : E_ST_ACCESS_FAULT
        };
      end
    end
  end

  // Fetch pipeline. Instruction flush cancels the bundle without resetting unrelated beat metadata.
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_fetch_pipeline
    if (!rst_ni) begin
      fetch_pending_q           <= '0;
      fetch_busy_q              <= 1'b0;
      fetch_next_beat_q          <= '0;
      fetch_bundle_addr_q        <= '0;
      fetch_pc_misaligned_q      <= 1'b0;
      foreach (fetch_metadata_q[stage]) fetch_metadata_q[stage] <= '0;
      fetch_bundle_q            <= '0;
    end else begin
      if (instr_flush_i) begin
        // Override pending fetch validity; other beat metadata is intentionally retained.
        fetch_busy_q              <= 1'b0;
        fetch_pending_q           <= '0;
        fetch_bundle_q            <= '0;
      end else begin
        fetch_pending_q[0] <= fetch_beat_issue;
        for (int stage = 1; stage < READ_STAGES; stage++) begin
          fetch_pending_q[stage] <= fetch_pending_q[stage-1];
          if (fetch_pending_q[stage-1]) fetch_metadata_q[stage] <= fetch_metadata_q[stage-1];
        end
        if (result_valid_q[INSTR_PORT]) begin
          fetch_bundle_q <= fetch_result;
        end
        if (fetch_beat_issue) begin
          fetch_busy_q          <= int'(fetch_beat) != FETCH_BEATS - 1;
          fetch_next_beat_q     <= fetch_beat + 1'b1;
          fetch_bundle_addr_q   <= fetch_bundle_addr;
          fetch_pc_misaligned_q <= fetch_pc_misaligned;
          fetch_metadata_q[0].beat <= fetch_beat;
          fetch_metadata_q[0].upper_half <= fetch_read_addr[2];
          fetch_metadata_q[0].last <= int'(fetch_beat) == FETCH_BEATS - 1;
          fetch_metadata_q[0].except <= fetch_pc_misaligned ? '1 : fetch_lane_except;
          fetch_metadata_q[0].code <= fetch_pc_misaligned ? {2{E_I_ADDR_MISALIGNED}} : fetch_lane_code;
        end
      end
    end
  end

  // Response reservations and stall capture. A fetch reserves one slot for its entire bundle.
  memory_response_buffer #(
    .DATA_T(instr_response_t),
    .DEPTH(RESPONSE_DEPTH)
  ) u_instr_buffer (
    .clk_i,
    .rst_ni,
    .flush_i       (instr_flush_i),
    .allocate_i    (request_accepted[INSTR_PORT]),
    .credit_o      (response_credit[INSTR_PORT]),
    .result_valid_i(result_valid_q[INSTR_PORT] && fetch_last_beat_q),
    .result_i      (fetch_result),
    .valid_o       (response_o.instr_valid),
    .ready_i       (instr_ready_i),
    .data_o        (fetch_response),
    .outstanding_o (outstanding_o[INSTR_PORT]),
    .occupancy_o   (occupancy_o[INSTR_PORT])
  );
  memory_response_buffer #(
    .DATA_T(data_response_t),
    .DEPTH(RESPONSE_DEPTH)
  ) u_load_buffer (
    .clk_i,
    .rst_ni,
    .flush_i       (load_flush),
    .allocate_i    (request_accepted[LOAD_PORT]),
    .credit_o      (response_credit[LOAD_PORT]),
    .result_valid_i(result_valid_q[LOAD_PORT]),
    .result_i      (load_result),
    .valid_o       (response_o.load_valid),
    .ready_i       (load_ready_i),
    .data_o        (load_response),
    .outstanding_o (outstanding_o[LOAD_PORT]),
    .occupancy_o   (occupancy_o[LOAD_PORT])
  );
  memory_response_buffer #(
    .DATA_T(data_response_t),
    .DEPTH(RESPONSE_DEPTH)
  ) u_store_buffer (
    .clk_i,
    .rst_ni,
    .flush_i       (1'b0),
    .allocate_i    (request_accepted[STORE_PORT]),
    .credit_o      (response_credit[STORE_PORT]),
    .result_valid_i(result_valid_q[STORE_PORT]),
    .result_i      (store_response_q),
    .valid_o       (response_o.store_valid),
    .ready_i       (store_ready_i),
    .data_o        (store_response),
    .outstanding_o (outstanding_o[STORE_PORT]),
    .occupancy_o   (occupancy_o[STORE_PORT])
  );

  assign response_o.instr_data   = fetch_response.data;
  assign response_o.instr_except = fetch_response.except;
  assign response_o.instr_code   = fetch_response.code;
  assign response_o.load_data    = load_response.data;
  assign response_o.load_tag     = load_response.tag;
  assign response_o.load_except  = load_response.except;
  assign response_o.load_code    = load_response.code;
  assign response_o.store_tag    = store_response.tag;
  assign response_o.store_except = store_response.except;
  assign response_o.store_code   = store_response.code;

  // Configuration checks; unsupported modes must fail rather than alter the interface contract.
  initial begin : check_configuration
    if (LATENCY == 0) $fatal(1, "TC_SRAM adapter requires a positive read latency");
    if (RESPONSE_DEPTH < LATENCY + 1 || COUNT_WIDTH < $clog2(RESPONSE_DEPTH + 1))
      $fatal(1, "TC_SRAM response capacity must cover the read pipeline plus one slot");
    if (N == 0 || (N & (N - 1)) != 0 || N != len5_config_pkg::LEN5_MULTIPLE_ISSUES)
      $fatal(1, "TC_SRAM fetch width must match the power-of-two CPU bundle width");
    if (SIZE_BYTES < 8 || SIZE_BYTES % 8 != 0 || BASE_ADDR[2:0] != 0 ||
        BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(SIZE_BYTES-1)))
      $fatal(1, "Invalid TC_SRAM address window");
    if (SERIAL_ADDR[2:0] != 0 || EXIT_ADDR[2:0] != 0 || SERIAL_ADDR == EXIT_ADDR ||
        in_region(SERIAL_ADDR, 1, BASE_ADDR, 64'(SIZE_BYTES)) ||
        in_region(EXIT_ADDR, 1, BASE_ADDR, 64'(SIZE_BYTES)))
      $fatal(1, "Invalid or overlapping SRAM/MMIO regions");
    if ((SERIAL_ADDR & len5_config_pkg::MMAP_MASK) == 0 ||
        (EXIT_ADDR & len5_config_pkg::MMAP_MASK) == 0)
      $fatal(1, "MMIO addresses must be excluded by MMAP_MASK from store-to-load forwarding");
    if (len5_config_pkg::ONLY_DOUBLEWORD_MEM_ACCESSES || len5_config_pkg::LEN5_C_EN)
      $fatal(1, "TC_SRAM requires original load offsets and uncompressed instructions");
  end
endmodule
