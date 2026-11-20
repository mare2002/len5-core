// Copyright 2026 Politecnico di Torino.
// SPDX-License-Identifier: SHL-2.0
`include "len5_typedef.svh"
module lsu_issue_route_tb #(
  parameter int LSU_WIDTH = 4,
  parameter int LB_WIDTH = 2,
  parameter int SB_WIDTH = 1,
  parameter bit FIFO = 0
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  localparam int IssueWidth = 8;
  localparam int Depth = 8;
  localparam int Records = 32;
  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = IssueWidth;
    cfg.LSU_ISSUE_WIDTH = LSU_WIDTH;
    cfg.LDBUFF_ISSUE_WIDTH = LB_WIDTH;
    cfg.STBUFF_ISSUE_WIDTH = SB_WIDTH;
    cfg.LDBUFF_DEPTH = Depth;
    cfg.STBUFF_DEPTH = Depth;
    cfg.LSU_USE_FIFO = FIFO;
    cfg.LSU_FIFO_DEPTH = 16;
    cfg.ROB_DEPTH = 64;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  localparam bit ConfigValid = check_build(Cfg);
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  typedef struct packed {
    logic store;
    ldst_width_t op;
    rob_idx_t rob;
    operand_t rs1;
    operand_t rs2;
    logic [63:0] imm;
  } instruction_t;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic [IssueWidth-1:0] issue_valid = '0, issue_ready;
  eu_ctl_t [IssueWidth-1:0] ctl;
  operand_t [IssueWidth-1:0] rs1, rs2;
  rob_idx_t [IssueWidth-1:0] rob;
  logic [IssueWidth-1:0][63:0] imm;
  logic load_result_valid, store_result_valid;
  instruction_t records[Records];
  instruction_t expected_load[Depth], expected_store[Depth];
  int expected_boundary[Depth];
  int submitted = 0, consumed = 0, load_count = 0, store_count = 0;
  int transfers = 0, multi_transfers = 0;

  load_store_unit #(.Len5Cfg(Cfg)) dut (
    .clk_i(clk),
    .rst_ni(rst_n),
    .mis_flush_i(flush),
    .except_flush_i('0),
    .issue_valid_i(issue_valid),
    .issue_ready_o(issue_ready),
    .issue_eu_ctl_i(ctl),
    .issue_rs1_i(rs1),
    .issue_rs2_i(rs2),
    .issue_imm_i(imm),
    .issue_dest_rob_idx_i(rob),
    .comm_sb_mem_clear_i('0),
    .comm_sb_mem_idx_o(),
    .cdb_valid_i('0),
    .cdb_lb_ready_i('0),
    .cdb_sb_ready_i('0),
    .cdb_lb_valid_o(load_result_valid),
    .cdb_sb_valid_o(store_result_valid),
    .cdb_data_i('0),
    .cdb_lb_data_o(),
    .cdb_sb_data_o(),
    .mem_load_valid_o(),
    .mem_load_ready_i('0),
    .mem_load_valid_i('0),
    .mem_load_ready_o(),
    .mem_load_we_o(),
    .mem_load_addr_o(),
    .mem_load_be_o(),
    .mem_load_tag_o(),
    .mem_load_rdata_i('0),
    .mem_load_tag_i('0),
    .mem_load_except_raised_i('0),
    .mem_load_except_code_i('0),
    .mem_store_valid_o(),
    .mem_store_ready_i('0),
    .mem_store_valid_i('0),
    .mem_store_ready_o(),
    .mem_store_we_o(),
    .mem_store_addr_o(),
    .mem_store_be_o(),
    .mem_store_wdata_o(),
    .mem_store_tag_o(),
    .mem_store_tag_i('0),
    .mem_store_except_raised_i('0),
    .mem_store_except_code_i('0)
  );

  function automatic instruction_t instruction(int index, bit store);
    instruction_t result;
    result.store = store;
    case (index % 4)
      0: result.op = store ? S_BYTE : L_BYTE_U;
      1: result.op = store ? S_HALFWORD : L_HALFWORD_U;
      2: result.op = store ? S_WORD : L_WORD_U;
      default: result.op = store ? S_DOUBLEWORD : L_DOUBLEWORD;
    endcase
    result.rob = rob_idx_t'(index + 1);
    result.rs1 = '{ready: 1'b1, rob_idx: rob_idx_t'(32 + index), value: 64'h1000 + 64'(64*index)};
    result.rs2 = '{ready: 1'b1, rob_idx: rob_idx_t'(index), value: 64'hca00 + 64'(index)};
    result.imm = (64'(index) + 64'd1) << 3;
    return result;
  endfunction

  // Independent stream model: accept only the capacity- and quota-limited prefix.
  always @(posedge clk) begin
    int offered, loads, stores;
    bit blocked, accept;
    instruction_t expected;
    if (!rst_n || flush) begin
      consumed = 0;
      load_count = 0;
      store_count = 0;
    end else begin
      offered = consumed;
      loads = 0;
      stores = 0;
      blocked = 0;
      for (int k = 0; k < LSU_WIDTH; k++) begin
        if (dut.fifo_valid[k]) begin
          assert (offered < submitted) else $fatal(1, "FIFO produced an unsubmitted instruction");
          expected = records[offered];
          assert (dut.fifo_payload_out[k].rob == expected.rob && dut.fifo_payload_out[k].width == expected.op)
          else $fatal(1, "FIFO instruction order changed");
          if (expected.store) accept = !blocked && stores < SB_WIDTH && store_count < Depth;
          else accept = !blocked && loads < LB_WIDTH && load_count < Depth;
          assert (dut.fifo_pop_ready[k] == accept)
          else $fatal(1, "incorrect allocation prefix at lane %0d: expected ready=%0b", k, accept);
          if (accept) begin
            if (expected.store) begin
              expected_store[store_count] = expected;
              store_count++;
              stores++;
            end else begin
              expected_load[load_count] = expected;
              expected_boundary[load_count] = store_count;
              load_count++;
              loads++;
            end
            consumed++;
          end else blocked = 1;
          offered++;
        end
      end
      transfers += loads + stores;
      if (loads + stores > 1) multi_transfers++;
      #1;
      assert (!load_result_valid && !store_result_valid)
      else $fatal(1, "unanswered memory access completed");
      assert ($countones(dut.u_load_buffer.free_slots) == Depth - load_count &&
              $countones(dut.u_store_buffer.occupied_slots) == store_count)
      else $fatal(1, "allocation lost or duplicated an instruction");
      assert (dut.sq_head == 0 && int'(dut.issue_sq_tail[0]) == (store_count & (Depth - 1)))
      else $fatal(1, "incorrect SQ pointer progression");
      for (int i = 0; i < load_count; i++) begin
        assert (dut.u_load_buffer.data[i].dest_rob_idx == expected_load[i].rob &&
                dut.u_load_buffer.data[i].load_type == expected_load[i].op &&
                dut.u_load_buffer.data[i].rs1_rob_idx == expected_load[i].rs1.rob_idx &&
                dut.u_load_buffer.data[i].rs1_value == expected_load[i].rs1.value)
        else $fatal(1, "load one-hot payload mux corrupted entry %0d", i);
        assert (dut.u_load_buffer.data[i].imm_addr_value == expected_load[i].imm ||
                dut.u_load_buffer.data[i].imm_addr_value == expected_load[i].rs1.value + expected_load[i].imm)
        else $fatal(1, "load immediate/address corrupted");
        assert (int'(dut.u_load_buffer.data[i].saved_tail_idx) == (expected_boundary[i] & (Depth - 1)) &&
                dut.u_load_buffer.data[i].older_stores_remain == (expected_boundary[i] != 0))
        else $fatal(1, "incorrect load boundary in entry %0d", i);
      end
      for (int i = 0; i < store_count; i++) begin
        assert (dut.u_store_buffer.data[i].dest_rob_idx == expected_store[i].rob &&
                dut.u_store_buffer.data[i].store_type == expected_store[i].op &&
                dut.u_store_buffer.data[i].rs1_rob_idx == expected_store[i].rs1.rob_idx &&
                dut.u_store_buffer.data[i].rs1_value == expected_store[i].rs1.value &&
                dut.u_store_buffer.data[i].rs2_rob_idx == expected_store[i].rs2.rob_idx &&
                dut.u_store_buffer.data[i].rs2_value == expected_store[i].rs2.value)
        else $fatal(1, "store one-hot payload mux corrupted entry %0d", i);
        assert (dut.u_store_buffer.data[i].imm_addr_value == expected_store[i].imm ||
                dut.u_store_buffer.data[i].imm_addr_value == expected_store[i].rs1.value + expected_store[i].imm)
        else $fatal(1, "store immediate/address corrupted");
      end
    end
  end

  task automatic tick();
    @(posedge clk);
    #2;
  endtask

  task automatic clear_queues();
    issue_valid = 0;
    flush = 1;
    tick();
    submitted = 0;
    flush = 0;
    tick();
  endtask

  task automatic drive_instruction(int lane, instruction_t value);
    issue_valid[lane] = 1;
    ctl[lane] = '0;
    ctl[lane].lsu = value.op;
    rs1[lane] = value.rs1;
    rs2[lane] = value.rs2;
    rob[lane] = value.rob;
    imm[lane] = value.imm;
  endtask

  task automatic send_batch(int pattern, int count = LSU_WIDTH);
    int start, cursor, watchdog;
    logic [IssueWidth-1:0] accepted;
    start = submitted;
    cursor = 0;
    watchdog = 0;
    for (int i = 0; i < count; i++) begin
      records[submitted] = instruction(submitted, 1'((pattern >> i) & 1));
      submitted++;
    end
    while (cursor < count) begin
      issue_valid = 0;
      for (int k = 0; k < LSU_WIDTH && cursor+k < count; k++)
        drive_instruction(k, records[start+cursor+k]);
      @(posedge clk);
      accepted = issue_valid & issue_ready;
      assert ((accepted & (accepted + 1'b1)) == 0) else $fatal(1, "upstream acceptance is not a prefix");
      @(negedge clk);
      cursor += $countones(accepted);
      watchdog++;
      assert (watchdog < 64) else $fatal(1, "input allocation stalled");
    end
    issue_valid = 0;
    for (int n = 0; n < 64 && consumed != submitted; n++) tick();
    assert (consumed == submitted) else $fatal(1, "FIFO output allocation stalled");
  endtask

  initial begin
    tick();
    rst_n = 1;
    // Every mixed bundle pattern exercises independent quotas and original ordering.
    for (int pattern = 0; pattern < (1 << LSU_WIDTH); pattern++) begin
      clear_queues();
      send_batch(pattern);
    end

    // A full SQ still permits following loads to capture the full older-store prefix.
    clear_queues();
    while (store_count < Depth)
      send_batch((1 << LSU_WIDTH) - 1, Depth - store_count < LSU_WIDTH ? Depth - store_count : LSU_WIDTH);
    while (load_count < Depth)
      send_batch(0, Depth - load_count < LSU_WIDTH ? Depth - load_count : LSU_WIDTH);
    assert (load_count == Depth && store_count == Depth) else $fatal(1, "queues did not fill");
    records[submitted] = instruction(submitted, 1);
    drive_instruction(0, records[submitted]);
    submitted++;
    repeat (4) begin
      bit accepted;
      @(posedge clk);
      accepted = issue_valid[0] && issue_ready[0];
      #2;
      if (accepted) issue_valid = 0;
      assert (consumed == 2*Depth) else $fatal(1, "full queues accepted an extra instruction");
    end
    clear_queues();
    assert (consumed == 0 && load_count == 0 && store_count == 0)
    else $fatal(1, "flush did not reset allocation state");
    $display("PASS LSU one-hot routing LSU_WIDTH=%0d LB_WIDTH=%0d SB_WIDTH=%0d FIFO=%0b transfers=%0d multi=%0d",
             LSU_WIDTH, LB_WIDTH, SB_WIDTH, FIFO, transfers, multi_transfers);
    $finish;
  end
  initial begin
    #2000000;
    $fatal(1, "LSU routing test timed out");
  end
endmodule
