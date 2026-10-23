// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_adapter_tb;
  import len5_pkg::*;
  import len5_config_pkg::*;
  import tb_config_pkg::*;
  import memory_backend_pkg::*;
  localparam int N = LEN5_MULTIPLE_ISSUES;
  localparam int Capacity = SRAM_RESPONSE_DEPTH;
  localparam int FetchDepth = FETCH_MEMIF_FIFO_DEPTH;
  localparam int FrontendCapacity = FetchDepth + (FETCH_ANS_SPILL_SKIP ? 0 : 2);
  localparam int Size = 256;
  localparam int IWidth = N > 2 ? 32 * N : 64;
  localparam int IBytes = IWidth / 8;
  localparam int IAddrWidth = $clog2(Size / IBytes);
  localparam int DAddrWidth = $clog2(Size / 8);
  localparam logic [63:0] IBase = IMEM_BASE_ADDR;
  localparam logic [63:0] DBase = DMEM_BASE_ADDR;
  localparam logic [63:0] Serial = SERIAL_ADDR, Exit = EXIT_ADDR;
  bit clk = 0, rst = 0, flush = 0;
  bit [2:0] req = 0, ready = 0;
  bit store_we = 1;
  logic [2:0][63:0] addr, wdata;
  logic [           2:0][             7:0] be;
  logic [           2:0][BUFF_IDX_LEN-1:0] tag;
  logic                                    imem_req;
  logic [IAddrWidth-1:0]                   imem_addr;
  logic [    IWidth-1:0]                   imem_data;
  logic [1:0] dmem_req, dmem_we;
  logic [1:0][DAddrWidth-1:0] dmem_addr;
  logic [1:0][63:0] dmem_wdata, dmem_data;
  logic [1:0][7:0] dmem_be;
  logic [2:0][SRAM_COUNT_WIDTH-1:0] outstanding, occupancy;
  logic imem_initialized, dmem_initialized, initialized, mmio;
  memory_response_t rsp;
  typedef struct packed {
    logic [N-1:0][31:0] data;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } fetch_response_t;
  fetch_response_t instr_response;
  logic instr_request, instr_credit, instr_result_ready, instr_response_valid;
  logic [63:0] instr_response_addr;
  assign initialized   = imem_initialized && dmem_initialized;

  fetch_pkg::prediction_t [N-1:0] fetch_prediction, returned_prediction;
  instr_t [N-1:0] returned_instruction;
  logic [63:0] instr_address;
  for (genvar lane = 0; lane < N; lane++) begin : gen_fetch_lanes
    assign fetch_prediction[lane] = '{pc: addr[0] + 64'(4 * lane), hit: 1'b0, target: '0, taken: 1'b0};
    assign instr_response.data[lane] = returned_instruction[lane].raw;
  end
  assign instr_response_addr = returned_prediction[0].pc;
  fetch_mem_if #(
    .MAX_MEM_OUTSTANDING_REQUESTS(FetchDepth),
    .DRAIN_ON_FLUSH(1'b1)
  ) u_frontend_responses (
    .clk_i(clk), .rst_ni(rst), .flush_i(flush),
    .fetch_valid_i(req[0]), .fetch_ready_o(instr_credit), .fetch_pred_i(fetch_prediction),
    .valid_instr_i('1), .valid_instr_o(),
    .issue_valid_o(instr_response_valid), .issue_ready_i(ready[0]),
    .issue_instr_o(returned_instruction), .issue_pred_o(returned_prediction),
    .issue_except_raised_o(instr_response.except), .issue_except_code_o(instr_response.code),
    .instr_valid_i(rsp.instr_valid), .instr_ready_i(rsp.instr_gnt),
    .instr_ready_o(instr_result_ready), .instr_valid_o(instr_request), .instr_we_o(),
    .instr_rdata_i(rsp.instr_data), .instr_addr_o(instr_address),
    .instr_except_raised_i(rsp.instr_except), .instr_except_code_i(rsp.instr_code)
  );
  tc_sram_adapter #(
    .IMEM_SIZE_BYTES(Size),
    .DMEM_SIZE_BYTES(Size)
  ) dut (
    .clk_i        (clk),
    .rst_ni       (rst),
    .initialized_i(initialized),
    .instr_req_i  (instr_request),
    .instr_ready_i(instr_result_ready),
    .instr_addr_i (instr_address),
    .load_req_i   (req[1]),
    .load_ready_i (ready[1]),
    .load_addr_i  (addr[1]),
    .load_be_i    (be[1]),
    .load_tag_i   (tag[1]),
    .store_req_i  (req[2]),
    .store_ready_i(ready[2]),
    .store_we_i   (store_we),
    .store_addr_i (addr[2]),
    .store_data_i (wdata[2]),
    .store_be_i   (be[2]),
    .store_tag_i  (tag[2]),
    .response_o   (rsp),
    .imem_req_o   (imem_req),
    .imem_addr_o  (imem_addr),
    .imem_rdata_i (imem_data),
    .dmem_req_o   (dmem_req),
    .dmem_we_o    (dmem_we),
    .dmem_addr_o  (dmem_addr),
    .dmem_wdata_o (dmem_wdata),
    .dmem_be_o    (dmem_be),
    .dmem_rdata_i (dmem_data),
    .mmio_write_o (mmio),
    .outstanding_o(outstanding),
    .occupancy_o  (occupancy)
  );
  tc_sram_storage #(
    .BASE_ADDR       (IBase),
    .SIZE_BYTES      (Size),
    .LATENCY         (IMEM_LATENCY),
    .DATA_WIDTH      (IWidth),
    .NUM_PORTS       (1),
    .OTHER_BASE_ADDR (DBase),
    .OTHER_SIZE_BYTES(Size),
    .SIM_INIT        ("zeros")
  ) imem (
    .clk_i        (clk),
    .req_i        (imem_req),
    .we_i         (1'b0),
    .addr_i       (imem_addr),
    .wdata_i      ('0),
    .be_i         ('0),
    .rdata_o      (imem_data),
    .initialized_o(imem_initialized)
  );
  tc_sram_storage #(
    .BASE_ADDR       (DBase),
    .SIZE_BYTES      (Size),
    .LATENCY         (DMEM_LATENCY),
    .DATA_WIDTH      (64),
    .NUM_PORTS       (2),
    .OTHER_BASE_ADDR (IBase),
    .OTHER_SIZE_BYTES(Size),
    .SIM_INIT        ("zeros")
  ) dmem (
    .clk_i        (clk),
    .req_i        (dmem_req),
    .we_i         (dmem_we),
    .addr_i       (dmem_addr),
    .wdata_i      (dmem_wdata),
    .be_i         (dmem_be),
    .rdata_o      (dmem_data),
    .initialized_o(dmem_initialized)
  );

  byte unsigned reference_mem[Size];
  typedef struct packed {
    logic [63:0] data;
    logic [BUFF_IDX_LEN-1:0] tag;
    except_code_t code;
    int issued;
    int due;
  } expected_t;
  typedef struct packed {
    logic live;
    logic [63:0] address;
    logic [N-1:0][31:0] data;
    except_code_t [N-1:0] code;
    int issued;
    int due;
  } fetch_expected_t;
  expected_t loads[$], stores[$];
  fetch_expected_t fetches[$], fetch_returns[$];
  int cycle_no = 0, seed = 1, cycles = 10000;
  int unsigned rng;
  int accepted[3], completed[3], errors[3], native_count[3], blocked[3], stalled[3];
  int max_out[3], max_occ[3], sum_out[3], sum_occ[3], latency_sum[3];
  int all_three = 0, collision = 0, flush_count = 0, mmio_count = 0;
  int max_fetch_reserved = 0, fetch_return_count = 0, stale_returns = 0;
  int load_reset_canceled = 0, load_flush_pending = 0, load_flush_buffered = 0;
  int load_flush_repeated = 0, load_flush_simultaneous = 0;
  bit previous_flush = 0;

  function automatic int unsigned random32();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int size_of(logic [7:0] mask);
    case (mask)
      1:       return 1;
      3:       return 2;
      15:      return 4;
      255:     return 8;
      default: return 0;
    endcase
  endfunction
  // Independent byte-address oracle; do not reuse the DUT's decoder or range helpers.
  function automatic except_code_t fault(logic [63:0] a, int size, int port_id);
    logic [63:0] base_addr;
    base_addr = port_id == 0 ? IBase : DBase;
    if (size != 0 && a % 64'(size) != 0)
      return port_id == 0 ? E_I_ADDR_MISALIGNED : port_id == 1 ? E_LD_ADDR_MISALIGNED : E_ST_ADDR_MISALIGNED;
    if (port_id == 2 && size != 0 && (a == Serial || a == Exit)) return E_UNKNOWN;
    if (size == 0 || a < base_addr || a - base_addr > 64'(Size - size))
      return port_id == 0 ? E_I_ACCESS_FAULT : port_id == 1 ? E_LD_ACCESS_FAULT : E_ST_ACCESS_FAULT;
    return E_UNKNOWN;
  endfunction
  function automatic logic [63:0] read_bytes(logic [63:0] a, int size);
    logic [63:0] value = 0;
    for (int b = 0; b < size; b++) value[b*8+:8] = reference_mem[int'(a-DBase)+b];
    return value;
  endfunction
  function automatic logic [31:0] instruction_word(logic [63:0] a);
    logic [31:0] value;
    for (int b = 0; b < 4; b++) begin
      int index_byte;
      index_byte    = int'(a - IBase) + b;
      value[b*8+:8] = 8'((index_byte * 37) ^ ((index_byte / 4) * 13) ^ 'h5a);
    end
    return value;
  endfunction
  function automatic logic [63:0] random_address(int size, int port_id);
    logic [63:0] a, base_addr;
    base_addr = port_id == 0 ? IBase : DBase;
    case (random32() % 14)
      0:       a = base_addr - 8;
      1:       a = base_addr + 64'(Size);
      2:       a = base_addr + 64'(Size) - 1;
      3:       a = 64'hffff_ffff_ffff_fff8;
      4:       a = Serial;
      5:       a = Exit;
      6:       a = Serial + 8;
      7:       a = port_id == 0 ? DBase : IBase;
      default: a = base_addr + 64'(random32() % Size);
    endcase
    if ((random32() % 4) != 0 && size != 0) a &= ~(64'(size) - 1);
    return a;
  endfunction

  task automatic tick;
    expected_t       e;
    fetch_expected_t f;
    bit [2:0] grant, valid, accepted_now, native_req;
    bit          expected_native;
    logic [63:0] fetch_base;
    int          size;
    #5;
    grant        = {rsp.store_gnt, rsp.load_gnt, instr_credit};
    valid        = {rsp.store_valid, rsp.load_valid, instr_response_valid && !flush};
    native_req   = {dmem_req, imem_req};
    accepted_now = req & grant;
    if (flush) foreach (fetch_returns[i]) fetch_returns[i].live = 0;
    if (!rst) begin
      load_reset_canceled += loads.size();
      loads.delete();
      stores.delete();
      fetches.delete();
      fetch_returns.delete();
      assert (native_req == 0 && valid == 0 && grant == 0)
      else $fatal(1, "Activity during reset");
      assert (outstanding == '0 && occupancy == '0)
      else $fatal(1, "Reset retained memory transaction state");
      previous_flush = 0;
    end else begin
      assert (int'(outstanding[1]) == loads.size())
      else $fatal(1, "Load reservation mismatch cycle %0d: got %0d expected %0d", cycle_no,
                  outstanding[1], loads.size());
      if (flush) begin
        fetches.delete();
        flush_count++;
        assert (!valid[0] && !grant[0])
        else $fatal(1, "Fetch activity during flush");
        // Instruction flush cancels frontend work; accepted DMEM reads stay owned.
        if (loads.size() != 0) begin
          if (cycle_no < loads[loads.size()-1].due) load_flush_pending++;
          if (previous_flush) load_flush_repeated++;
        end
        if (occupancy[1] != 0 && !ready[1]) load_flush_buffered++;
        if (accepted_now[1] && valid[1] && ready[1]) load_flush_simultaneous++;
      end
      previous_flush = flush;
      if (!flush) begin
        assert (rsp.instr_gnt == initialized && occupancy[0] == 0)
        else $fatal(1, "IMEM added request throttling or response storage");
        assert (int'(outstanding[0]) == fetch_returns.size())
        else $fatal(1, "IMEM outstanding count mismatch");
      end
      // Queue accepted requests before checking responses, including true latency-zero returns.
      if (accepted_now[0]) begin
        fetch_base = N == 1 ? addr[0] : addr[0] / (N * 4) * (N * 4);
        f          = '0;
        f.live     = 1;
        f.address  = addr[0];
        f.issued   = cycle_no;
        f.due      = cycle_no + int'(IMEM_LATENCY);
        for (int lane = 0; lane < N; lane++) begin
          f.code[lane] = addr[0] % 4 != 0 ? E_I_ADDR_MISALIGNED :
              fault(fetch_base + 64'(4 * lane), 4, 0);
          f.data[lane] = f.code[lane] == E_UNKNOWN ? instruction_word(fetch_base + 64'(4 * lane)) :
              0;
          if (f.code[lane] != E_UNKNOWN) errors[0]++;
        end
        fetches.push_back(f);
        fetch_returns.push_back(f);
        expected_native = addr[0] % 4 == 0 && fault(fetch_base, 4, 0) == E_UNKNOWN;
        assert (imem_req == expected_native)
        else $fatal(1, "Fetch SRAM request mismatch");
        if (expected_native) assert (imem_addr == IAddrWidth'((fetch_base - IBase) / IBytes));
      end else assert (!imem_req);
      for (int p = 1; p < 3; p++) begin
        size = size_of(be[p]);
        e = '{
            data: 0,
            tag: tag[p],
            code: fault(addr[p], size, p),
            issued: cycle_no,
            due: cycle_no + (p == 1 ? int'(DMEM_LATENCY) : 1)
        };
        if (p == 2 && !store_we) e.code = E_ST_ACCESS_FAULT;
        expected_native = accepted_now[p] && e.code == E_UNKNOWN && addr[p] != Serial && addr[p] != Exit;
        assert (dmem_req[p-1] == expected_native)
        else $fatal(1, "Native request mismatch port %0d", p);
        if (expected_native) assert (dmem_addr[p-1] == DAddrWidth'((addr[p] - DBase) / 8));
        if (p == 1 && expected_native) e.data = read_bytes(addr[p], size);
        if (accepted_now[p]) begin
          if (e.code != E_UNKNOWN) errors[p]++;
          if (p == 1) loads.push_back(e);
          else stores.push_back(e);
        end
        if (p == 2) begin
          assert (mmio == (accepted_now[2] && store_we && e.code == E_UNKNOWN && (addr[p] == Serial || addr[p] == Exit)));
          if (mmio) mmio_count++;
          if (expected_native) begin
            assert (dmem_we == 2'b10 && dmem_be[1] == (be[p] << (addr[p]%8)) &&
                    dmem_wdata[1] == (wdata[p] << (8*(addr[p]%8))))
            else $fatal(1, "Store lanes mismatch");
          end
        end
      end
      if (loads.size() != 0 && cycle_no >= loads[0].due) assert (valid[1]);
      if (stores.size() != 0 && cycle_no >= stores[0].due) assert (valid[2]);
      if (fetches.size() != 0 && cycle_no >= fetches[0].due + int'(FETCH_ANS_SPILL_SKIP == 0)) assert (valid[0]);
      // Every visible payload must remain the oldest expected response even while stalled.
      if (valid[0]) begin
        assert (fetches.size() != 0)
        else $fatal(1, "Unsolicited fetch");
        f = fetches[0];
        assert (cycle_no >= f.due && instr_response_addr == f.address &&
                instr_response.data === f.data && instr_response.code == f.code)
        else
          $fatal(
              1,
              "Fetch mismatch cycle %0d data %h/%h code %h/%h",
              cycle_no,
              instr_response.data,
              f.data,
              instr_response.code,
              f.code
          );
        for (int lane = 0; lane < N; lane++)
        assert (instr_response.except[lane] == (f.code[lane] != E_UNKNOWN));
        if (ready[0]) begin
          f = fetches.pop_front();
          latency_sum[0] += cycle_no - f.issued;
        end
      end
      if (valid[1]) begin
        assert (loads.size() != 0)
        else $fatal(1, "Unsolicited load");
        e = loads[0];
        assert (cycle_no >= e.due && rsp.load_tag == e.tag && rsp.load_code == e.code &&
                rsp.load_except == (e.code != E_UNKNOWN) && rsp.load_data === e.data)
        else
          $fatal(
              1,
              "Load mismatch cycle %0d tag %h/%h data %h/%h code %h/%h",
              cycle_no,
              rsp.load_tag,
              e.tag,
              rsp.load_data,
              e.data,
              rsp.load_code,
              e.code
          );
        if (ready[1]) begin
          e = loads.pop_front();
          latency_sum[1] += cycle_no - e.issued;
        end
      end
      if (valid[2]) begin
        assert (stores.size() != 0)
        else $fatal(1, "Unsolicited store");
        e = stores[0];
        assert (cycle_no >= e.due && rsp.store_tag == e.tag && rsp.store_code == e.code &&
                rsp.store_except == (e.code != E_UNKNOWN))
        else $fatal(1, "Store mismatch");
        if (ready[2]) begin
          e = stores.pop_front();
          latency_sum[2] += cycle_no - e.issued;
        end
      end
      // Sample loads before applying writes: native DMEM collisions are read-before-write.
      if (dmem_req[1]) begin
        size = size_of(be[2]);
        for (int b = 0; b < size; b++) reference_mem[int'(addr[2]-DBase)+b] = wdata[2][8*b+:8];
      end
      for (int p = 0; p < 3; p++) begin
        accepted[p] += int'(accepted_now[p]);
        completed[p] += int'(valid[p] && ready[p]);
        blocked[p] += int'(req[p] && !grant[p]);
        stalled[p] += int'(valid[p] && !ready[p]);
        native_count[p] += int'(native_req[p]);
        sum_out[p] += int'(outstanding[p]);
        sum_occ[p] += int'(occupancy[p]);
        if (int'(outstanding[p]) > max_out[p]) max_out[p] = int'(outstanding[p]);
        if (int'(occupancy[p]) > max_occ[p]) max_occ[p] = int'(occupancy[p]);
      end
      if (&native_req) all_three++;
      if (&dmem_req && dmem_addr[0] == dmem_addr[1]) collision++;
      if (fetches.size() > max_fetch_reserved) max_fetch_reserved = fetches.size();
    end
    assert (accepted[1] == completed[1] + load_reset_canceled + loads.size())
    else $fatal(1, "Load conservation failed: accepted=%0d completed=%0d reset=%0d pending=%0d",
                accepted[1], completed[1], load_reset_canceled, loads.size());
    // Check native completion separately from frontend delivery: a FIFO must not
    // hide a late, reordered, or corrupt adapter response.
    if (fetch_returns.size() != 0) begin
      assert (rsp.instr_valid == (cycle_no == fetch_returns[0].due))
      else $fatal(1, "IMEM response did not match configured latency");
    end else assert (!rsp.instr_valid);
    if (rsp.instr_valid) begin
      f = fetch_returns.pop_front();
      assert (instr_result_ready && rsp.instr_data === f.data && rsp.instr_code == f.code)
      else $fatal(1, "Pipelined IMEM response mismatch");
      for (int lane = 0; lane < N; lane++)
      assert (rsp.instr_except[lane] == (f.code[lane] != E_UNKNOWN));
      fetch_return_count++;
      if (!f.live) stale_returns++;
    end
    clk = 1;
    #5;
    clk = 0;
    cycle_no++;
  endtask
  task automatic drain;
    req   = 0;
    ready = 7;
    flush = 0;
    repeat (IMEM_LATENCY + DMEM_LATENCY + Capacity + FetchDepth + 5) tick();
    assert (loads.size() == 0 && stores.size() == 0 && fetches.size() == 0 && fetch_returns.size() == 0)
    else $fatal(1, "Drain failed");
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    rng = 32'(seed);
    if (rng == 0) rng = 1;
    addr  = '0;
    be    = '0;
    tag   = '0;
    wdata = '0;
    foreach (reference_mem[i]) reference_mem[i] = 0;
    repeat (3) tick();
    rst   = 1;
    ready = 7;
    // Let the spill controllers leave RESET before checking normal response timing.
    tick();
    for (int size = 1; size <= 8; size *= 2) begin
      for (int off = 0; off < 8; off += size) begin
        addr[0]  = IBase + (64'(off) & ~64'd3);
        addr[1]  = DBase + 64'(off);
        addr[2]  = addr[1];
        be[1]    = 8'((1 << size) - 1);
        be[2]    = be[1];
        req      = 7;
        wdata[2] = 64'h8877_6655_4433_2211;
        tick();
        wdata[2] = ~wdata[2];
        tick();
        drain();
      end
    end
    for (int size = 2; size <= 8; size *= 2) begin
      for (int off = 1; off < size; off++) begin
        req     = 7;
        addr[0] = IBase + 2;
        addr[1] = DBase + 64'(off);
        addr[2] = addr[1];
        be[1]   = 8'((1 << size) - 1);
        be[2]   = be[1];
        tag[1]  = '1;
        tag[2]  = '1;
        tick();
        drain();
      end
    end
    // Last valid instruction, all bundle offsets, wrong memory, and instruction/data bounds.
    for (int off = 0; off <= IBytes; off += 4) begin
      req     = 7;
      addr[0] = IBase + 64'(Size) - 64'(IBytes) + 64'(off);
      addr[1] = IBase;
      addr[2] = IBase;
      be[1]   = 255;
      be[2]   = 255;
      tick();
      drain();
    end
    store_we = 0;
    req      = 4;
    addr[2]  = DBase;
    tick();
    drain();
    store_we = 1;
    begin
      int start_load, start_store, start_fetch;
      drain();
      start_load  = accepted[1];
      start_store = accepted[2];
      start_fetch = native_count[0];
      req         = 7;
      ready       = 7;
      addr[0]     = IBase;
      addr[1]     = DBase + 8;
      addr[2]     = DBase + 16;
      be[1]       = 255;
      be[2]       = 255;
      for (int i = 0; i < 32; i++) begin
        addr[0] = IBase + 64'((i * 4) % Size);
        tick();
      end
      assert (accepted[1] - start_load == 32 && accepted[2] - start_store == 32)
      else $fatal(1, "Unexpected throughput");
      if (FetchDepth > IMEM_LATENCY) begin
        assert (native_count[0] - start_fetch == 32)
        else $fatal(1, "IMEM failed to accept one bundle per cycle with frontend credit");
      end
      drain();
    end
    // Fill all frontend reservations with consecutive reads even when latency exceeds depth.
    begin
      int start_fetch;
      start_fetch = accepted[0];
      req         = 1;
      ready[0]    = 0;
      for (int i = 0; i < FetchDepth; i++) begin
        addr[0] = IBase + 64'((i * 4) % Size);
        tick();
        assert (accepted[0] - start_fetch == i + 1)
        else $fatal(1, "IMEM serialized outstanding requests");
      end
      repeat (2 * IMEM_LATENCY + FetchDepth + 4) tick();
      assert (accepted[0] - start_fetch == FrontendCapacity && fetch_returns.size() == 0 &&
              fetches.size() == FrontendCapacity)
      else
        $fatal(1, "Full frontend FIFO did not backpressure requests while receiving all results");
      drain();
    end
    // Fill data buffers and frontend reservations, then resume simultaneous traffic.
    ready   = 0;
    req     = 7;
    addr[0] = IBase;
    addr[1] = DBase;
    addr[2] = DBase + 8;
    be[1]   = 255;
    be[2]   = 255;
    repeat (IMEM_LATENCY + DMEM_LATENCY + Capacity + FetchDepth + 4) tick();
    ready   = 7;
    addr[0] = IBase + 64'(IBytes);
    repeat (4) tick();
    drain();
    // Flush in-flight reads and completed frontend entries; new requests must not inherit old results.
    for (int phase = 0; phase < 2; phase++) begin
      req      = 1;
      ready[0] = 0;
      addr[0]  = IBase;
      tick();
      tick();
      if (phase == 1) repeat (IMEM_LATENCY + 1) tick();
      flush = 1;
      tick();
      flush    = 0;
      ready[0] = 1;
      addr[0]  = IBase + 64'(IBytes);
      tick();
      drain();
    end
    // Cross-channel flush independence: no adapter load-flush input or synthetic CPU is used.
    begin
      int start_load, start_completed;
      start_load = accepted[1];
      start_completed = completed[1];
      req = 3;
      ready = 0;
      addr[0] = IBase;
      addr[1] = DBase;
      be[1] = 255;
      tag[1] = 0;
      tick();
      req = 0;
      flush = 1;
      repeat (DMEM_LATENCY + 2) tick();
      assert (loads.size() == 1 && completed[1] == start_completed && occupancy[1] == 1)
      else $fatal(1, "Instruction flush lost the pending/backpressured load");
      req = 2;
      addr[1] = DBase + 64'(Size);
      tag[1] = '1;
      tick();
      req = 0;
      repeat (DMEM_LATENCY + 2) tick();
      assert (loads.size() == 2 && occupancy[1] == 2)
      else $fatal(1, "Repeated instruction flush lost native/faulted load responses");
      drain();
      assert (accepted[1] - start_load == 2 && completed[1] - start_completed == 2)
      else $fatal(1, "Loads did not complete exactly once across instruction flush");

      // Continuous traffic guarantees a same-edge load request/response/flush at every latency.
      req = 2;
      ready = 7;
      flush = 1;
      for (int beat = 0; beat < DMEM_LATENCY + 4; beat++) begin
        addr[1] = beat % 3 == 2 ? DBase + 64'(Size) : DBase + (64'(beat) % 64'd4) * 64'd8;
        tag[1] = BUFF_IDX_LEN'(beat);
        tick();
      end
      drain();

      // Reset alone can cancel a held response and a newly accepted read.
      req = 2;
      ready[1] = 0;
      addr[1] = DBase;
      tick();
      req = 0;
      repeat (DMEM_LATENCY + 1) tick();
      req = 2;
      addr[1] = DBase + 64'(Size);
      tick();
      req = 0;
      assert (loads.size() == 2) else $fatal(1, "Reset fixture lacks accepted load obligations");
      rst = 0;
      repeat (2) tick();
      rst = 1;
      tick();
      drain();
    end
    for (int i = 0; i < cycles; i++) begin
      flush = random32() % 40 == 0;
      for (int p = 0; p < 3; p++) begin
        req[p]   = random32() % 10 != 0;
        ready[p] = random32() % 4 != 0;
        be[p]    = 8'((1 << (1 << (random32() % 4))) - 1);
        if (random32() % 30 == 0) be[p] = 8'h05;
        addr[p]  = random_address(p == 0 ? 4 : size_of(be[p]), p);
        tag[p]   = BUFF_IDX_LEN'(random32());
        wdata[p] = {random32(), random32()};
      end
      store_we = random32() % 31 != 0;
      if (i % 25 == 0) begin
        addr[0] = IBase;
        addr[1] = DBase;
        addr[2] = DBase;
        be[1]   = 255;
        be[2]   = 255;
        req     = 7;
      end
      tick();
      if (i == cycles / 2) begin
        rst = 0;
        repeat (2) tick();
        rst = 1;
        req = 0;
        tick();
      end
    end
    drain();
    for (int a = 0; a < Size; a += 8) begin
      req     = 2;
      addr[1] = DBase + 64'(a);
      be[1]   = 255;
      tick();
    end
    drain();
    assert (all_three > 0 && collision > 0 && mmio_count > 0 && flush_count > 0);
    assert (max_fetch_reserved == FrontendCapacity && fetch_return_count > 0);
    if (IMEM_LATENCY > 0) assert (stale_returns > 0);
    $display("FETCH_DRAIN stale_returns=%0d", stale_returns);
    assert (load_flush_buffered > 0 && load_flush_repeated > 0 && load_flush_simultaneous > 0 &&
            load_reset_canceled >= 2 && accepted[1] == completed[1] + load_reset_canceled);
    if (DMEM_LATENCY > 1) assert (load_flush_pending > 0);
    $display("LOAD_DRAIN pending_flush=%0d buffered_flush=%0d repeated_flush=%0d simultaneous=%0d reset_canceled=%0d",
             load_flush_pending, load_flush_buffered, load_flush_repeated,
             load_flush_simultaneous, load_reset_canceled);
    for (int p = 0; p < 3; p++) begin
      assert (errors[p] > 0 &&
              max_out[p] == (p == 0 ? (int'(IMEM_LATENCY) < FetchDepth ? int'(IMEM_LATENCY) : FetchDepth) : Capacity) &&
              max_occ[p] == (p == 0 ? 0 : Capacity) && stalled[p] > 0 && blocked[p] > 0);
      $display(
          "PORT %0d accepted=%0d completed=%0d native=%0d errors=%0d latency=%f max_out=%0d avg_out=%f max_occ=%0d avg_occ=%f req_stall=%0d rsp_stall=%0d",
          p, accepted[p], completed[p], native_count[p], errors[p],
          real'(latency_sum[p]) / real'(completed[p]), max_out[p],
          real'(sum_out[p]) / real'(cycle_no), max_occ[p], real'(sum_occ[p]) / real'(cycle_no),
          blocked[p], stalled[p]);
    end
    $display("IMEM latency=%0d DMEM latency=%0d frontend_depth=%0d returns=%0d max_reserved=%0d",
             IMEM_LATENCY, DMEM_LATENCY, FetchDepth, fetch_return_count, max_fetch_reserved);
    $display("PASS seed=%0d cycles=%0d all_ports=%0d collisions=%0d flushes=%0d mmio=%0d", seed,
             cycle_no, all_three, collision, flush_count, mmio_count);
    $finish;
  end
endmodule
