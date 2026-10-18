// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_adapter #(
    parameter int unsigned N = len5_config_pkg::LEN5_MULTIPLE_ISSUES,
    parameter logic [63:0] BASE_ADDR = len5_config_pkg::SRAM_BASE_ADDR,
    parameter int unsigned SIZE_BYTES = len5_config_pkg::SRAM_SIZE_BYTES,
    parameter int unsigned LATENCY = len5_config_pkg::SRAM_LATENCY,
    parameter logic [63:0] SERIAL_ADDR = len5_config_pkg::SERIAL_ADDR,
    parameter logic [63:0] EXIT_ADDR = len5_config_pkg::EXIT_ADDR,
    parameter int unsigned ADDR_WIDTH = SIZE_BYTES / 8 > 1 ? $clog2(SIZE_BYTES / 8) : 1
) (
    input logic clk_i,
    rst_ni,
    instr_flush_i,
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
    output logic [2:0][1:0] outstanding_o,
    occupancy_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;
  localparam int unsigned BEATS = (N + 1) / 2;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned BEAT_W = BEATS > 1 ? $clog2(BEATS) : 1;
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
  data_response_t load_meta_q, store_meta_q, load_result, load_rsp, store_rsp;
  instr_response_t instr_accum_q, instr_result, instr_rsp;
  logic [2:0] accept, credit, result_valid;
  logic unused_load_mmio;
  logic [1:0] unused_instr_mmio;
  logic load_sram, store_sram, store_mmio, load_except, store_except;
  except_code_t load_code, store_code;
  logic [2:0] load_offset_q;
  logic [7:0] load_mask_q;
  logic busy_q, instr_issue, instr_last_q, instr_half_q, instr_misaligned;
  logic [BEAT_W-1:0] beat_q, beat, result_beat_q;
  logic [63:0] bundle_base_q, bundle_base, read_addr;
  logic bundle_bad_q;
  logic [1:0] instr_sram, instr_except, instr_except_q;
  except_code_t [1:0] instr_code, instr_code_q;
  logic [1:0][63:0] lane_addr;

  wire unused_read_ports = &{1'b0, sram_rdata_i[2], store_rsp.data, instr_sram[1]};

  initial begin
    if (LATENCY != 1) $fatal(1, "TC_SRAM adapter supports SRAM_LATENCY=1 only");
    if (N == 0 || (N & (N - 1)) != 0 || N != len5_config_pkg::LEN5_MULTIPLE_ISSUES)
      $fatal(1, "TC_SRAM fetch width must match the power-of-two CPU bundle width");
    if (SIZE_BYTES < 8 || SIZE_BYTES % 8 != 0 || BASE_ADDR[2:0] != 0 ||
        BASE_ADDR > (64'hffff_ffff_ffff_ffff - 64'(SIZE_BYTES-1)))
      $fatal(1, "Invalid TC_SRAM address window");
    if (SERIAL_ADDR[2:0] != 0 || EXIT_ADDR[2:0] != 0 || SERIAL_ADDR == EXIT_ADDR || in_region(
            SERIAL_ADDR, 1, BASE_ADDR, 64'(SIZE_BYTES)
        ) || in_region(
            EXIT_ADDR, 1, BASE_ADDR, 64'(SIZE_BYTES)
        ))
      $fatal(1, "Invalid or overlapping SRAM/MMIO regions");
    if ((SERIAL_ADDR & len5_config_pkg::MMAP_MASK) == 0 ||
        (EXIT_ADDR & len5_config_pkg::MMAP_MASK) == 0)
      $fatal(1, "MMIO addresses must be excluded by MMAP_MASK from store-to-load forwarding");
    if (len5_config_pkg::ONLY_DOUBLEWORD_MEM_ACCESSES || len5_config_pkg::LEN5_C_EN)
      $fatal(1, "TC_SRAM requires original load offsets and uncompressed instructions");
  end

  memory_access_check #(
      .BASE_ADDR(BASE_ADDR),
      .SIZE_BYTES(SIZE_BYTES),
      .SERIAL_ADDR(SERIAL_ADDR),
      .EXIT_ADDR(EXIT_ADDR),
      .KIND(1)
  ) u_load_decode (
      .addr_i  (load_addr_i),
      .bytes_i (access_bytes(load_be_i)),
      .sram_o  (load_sram),
      .mmio_o  (unused_load_mmio),
      .except_o(load_except),
      .code_o  (load_code)
  );
  memory_access_check #(
      .BASE_ADDR(BASE_ADDR),
      .SIZE_BYTES(SIZE_BYTES),
      .SERIAL_ADDR(SERIAL_ADDR),
      .EXIT_ADDR(EXIT_ADDR),
      .KIND(2)
  ) u_store_decode (
      .addr_i  (store_addr_i),
      .bytes_i (access_bytes(store_be_i)),
      .sram_o  (store_sram),
      .mmio_o  (store_mmio),
      .except_o(store_except),
      .code_o  (store_code)
  );

  assign response_o.load_gnt = initialized_i && credit[1];
  assign response_o.store_gnt = initialized_i && credit[2];
  assign response_o.instr_gnt = initialized_i && credit[0] && !busy_q;
  assign accept = {
    store_req_i && response_o.store_gnt,
    load_req_i && response_o.load_gnt,
    instr_req_i && response_o.instr_gnt
  };
  assign mmio_write_o = accept[2] && store_we_i && store_mmio;

  // One native fetch read per cycle; N>2 requires consecutive beats per bundle.
  assign instr_issue = initialized_i && rst_ni && !instr_flush_i && (busy_q || accept[0]);
  assign beat = busy_q ? beat_q : '0;
  assign bundle_base = busy_q ? bundle_base_q : (N == 1 ? instr_addr_i : instr_addr_i & ~64'(N*4-1));
  assign instr_misaligned = busy_q ? bundle_bad_q : (instr_addr_i[1:0] != 0);
  assign read_addr = bundle_base + 64'(beat) * 8;
  for (genvar j = 0; j < 2; j++) begin : gen_instr_decode
    assign lane_addr[j] = read_addr + 64'(j * 4);
    memory_access_check #(
        .BASE_ADDR(BASE_ADDR),
        .SIZE_BYTES(SIZE_BYTES),
        .KIND(0)
    ) u_decode (
        .addr_i  (lane_addr[j]),
        .bytes_i (4),
        .sram_o  (instr_sram[j]),
        .mmio_o  (unused_instr_mmio[j]),
        .except_o(instr_except[j]),
        .code_o  (instr_code[j])
    );
  end

  always_comb begin
    sram_req_o = '0;
    sram_we_o = 3'b100;
    sram_addr_o[0] = ADDR_WIDTH'((read_addr - BASE_ADDR) >> 3);
    sram_addr_o[1] = ADDR_WIDTH'((load_addr_i - BASE_ADDR) >> 3);
    sram_addr_o[2] = ADDR_WIDTH'((store_addr_i - BASE_ADDR) >> 3);
    sram_wdata_o = '0;
    sram_wdata_o[2] = store_data_i << (8 * store_addr_i[2:0]);
    sram_be_o = '0;
    sram_be_o[2] = store_be_i << store_addr_i[2:0];
    sram_req_o[0] = instr_issue && !instr_misaligned && instr_sram[0];
    sram_req_o[1] = accept[1] && load_sram;
    sram_req_o[2] = accept[2] && store_sram && store_we_i;
    load_result = load_meta_q;
    load_result.data = '0;
    for (int b = 0; b < 8; b++) begin
      if (load_mask_q[b] && !load_meta_q.except)
        load_result.data[b*8+:8] = 8'(sram_rdata_i[1] >> (8 * (int'(load_offset_q) + b)));
    end
    instr_result = instr_accum_q;
    for (int j = 0; j < 2; j++) begin
      if (int'(result_beat_q) * 2 + j < N) begin
        instr_result.data[int'(result_beat_q)*2+j] = instr_except_q[j] ? '0 :
          32'(sram_rdata_i[0] >> (32*(N == 1 ? int'(instr_half_q) : j)));
        instr_result.except[int'(result_beat_q)*2+j] = instr_except_q[j];
        instr_result.code[int'(result_beat_q)*2+j] = instr_code_q[j];
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      result_valid <= '0;
      busy_q <= 0;
      beat_q <= '0;
      bundle_base_q <= '0;
      bundle_bad_q <= 0;
      instr_last_q <= 0;
      instr_half_q <= 0;
      result_beat_q <= '0;
      instr_except_q <= '0;
      instr_code_q <= '0;
      instr_accum_q <= '0;
      load_meta_q <= '0;
      store_meta_q <= '0;
      load_offset_q <= '0;
      load_mask_q <= '0;
    end else begin
      result_valid[2:1] <= accept[2:1];
      if (accept[1]) begin
        load_meta_q   <= '{data: '0, tag: load_tag_i, except: load_except, code: load_code};
        load_offset_q <= load_addr_i[2:0];
        load_mask_q   <= load_be_i;
      end
      if (accept[2])
        store_meta_q <= '{
            data: '0,
            tag: store_tag_i,
            except: store_except || !store_we_i,
            code: store_we_i ? store_code : E_ST_ACCESS_FAULT
        };
      result_valid[0] <= instr_issue;
      if (instr_flush_i) begin
        busy_q <= 0;
        result_valid[0] <= 0;
        instr_accum_q <= '0;
      end else begin
        if (result_valid[0]) instr_accum_q <= instr_result;
        if (instr_issue) begin
          busy_q <= int'(beat) != BEATS - 1;
          beat_q <= beat + 1'b1;
          bundle_base_q <= bundle_base;
          bundle_bad_q <= instr_misaligned;
          result_beat_q <= beat;
          instr_half_q <= read_addr[2];
          instr_last_q <= int'(beat) == BEATS - 1;
          instr_except_q <= instr_misaligned ? '1 : instr_except;
          instr_code_q <= instr_misaligned ? {2{E_I_ADDR_MISALIGNED}} : instr_code;
        end
      end
    end
  end

  memory_response_buffer #(
      .DATA_T(instr_response_t)
  ) u_instr_buffer (
      .clk_i,
      .rst_ni,
      .flush_i(instr_flush_i),
      .allocate_i(accept[0]),
      .credit_o(credit[0]),
      .result_valid_i(result_valid[0] && instr_last_q),
      .result_i(instr_result),
      .valid_o(response_o.instr_valid),
      .ready_i(instr_ready_i),
      .data_o(instr_rsp),
      .outstanding_o(outstanding_o[0]),
      .occupancy_o(occupancy_o[0])
  );
  memory_response_buffer #(
      .DATA_T(data_response_t)
  ) u_load_buffer (
      .clk_i,
      .rst_ni,
      .flush_i(1'b0),
      .allocate_i(accept[1]),
      .credit_o(credit[1]),
      .result_valid_i(result_valid[1]),
      .result_i(load_result),
      .valid_o(response_o.load_valid),
      .ready_i(load_ready_i),
      .data_o(load_rsp),
      .outstanding_o(outstanding_o[1]),
      .occupancy_o(occupancy_o[1])
  );
  memory_response_buffer #(
      .DATA_T(data_response_t)
  ) u_store_buffer (
      .clk_i,
      .rst_ni,
      .flush_i(1'b0),
      .allocate_i(accept[2]),
      .credit_o(credit[2]),
      .result_valid_i(result_valid[2]),
      .result_i(store_meta_q),
      .valid_o(response_o.store_valid),
      .ready_i(store_ready_i),
      .data_o(store_rsp),
      .outstanding_o(outstanding_o[2]),
      .occupancy_o(occupancy_o[2])
  );
  assign response_o.instr_data = instr_rsp.data;
  assign response_o.instr_except = instr_rsp.except;
  assign response_o.instr_code = instr_rsp.code;
  assign response_o.load_data = load_rsp.data;
  assign response_o.load_tag = load_rsp.tag;
  assign response_o.load_except = load_rsp.except;
  assign response_o.load_code = load_rsp.code;
  assign response_o.store_tag = store_rsp.tag;
  assign response_o.store_except = store_rsp.except;
  assign response_o.store_code = store_rsp.code;
endmodule
