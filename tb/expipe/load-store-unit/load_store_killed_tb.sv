`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Run with: bash scripts/sim/check-load-store.sh
module load_store_killed_tb #(
    parameter int unsigned BOOT_VM_MODE = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_VM_MODE),
    parameter logic [31:0] BOOT_PC_HI = 32'((len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_PC),
    parameter logic [63:0] BOOT_PC = {BOOT_PC_HI, BOOT_PC_LO},
    parameter int unsigned LEN5_MULTIPLE_ISSUES = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULTIPLE_ISSUES,
    parameter bit LEN5_M_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_M_EN,
    parameter bit LEN5_DIV_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_DIV_EN,
    parameter bit LEN5_F_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_F_EN,
    parameter bit LEN5_D_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_D_EN,
    parameter bit LEN5_C_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_C_EN,
    parameter bit LEN5_A_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_A_EN,
    parameter bit LEN5_STORE_LOAD_FWD_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_STORE_LOAD_FWD_EN,
    parameter int unsigned MAX_EU_N = len5_config_pkg::DEFAULT_LEN5_CFG.MAX_EU_N,
    parameter bit ONLY_DOUBLEWORD_MEM_ACCESSES = len5_config_pkg::DEFAULT_LEN5_CFG.ONLY_DOUBLEWORD_MEM_ACCESSES,
    parameter bit LEN5_CSR_HPMCOUNTERS_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_CSR_HPMCOUNTERS_EN,
    parameter logic [31:0] MMAP_MASK_HI = 32'((len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK) >> 32),
    parameter logic [31:0] MMAP_MASK_LO = 32'(len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK),
    parameter logic [63:0] MMAP_MASK = {MMAP_MASK_HI, MMAP_MASK_LO},
    parameter int unsigned BPU_HLEN = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_HLEN,
    parameter int unsigned BPU_BTB_BITS = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_BTB_BITS,
    parameter int unsigned RAS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.RAS_DEPTH,
    parameter int unsigned FETCH_MEMIF_FIFO_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEMIF_FIFO_DEPTH,
    parameter bit FETCH_MEM_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEM_DRAIN_ON_FLUSH,
    parameter bit LOAD_BUFFER_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.LOAD_BUFFER_DRAIN_ON_FLUSH,
    parameter bit FETCH_REQ_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_REQ_SPILL_SKIP,
    parameter bit FETCH_ANS_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_ANS_SPILL_SKIP,
    parameter int unsigned IQ_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.IQ_DEPTH,
    parameter int unsigned LDBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.LDBUFF_DEPTH,
    parameter int unsigned STBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.STBUFF_DEPTH,
    parameter bit LSU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.LSU_SPILL_SKIP,
    parameter int unsigned ALU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RS_DEPTH,
    parameter bit ALU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_SPILL_SKIP,
    parameter bit ALU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RR_ARBITER,
    parameter int unsigned MULT_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RS_DEPTH,
    parameter bit LEN5_MULT_SERIAL = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULT_SERIAL,
    parameter int unsigned MULT_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_PIPE_DEPTH,
    parameter bit MULT_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RR_ARBITER,
    parameter int unsigned DIV_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RS_DEPTH,
    parameter bit DIV_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RR_ARBITER,
    parameter int unsigned FPU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RS_DEPTH,
    parameter bit FPU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RR_ARBITER,
    parameter int unsigned FPU_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_PIPE_DEPTH,
    parameter bit FPU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_SPILL_SKIP,
    parameter int unsigned BU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.BU_RS_DEPTH,
    parameter bit BU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.BU_SPILL_SKIP,
    parameter int unsigned ROB_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ROB_DEPTH,
    parameter bit COMMIT_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.COMMIT_SPILL_SKIP,
    parameter int unsigned BPU_INIT_C2B = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BPU_INIT_C2B),
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::build_config(
        '{
            BOOT_VM_MODE: len5_config_pkg::boot_mode_t'(BOOT_VM_MODE),
            BOOT_PC: BOOT_PC,
            LEN5_MULTIPLE_ISSUES: LEN5_MULTIPLE_ISSUES,
            LEN5_M_EN: LEN5_M_EN,
            LEN5_DIV_EN: LEN5_DIV_EN,
            LEN5_F_EN: LEN5_F_EN,
            LEN5_D_EN: LEN5_D_EN,
            LEN5_C_EN: LEN5_C_EN,
            LEN5_A_EN: LEN5_A_EN,
            LEN5_STORE_LOAD_FWD_EN: LEN5_STORE_LOAD_FWD_EN,
            MAX_EU_N: MAX_EU_N,
            ONLY_DOUBLEWORD_MEM_ACCESSES: ONLY_DOUBLEWORD_MEM_ACCESSES,
            LEN5_CSR_HPMCOUNTERS_EN: LEN5_CSR_HPMCOUNTERS_EN,
            MMAP_MASK: MMAP_MASK,
            BPU_HLEN: BPU_HLEN,
            BPU_BTB_BITS: BPU_BTB_BITS,
            RAS_DEPTH: RAS_DEPTH,
            FETCH_MEMIF_FIFO_DEPTH: FETCH_MEMIF_FIFO_DEPTH,
            FETCH_MEM_DRAIN_ON_FLUSH: FETCH_MEM_DRAIN_ON_FLUSH,
            LOAD_BUFFER_DRAIN_ON_FLUSH: LOAD_BUFFER_DRAIN_ON_FLUSH,
            FETCH_REQ_SPILL_SKIP: FETCH_REQ_SPILL_SKIP,
            FETCH_ANS_SPILL_SKIP: FETCH_ANS_SPILL_SKIP,
            IQ_DEPTH: IQ_DEPTH,
            LDBUFF_DEPTH: LDBUFF_DEPTH,
            STBUFF_DEPTH: STBUFF_DEPTH,
            LSU_SPILL_SKIP: LSU_SPILL_SKIP,
            ALU_RS_DEPTH: ALU_RS_DEPTH,
            ALU_SPILL_SKIP: ALU_SPILL_SKIP,
            ALU_RR_ARBITER: ALU_RR_ARBITER,
            MULT_RS_DEPTH: MULT_RS_DEPTH,
            LEN5_MULT_SERIAL: LEN5_MULT_SERIAL,
            MULT_PIPE_DEPTH: MULT_PIPE_DEPTH,
            MULT_RR_ARBITER: MULT_RR_ARBITER,
            DIV_RS_DEPTH: DIV_RS_DEPTH,
            DIV_RR_ARBITER: DIV_RR_ARBITER,
            FPU_RS_DEPTH: FPU_RS_DEPTH,
            FPU_RR_ARBITER: FPU_RR_ARBITER,
            FPU_PIPE_DEPTH: FPU_PIPE_DEPTH,
            FPU_SPILL_SKIP: FPU_SPILL_SKIP,
            BU_RS_DEPTH: BU_RS_DEPTH,
            BU_SPILL_SKIP: BU_SPILL_SKIP,
            ROB_DEPTH: ROB_DEPTH,
            COMMIT_SPILL_SKIP: COMMIT_SPILL_SKIP,
            BPU_INIT_C2B: 2'(BPU_INIT_C2B)
        }
    ),
    localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
    localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
    localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg)
);

  /* verilator lint_off BLKSEQ */
  import len5_pkg::*;
  import len5_config_pkg::*;
  import expipe_pkg::*;

  logic clk;
  initial clk = 0;
  always #5 clk = ~clk;
  /* verilator lint_off SYNCASYNCNET */
  logic rst_n = 0, flush = 0;
  /* verilator lint_on SYNCASYNCNET */
  logic issue_load = 0, issue_store = 0, load_ready, store_ready;
  ldst_width_t issue_type = LS_DOUBLEWORD;
  op_data_t rs1, rs2;
  rob_idx_t issue_idx = 0;
  logic     broadcast_valid = 0;
  cdb_data_t broadcast, load_result, store_result;
  logic load_result_valid, store_result_valid;
  logic load_req, load_gnt = 1, load_rsp;
  logic [XLEN-1:0] load_addr, load_data;
  logic [7:0] load_be;
  logic [Len5Cfg.BUFF_IDX_LEN-1:0] load_tag, load_rsp_tag;
  logic store_req, store_gnt = 1, store_rsp;
  logic [XLEN-1:0] store_addr, store_data;
  logic [7:0] store_be;
  logic [Len5Cfg.BUFF_IDX_LEN-1:0] store_tag, store_rsp_tag;

  load_store_unit #(
      .Len5Cfg(Len5Cfg)
  ) dut (
      .clk_i                    (clk),
      .rst_ni                   (rst_n),
      .mis_flush_i              (flush),
      .except_flush_i           (flush),
      .issue_lb_valid_i         (issue_load),
      .issue_sb_valid_i         (issue_store),
      .issue_lb_ready_o         (load_ready),
      .issue_sb_ready_o         (store_ready),
      .issue_type_i             (issue_type),
      .issue_rs1_i              (rs1),
      .issue_rs2_i              (rs2),
      .issue_imm_i              (64'b0),
      .issue_dest_rob_idx_i     (issue_idx),
      .comm_sb_mem_clear_i      (1'b1),
      .comm_sb_mem_idx_o        (),
      .cdb_valid_i              (broadcast_valid),
      .cdb_lb_ready_i           (1'b1),
      .cdb_sb_ready_i           (1'b1),
      .cdb_lb_valid_o           (load_result_valid),
      .cdb_sb_valid_o           (store_result_valid),
      .cdb_data_i               (broadcast),
      .cdb_lb_data_o            (load_result),
      .cdb_sb_data_o            (store_result),
      .mem_load_valid_o         (load_req),
      .mem_load_ready_i         (load_gnt),
      .mem_load_valid_i         (load_rsp),
      .mem_load_ready_o         (),
      .mem_load_we_o            (),
      .mem_load_addr_o          (load_addr),
      .mem_load_be_o            (load_be),
      .mem_load_tag_o           (load_tag),
      .mem_load_rdata_i         (load_data),
      .mem_load_tag_i           (load_rsp_tag),
      .mem_load_except_raised_i (1'b0),
      .mem_load_except_code_i   (E_UNKNOWN),
      .mem_store_valid_o        (store_req),
      .mem_store_ready_i        (store_gnt),
      .mem_store_valid_i        (store_rsp),
      .mem_store_ready_o        (),
      .mem_store_we_o           (),
      .mem_store_addr_o         (store_addr),
      .mem_store_be_o           (store_be),
      .mem_store_wdata_o        (store_data),
      .mem_store_tag_o          (store_tag),
      .mem_store_tag_i          (store_rsp_tag),
      .mem_store_except_raised_i(1'b0),
      .mem_store_except_code_i  (E_UNKNOWN)
  );


  localparam int TagCount = 1 << Len5Cfg.BUFF_IDX_LEN;
  bit   [TagCount-1:0] pending;
  logic [        63:0] pending_value[         TagCount];
  logic [        63:0] expected     [Len5Cfg.ROB_DEPTH];
  bit [Len5Cfg.ROB_DEPTH-1:0] expected_valid, seen;
  int read_count, store_count;
  logic [                     2:0] store_pipe;
  logic [Len5Cfg.BUFF_IDX_LEN-1:0] store_tags [3];
  assign store_rsp     = store_pipe[2];
  assign store_rsp_tag = store_tags[2];
  always @(posedge clk) begin
    int destination;
    if (!rst_n) begin
      pending        = '0;
      expected_valid = '0;
      seen           = '0;
      store_pipe <= '0;
      read_count  = 0;
      store_count = 0;
    end else begin
      if (flush) expected_valid = '0;
      if (issue_load && load_ready) expected_valid[issue_idx] = 1;
      if (load_req && load_gnt) begin
        assert (!pending[load_tag])
        else $fatal(1, "Load tag reused before response");
        pending[load_tag]       = 1;
        destination             = int'((load_addr - 64'h1000) / 8);
        pending_value[load_tag] = expected[destination];
        read_count++;
      end
      if (load_rsp) begin
        assert (pending[load_rsp_tag])
        else $fatal(1, "Unowned response in killed-load test");
        pending[load_rsp_tag] = 0;
      end
      store_pipe    <= {store_pipe[1:0], store_req && store_gnt};
      store_tags[0] <= store_tag;
      for (int i = 1; i < 3; i++) store_tags[i] <= store_tags[i-1];
      if (store_req && store_gnt) store_count++;
      if (load_result_valid) begin
        assert (!flush && expected_valid[load_result.rob_idx])
        else $fatal(1, "Killed load published to CDB");
        assert (load_result.res_value == expected[load_result.rob_idx])
        else $fatal(1, "Wrong generation completed after tag reuse");
        expected_valid[load_result.rob_idx] = 0;
        seen[load_result.rob_idx]           = 1;
      end
    end
  end
  task automatic cycles(int count);
    repeat (count) @(negedge clk);
  endtask
  task automatic reset_dut;
    rst_n       = 0;
    flush       = 0;
    issue_load  = 0;
    issue_store = 0;
    load_rsp    = 0;
    load_gnt    = 1;
    store_gnt   = 1;
    cycles(3);
    rst_n = 1;
    cycles(1);
  endtask
  task automatic issue(bit is_load, int destination, logic [63:0] value);
    rs1                   = '{ready: 1'b1, rob_idx: '0, value: 64'h1000 + 64'(destination * 8)};
    rs2                   = '{ready: 1'b1, rob_idx: '0, value: 64'hfedcba9876543210};
    issue_type            = LS_DOUBLEWORD;
    issue_idx             = rob_idx_t'(destination);
    expected[destination] = value;
    seen[destination]     = 0;
    issue_load            = is_load;
    issue_store           = !is_load;
    for (int i = 0; i < 100; i++) begin
      @(posedge clk);
      if (is_load ? load_ready : store_ready) begin
        @(negedge clk);
        issue_load  = 0;
        issue_store = 0;
        return;
      end
      @(negedge clk);
    end
    $fatal(1, "Issue blocked by a killed entry despite free capacity");
  endtask
  task automatic wait_reads(int count);
    for (int i = 0; i < 100; i++) begin
      if (read_count >= count) return;
      cycles(1);
    end
    $fatal(1, "Load scheduling blocked after flush");
  endtask
  task automatic respond(int tag_value, bit with_flush = 0);
    load_rsp_tag = Len5Cfg.BUFF_IDX_LEN'(tag_value);
    load_data    = pending_value[tag_value];
    load_rsp     = 1;
    flush        = with_flush;
    cycles(1);
    load_rsp = 0;
    flush    = 0;
  endtask
  function automatic int pending_tag;
    for (int i = 0; i < TagCount; i++) if (pending[i]) return i;
    return -1;
  endfunction
  task automatic drain;
    issue_load  = 0;
    issue_store = 0;
    flush       = 0;
    load_gnt    = 1;
    for (int i = 0; i < 200; i++) begin
      int t;
      t = pending_tag();
      if (t >= 0) respond(t);
      else cycles(1);
      if (pending == 0 && expected_valid == 0 && !load_req) begin
        cycles(10);
        return;
      end
    end
    $fatal(1, "Killed-load drain failed");
  endtask
  initial begin
    int old_tag, new_tag, start_reads, start_stores;
    int unsigned rng;
    int          seed;
    seed = 1;
    void'($value$plusargs("seed=%d", seed));
    rng          = 32'(seed) ^ 32'h12345678;
    rs1          = '0;
    rs2          = '0;
    broadcast    = '0;
    load_rsp     = 0;
    load_rsp_tag = '0;
    load_data    = '0;
    assert (Len5Cfg.LOAD_BUFFER_DRAIN_ON_FLUSH)
    else $fatal(1, "Test requires load-tag retention configuration");
    reset_dut();
    start_reads = read_count;
    issue(1, 0, 64'h111);
    wait_reads(start_reads + 1);
    old_tag = pending_tag();
    flush   = 1;
    cycles(1);
    flush = 0;
    issue(1, 1, 64'h222);
    wait_reads(start_reads + 2);
    new_tag = -1;
    for (int i = 0; i < TagCount; i++) if (pending[i] && i != old_tag) new_tag = i;
    assert (new_tag >= 0);
    start_stores = store_count;
    issue(0, 0, 0);
    cycles(15);
    assert (store_count == start_stores + 1 && pending[old_tag])
    else $fatal(1, "Killed load blocked a store");
    respond(new_tag);
    cycles(10);
    assert (seen[1] && !seen[0])
    else $fatal(1, "Killed head blocked active CDB publication");
    respond(old_tag);
    drain();
    assert (!seen[0]);

    // Exhaust every load tag. Stores must progress while allocation is stalled.
    reset_dut();
    start_reads = read_count;
    for (int i = 0; i < Len5Cfg.LDBUFF_DEPTH; i++) issue(1, i, 64'(i) + 64'h900);
    wait_reads(start_reads + int'(Len5Cfg.LDBUFF_DEPTH));
    flush = 1;
    cycles(1);
    flush = 0;
    cycles(2);
    assert (!load_ready && $countones(pending) == int'(Len5Cfg.LDBUFF_DEPTH));
    start_stores = store_count;
    issue(0, 0, 0);
    cycles(15);
    assert (store_count == start_stores + 1 && $countones(pending) == int'(Len5Cfg.LDBUFF_DEPTH));
    old_tag = pending_tag();
    respond(old_tag);
    cycles(int'(Len5Cfg.LDBUFF_DEPTH) + 2);
    issue(1, int'(Len5Cfg.LDBUFF_DEPTH), 64'habcdef);
    wait_reads(start_reads + int'(Len5Cfg.LDBUFF_DEPTH) + 1);
    assert (pending[old_tag]);
    drain();
    assert (seen[Len5Cfg.LDBUFF_DEPTH]);

    // A response on the flush edge frees its tag immediately.
    reset_dut();
    start_reads = read_count;
    issue(1, 0, 64'h333);
    wait_reads(start_reads + 1);
    old_tag = pending_tag();
    respond(old_tag, 1);
    cycles(1);
    issue(1, 1, 64'h444);
    wait_reads(start_reads + 2);
    assert (pending[old_tag])
    else $fatal(1, "Flush plus response did not free tag zero");
    respond(old_tag);
    drain();
    assert (seen[1] && !seen[0]);

    // Request accepted on the flush edge remains owned until its response.
    reset_dut();
    start_reads = read_count;
    load_gnt    = 0;
    issue(1, 0, 64'h555);
    while (!load_req) cycles(1);
    old_tag  = int'(load_tag);
    flush    = 1;
    load_gnt = 1;
    cycles(1);
    flush = 0;
    assert (read_count == start_reads + 1 && pending[old_tag]);
    flush = 1;
    cycles(1);
    flush = 0;  // Repeated flush must not release it.
    issue(1, 1, 64'h666);
    wait_reads(start_reads + 2);
    assert (int'(load_tag) != old_tag || !load_req);
    drain();
    assert (!seen[0] && seen[1]);

    // Unaccepted requests need no retained tag.
    reset_dut();
    load_gnt = 0;
    issue(1, 0, 64'h777);
    while (!load_req) cycles(1);
    flush = 1;
    cycles(1);
    flush    = 0;
    load_gnt = 1;
    assert (pending == 0);
    issue(1, 1, 64'h888);
    cycles(8);
    drain();
    assert (seen[1] && !seen[0]);

    // Random request/response/flush collisions, including out-of-order returns.
    reset_dut();
    for (int step = 0; step < 10000; step++) begin
      int t, destination;
      rng ^= rng << 13;
      rng ^= rng >> 17;
      rng ^= rng << 5;
      issue_load  = 0;
      flush       = rng % 17 == 0;
      load_gnt    = rng % 4 != 0;
      load_rsp    = 0;
      destination = int'(rng % Len5Cfg.ROB_DEPTH);
      if (!flush && !expected_valid[destination] && load_ready && rng % 3 != 0) begin
        issue_idx             = rob_idx_t'(destination);
        rs1                   = '{ready: 1'b1, rob_idx: '0, value: 64'h1000 + 64'(destination * 8)};
        expected[destination] = 64'hbeef000000000000 + 64'(step);
        seen[destination]     = 0;
        issue_load            = 1;
      end
      t = int'((rng >> 8) % TagCount);
      if (pending[t] && rng % 5 != 0) begin
        load_rsp     = 1;
        load_rsp_tag = Len5Cfg.BUFF_IDX_LEN'(t);
        load_data    = pending_value[t];
      end
      cycles(1);
    end
    load_rsp = 0;
    drain();
    $display(
        "PASS LOAD_S_KILLED: flush/request/response races, tag reuse, store progress, repeated flush and 10000 random cycles");
    $finish;
  end
  initial begin
    cycles(50000);
    $fatal(1, "Killed-load test timeout");
  end
endmodule
