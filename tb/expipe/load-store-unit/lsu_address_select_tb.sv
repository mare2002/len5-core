// Copyright 2026 Politecnico di Torino.
// SPDX-License-Identifier: SHL-2.0
`include "len5_typedef.svh"
module lsu_address_select_tb #(
  parameter int DEPTH = 4,
  parameter bit ADDR_RR = 0
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  localparam int Width = 8;
  localparam int IdxW = DEPTH > 1 ? $clog2(DEPTH) : 1;
  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = Width;
    cfg.LSU_ISSUE_WIDTH = Width;
    cfg.LDBUFF_ISSUE_WIDTH = Width;
    cfg.STBUFF_ISSUE_WIDTH = Width;
    cfg.LDBUFF_DEPTH = DEPTH;
    cfg.STBUFF_DEPTH = DEPTH;
    cfg.ROB_DEPTH = 64;
    cfg.LDBUFF_RR_ARBITER = ADDR_RR;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  localparam bit ConfigValid = check_build(Cfg);
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef `LEN5_CDB_DATA_T(Cfg) result_t;
  typedef `LEN5_ADDER_REQ_T(Cfg) addr_req_t;
  typedef `LEN5_ADDER_ANS_T(Cfg) addr_ans_t;
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  typedef logic [Cfg.BUFF_IDX_LEN-1:0] tag_t;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic [Width-1:0] lb_issue_valid = '0, sb_issue_valid = '0;
  logic [Width-1:0] lb_issue_ready, sb_issue_ready;
  operand_t [Width-1:0] rs1, rs2;
  ldst_width_t [Width-1:0] load_type, store_type;
  rob_idx_t [Width-1:0] rob;
  logic [Width-1:0][63:0] imm;
  logic broadcast_valid = 0;
  result_t broadcast_data = '0;
  logic lb_addr_ready = 0, sb_addr_ready = 0;
  logic lb_addr_valid, sb_addr_valid;
  addr_req_t lb_req, sb_req;
  addr_ans_t lb_ans, sb_ans;
  logic lb_ans_valid, sb_ans_valid;
  logic sb_auto_response = 1, sb_manual_response = 0, sb_addr_fault = 0;
  logic lb_mem_valid, sb_mem_valid;
  tag_t lb_mem_tag, sb_mem_tag;
  logic lb_result_ready = 0, sb_result_ready = 1;
  logic lb_result_valid, sb_result_valid;
  result_t sb_result;
  logic permission = 0;
  logic [IdxW-1:0] sq_head;
  logic [DEPTH-1:0] sq_data_ready, sq_addr_ready;
  logic [DEPTH-1:0][63:0] sq_data;
  logic [Width:0][IdxW-1:0] issue_sq_tail;
  logic [Width:0] issue_older_stores_remain;

  assign lb_ans_valid = lb_addr_valid && lb_addr_ready;
  assign lb_ans = '{tag: lb_req.tag, result: lb_req.base + lb_req.offs,
                    except_raised: 1'b0, except_code: E_LD_ADDR_MISALIGNED};
  assign sb_ans_valid = (sb_auto_response && sb_addr_valid && sb_addr_ready) || sb_manual_response;
  assign sb_ans = '{tag: sb_manual_response ? tag_t'(0) : sb_req.tag,
                    result: sb_manual_response ? 64'h1000 : sb_req.base + sb_req.offs,
                    except_raised: sb_addr_fault, except_code: E_ST_ADDR_MISALIGNED};

  load_buffer #(.Len5Cfg(Cfg)) lb (
    .clk_i(clk),
    .rst_ni(rst_n),
    .flush_i(flush),
    .issue_valid_i(lb_issue_valid),
    .issue_ready_o(lb_issue_ready),
    .issue_type_i(load_type),
    .issue_rs1_i(rs1),
    .issue_imm_i(imm),
    .issue_dest_rob_idx_i(rob),
    .issue_sq_tail_i('0),
    .issue_older_stores_remain_i('0),
    .cdb_valid_i(broadcast_valid),
    .cdb_ready_i(lb_result_ready),
    .cdb_valid_o(lb_result_valid),
    .cdb_data_i(broadcast_data),
    .cdb_data_o(),
    .adder_valid_i(lb_ans_valid),
    .adder_ready_i(lb_addr_ready),
    .adder_valid_o(lb_addr_valid),
    .adder_ready_o(),
    .adder_ans_i(lb_ans),
    .adder_req_o(lb_req),
    .sq_head_i('0),
    .sq_removed_i('0),
    .sq_addr_ready_i('0),
    .sq_data_ready_i('0),
    .sq_addr_i('0),
    .sq_data_i('0),
    .sq_type_i('0),
    .mem_valid_o(lb_mem_valid),
    .mem_ready_i(1'b1),
    .mem_valid_i(lb_mem_valid),
    .mem_ready_o(),
    .mem_we_o(),
    .mem_addr_o(),
    .mem_be_o(),
    .mem_tag_o(lb_mem_tag),
    .mem_rdata_i(64'habcdef),
    .mem_tag_i(lb_mem_tag),
    .mem_except_raised_i('0),
    .mem_except_code_i('0)
  );

  store_buffer #(.Len5Cfg(Cfg)) sb (
    .clk_i(clk),
    .rst_ni(rst_n),
    .flush_i(flush),
    .issue_valid_i(sb_issue_valid),
    .issue_ready_o(sb_issue_ready),
    .issue_type_i(store_type),
    .issue_rs1_i(rs1),
    .issue_rs2_i(rs2),
    .issue_imm_i(imm),
    .issue_dest_rob_idx_i(rob),
    .comm_mem_clear_i(permission),
    .comm_mem_idx_o(),
    .cdb_valid_i(broadcast_valid),
    .cdb_ready_i(sb_result_ready),
    .cdb_valid_o(sb_result_valid),
    .cdb_data_i(broadcast_data),
    .cdb_data_o(sb_result),
    .adder_valid_i(sb_ans_valid),
    .adder_ready_i(sb_addr_ready),
    .adder_valid_o(sb_addr_valid),
    .adder_ready_o(),
    .adder_ans_i(sb_ans),
    .adder_req_o(sb_req),
    .sq_head_o(sq_head),
    .issue_sq_tail_o(issue_sq_tail),
    .issue_older_stores_remain_o(issue_older_stores_remain),
    .sq_removed_o(),
    .sq_addr_ready_o(sq_addr_ready),
    .sq_data_ready_o(sq_data_ready),
    .sq_addr_o(),
    .sq_data_o(sq_data),
    .sq_type_o(),
    .mem_valid_o(sb_mem_valid),
    .mem_ready_i(1'b1),
    .mem_valid_i(sb_mem_valid),
    .mem_ready_o(),
    .mem_we_o(),
    .mem_addr_o(),
    .mem_be_o(),
    .mem_wdata_o(),
    .mem_tag_o(sb_mem_tag),
    .mem_tag_i(sb_mem_tag),
    .mem_except_raised_i('0),
    .mem_except_code_i('0)
  );

  task automatic tick();
    @(posedge clk);
    #1;
  endtask

  task automatic clear_queues();
    lb_issue_valid = '0;
    sb_issue_valid = '0;
    broadcast_valid = 0;
    permission = 0;
    lb_addr_ready = 0;
    sb_addr_ready = 0;
    lb_result_ready = 0;
    sb_result_ready = 1;
    sb_auto_response = 1;
    sb_manual_response = 0;
    sb_addr_fault = 0;
    flush = 1;
    tick();
    flush = 0;
    tick();
    foreach (rs1[k]) begin
      rs1[k] = '{ready: 1'b1, rob_idx: rob_idx_t'(40), value: 64'h1000 + 64'(8*k)};
      rs2[k] = '{ready: 1'b1, rob_idx: rob_idx_t'(40), value: 64'(k+1)};
      rob[k] = rob_idx_t'(k+1);
      imm[k] = '0;
      load_type[k] = L_DOUBLEWORD;
      store_type[k] = S_DOUBLEWORD;
    end
  endtask

  task automatic check_load(int index);
    #1;
    assert (lb_addr_valid && int'(lb_req.tag) == index)
    else $fatal(1, "load address selection: expected %0d, valid=%0b tag=%0d", index, lb_addr_valid, lb_req.tag);
  endtask

  task automatic check_store(int index);
    #1;
    assert (sb_addr_valid && int'(sb_req.tag) == index)
    else $fatal(1, "store address selection: expected %0d, valid=%0b tag=%0d head=%0d", index, sb_addr_valid, sb_req.tag, sq_head);
  endtask

  task automatic advance_store_head();
    permission = 1;
    sb_addr_ready = 1;
    sb_issue_valid = 1;
    tick();
    sb_issue_valid = 0;
    for (int n = 0; n < 16 && sb.occupied_slots != '0; n++) tick();
    assert (sb.occupied_slots == '0) else $fatal(1, "dummy store failed to complete");
    permission = 0;
    sb_addr_ready = 0;
  endtask

  // Independent allocation/removal counts check every exported store-prefix boundary.
  int expected_tail = 0, resident_stores = 0;
  always @(posedge clk) begin
    int accepted, remaining;
    if (!rst_n || flush) begin
      expected_tail = 0;
      resident_stores = 0;
    end else begin
      accepted = 0;
      remaining = resident_stores - int'(sb_result_valid && sb_result_ready);
      for (int k = 0; k <= Width; k++) begin
        if (k > 0 && sb_issue_valid[k-1] && sb_issue_ready[k-1]) accepted++;
        assert (int'(issue_sq_tail[k]) == ((expected_tail + k) & (DEPTH - 1)))
        else $fatal(1, "incorrect exported SQ boundary for prefix %0d", k);
        assert (issue_older_stores_remain[k] == (remaining != 0 || accepted != 0))
        else $fatal(1, "incorrect exported older-store flag for prefix %0d", k);
      end
      expected_tail = (expected_tail + accepted) & (DEPTH - 1);
      resident_stores = remaining + accepted;
    end
  end

  initial begin
    tick();
    rst_n = 1;
    clear_queues();

    // Every ready subset, at every head position, is selected in circular age order.
    for (int head = 0; head < DEPTH; head++) begin
      for (int mask = 1; mask < (1 << DEPTH); mask++) begin
        clear_queues();
        repeat (head) advance_store_head();
        assert (int'(sq_head) == head) else $fatal(1, "wrong initial SQ head");
        for (int k = 0; k < DEPTH; k++) rs1[k].ready = 1'((mask >> k) & 1);
        sb_issue_valid = Width'((1 << DEPTH) - 1);
        tick();
        sb_issue_valid = 0;
        for (int k = 0; k < DEPTH; k++) begin
          if ((mask & (1 << k)) != 0) begin
            check_store((head + k) & (DEPTH - 1));
            tick();
            check_store((head + k) & (DEPTH - 1));
            sb_addr_ready = 1;
            tick();
            sb_addr_ready = 0;
          end
        end
        #1;
        assert (!sb_addr_valid) else $fatal(1, "duplicate store address request");
      end
    end

    // A newly ready older store replaces an unaccepted younger address request.
    if (DEPTH > 1) begin
      clear_queues();
      rs1[0].ready = 0;
      sb_issue_valid = 3;
      tick();
      sb_issue_valid = 0;
      check_store(1);
      tick();
      broadcast_data.rob_idx = rs1[0].rob_idx;
      broadcast_data.res_value = 'h3000;
      broadcast_valid = 1;
      tick();
      broadcast_valid = 0;
      check_store(0);
    end

    // Removing the last resident store while accepting a new store separates prefix zero from one.
    clear_queues();
    permission = 1;
    sb_addr_ready = 1;
    sb_result_ready = 0;
    sb_issue_valid = 1;
    tick();
    sb_issue_valid = 0;
    for (int n = 0; n < 16 && !sb_result_valid; n++) tick();
    assert (sb_result_valid) else $fatal(1, "store did not reach completion");
    sb_result_ready = 1;
    sb_issue_valid = 1;
    #1;
    assert (sb_issue_ready[0] == (DEPTH > 1))
    else $fatal(1, "incorrect simultaneous store removal/allocation readiness");
    tick();
    sb_issue_valid = 0;

    // All four allocation operand-readiness combinations converge after CDB wakeup.
    for (int ready_mask = 0; ready_mask < 4; ready_mask++) begin
      clear_queues();
      rs1[0].ready = 1'(ready_mask & 1);
      rs2[0].ready = 1'((ready_mask >> 1) & 1);
      sb_issue_valid = 1;
      tick();
      sb_issue_valid = 0;
      #1;
      assert (sb_addr_valid == rs1[0].ready)
      else $fatal(1, "store address eligibility depends on wrong operand");
      broadcast_data.rob_idx = rob_idx_t'(40);
      broadcast_data.res_value = 'h3000;
      broadcast_valid = 1;
      tick();
      broadcast_valid = 0;
      check_store(0);
      assert (sq_data_ready[0]) else $fatal(1, "store data did not wake up");
    end

    // Address capture and simultaneous rs2 wakeup, both immediate and delayed.
    for (int delayed = 0; delayed < 2; delayed++) begin
      for (int fault = 0; fault < 2; fault++) begin
        clear_queues();
        sb_auto_response = !1'(delayed);
        sb_addr_fault = 1'(fault);
        rs2[0].ready = 0;
        sb_issue_valid = 1;
        tick();
        sb_issue_valid = 0;
        if (delayed != 0) begin
          sb_addr_ready = 1;
          tick();
          sb_addr_ready = 0;
          sb_manual_response = 1;
        end
        broadcast_data.rob_idx = rs2[0].rob_idx;
        broadcast_data.res_value = 'h55aa;
        broadcast_valid = 1;
        sb_addr_ready = 1;
        sb_result_ready = 0;
        tick();
        broadcast_valid = 0;
        sb_manual_response = 0;
        assert (sq_data_ready[0] && sq_data[0] == 'h55aa)
        else $fatal(1, "address capture lost simultaneous rs2 wakeup");
        if (fault != 0) begin
          assert (sb_result_valid && sb_result.except_raised && sb_result.res_value == 'h1000)
          else $fatal(1, "address exception was not saved");
        end else begin
          assert (sq_addr_ready[0]) else $fatal(1, "address result was not saved");
        end
      end
    end

    // The initial all-ready load batch is served once per entry.
    clear_queues();
    lb_issue_valid = Width'((1 << DEPTH) - 1);
    tick();
    lb_issue_valid = 0;
    check_load(0);
    repeat (3) tick();
    lb_addr_ready = 1;
    for (int k = 0; k < DEPTH; k++) begin
      check_load(k);
      tick();
    end
    #1;
    assert (!lb_addr_valid) else $fatal(1, "duplicate load address request");

    // Address selection follows live candidates before request acceptance.
    clear_queues();
    for (int k = 0; k < DEPTH; k++) begin
      rs1[k].ready = k == DEPTH - 1;
      rs1[k].rob_idx = rob_idx_t'(40 + k);
    end
    lb_issue_valid = Width'((1 << DEPTH) - 1);
    tick();
    lb_issue_valid = 0;
    check_load(DEPTH - 1);
    tick();
    for (int k = 0; k < DEPTH - 1; k++) begin
      broadcast_valid = 1;
      broadcast_data.rob_idx = rob_idx_t'(40 + k);
      broadcast_data.res_value = 64'h2000 + 64'(8*k);
      tick();
      broadcast_valid = 0;
      check_load(0);
    end
    lb_addr_ready = 1;
    tick();
    if (DEPTH > 1) check_load(1);

    if (DEPTH >= 4) begin
      // A new low slot wins fixed priority; RR finishes the existing round first.
      clear_queues();
      lb_issue_valid = Width'((1 << DEPTH) - 1);
      tick();
      lb_issue_valid = 0;
      lb_addr_ready = 1;
      check_load(0);
      tick();
      lb_addr_ready = 0;
      check_load(1);
      tick();
      lb_result_ready = 1;
      for (int n = 0; n < 8 && !lb_issue_ready[0]; n++) tick();
      assert (lb_issue_ready[0]) else $fatal(1, "completed load slot did not become free");
      lb_result_ready = 0;
      rob[0] = rob_idx_t'(16);
      rs1[0].value = 'h1200;
      lb_issue_valid = 1;
      tick();
      lb_issue_valid = 0;
      repeat (3) begin
        check_load(ADDR_RR ? 1 : 0);
        tick();
      end
      lb_addr_ready = 1;
      tick();
      check_load(ADDR_RR ? 2 : 1);
    end

    clear_queues();
    assert (!lb_addr_valid && !sb_addr_valid) else $fatal(1, "flush retained address requests");
    $display("PASS address selection DEPTH=%0d ADDR_RR=%0b: all SQ masks/heads, live selection, address/rs2 capture, LQ policy and reuse", DEPTH, ADDR_RR);
    $finish;
  end
  initial begin
    #20000000;
    $fatal(1, "address-selection test timed out");
  end
endmodule
