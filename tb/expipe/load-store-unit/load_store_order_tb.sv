`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Run with: bash scripts/sim/check-load-store.sh
module load_store_order_tb #(
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

  // Independent memory model: writes at request acceptance, reads snapshot
  // memory at request acceptance, and both response channels have four-cycle latency.
  localparam int Latency = 4;
  byte unsigned memory[256];
  logic [Latency-1:0] load_valid_pipe, store_valid_pipe;
  logic [Len5Cfg.BUFF_IDX_LEN-1:0] load_tags[Latency], store_tags[Latency];
  logic [XLEN-1:0] load_values[          Latency];
  logic [XLEN-1:0] expected   [Len5Cfg.ROB_DEPTH];
  bit expected_valid[Len5Cfg.ROB_DEPTH], seen[Len5Cfg.ROB_DEPTH];
  int stores, reads;

  assign load_rsp      = load_valid_pipe[Latency-1];
  assign load_rsp_tag  = load_tags[Latency-1];
  assign load_data     = load_values[Latency-1];
  assign store_rsp     = store_valid_pipe[Latency-1];
  assign store_rsp_tag = store_tags[Latency-1];

  always @(posedge clk) begin
    if (!rst_n || flush) begin
      load_valid_pipe  <= '0;
      store_valid_pipe <= '0;
      foreach (load_tags[i]) begin
        load_tags[i]   <= '0;
        store_tags[i]  <= '0;
        load_values[i] <= '0;
      end
    end else begin
      load_valid_pipe  <= {load_valid_pipe[Latency-2:0], load_req && load_gnt};
      store_valid_pipe <= {store_valid_pipe[Latency-2:0], store_req && store_gnt};
      for (int i = 1; i < Latency; i++) begin
        load_tags[i]   <= load_tags[i-1];
        store_tags[i]  <= store_tags[i-1];
        load_values[i] <= load_values[i-1];
      end
      load_tags[0]  <= load_tag;
      store_tags[0] <= store_tag;
      if (load_req && load_gnt) begin
        logic [63:0] value;
        value = '0;
        assert (load_addr >= 64'h1000 && load_addr < 64'h1100)
        else $fatal(1, "Bad load address");
        for (int b = 0; b < 8; b++) begin
          if (load_be[b]) value[8*b+:8] = memory[int'(load_addr-64'h1000)+b];
        end
        load_values[0] <= value;
        reads++;
      end
      if (store_req && store_gnt) begin
        assert (store_addr >= 64'h1000 && store_addr < 64'h1100)
        else $fatal(1, "Bad store address");
        for (int b = 0; b < 8; b++) begin
          if (store_be[b]) memory[int'(store_addr-64'h1000)+b] = store_data[8*b+:8];
        end
        stores++;
      end
      if (load_result_valid) begin
        assert (!load_result.except_raised)
        else $fatal(1, "Unexpected load exception");
        assert (expected_valid[load_result.rob_idx])
        else $fatal(1, "Unexpected load result");
        assert (load_result.res_value == expected[load_result.rob_idx])
        else
          $fatal(
              1,
              "Load %0d: got %h, expected %h",
              load_result.rob_idx,
              load_result.res_value,
              expected[load_result.rob_idx]
          );
        seen[load_result.rob_idx]           = 1;
        expected_valid[load_result.rob_idx] = 0;
      end
      if (store_result_valid) begin
        assert (!store_result.except_raised)
        else $fatal(1, "Unexpected store exception");
      end
    end
  end

  task automatic cycles(int count);
    repeat (count) @(negedge clk);
  endtask

  task automatic reset_dut();
    rst_n           = 0;
    issue_load      = 0;
    issue_store     = 0;
    broadcast_valid = 0;
    load_gnt        = 1;
    store_gnt       = 1;
    stores          = 0;
    reads           = 0;
    foreach (memory[i]) memory[i] = 0;
    foreach (expected_valid[i]) begin
      expected_valid[i] = 0;
      seen[i]           = 0;
    end
    memory[0] = 8'h11;
    memory[1] = 8'h22;
    memory[2] = 8'h33;
    memory[3] = 8'h44;
    memory[4] = 8'h55;
    memory[5] = 8'h66;
    memory[6] = 8'h77;
    memory[7] = 8'h88;
    cycles(3);
    rst_n = 1;
    cycles(1);
  endtask

  task automatic issue(bit is_load, rob_idx_t idx, logic [63:0] address, logic [63:0] value,
                       ldst_width_t access_type, bit address_ready = 1);
    rs1         = '{ready: address_ready, rob_idx: rob_idx_t'(27), value: address};
    rs2         = '{ready: 1'b1, rob_idx: '0, value: value};
    issue_type  = access_type;
    issue_idx   = idx;
    issue_load  = is_load;
    issue_store = !is_load;
    do @(posedge clk); while (!(is_load ? load_ready : store_ready));
    @(negedge clk);
    issue_load  = 0;
    issue_store = 0;
  endtask

  task automatic expect_load(rob_idx_t idx, logic [63:0] value);
    expected[idx]       = value;
    expected_valid[idx] = 1;
    seen[idx]           = 0;
  endtask

  task automatic await_load(rob_idx_t idx);
    for (int i = 0; i < 100; i++) begin
      if (seen[idx]) return;
      cycles(1);
    end
    $fatal(1, "Load %0d did not complete", idx);
  endtask

  initial begin
    rs1       = '0;
    rs2       = '0;
    broadcast = '0;
    cycles(1);

    // Unknown older address must hold a younger store, then overlap must
    // continue holding it while the older load's memory request is stalled.
    reset_dut();
    load_gnt = 0;
    expect_load(1, 64'h8877665544332211);
    issue(1, 1, 0, 0, LS_DOUBLEWORD, 0);
    issue(0, 2, 64'h1000, 64'h99, LS_DOUBLEWORD);
    cycles(8);
    assert (stores == 0)
    else $fatal(1, "Store passed an older load with unknown address");
    broadcast           = '0;
    broadcast.rob_idx   = rob_idx_t'(27);
    broadcast.res_value = 64'h1000;
    broadcast_valid     = 1;
    cycles(1);
    broadcast_valid = 0;
    cycles(5);
    assert (stores == 0)
    else $fatal(1, "Overlapping store passed a stalled older load");
    load_gnt = 1;
    await_load(1);
    cycles(8);

    // Also protect a wider older load from a narrower store starting inside it.
    reset_dut();
    load_gnt = 0;
    expect_load(1, 64'h44332211);
    issue(1, 1, 64'h1000, 0, LS_WORD_U);
    issue(0, 2, 64'h1003, 64'haa, LS_BYTE);
    cycles(8);
    assert (stores == 0)
    else $fatal(1, "Narrow store overwrote part of an older wide load");
    load_gnt = 1;
    await_load(1);
    cycles(8);

    // A stalled store must forget its completed older load before that load
    // slot is reused by a younger load that depends on the store itself.
    reset_dut();
    load_gnt  = 0;
    store_gnt = 0;
    expect_load(1, 64'h8877665544332211);
    issue(1, 1, 64'h1000, 0, LS_DOUBLEWORD);
    issue(0, 2, 64'h1008, 64'h77, LS_DOUBLEWORD);
    load_gnt = 1;
    await_load(1);
    cycles(2);
    for (int i = 0; i < Len5Cfg.LDBUFF_DEPTH; i++) begin
      expect_load(rob_idx_t'(i + 3), 64'h77);
      issue(1, rob_idx_t'(i + 3), 0, 0, LS_DOUBLEWORD, 0);
    end
    store_gnt = 1;
    cycles(10);
    assert (stores == 1)
    else $fatal(1, "Reused younger load slot blocked an older store");
    broadcast           = '0;
    broadcast.rob_idx   = rob_idx_t'(27);
    broadcast.res_value = 64'h1008;
    broadcast_valid     = 1;
    cycles(1);
    broadcast_valid = 0;
    for (int i = 0; i < Len5Cfg.LDBUFF_DEPTH; i++) await_load(rob_idx_t'(i + 3));
    assert (stores == 1)
    else $fatal(1, "Store did not resume after the load captured its value");

    // A known disjoint load should not serialize an independent store.
    reset_dut();
    load_gnt = 0;
    expect_load(1, 64'h8877665544332211);
    issue(1, 1, 64'h1000, 0, LS_DOUBLEWORD);
    cycles(3);
    issue(0, 2, 64'h1008, 64'h77, LS_DOUBLEWORD);
    cycles(8);
    assert (stores == 1 && !seen[1])
    else $fatal(1, "Disjoint store unnecessarily waited for a load");
    load_gnt = 1;
    await_load(1);

    // Different starting addresses and widths can still overlap.
    reset_dut();
    load_gnt = 0;
    expect_load(1, 64'h44);
    issue(1, 1, 64'h1003, 0, LS_BYTE_U);
    issue(0, 2, 64'h1000, 64'hdeadbeef, LS_WORD);
    cycles(8);
    assert (stores == 0)
    else $fatal(1, "Partial overlap was not protected");
    load_gnt = 1;
    await_load(1);
    cycles(8);

    // Cached value exists while the load waits for an unrelated older store.
    // The load must forward on dependency release, with memory reads disabled.
    reset_dut();
    issue(0, 1, 64'h1000, 64'h18, LS_DOUBLEWORD);
    cycles(10);
    store_gnt = 0;
    load_gnt  = 0;
    issue(0, 2, 64'h1008, 64'h10, LS_DOUBLEWORD);
    expect_load(3, 64'h18);
    issue(1, 3, 64'h1000, 0, LS_DOUBLEWORD);
    issue(0, 4, 64'h1000, 0, LS_DOUBLEWORD);
    cycles(5);
    store_gnt = 1;
    await_load(3);
    assert (reads == 0)
    else $fatal(1, "Cached load accessed memory");
    cycles(10);
    assert (stores == 3)
    else $fatal(1, "Younger store stayed blocked after forwarding");

    // Response tags lag request tags: each address must retain the pointer
    // to its own store entry. Exercise both queues wrapping and reusing slots.
    reset_dut();
    load_gnt = 0;
    for (int i = 0; i < 20; i++) begin
      issue(0, 1, 64'h1000 + 8 * 64'(i % 16), 64'(i + 1), LS_DOUBLEWORD);
      cycles(10);
      expect_load(2, 64'(i + 1));
      issue(1, 2, 64'h1000 + 8 * 64'(i % 16), 0, LS_DOUBLEWORD);
      await_load(2);
      cycles(2);
    end
    assert (reads == 0)
    else $fatal(1, "L0 used a response tag instead of the request tag");

    // Flushing an unresolved load and blocked store must release dependencies.
    reset_dut();
    issue(1, 1, 0, 0, LS_DOUBLEWORD, 0);
    issue(0, 2, 64'h1000, 64'h12, LS_DOUBLEWORD);
    cycles(5);
    assert (stores == 0)
    else $fatal(1, "Unresolved load did not block the store");
    flush = 1;
    cycles(1);
    flush = 0;
    issue(0, 3, 64'h1000, 64'h34, LS_DOUBLEWORD);
    cycles(10);
    assert (stores == 1)
    else $fatal(1, "Flush left stale load dependencies");

    // The store buffer keeps cached entries across a flush, but an invalidated
    // L0 pointer must not produce a hit merely because its old entry matches.
    flush = 1;
    cycles(1);
    flush    = 0;
    load_gnt = 0;
    expect_load(4, 64'h34);
    issue(1, 4, 64'h1000, 0, LS_DOUBLEWORD);
    cycles(8);
    assert (!seen[4])
    else $fatal(1, "Invalid L0 entry forwarded after a flush");
    load_gnt = 1;
    await_load(4);

    $display("PASS: load/store ordering, forwarding, delayed tags, queue reuse, and flush");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "Load/store regression timed out");
  end
  /* verilator lint_on BLKSEQ */
endmodule
