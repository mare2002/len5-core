// Copyright 2026 Politecnico di Torino.
// SPDX-License-Identifier: SHL-2.0
`include "len5_typedef.svh"
module lsu_redesign_tb #(
  parameter int IW = 4,
  parameter int LSU_WIDTH = IW,
  parameter int LB_WIDTH = LSU_WIDTH,
  parameter int SB_WIDTH = LSU_WIDTH,
  parameter int LD = 4,
  parameter int SD = 4,
  parameter bit FIFO = 0,
  parameter bit FWD = 1,
  parameter bit ALIGNED_READ = 0,
  parameter bit SPILL = 1,
  parameter bit DRAIN = 1,
  parameter bit ADDR_RR = 0
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH                  = IW;
    cfg.LSU_ISSUE_WIDTH              = LSU_WIDTH;
    cfg.LDBUFF_ISSUE_WIDTH           = LB_WIDTH;
    cfg.STBUFF_ISSUE_WIDTH           = SB_WIDTH;
    cfg.LSU_USE_FIFO                 = FIFO;
    cfg.LSU_FIFO_DEPTH               = 16;
    cfg.LDBUFF_DEPTH                 = LD;
    cfg.STBUFF_DEPTH                 = SD;
    cfg.ROB_DEPTH                    = 64;
    cfg.LEN5_STORE_LOAD_FWD_EN       = FWD;
    cfg.ONLY_DOUBLEWORD_MEM_ACCESSES = ALIGNED_READ;
    cfg.LOAD_BUFFER_DRAIN_ON_FLUSH   = DRAIN;
    cfg.LSU_SPILL_SKIP               = SPILL;
    cfg.LDBUFF_RR_ARBITER            = ADDR_RR;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  localparam bit ConfigValid = check_build(Cfg);
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef `LEN5_CDB_DATA_T(Cfg) result_t;
  typedef logic [Cfg.BUFF_IDX_LEN-1:0] tag_t;
  localparam int Tags = 1 << Cfg.BUFF_IDX_LEN;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic [IW-1:0] request, is_store, grant, issue_ready;
  ldst_width_t [IW-1:0] width;
  operand_t [IW-1:0] rs1, rs2;
  logic [IW-1:0][63:0] imm, lane_value;
  rob_idx_t     [IW-1:0] rob;
  logic         [IW-1:0] lane_fault;
  except_code_t [IW-1:0] lane_code;
  logic permission = 1, accept_load = 1, accept_store = 1;
  rob_idx_t permission_idx;
  logic     broadcast_valid = 0;
  result_t broadcast, load_result, store_result;
  logic load_result_valid, store_result_valid, load_result_ready, store_result_ready;
  logic load_req, load_ready = 1, load_rsp, load_rsp_ready;
  logic [63:0] load_addr, load_rdata;
  logic [7:0] load_be;
  tag_t load_tag, load_rsp_tag;
  logic load_fault;
  logic store_req, store_ready = 1, store_rsp, store_rsp_ready;
  logic [63:0] store_addr, store_wdata;
  logic [7:0] store_be;
  tag_t store_tag, store_rsp_tag;
  logic store_fault;
  logic release_reads = 1, release_stores = 1;
  int read_delay = 3, write_delay = 5;
  int          random_seed = 1;
  int unsigned rng = 1;
  int reads, writes, load_completions, store_completions, reordered, multi_accepts;
  int directed_reordered = 0, directed_multi = 0;
  bit          pending      [Tags];
  logic [63:0] pending_data [Tags];
  bit          pending_fault[Tags];
  int pending_delay[Tags], pending_order[Tags];
  bit   write_pending;
  tag_t write_tag;
  logic [63:0] write_addr, write_data;
  logic [7:0] write_be;
  int         write_remaining;
  bit         write_fault;
  byte unsigned memory[512], architectural[512];
  bit expected_valid[64], expected_store[64], expected_fault[64], seen[64];
  logic         [63:0] expected_value[64];
  except_code_t        expected_code [64];
  int                  store_order   [ $];
  int                  chosen;
  bit previous_load_stall, previous_store_stall, previous_result_stall, previous_store_result_stall;
  logic [63:0] previous_load_addr, previous_store_addr, previous_store_data;
  logic [7:0] previous_load_be, previous_store_be;
  tag_t previous_load_tag, previous_store_tag;
  result_t previous_result, previous_store_result;

  // Independent, non-wrapping store positions model each load's older prefix.
  longint unsigned reference_store_head, reference_store_tail;
  longint unsigned reference_load_boundary[LD];
  int unsigned reference_head_base;
  bit reference_load_live[LD];

  // Model the same oldest-first grant contract as issue_stage, independently
  // of the LSU's capacity calculations; use a single completion bus.
  always_comb begin
    logic prefix;
    prefix = 1'b1;
    grant  = '0;
    for (int i = 0; i < IW; i++) begin
      if (request[i]) begin
        grant[i] = prefix && issue_ready[i];
        prefix &= grant[i];
      end
    end
  end
  eu_ctl_t [IW-1:0] controls;
  for (genvar i = 0; i < IW; i++) begin : gen_controls
    assign controls[i].lsu = width[i];
  end
  assign store_result_ready = accept_store;
  assign load_result_ready  = accept_load && !(store_result_valid && accept_store);
  load_store_unit #(
    .Len5Cfg(Cfg)
  ) dut (
    .clk_i                    (clk),
    .rst_ni                   (rst_n),
    .mis_flush_i              (flush),
    .except_flush_i           (flush),
    .issue_valid_i            (request),
    .issue_ready_o            (issue_ready),
    .issue_eu_ctl_i           (controls),
    .issue_rs1_i              (rs1),
    .issue_rs2_i              (rs2),
    .issue_imm_i              (imm),
    .issue_dest_rob_idx_i     (rob),
    .comm_sb_mem_clear_i      (permission),
    .comm_sb_mem_idx_o        (permission_idx),
    .cdb_valid_i              (broadcast_valid),
    .cdb_data_i               (broadcast),
    .cdb_lb_ready_i           (load_result_ready),
    .cdb_sb_ready_i           (store_result_ready),
    .cdb_lb_valid_o           (load_result_valid),
    .cdb_sb_valid_o           (store_result_valid),
    .cdb_lb_data_o            (load_result),
    .cdb_sb_data_o            (store_result),
    .mem_load_valid_o         (load_req),
    .mem_load_ready_i         (load_ready),
    .mem_load_valid_i         (load_rsp),
    .mem_load_ready_o         (load_rsp_ready),
    .mem_load_we_o            (),
    .mem_load_addr_o          (load_addr),
    .mem_load_be_o            (load_be),
    .mem_load_tag_o           (load_tag),
    .mem_load_tag_i           (load_rsp_tag),
    .mem_load_rdata_i         (load_rdata),
    .mem_load_except_raised_i (load_fault),
    .mem_load_except_code_i   (E_LD_ACCESS_FAULT),
    .mem_store_valid_o        (store_req),
    .mem_store_ready_i        (store_ready),
    .mem_store_valid_i        (store_rsp),
    .mem_store_ready_o        (store_rsp_ready),
    .mem_store_we_o           (),
    .mem_store_addr_o         (store_addr),
    .mem_store_be_o           (store_be),
    .mem_store_wdata_o        (store_wdata),
    .mem_store_tag_o          (store_tag),
    .mem_store_tag_i          (store_rsp_tag),
    .mem_store_except_raised_i(store_fault),
    .mem_store_except_code_i  (E_ST_ACCESS_FAULT)
  );
  always @(posedge clk) begin : boundary_scoreboard
    longint unsigned remaining;
    int load_lane;
    if (!rst_n) begin
      reference_store_head = 0;
      reference_store_tail = 0;
      reference_head_base = 0;
      foreach (reference_load_live[i]) begin
        reference_load_live[i] = 0;
        reference_load_boundary[i] = 0;
      end
    end else if (flush) begin
      // An accepted write may survive flush at an arbitrary physical head.
      reference_head_base = dut.u_store_buffer.data[dut.sq_head].write_sent ? int'(dut.sq_head) : 0;
      reference_store_head = 0;
      reference_store_tail = dut.u_store_buffer.data[dut.sq_head].write_sent ? 1 : 0;
      foreach (reference_load_live[i]) reference_load_live[i] = 0;
    end else begin
      assert (reference_store_tail - reference_store_head == 64'($countones(dut.u_store_buffer.occupied_slots)))
      else $fatal(1, "SQ occupancy disagrees with independent store positions");
      assert (int'(dut.sq_head) == int'((64'(reference_head_base) + reference_store_head) & 64'(SD - 1)) &&
              int'(dut.issue_sq_tail[0]) == int'((64'(reference_head_base) + reference_store_tail) & 64'(SD - 1)))
      else $fatal(1, "SQ indices disagree with independent store positions");
      foreach (reference_load_live[i]) begin
        if (reference_load_live[i]) begin
          remaining = reference_load_boundary[i] > reference_store_head ?
              reference_load_boundary[i] - reference_store_head : 0;
          assert (remaining <= 64'(SD) && dut.u_load_buffer.data[i].older_stores_remain == (remaining != 0))
          else $fatal(1, "older prefix lost or resurrected after SQ wrap");
          assert (int'(dut.u_load_buffer.data[i].saved_tail_idx) ==
                  int'((64'(reference_head_base) + reference_load_boundary[i]) & 64'(SD - 1)))
          else $fatal(1, "load's saved store boundary changed");
        end
      end

      if (dut.u_load_buffer.result_fire) reference_load_live[dut.u_load_buffer.result_idx] = 0;
      if (dut.sq_removed) reference_store_head++;
      load_lane = 0;
      for (int k = 0; k < LSU_WIDTH; k++) begin
        if (dut.fifo_valid[k] && dut.fifo_pop_ready[k]) begin
          if (dut.fifo_payload_out[k].width inside {S_BYTE, S_HALFWORD, S_WORD, S_DOUBLEWORD}) reference_store_tail++;
          else begin
            reference_load_live[dut.u_load_buffer.new_idx[load_lane]] = 1;
            reference_load_boundary[dut.u_load_buffer.new_idx[load_lane]] = reference_store_tail;
            load_lane++;
          end
        end
      end
    end
  end

  function automatic int size_of(ldst_width_t op);
    case (op)
      L_BYTE, L_BYTE_U, S_BYTE:             return 1;
      L_HALFWORD, L_HALFWORD_U, S_HALFWORD: return 2;
      L_WORD, L_WORD_U, S_WORD:             return 4;
      default:                              return 8;
    endcase
  endfunction
  function automatic logic [63:0] extend_value(logic [63:0] value, ldst_width_t op);
    case (op)
      L_BYTE:       return {{56{value[7]}}, value[7:0]};
      L_BYTE_U:     return {56'b0, value[7:0]};
      L_HALFWORD:   return {{48{value[15]}}, value[15:0]};
      L_HALFWORD_U: return {48'b0, value[15:0]};
      L_WORD:       return {{32{value[31]}}, value[31:0]};
      L_WORD_U:     return {32'b0, value[31:0]};
      default:      return value;
    endcase
  endfunction
  function automatic logic [63:0] reference_load(int offset, ldst_width_t op);
    logic [63:0] value = '0;
    for (int b = 0; b < size_of(op); b++) value[b*8+:8] = architectural[offset+b];
    return extend_value(value, op);
  endfunction
  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  always_comb begin
    chosen = -1;
    // Highest tag first deliberately permits a younger request to respond first.
    for (int t = 0; t < Tags; t++) if (pending[t] && pending_delay[t] == 0) chosen = t;
    load_rsp      = release_reads && chosen >= 0;
    load_rsp_tag  = chosen >= 0 ? tag_t'(chosen) : '0;
    load_rdata    = chosen >= 0 ? pending_data[chosen] : '0;
    load_fault    = chosen >= 0 && pending_fault[chosen];
    store_rsp     = release_stores && write_pending && write_remaining == 0;
    store_rsp_tag = write_tag;
    store_fault   = write_fault;
  end

  // Independent byte-addressed memory. Writes become visible only when their
  // response is consumed, exercising the required read-after-write ordering.
  always @(posedge clk) begin : memory_and_scoreboard
    logic [63:0] value;
    int          offset;
    if (!rst_n) begin
      foreach (pending[t]) begin
        pending[t]       = 0;
        pending_delay[t] = 0;
        pending_data[t]  = 0;
        pending_fault[t] = 0;
        pending_order[t] = 0;
      end
      write_pending     = 0;
      write_tag         = '0;
      write_remaining   = 0;
      write_fault       = 0;
      write_addr        = 0;
      write_data        = 0;
      write_be          = 0;
      reads             = 0;
      writes            = 0;
      load_completions  = 0;
      store_completions = 0;
      reordered         = 0;
      multi_accepts     = 0;
      store_order.delete();
      foreach (expected_valid[t]) begin
        expected_valid[t] = 0;
        seen[t]           = 0;
      end
      previous_load_stall         = 0;
      previous_store_stall        = 0;
      previous_result_stall       = 0;
      previous_store_result_stall = 0;
    end else begin
      if (flush) begin
        foreach (expected_valid[t]) expected_valid[t] = 0;
        store_order.delete();
      end
      if (load_rsp && load_rsp_ready) begin
        assert (pending[load_rsp_tag])
        else $fatal(1, "duplicate read response");
        foreach (pending[t])
        if (pending[t] && pending_order[t] < pending_order[load_rsp_tag]) reordered++;
        pending[load_rsp_tag] = 0;
      end
      if (flush && !DRAIN) foreach (pending[t]) pending[t] = 0;
      if (store_rsp && store_rsp_ready) begin
        assert (write_pending)
        else $fatal(1, "duplicate write response");
        if (!write_fault && write_addr < 'h1200)
          for (int b = 0; b < 8; b++)
          if (write_be[b]) memory[int'(write_addr-64'h1000)+b] = write_data[b*8+:8];
        write_pending = 0;
      end
      foreach (pending[t]) if (pending[t] && pending_delay[t] > 0) pending_delay[t]--;
      if (write_remaining > 0) write_remaining--;
      if (load_req && load_ready) begin
        assert (!pending[load_tag])
        else $fatal(1, "outstanding load slot reused");
        pending[load_tag]       = 1;
        pending_delay[load_tag] = read_delay;
        pending_order[load_tag] = reads++;
        pending_fault[load_tag] = load_addr == 64'h11f0 || (load_addr & Cfg.MMAP_MASK) != 0;
        value                   = 0;
        offset                  = int'(load_addr - 64'h1000);
        assert (pending_fault[load_tag] || (offset >= 0 && offset <= 504))
        else $fatal(1, "bad memory read address %h", load_addr);
        for (int b = 0; b < 8; b++)
        if (!pending_fault[load_tag] && (ALIGNED_READ || load_be[b]))
          value[b*8+:8] = memory[offset+b];
        pending_data[load_tag] = value;
      end
      if (store_req && store_ready) begin
        assert (permission && !flush && !write_pending)
        else $fatal(1, "unauthorized or multiple outstanding writes");
        assert (store_order.size() > 0 && permission_idx == rob_idx_t'(store_order[0]))
        else $fatal(1, "store request reordered");
        write_pending   = 1;
        write_remaining = write_delay;
        write_tag       = store_tag;
        write_addr      = store_addr;
        write_data      = store_wdata;
        write_be        = store_be;
        write_fault     = store_addr == 64'h11f8;
        writes++;
      end
      if (!flush) begin
        if ($countones(grant) > 1) multi_accepts++;
        for (int i = 0; i < IW; i++)
        if (grant[i]) begin
          assert (!expected_valid[rob[i]])
          else $fatal(1, "test reused live ROB tag");
          expected_valid[rob[i]] = 1;
          expected_store[rob[i]] = is_store[i];
          expected_fault[rob[i]] = lane_fault[i];
          expected_value[rob[i]] = lane_value[i];
          expected_code[rob[i]]  = lane_code[i];
          seen[rob[i]]           = 0;
          if (is_store[i]) store_order.push_back(int'(rob[i]));
        end
        if (load_result_valid && load_result_ready) check_result(load_result, 0);
        if (store_result_valid && store_result_ready) begin
          check_result(store_result, 1);
          assert (store_order.size() > 0 && store_order.pop_front() == int'(store_result.rob_idx))
          else $fatal(1, "store completion reordered");
        end
        if (previous_load_stall)
          assert (load_req && {load_addr,load_be,load_tag} == {previous_load_addr,previous_load_be,previous_load_tag})
          else $fatal(1, "unstable read request");
        if (previous_store_stall)
          assert (store_req && {store_addr,store_wdata,store_be,store_tag} == {previous_store_addr,previous_store_data,previous_store_be,previous_store_tag})
          else $fatal(1, "unstable write request");
        if (previous_result_stall)
          assert (load_result_valid)
          else $fatal(1, "load completion withdrawn before acceptance");
      end
      if (!flush && previous_store_result_stall)
        assert (store_result_valid && store_result == previous_store_result)
        else $fatal(1, "unstable store result");
      previous_store_result_stall = !flush && store_result_valid && !store_result_ready;
      previous_store_result       = store_result;
      previous_load_stall         = !flush && load_req && !load_ready;
      previous_load_addr          = load_addr;
      previous_load_be            = load_be;
      previous_load_tag           = load_tag;
      previous_store_stall        = !flush && store_req && !store_ready;
      previous_store_addr         = store_addr;
      previous_store_data         = store_wdata;
      previous_store_be           = store_be;
      previous_store_tag          = store_tag;
      previous_result_stall       = !flush && load_result_valid && !load_result_ready;
      previous_result             = load_result;
    end
  end
  task automatic check_result(result_t result, bit store);
    assert (expected_valid[result.rob_idx] && expected_store[result.rob_idx] == store)
    else $fatal(1, "unexpected/stale result ROB=%0d", result.rob_idx);
    assert (result.except_raised == expected_fault[result.rob_idx])
    else $fatal(1, "wrong exception ROB=%0d", result.rob_idx);
    if (result.except_raised)
      assert (result.except_code == expected_code[result.rob_idx])
      else $fatal(1, "wrong exception cause");
    if (!store || result.except_raised)
      assert (result.res_value == expected_value[result.rob_idx])
      else
        $fatal(
            1,
            "ROB=%0d got=%h expected=%h",
            result.rob_idx,
            result.res_value,
            expected_value[result.rob_idx]
        );
    expected_valid[result.rob_idx] = 0;
    seen[result.rob_idx]           = 1;
    if (store) store_completions++;
    else load_completions++;
  endtask
  task automatic cycles(int count);
    repeat (count) @(negedge clk);
  endtask
  task automatic reset_dut();
    rst_n           = 0;
    flush           = 0;
    request         = '0;
    is_store        = '0;
    broadcast_valid = 0;
    permission      = 1;
    accept_load     = 1;
    accept_store    = 1;
    load_ready      = 1;
    store_ready     = 1;
    release_reads   = 1;
    release_stores  = 1;
    read_delay      = 3;
    write_delay     = 5;
    foreach (memory[b]) begin
      memory[b]        = 8'(b);
      architectural[b] = 8'(b);
    end
    cycles(3);
    rst_n = 1;
    cycles(1);
  endtask
  task automatic lane(int i, bit store, int id, logic [63:0] address, logic [63:0] value,
                      ldst_width_t op = L_DOUBLEWORD, bit address_ready = 1, bit data_ready = 1,
                      bit fault = 0, except_code_t code = E_UNKNOWN);
    request[i]  = 1;
    is_store[i] = store;
    rob[i]      = rob_idx_t'(id);
    if (store) begin
      case (size_of(
          op
      ))
        1:       width[i] = S_BYTE;
        2:       width[i] = S_HALFWORD;
        4:       width[i] = S_WORD;
        8:       width[i] = S_DOUBLEWORD;
        default: $fatal(1, "invalid store width");
      endcase
    end else width[i] = op;
    rs1[i]        = '{address_ready, rob_idx_t'(60), address};
    rs2[i]        = '{data_ready, rob_idx_t'(61), value};
    imm[i]        = '0;
    lane_value[i] = store && fault ? address : value;
    lane_fault[i] = fault;
    lane_code[i]  = code;
  endtask
  task automatic send_bundle();
    logic [IW-1:0] accepted;
    int            watchdog = 0;
    do begin
      @(posedge clk);
      accepted = grant;
      @(negedge clk);
      // The issue queue removes accepted lanes before the router packs again.
      for (int i = 0; i < IW; i++) begin
        if (i + $countones(accepted) < IW) begin
          request[i]    = request[i+$countones(accepted)];
          is_store[i]   = is_store[i+$countones(accepted)];
          width[i]      = width[i+$countones(accepted)];
          rs1[i]        = rs1[i+$countones(accepted)];
          rs2[i]        = rs2[i+$countones(accepted)];
          imm[i]        = imm[i+$countones(accepted)];
          rob[i]        = rob[i+$countones(accepted)];
          lane_value[i] = lane_value[i+$countones(accepted)];
          lane_fault[i] = lane_fault[i+$countones(accepted)];
          lane_code[i]  = lane_code[i+$countones(accepted)];
        end else request[i] = 1'b0;
      end
      watchdog++;
      assert (watchdog < 500)
      else $fatal(1, "issue deadlock req=%b", request);
    end while (request != 0);
  endtask
  task automatic issue(bit store, int id, logic [63:0] address, logic [63:0] value,
                       ldst_width_t op = L_DOUBLEWORD, bit address_ready = 1, bit data_ready = 1,
                       bit fault = 0, except_code_t code = E_UNKNOWN);
    lane(0, store, id, address, value, op, address_ready, data_ready, fault, code);
    send_bundle();
  endtask
  task automatic await_result(int id);
    for (int n = 0; n < 500; n++) begin
      if (seen[id]) return;
      cycles(1);
    end
    $fatal(1, "result deadlock ROB=%0d", id);
  endtask
  task automatic drain();
    bit live;
    for (int n = 0; n < 1000; n++) begin
      live = write_pending || ($countones(dut.u_store_buffer.occupied_slots) != 0);
      foreach (expected_valid[i]) live |= expected_valid[i];
      foreach (pending[i]) live |= pending[i];
      if (!live) begin
        cycles(2);
        return;
      end
      cycles(1);
    end
    $fatal(1, "drain deadlock");
  endtask
  task automatic wake(int id, logic [63:0] value);
    broadcast           = '0;
    broadcast.rob_idx   = rob_idx_t'(id);
    broadcast.res_value = value;
    broadcast_valid     = 1;
    cycles(1);
    broadcast_valid = 0;
  endtask
  task automatic pipeline_flush();
    flush = 1;
    cycles(1);
    flush = 0;
  endtask
  initial begin : scenarios
    int before_reads, before_writes;
    logic [63:0] value, address;
    ldst_width_t op;
    request    = '0;
    is_store   = '0;
    rs1        = '0;
    rs2        = '0;
    width      = '0;
    rob        = '0;
    imm        = '0;
    broadcast  = '0;
    lane_fault = '0;
    lane_code  = '0;
    lane_value = '0;
    assert (ConfigValid)
    else $fatal(1, "invalid test configuration");
    if ($value$plusargs("SEED=%d", random_seed)) rng = unsigned'(random_seed);
    cycles(1);

    // Precise write: permission, delayed B, stable completion, and no younger
    // request while the first completion is backpressured.
    reset_dut();
    permission     = 0;
    release_stores = 0;
    accept_store   = 0;
    issue(1, 1, 'h1000, 64'h89abcdef);
    if (SD > 1) issue(1, 2, 'h1008, 'h42);
    cycles(8);
    assert (writes == 0)
    else $fatal(1, "speculative write");
    permission = 1;
    cycles(8);
    assert (writes == 1 && int'($countones(dut.u_store_buffer.occupied_slots)) == (SD > 1 ? 2 : 1))
    else $fatal(1, "store released at send");
    release_stores = 1;
    cycles(8);
    assert (writes == 1 && store_result_valid && int'($countones(dut.u_store_buffer.occupied_slots)) == (SD > 1 ? 2 : 1))
    else $fatal(1, "store released at response");
    accept_store = 1;
    drain();
    assert (writes == (SD > 1 ? 2 : 1))
    else $fatal(1, "lost write");

    // Pending, MEM_WAIT, and COMPLETED stores all remain forwarding sources.
    for (int phase = 0; phase < 3; phase++) begin
      for (int w = 0; w < 7; w++) begin
        reset_dut();
        permission     = phase != 0;
        release_stores = phase == 2;
        accept_store   = 0;
        if (phase == 2) accept_load = 0;
        issue(1, 1, 'h1000, 64'h88776655aa99eeff);
        cycles(10);
        op = ldst_width_t'(w);
        address = 64'h1000 + (op inside {L_BYTE, L_BYTE_U} ? 3 : op inside {L_HALFWORD, L_HALFWORD_U} ? 2 : 0);
        if (phase == 2) address = 64'h1008 - 64'(size_of(op));
        value = extend_value(64'h88776655aa99eeff >> ((address - 'h1000) * 8), op);
        issue(0, 10 + w, address, value, op);
        if (FWD && phase != 2) await_result(10 + w);
        else if (FWD) begin
          // Both completion channels retain their results while the store is stalled.
          for (int n = 0; n < 500 && !load_result_valid; n++) cycles(1);
          assert (load_result_valid && load_result.rob_idx == rob_idx_t'(10 + w) &&
                  load_result.res_value == value && reads == 0)
          else $fatal(1, "forwarding from completed store did not finish behind stalled CDB");
          assert (dut.u_load_buffer.data[0].rs1_value == 64'h88776655aa99eeff &&
                  dut.u_load_buffer.data[0].byte_offset == address[2:0])
          else $fatal(1, "forwarding did not retain raw store data and its byte offset");
        end
        permission     = 1;
        release_stores = 1;
        accept_store   = 1;
        accept_load    = 1;
        await_result(10 + w);
        if (FWD)
          assert (reads == 0)
          else $fatal(1, "resident-store forwarding used memory");
        drain();
      end
    end

    // Partial youngest overlap must hide an older full match; no byte merging.
    if (SD >= 2) begin
      reset_dut();
      permission = 0;
      issue(1, 1, 'h1000, 64'h0102030405060708);
      issue(1, 2, 'h1002, 'haa, L_BYTE);
      issue(0, 3, 'h1000, 64'h0102030405aa0708);
      cycles(10);
      assert (!seen[3] && reads == 0)
      else $fatal(1, "partial younger overlap bypassed");
      permission = 1;
      drain();
      assert (reads == 1)
      else $fatal(1, "partial load did not retry memory once");
    end

    // Equal head/boundary indices represent a full older prefix when the flag is set.
    if (SD < 64) begin
      reset_dut();
      permission = 0;
      accept_load = 0;
      for (int i = 0; i < SD; i++) issue(1, i + 1, 'h1000, 64'(i + 1));
      issue(0, SD + 1, 'h1000, 64'(SD));
      cycles(SD + 6);
      assert (int'($countones(dut.u_store_buffer.occupied_slots)) == SD && dut.sq_head == dut.issue_sq_tail[0] &&
              dut.u_load_buffer.data[0].saved_tail_idx == dut.sq_head &&
              dut.u_load_buffer.data[0].older_stores_remain)
      else $fatal(1, "full older-store prefix mistaken for an empty prefix");
      permission = 1;
      await_result(1);
      assert (dut.u_load_buffer.data[0].older_stores_remain == (SD > 1))
      else $fatal(1, "older prefix cleared before the last older store");
      for (int i = 1; i < SD; i++) await_result(i + 1);
      assert (!dut.u_load_buffer.data[0].older_stores_remain)
      else $fatal(1, "last older store did not clear the prefix");
      accept_load = 1;
      drain();
    end

    // A stalled load with no older stores must ignore new stores through repeated SQ wraps.
    reset_dut();
    release_reads = 0;
    issue(0, 1, 'h1000, reference_load(0, L_DOUBLEWORD));
    cycles(8);
    assert (reads == 1 && !seen[1] && !dut.u_load_buffer.data[0].older_stores_remain &&
            dut.u_load_buffer.data[0].saved_tail_idx == dut.sq_head)
    else $fatal(1, "empty store prefix was not captured");
    for (int i = 0; i < 2 * SD + 2; i++) begin
      issue(1, 2, 'h1080, 64'(i));
      await_result(2);
      assert (!seen[1] && !dut.u_load_buffer.data[0].older_stores_remain &&
              int'(dut.u_load_buffer.data[0].saved_tail_idx) == 0)
      else $fatal(1, "SQ wrap revived a younger-store dependency");
    end
    release_reads = 1;
    drain();

    // Interleaved accepted lanes: each boundary includes same-bundle older stores.
    if (IW >= 4 && LSU_WIDTH >= 4 && SD >= 3 && LD >= 2) begin
      reset_dut();
      permission = 0;
      accept_load = 0;
      issue(1, 1, 'h1040, 'h90);
      lane(0, 1, 2, 'h1000, 10);
      lane(1, 0, 3, 'h1000, 10);
      lane(2, 1, 4, 'h1000, 20);
      lane(3, 0, 5, 'h1000, 20);
      send_bundle();
      for (int n = 0; n < 32 &&
           !(dut.u_load_buffer.data[0].dest_rob_idx == 3 &&
             dut.u_load_buffer.data[LD > 1 ? 1 : 0].dest_rob_idx == 5); n++) cycles(1);
      assert (dut.u_load_buffer.data[0].older_stores_remain &&
              dut.u_load_buffer.data[LD > 1 ? 1 : 0].older_stores_remain &&
              int'(dut.u_load_buffer.data[0].saved_tail_idx) == 2 &&
              int'(dut.u_load_buffer.data[LD > 1 ? 1 : 0].saved_tail_idx) == 3)
      else $fatal(1, "same-bundle store boundaries");
      accept_load = 1;
      if (FWD) begin
        await_result(3);
        await_result(5);
      end
      permission = 1;
      drain();
      assert (multi_accepts > 0)
      else $fatal(1, "no multi-allocation");
      directed_multi += multi_accepts;
    end

    // Youngest full store wins; the younger-than-load store must be ignored.
    if (SD >= 3 && LD >= 1) begin
      reset_dut();
      permission = 0;
      issue(1, 1, 'h1000, 10);
      issue(1, 2, 'h1000, 20);
      issue(0, 3, 'h1000, 20);
      issue(1, 4, 'h1000, 30);
      if (FWD) await_result(3);
      permission = 1;
      drain();
    end

    // Address/data wake independently, including wakeup on allocation edge.
    reset_dut();
    permission = 0;
    issue(1, 1, 'h1000, 0, L_DOUBLEWORD, 0, 0);
    issue(0, 2, 'h1000, 'h1234);
    cycles(8);
    assert (reads == 0 && !seen[2])
    else $fatal(1, "unknown store address bypassed");
    wake(60, 'h1000);
    cycles(5);
    assert (dut.sq_addr_ready[dut.sq_head] && !dut.sq_data_ready[dut.sq_head])
    else $fatal(1, "store address waited for missing rs2");
    assert (!seen[2])
    else $fatal(1, "unresolved store data forwarded");
    wake(61, 'h1234);
    if (FWD) await_result(2);
    permission = 1;
    drain();
    reset_dut();
    broadcast           = '0;
    broadcast.rob_idx   = rob_idx_t'(60);
    broadcast.res_value = 'h1000;
    broadcast_valid     = 1;
    issue(0, 1, 0, 64'h0706050403020100, L_DOUBLEWORD, 0);
    broadcast_valid = 0;
    await_result(1);

    // Ready loads pass unresolved older loads; stalled CDB selection is stable.
    if (LD >= 2) begin
      reset_dut();
      issue(0, 1, 0, 64'h0706050403020100, L_DOUBLEWORD, 0);
      issue(0, 2, 'h1008, 64'h0f0e0d0c0b0a0908);
      await_result(2);
      assert (!seen[1])
      else $fatal(1, "unresolved load executed");
      release_reads = 0;
      issue(0, 3, 'h1010, 64'h1716151413121110);
      cycles(8);
      assert (dut.u_load_buffer.data[0].dest_rob_idx == 1 && dut.u_load_buffer.data[LD > 1 ? 1 : 0].dest_rob_idx == 3)
      else $fatal(1, "load queue did not reuse arbitrary free slot");
      release_reads = 1;
      await_result(3);
      wake(60, 'h1000);
      await_result(1);
      reset_dut();
      accept_load = 0;
      issue(0, 1, 'h1000, 64'h0706050403020100);
      cycles(10);
      issue(0, 2, 'h1008, 64'h0f0e0d0c0b0a0908);
      cycles(10);
      accept_load = 1;
      drain();
    end

    // Independent channels hold both results; accepting a store must not consume a stalled load.
    for (int flush_result = 0; flush_result < 2; flush_result++) begin
      reset_dut();
      accept_load  = 0;
      accept_store = 0;
      write_delay  = 80;
      issue(1, 1, 'h1000, 64'h8877665544332211);
      issue(0, 2, 'h1008, reference_load(8, L_DOUBLEWORD));
      for (int n = 0; n < 100 && !load_result_valid; n++) cycles(1);
      assert (load_result_valid)
      else $fatal(1, "load completion did not become valid");
      cycles(100);
      assert (store_result_valid && load_result_valid && !seen[1] && !seen[2] && $countones(dut.u_store_buffer.occupied_slots) == 1)
      else $fatal(1, "independent LSU completions were lost under backpressure");
      if (flush_result != 0) begin
        flush = 1;
        cycles(1);
        flush = 0;
        cycles(8);
        assert (!load_result_valid && !store_result_valid && $countones(dut.u_store_buffer.occupied_slots) == 0)
        else $fatal(1, "flush retained stale LSU completion");
        accept_load = 1;
        issue(0, 2, 'h1010, reference_load(16, L_DOUBLEWORD));
        await_result(2);
      end else begin
        accept_store = 1;
        await_result(1);
        assert (load_result_valid && !seen[2])
        else $fatal(1, "store handshake consumed stalled load completion");
        accept_load = 1;
        await_result(2);
      end
      drain();
    end

    // Return independent loads in reverse physical-slot order before any
    // flush, so cancellation and drain backends both exercise response routing.
    reset_dut();
    release_reads = 0;
    for (int i = 0; i < LD; i++)
    issue(0, i + 1, 'h1000 + 64'(i * 8), reference_load(i * 8, L_DOUBLEWORD));
    cycles(16);
    assert (reads == LD)
    else $fatal(1, "multiple load requests not outstanding");
    release_reads = 1;
    drain();
    if (LD > 1)
      assert (reordered > 0)
      else $fatal(1, "read response reordering not exercised");
    directed_reordered += reordered;

    // Full LQ quarantine after flush, reused ROB tags, reordered old responses.
    reset_dut();
    release_reads = 0;
    for (int i = 0; i < LD; i++)
    issue(0, i + 1, 'h1000 + 64'(i * 8), reference_load(i * 8, L_DOUBLEWORD));
    cycles(20);
    assert (reads == LD)
    else $fatal(1, "loads did not execute concurrently");
    pipeline_flush();
    cycles(2);
    if (DRAIN && !FIFO) begin
      lane(0, 0, 1, 'h1080, reference_load(128, L_DOUBLEWORD));
      cycles(1);
      assert (grant == 0)
      else $fatal(1, "killed slots reused before drain");
      request = 0;
    end
    release_reads = 1;
    cycles(LD + 8);
    if (DRAIN && LD > 1)
      assert (reordered > 0)
      else $fatal(1, "no reordered read responses exercised");
    directed_reordered += reordered;
    issue(0, 1, 'h1080, reference_load(128, L_DOUBLEWORD));
    drain();

    // Fill the circular SQ and, when configured, its allocation FIFO. A load
    // behind a blocked store must not pass even though the LQ is empty.
    reset_dut();
    permission = 0;
    for (int i = 0; i < SD + (FIFO ? 16 : 0); i++) issue(1, i + 1, 'h1000, 64'(i));
    cycles(5);
    lane(0, 1, 40, 'h1000, 'h99);
    if (IW > 1) lane(1, 0, 41, 'h1000, 'h99);
    cycles(2);
    assert (grant == 0)
    else $fatal(1, "full SQ did not block younger load");
    request    = '0;
    permission = 1;
    drain();

    // An address fault completes without rs2; a later CDB must not revive that operand.
    reset_dut();
    accept_store = 0;
    permission   = 0;
    issue(1, 1, 'h1001, 0, L_DOUBLEWORD, 1, 0, 1, E_ST_ADDR_MISALIGNED);
    cycles(10);
    assert (store_result_valid && store_result.except_raised &&
            store_result.except_code == E_ST_ADDR_MISALIGNED && store_result.res_value == 'h1001 &&
            dut.sq_data_ready[0] && writes == 0)
    else $fatal(1, "store address fault waited for unresolved rs2 or lost its result");
    wake(61, 'hfeed);
    assert (store_result_valid && dut.sq_data[0] == 0 && writes == 0)
    else $fatal(1, "completed address fault accepted a late operand wakeup");
    // Forwarding can complete speculatively while the older store awaits fault delivery.
    if (FWD) begin
      issue(0, 2, 'h1001, 0, L_BYTE_U);
      await_result(2);
      assert (store_result_valid && store_result.except_raised && reads == 0 && writes == 0)
      else $fatal(1, "younger load did not forward independently of the store fault");
    end
    accept_store = 1;
    drain();

    // The combined enum command must capture the address and wake rs2 together.
    reset_dut();
    permission = 0;
    issue(1, 1, 0, 0, L_DOUBLEWORD, 0, 0);
    cycles(FIFO ? 2 : 0);
    wake(60, 'h1000);
    #1;
    for (int n = 0; n < 20 && !dut.adder_sb_valid; n++) begin
      cycles(1);
      #1;
    end
    assert (dut.adder_sb_valid)
    else $fatal(1, "address response missing in concurrent-wakeup test");
    broadcast           = '0;
    broadcast.rob_idx   = rob_idx_t'(61);
    broadcast.res_value = 'h8877665544332211;
    broadcast_valid     = 1;
    #1;
    assert (dut.adder_sb_valid && dut.adder_sb_ans.tag == 0 && !dut.sq_data_ready[0] &&
            dut.u_store_buffer.data[0].rs2_rob_idx == broadcast.rob_idx)
    else $fatal(1, "test did not exercise simultaneous address and rs2 operations");
    cycles(1);
    broadcast_valid = 0;
    #1;
    assert (dut.sq_addr_ready[0] && dut.sq_data_ready[0] && dut.sq_addr[0] == 'h1000 &&
            dut.sq_data[0] == 'h8877665544332211 && writes == 0)
    else $fatal(1, "concurrent address capture or operand wakeup was lost");
    permission = 1;
    drain();

    // Store removal and load response capture update independent fields together.
    reset_dut();
    accept_store  = 0;
    release_reads = 0;
    issue(1, 1, 'h1000, 'h1234);
    issue(0, 2, 'h100f, reference_load(15, L_BYTE_U), L_BYTE_U);
    cycles(20);
    assert (store_result_valid && reads == 1 && !seen[2])
    else $fatal(1, "concurrent dependency-clear test did not reach held responses");
    accept_store  = 1;
    release_reads = 1;
    #1;
    assert (dut.sq_removed && load_rsp && load_rsp_tag == 0 &&
            dut.u_load_buffer.data[0].older_stores_remain)
    else $fatal(1, "test did not exercise simultaneous dependency and memory operations");
    cycles(1);
    #1;
    assert (!dut.u_load_buffer.data[0].older_stores_remain &&
            dut.u_load_buffer.data[0].rs1_value == (ALIGNED_READ ? 64'h0f0e0d0c0b0a0908 : 64'h0f) &&
            dut.u_load_buffer.data[0].byte_offset == (ALIGNED_READ ? 3'd7 : 3'd0))
    else $fatal(1, "concurrent boundary completion or response capture was lost");
    drain();

    // A disjoint load can execute before older stores resolve their data,
    // once all their addresses are known.
    reset_dut();
    permission = 0;
    issue(1, 1, 'h1000, 0, L_DOUBLEWORD, 1, 0);
    cycles(5);
    issue(0, 2, 'h1008, reference_load(8, L_DOUBLEWORD));
    await_result(2);
    assert (writes == 0)
    else $fatal(1, "store with unresolved data wrote memory");
    wake(61, 'h1234);
    permission = 1;
    drain();

    // Flushing unresolved operands and address dependencies releases all
    // speculative entries, independent of free-slot and pointer positions.
    reset_dut();
    issue(1, 1, 0, 0, L_DOUBLEWORD, 0, 0);
    issue(0, 2, 0, 0, L_DOUBLEWORD, 0);
    cycles(5);
    pipeline_flush();
    wake(60, 'h1000);
    wake(61, 'h12);
    cycles(8);
    assert (writes == 0 && reads == 0 && $countones(dut.u_store_buffer.occupied_slots) == 0)
    else $fatal(1, "flushed dependency executed");
    issue(0, 1, 'h1000, reference_load(0, L_DOUBLEWORD));
    drain();

    // Response plus flush on the same edge consumes ownership exactly once.
    reset_dut();
    release_reads = 0;
    issue(0, 1, 'h1000, reference_load(0, L_DOUBLEWORD));
    cycles(8);
    release_reads = 1;
    pipeline_flush();
    cycles(5);
    assert (load_completions == 0)
    else $fatal(1, "flush-edge response broadcast");
    issue(0, 1, 'h1008, reference_load(8, L_DOUBLEWORD));
    drain();
    reset_dut();
    release_stores = 0;
    issue(1, 1, 'h1000, 'h7788);
    cycles(10);
    release_stores = 1;
    pipeline_flush();
    cycles(6);
    assert ($countones(dut.u_store_buffer.occupied_slots) == 0 && store_completions == 0)
    else $fatal(1, "flush-edge write response lost");
    issue(0, 1, 'h1000, 'h7788);
    drain();

    // MMIO values must never be supplied by store forwarding. The native
    // memory contract permits the output store and faults the subsequent read.
    reset_dut();
    permission = 0;
    issue(1, 1, 'h20000000, 'habcd);
    issue(0, 2, 'h20000000, 'h20000000, L_DOUBLEWORD, 1, 1, 1, E_LD_ACCESS_FAULT);
    cycles(10);
    assert (!seen[2] && reads == 0)
    else $fatal(1, "MMIO access forwarded");
    permission = 1;
    drain();
    assert (reads == 1)
    else $fatal(1, "MMIO read did not reach adapter");

    // Allocation concurrent with head removal uses the post-removal prefix.
    if (!FIFO && IW >= 2 && SD >= 2) begin
      reset_dut();
      accept_store = 0;
      issue(1, 1, 'h1000, 'h22);
      cycles(12);
      assert (store_result_valid)
      else $fatal(1, "store completion missing");
      lane(0, 1, 2, 'h1008, 'h33);
      lane(1, 0, 3, 'h1008, 'h33);
      accept_store = 1;
      send_bundle();
      assert (dut.u_load_buffer.data[0].older_stores_remain &&
              int'(dut.u_load_buffer.data[0].saved_tail_idx) == (2 & (SD - 1)))
      else $fatal(1, "head removal plus allocation boundary");
      drain();
    end

    // Faults preserve full faulting addresses and stable ROB identity.
    reset_dut();
    issue(0, 1, 'h11f0, 'h11f0, L_DOUBLEWORD, 1, 1, 1, E_LD_ACCESS_FAULT);
    await_result(1);
    issue(0, 2, 'h1001, 'h1001, L_WORD, 1, 1, 1, E_LD_ADDR_MISALIGNED);
    await_result(2);
    accept_store = 0;
    issue(1, 3, 'h11f8, 0, L_DOUBLEWORD, 1, 1, 1, E_ST_ACCESS_FAULT);
    cycles(20);
    assert (store_result_valid && store_result.rob_idx == 3 && store_result.except_raised &&
            store_result.except_code == E_ST_ACCESS_FAULT && store_result.res_value == 'h11f8 && $countones(dut.u_store_buffer.occupied_slots) == 1)
    else $fatal(1, "store fault not retained under result backpressure");
    accept_store = 1;
    await_result(3);
    issue(1, 4, 'h1001, 0, L_HALFWORD, 1, 1, 1, E_ST_ADDR_MISALIGNED);
    await_result(4);
    assert (writes == 1 && reads == 1)
    else $fatal(1, "misaligned operation accessed memory");

    // Flush retains non-cancelable writes but suppresses stale completions.
    for (int completed = 0; completed < 2; completed++) begin
      reset_dut();
      accept_store   = 0;
      release_stores = completed != 0;
      issue(1, 1, 'h1000, 'h55);
      cycles(15);
      assert (writes == 1)
      else $fatal(1, "missing accepted write");
      pipeline_flush();
      assert ($countones(dut.u_store_buffer.occupied_slots) == 1)
      else $fatal(1, "flush dropped non-cancelable write");
      release_stores = 1;
      accept_store   = 1;
      cycles(10);
      assert ($countones(dut.u_store_buffer.occupied_slots) == 0 && store_completions == 0)
      else $fatal(1, "stale store completion after flush");
      issue(0, 1, 'h1000, 'h55);
      drain();
    end

    // Random ordered issue and byte reference, with repeated SQ wrap, full
    // queues, response reordering, sparse bundles, and independent stalls.
    reset_dut();
    for (int batch = 0; batch < 100; batch++) begin
      for (int i = 0; i < IW; i++) begin
        bit store;
        int offset;
        store  = (random_word() % 3) != 0;
        op     = ldst_width_t'(random_word() % 7);
        offset = int'(random_word() % 32) * 8;
        offset += int'(random_word() % unsigned'(8 / size_of(op))) * size_of(op);
        value = {random_word(), random_word()};
        if (store) begin
          for (int b = 0; b < size_of(op); b++) architectural[offset+b] = value[b*8+:8];
        end else value = reference_load(offset, op);
        lane(i, store, i + 1, 'h1000 + 64'(offset), value, op);
      end
      load_ready   = (batch % 3) != 0;
      store_ready  = (batch % 4) != 0;
      accept_load  = (batch % 5) != 0;
      accept_store = (batch % 6) != 0;
      read_delay   = batch % 7;
      write_delay  = batch % 9;
      // Capacity may block a bundle; release stalls before waiting for grants.
      if (IW <= LD && IW <= SD && (!FIFO || LSU_WIDTH == IW)) begin
        fork
          begin
            cycles(8);
            load_ready   = 1;
            store_ready  = 1;
            accept_load  = 1;
            accept_store = 1;
          end
          send_bundle();
        join
      end else begin
        load_ready   = 1;
        store_ready  = 1;
        accept_load  = 1;
        accept_store = 1;
        send_bundle();
      end
      drain();
    end
    before_reads  = reads;
    before_writes = writes;
    $write("PASS LSU IW=%0d LSU_WIDTH=%0d LB_WIDTH=%0d SB_WIDTH=%0d LQ=%0d SQ=%0d ",
           IW, LSU_WIDTH, LB_WIDTH, SB_WIDTH, LD, SD);
    $display(
        "fifo=%0d fwd=%0d aligned=%0d spill=%0d drain=%0d seed=%0d reads=%0d writes=%0d multi=%0d reordered=%0d",
        FIFO, FWD, ALIGNED_READ, SPILL, DRAIN, random_seed, before_reads,
        before_writes, multi_accepts + directed_multi, reordered + directed_reordered);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "test timeout");
  end
endmodule
