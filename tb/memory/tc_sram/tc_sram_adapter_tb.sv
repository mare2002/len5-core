// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module tc_sram_adapter_tb;
  import len5_pkg::*;
  import len5_config_pkg::*;
  import memory_backend_pkg::*;
  localparam int N = LEN5_MULTIPLE_ISSUES;
  localparam int LATENCY = SRAM_LATENCY;
  localparam int CAPACITY = SRAM_RESPONSE_DEPTH;
  localparam logic [63:0] BASE = 64'h1000;
  localparam int SIZE = 256;
  localparam int AW = $clog2(SIZE / 8);
  localparam logic [63:0] SERIAL = 64'h3000_0000, EXIT = 64'h3000_0100;
  bit clk = 0, rst = 0, flush = 0, load_flush = 0;
  bit [2:0] req = 0, ready = 0;
  logic [2:0][63:0] addr, wdata, rdata;
  logic [2:0][7:0] be;
  logic [2:0][BUFF_IDX_LEN-1:0] tag;
  logic [2:0] sr_req, sr_we;
  logic [2:0][AW-1:0] sr_addr;
  logic [2:0][63:0] sr_wdata;
  logic [2:0][7:0] sr_be;
  logic [2:0][SRAM_COUNT_WIDTH-1:0] outstanding, occupancy;
  logic initialized, mmio;
  memory_response_t rsp;
  tc_sram_adapter #(
      .BASE_ADDR  (BASE),
      .SIZE_BYTES (SIZE),
      .SERIAL_ADDR(SERIAL),
      .EXIT_ADDR  (EXIT)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst),
      .instr_flush_i(flush),
      .load_flush_i(load_flush),
      .initialized_i(initialized),
      .instr_req_i(req[0]),
      .instr_ready_i(ready[0]),
      .instr_addr_i(addr[0]),
      .load_req_i(req[1]),
      .load_ready_i(ready[1]),
      .load_addr_i(addr[1]),
      .load_be_i(be[1]),
      .load_tag_i(tag[1]),
      .store_req_i(req[2]),
      .store_ready_i(ready[2]),
      .store_we_i(1'b1),
      .store_addr_i(addr[2]),
      .store_data_i(wdata[2]),
      .store_be_i(be[2]),
      .store_tag_i(tag[2]),
      .response_o(rsp),
      .sram_req_o(sr_req),
      .sram_we_o(sr_we),
      .sram_addr_o(sr_addr),
      .sram_wdata_o(sr_wdata),
      .sram_be_o(sr_be),
      .sram_rdata_i(rdata),
      .mmio_write_o(mmio),
      .outstanding_o(outstanding),
      .occupancy_o(occupancy)
  );
  tc_sram_storage #(
      .BASE_ADDR(BASE),
      .SIZE_BYTES(SIZE),
      .SIM_INIT("zeros"),
      .LOAD_FIRMWARE(0)
  ) storage (
      .clk_i(clk),
      .req_i(sr_req),
      .we_i(sr_we),
      .addr_i(sr_addr),
      .wdata_i(sr_wdata),
      .be_i(sr_be),
      .rdata_o(rdata),
      .initialized_o(initialized)
  );

  byte unsigned reference_mem[SIZE];
  typedef struct packed {
    logic [63:0] data;
    logic [BUFF_IDX_LEN-1:0] tag;
    except_code_t code;
    int due;
  } expected_t;
  typedef struct packed {
    logic [N-1:0][31:0] data;
    except_code_t [N-1:0] code;
    int due;
  } fetch_expected_t;
  expected_t loads[$], stores[$];
  fetch_expected_t fetches[$];
  int cycle_no = 0, seed = 1, cycles = 10000;
  int unsigned rng;
  int accepted[3], completed[3], errors[3], native_count[3], blocked[3], stalled[3];
  int max_out[3], max_occ[3], sum_out[3], sum_occ[3], latency_sum[3];
  int fetch_beat = -1, fetch_slot;
  logic [63:0] fetch_base;
  bit fetch_bad;
  int all_three = 0, collision = 0, flush_count = 0, mmio_count = 0;

  function automatic int unsigned random32();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic int size_of(logic [7:0] mask);
    case (mask)
      1: return 1;
      3: return 2;
      15: return 4;
      255: return 8;
      default: return 0;
    endcase
  endfunction
  function automatic except_code_t fault(logic [63:0] a, int size, int port_id);
    if (size != 0 && a % 64'(size) != 0)
      return port_id == 0 ? E_I_ADDR_MISALIGNED : port_id == 1 ? E_LD_ADDR_MISALIGNED : E_ST_ADDR_MISALIGNED;
    if (port_id == 2 && size != 0 && (a == SERIAL || a == EXIT)) return E_UNKNOWN;
    if (size == 0 || a < BASE || a > BASE + 64'(SIZE) - 64'(size))
      return port_id == 0 ? E_I_ACCESS_FAULT : port_id == 1 ? E_LD_ACCESS_FAULT : E_ST_ACCESS_FAULT;
    return E_UNKNOWN;
  endfunction
  function automatic logic [63:0] read_bytes(logic [63:0] a, int size);
    logic [63:0] value = 0;
    for (int b = 0; b < size; b++) value[b*8+:8] = reference_mem[int'(a-BASE)+b];
    return value;
  endfunction
  function automatic logic [63:0] random_address(int size);
    logic [63:0] a;
    case (random32() % 12)
      0: a = BASE - 8;
      1: a = BASE + 64'(SIZE);
      2: a = BASE + 64'(SIZE) - 1;
      3: a = 64'hffff_ffff_ffff_fff8;
      4: a = SERIAL;
      5: a = EXIT;
      6: a = SERIAL + 8;
      default: a = BASE + 64'(random32() % SIZE);
    endcase
    if ((random32() % 4) != 0 && size != 0) a &= ~(64'(size) - 1);
    return a;
  endfunction

  task automatic tick;
    expected_t e;
    fetch_expected_t f;
    bit [2:0] grant, valid, accepted_now;
    bit expected_native;
    logic [63:0] a;
    int size;
    #5;
    grant = {rsp.store_gnt, rsp.load_gnt, rsp.instr_gnt};
    valid = {rsp.store_valid, rsp.load_valid, rsp.instr_valid};
    if (!rst) begin
      loads.delete();
      stores.delete();
      fetches.delete();
      fetch_beat = -1;
      assert (sr_req == 0 && valid == 0)
      else $fatal(1, "Activity during reset");
    end else begin
      if (flush) begin
        fetches.delete();
        fetch_beat = -1;
        flush_count++;
      end
      if (LATENCY > 1 && load_flush) begin
        loads.delete();
        assert (!valid[1] && !grant[1])
        else $fatal(1, "Load activity during cancellation");
      end
      // Results must be visible as soon as their fixed-latency operation reaches the queue head.
      if (loads.size() != 0 && cycle_no >= loads[0].due) assert (valid[1]);
      if (stores.size() != 0 && cycle_no >= stores[0].due) assert (valid[2]);
      if (fetches.size() != 0 && cycle_no >= fetches[0].due) assert (valid[0]);
      // Validate every visible response, including every stalled cycle.
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
          latency_sum[1] += cycle_no - e.due + LATENCY;
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
          latency_sum[2] += cycle_no - e.due + 1;
        end
      end
      if (valid[0]) begin
        assert (fetches.size() != 0)
        else $fatal(1, "Unsolicited fetch");
        f = fetches[0];
        assert (cycle_no >= f.due && rsp.instr_data === f.data && rsp.instr_code == f.code)
        else
          $fatal(
              1,
              "Fetch mismatch cycle %0d got %h expected %h code %h/%h",
              cycle_no,
              rsp.instr_data,
              f.data,
              rsp.instr_code,
              f.code
          );
        for (int j = 0; j < N; j++) assert (rsp.instr_except[j] == (f.code[j] != E_UNKNOWN));
        if (ready[0]) begin
          f = fetches.pop_front();
          fetch_slot--;
          latency_sum[0] += cycle_no - f.due + (N + 1) / 2 + LATENCY - 1;
        end
      end
      accepted_now = req & grant;
      for (int p = 0; p < 3; p++) begin
        accepted[p] += int'(accepted_now[p]);
        completed[p] += int'(valid[p] && ready[p]);
        blocked[p] += int'(req[p] && !grant[p]);
        stalled[p] += int'(valid[p] && !ready[p]);
        native_count[p] += int'(sr_req[p]);
        sum_out[p] += int'(outstanding[p]);
        sum_occ[p] += int'(occupancy[p]);
        if (int'(outstanding[p]) > max_out[p]) max_out[p] = int'(outstanding[p]);
        if (int'(occupancy[p]) > max_occ[p]) max_occ[p] = int'(occupancy[p]);
      end
      if (&sr_req) all_three++;
      if (sr_req[1] && sr_req[2] && sr_addr[1] == sr_addr[2]) collision++;
      if (accepted_now[0]) begin
        assert (fetch_beat == -1)
        else $fatal(1, "Overlapping fetch assembly");
        fetch_base = N == 1 ? addr[0] : addr[0] / (N * 4) * (N * 4);
        fetch_bad = (addr[0] % 4) != 0;
        fetch_beat = 0;
        fetch_slot = fetches.size();
        f = '0;
        f.due = cycle_no + (N + 1) / 2 + LATENCY - 1;
        fetches.push_back(f);
      end
      if (fetch_beat != -1) begin
        a = fetch_base + 64'(fetch_beat * 8);
        expected_native = !fetch_bad && fault(a, 4, 0) == E_UNKNOWN;
        assert (sr_req[0] == expected_native)
        else $fatal(1, "Fetch SRAM request mismatch");
        if (expected_native) assert (sr_addr[0] == AW'((a - BASE) / 8));
        f = fetches[fetch_slot];
        for (int j = 0; j < 2; j++)
        if (fetch_beat * 2 + j < N) begin
          f.code[fetch_beat*2+j] = fetch_bad ? E_I_ADDR_MISALIGNED : fault(a + 64'(4 * j), 4, 0);
          f.data[fetch_beat*2+j] = f.code[fetch_beat*2+j] == E_UNKNOWN ?
              32'(read_bytes(a + 64'(4 * j), 4)) : 0;
          if (f.code[fetch_beat*2+j] != E_UNKNOWN) errors[0]++;
        end
        fetches[fetch_slot] = f;
        fetch_beat++;
        if (fetch_beat == (N + 1) / 2) fetch_beat = -1;
      end else assert (!sr_req[0]);
      for (int p = 1; p < 3; p++) begin
        size = size_of(be[p]);
        e = '{data: 0, tag: tag[p], code: fault(addr[p], size, p), due: cycle_no + (p == 1 ? LATENCY : 1)};
        expected_native = accepted_now[p] && e.code == E_UNKNOWN && addr[p] != SERIAL && addr[p] != EXIT;
        assert (sr_req[p] == expected_native)
        else $fatal(1, "Native request mismatch port %0d", p);
        if (expected_native) assert (sr_addr[p] == AW'((addr[p] - BASE) / 8));
        if (p == 1 && expected_native) e.data = read_bytes(addr[p], size);
        if (accepted_now[p]) begin
          if (e.code != E_UNKNOWN) errors[p]++;
          if (p == 1) loads.push_back(e);
          else stores.push_back(e);
        end
        if (p == 2) begin
          assert (mmio == (accepted_now[2] && e.code == E_UNKNOWN && (addr[p] == SERIAL || addr[p] == EXIT)));
          if (mmio) mmio_count++;
          if (expected_native) begin
            assert (sr_we == 3'b100 && sr_be[2] == (be[p] << (addr[p]%8)) &&
                    sr_wdata[2] == (wdata[p] << (8*(addr[p]%8))))
            else $fatal(1, "Store lanes mismatch");
            for (int b = 0; b < size; b++) reference_mem[int'(addr[p]-BASE)+b] = wdata[p][8*b+:8];
          end
        end
      end
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
    load_flush = 0;
    repeat (LATENCY + CAPACITY + (N + 1) / 2 + 5) tick();
    assert (loads.size() == 0 && stores.size() == 0 && fetches.size() == 0)
    else $fatal(1, "Drain failed");
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    void'($value$plusargs("cycles=%d", cycles));
    rng = 32'(seed);
    if (rng == 0) rng = 1;
    addr = '0;
    be = '0;
    tag = '0;
    wdata = '0;
    foreach (reference_mem[i]) reference_mem[i] = 0;
    repeat (3) tick();
    rst   = 1;
    ready = 7;
    // Every legal byte lane, partial preservation, both instruction halves,
    // repeated writes, read-before-write collisions and consecutive traffic.
    for (int size = 1; size <= 8; size *= 2) begin
      for (int off = 0; off < 8; off += size) begin
        addr[0] = BASE;
        addr[1] = BASE + 64'(off);
        addr[2] = addr[1];
        be[1] = 8'((1 << size) - 1);
        be[2] = be[1];
        req = 7;
        wdata[2] = 64'h8877_6655_4433_2211;
        tick();
        wdata[2] = ~wdata[2];
        tick();
        drain();
      end
    end
    // Directed misalignment for every forbidden offset at each access size.
    for (int size = 2; size <= 8; size *= 2) begin
      for (int off = 1; off < size; off++) begin
        req = 7;
        addr[0] = BASE + 2;
        addr[1] = BASE + 64'(off);
        addr[2] = addr[1];
        be[1] = 8'((1 << size) - 1);
        be[2] = be[1];
        tag[1] = '1;
        tag[2] = '1;
        tick();
        drain();
      end
    end
    // A full-rate legal run proves no data-port bubbles and full native fetch bandwidth.
    begin
      int start_load, start_store, start_fetch;
      drain();
      start_load = accepted[1];
      start_store = accepted[2];
      start_fetch = native_count[0];
      req = 7;
      ready = 7;
      addr[0] = BASE;
      addr[1] = BASE + 8;
      addr[2] = BASE + 16;
      be[1] = 255;
      be[2] = 255;
      repeat (32) tick();
      assert (accepted[1]-start_load==32 && accepted[2]-start_store==32 && native_count[0]-start_fetch==32)
      else $fatal(1, "Unexpected bubble at full rate");
      drain();
    end
    // Force maximum reservation and occupied response buffers on all ports.
    ready = 0;
    req = 7;
    addr[0] = BASE;
    addr[1] = BASE;
    addr[2] = BASE + 8;
    be[1] = 255;
    be[2] = 255;
    repeat ((CAPACITY + 1) * ((N + 1) / 2) + LATENCY + 2) tick();
    drain();
    // A canceled read must never complete a post-flush request reusing the same LSU tag.
    if (LATENCY > 1) begin
      req = 2;
      addr[1] = BASE;
      tag[1] = 0;
      tick();
      load_flush = 1;
      tick();
      load_flush = 0;
      addr[1] = BASE + 8;
      tick();
      drain();
    end
    for (int i = 0; i < cycles; i++) begin
      flush = random32() % 40 == 0;
      if (LATENCY > 1) load_flush = random32() % 53 == 0;
      for (int p = 0; p < 3; p++) begin
        req[p] = random32() % 10 != 0;
        ready[p] = random32() % 4 != 0;
        be[p] = 8'((1 << (1 << (random32() % 4))) - 1);
        if (random32() % 30 == 0) be[p] = 8'h05;
        addr[p]  = random_address(p == 0 ? 4 : size_of(be[p]));
        tag[p]   = BUFF_IDX_LEN'(random32());
        wdata[p] = {random32(), random32()};
      end
      if (i % 25 == 0) begin
        addr[1] = BASE;
        addr[2] = BASE;
        be[1] = 255;
        be[2] = 255;
        req = 7;
      end
      tick();
      if (i == cycles / 2) begin
        rst = 0;
        repeat (2) tick();
        rst = 1;
      end
    end
    drain();
    // Verify all final SRAM words through the adapter, not hierarchy.
    for (int a = 0; a < SIZE; a += 8) begin
      req = 2;
      addr[1] = BASE + 64'(a);
      be[1] = 255;
      tick();
    end
    drain();
    assert (all_three > 0 && collision > 0 && mmio_count > 0 && flush_count > 0);
    for (int p = 0; p < 3; p++) begin
      assert (errors[p] > 0 && max_out[p] == CAPACITY && max_occ[p] == CAPACITY && stalled[p] > 0 && blocked[p] > 0);
      $display(
          "PORT %0d accepted=%0d completed=%0d native=%0d errors=%0d latency=%f max_out=%0d avg_out=%f max_occ=%0d avg_occ=%f req_stall=%0d rsp_stall=%0d",
          p, accepted[p], completed[p], native_count[p], errors[p],
          real'(latency_sum[p]) / real'(completed[p]), max_out[p],
          real'(sum_out[p]) / real'(cycle_no), max_occ[p], real'(sum_occ[p]) / real'(cycle_no),
          blocked[p], stalled[p]);
    end
    $display("PASS seed=%0d cycles=%0d all_ports=%0d collisions=%0d flushes=%0d mmio=%0d", seed,
             cycle_no, all_three, collision, flush_count, mmio_count);
    $finish;
  end
endmodule
