`include "len5_typedef.svh"
// Copyright 2022 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: rob.sv
// Author: Michele Caon
// Date: 14/07/2022

/**
 * @brief Reaorder Buffer
 *
 * @details Based on a simple FIFO queue and expanded to support
 *          updates from the CDB.
 */
module rob #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
    localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
    localparam type issue_count_t = `LEN5_ISSUE_COUNT_T(Len5Cfg),
    localparam int DEPTH = Len5Cfg.ROB_DEPTH
) (
    // Clock and reset
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    // Issue stage
    input logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_i,  // ordered request prefix
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] issue_ready_o,  // available prefix, independent of requests
    input expipe_pkg::rob_entry_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_data_i,
    output rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_tail_idx_o,
    // Parallel operand lookups
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_rob_idx_i,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs1_valid_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs1_ready_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] opfwd_rs1_value_o,
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs2_rob_idx_i,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs2_valid_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs2_ready_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] opfwd_rs2_value_o,
    input rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs3_rob_idx_i,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs3_valid_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0] opfwd_rs3_ready_o,
    output logic [Len5Cfg.ISSUE_WIDTH-1:0][len5_pkg::XLEN-1:0] opfwd_rs3_value_o,

    // Store buffer
    input  rob_idx_t sb_mem_idx_i,   // executing store ROB index
    output logic     sb_mem_clear_o, // store is clear to execute

    // Commit stage
    output logic                   comm_valid_o,  // to downstream hardware
    input  logic                   comm_ready_i,  // from downstream hardware
    output expipe_pkg::rob_entry_t comm_data_o,
    output rob_idx_t               comm_idx_o,    // ROB head idx to update register status

    // Common data bus (CDB)
    input  logic      cdb_valid_i,
    input  cdb_data_t cdb_data_i,
    output logic      cdb_ready_o
);
//%TODO redo it later on when redoing the commit unit
  import expipe_pkg::*;
  import len5_pkg::XLEN;
  import len5_pkg::REG_IDX_LEN;
  import len5_pkg::E_MISPREDICTION;

  // INTERNAL SIGNALS
  // ----------------
  // Head and tail counters
  logic [$clog2(DEPTH)-1:0] head_idx, tail_idx, clear_idx, work_idx, commit_idx;
  logic head_reg_en, tail_cnt_en, clear_cnt_en, work_cnt_en;
  logic head_reg_clr, tail_cnt_clr, clear_cnt_clr, work_cnt_clr;

  // FIFO data
  logic       data_valid[DEPTH];
  rob_entry_t data      [DEPTH];

  // FIFO control
  logic fifo_push, fifo_pop, update_res;
  logic rob_full;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] alloc_available, issue_accept;
  issue_count_t alloc_count;
  logic unused_alloc_empty;
  logic [DEPTH-1:0] issue_write_en;
  rob_entry_t [DEPTH-1:0] issue_write_data;

  // Clear store instruction
  logic mem_instr_clear, entry_clear, cdb_clear;
  logic [DEPTH-1:0] uncleared;

  // Out of order commit
  logic instr_waw;
  logic comm_valid_in_order, comm_valid_ooo, commit_valid;

  // -----------------
  // FIFO CONTROL UNIT
  // -----------------
  // Push/pop/update control
  assign fifo_push = |alloc_count;
  assign fifo_pop = commit_valid & comm_ready_i;
  assign update_res = cdb_valid_i;
  assign rob_full = data_valid[tail_idx];

  // Counters control
  assign head_reg_clr = flush_i;
  assign tail_cnt_clr = flush_i;
  assign clear_cnt_clr = flush_i;
  assign work_cnt_clr = flush_i;
  assign head_reg_en = comm_valid_in_order & comm_ready_i;  // in-order commit only
  assign tail_cnt_en = fifo_push;
  assign clear_cnt_en = mem_instr_clear;
  assign work_cnt_en = commit_valid & comm_ready_i;  // in- OR out-of-order commit

  // DEPTH is a power of two and ISSUE_WIDTH < DEPTH; indices wrap by overflow.
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_alloc
    assign issue_tail_idx_o[i] = tail_idx + i[Len5Cfg.ROB_IDX_LEN-1:0];
    assign alloc_available[i] = !data_valid[issue_tail_idx_o[i]];
    assign issue_ready_o[i] = &alloc_available[i:0];
    assign issue_accept[i] = issue_ready_o[i] && issue_valid_i[i];
  end

  lzc #(
      .WIDTH(Len5Cfg.ISSUE_WIDTH + 1),
      .MODE (1'b0)
  ) u_alloc_count (
      .in_i   ({1'b1, ~issue_accept}),
      .cnt_o  (alloc_count),
      .empty_o(unused_alloc_empty)
  );

  always_comb begin : alloc_demux
    issue_write_en = '0;
    foreach (issue_write_data[i]) issue_write_data[i] = '0;
    for (int i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin
      if (issue_accept[i]) begin
        issue_write_en[issue_tail_idx_o[i]] = 1'b1;
        issue_write_data[issue_tail_idx_o[i]] = issue_data_i[i];
      end
    end
  end

  // Out-of-order memory access
  // --------------------------
  // NOTE: the instruction pointed by clear_idx may attempt memory access if
  // al previous instructions are "clear", meaning that each of them:
  // 1)  is valid
  // 2a) it is not memory critical (does not alter the program flow) OR
  // 2b) its result is ready AND no exception or misprediction has been raised
  // This information is used by instructions committing to memory to know if
  // they can be executed out-of-order. Instruction marked as non-critical allow
  // out-of-order execution of subsequent memory instructions unconditionally.
  // NOTE: exception detection for memory access instructions is assumed to be
  // performed at address computation time, not at memory access time.
  assign entry_clear = ~data[clear_idx].except_raised &
                       (data[clear_idx].except_code != E_MISPREDICTION) &
                       data[clear_idx].res_ready; // check conditions 2),3), 4)
  assign cdb_clear   = cdb_valid_i &
                       cdb_data_i.rob_idx == clear_idx &
                       ~cdb_data_i.except_raised &
                       (cdb_data_i.except_code != E_MISPREDICTION); // check cdb is writing at clear_idx and 2),3)
  for (genvar i = 0; i < DEPTH; i++) begin : gen_uncleared
    assign uncleared[i] = data_valid[i] & ~data[i].mem_clear & (i[Len5Cfg.ROB_IDX_LEN-1:0] != clear_idx);
  end

  // Release an unfinished walk when its full-tail entry retires. A completed walk stays at the tail for reuse.
  assign mem_instr_clear = data_valid[clear_idx] & (~data[clear_idx].mem_crit | entry_clear | cdb_clear) &
                           ((clear_idx != tail_idx) | ~rob_full |
                            (fifo_pop & (commit_idx == clear_idx) & (|uncleared)));

  // In-order commit slot
  // --------------------
  // The instruction at the head of the ROB can be committed if:
  // 1) it is valid
  // 2) its result is ready
  assign comm_valid_in_order = data_valid[head_idx] & data[head_idx].res_ready;

  // Out-of-order commit slot
  // ------------------------
  // If the instruction at the head of the ROB cannot be committed, a second
  // lookahead commit slot can attempt to commit an instruction if:
  // 1) it is valid
  // 2) it is not "order critical" (i.e., it cannot be committed out of order)
  // 3) its result is ready
  // 4) no exception has been raised (i.e., control flow is not altered)
  // 5) no misprediction has been raised (i.e., control flow is not altered)
  // 6) all previous instructions were marked as "clear" (see above)
  // 7) it does not write the same rd as the head instruction (WAW hazard)

  // WAW check for out of order commit
  assign instr_waw = data[head_idx].rd_upd & (data[head_idx].rd_idx == data[work_idx].rd_idx);

  // Commit valids
  assign comm_valid_ooo = data_valid[work_idx] &
                          ~data[work_idx].order_crit &
                          data[work_idx].res_ready &
                          ~data[work_idx].except_raised &
                          (data[work_idx].except_code != E_MISPREDICTION) &
                          data[work_idx].mem_clear &
                          ~instr_waw;

  // Committing instruction selection (head has priority)
  assign commit_valid = comm_valid_in_order | comm_valid_ooo;
  assign commit_idx = comm_valid_in_order ? head_idx : work_idx; // Give higher priority to in-order commit

  // -----------
  // FIFO UPDATE
  // -----------
  // NOTE: operations priority:
  // 1) push (from issue stage)
  // 2) pop in order
  // 3) pop out of order
  // 4) update result (from CDB)
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fifo_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data_valid[i] <= 1'b0;
        data[i]       <= '0;
      end
    end else if (flush_i) begin
      foreach (data[i]) begin
        data_valid[i] <= 1'b0;  // clearing valid is enough
      end
    end else begin
      foreach (data[i]) begin
        if (issue_write_en[i]) begin
          data_valid[i] <= 1'b1;
          data[i]       <= issue_write_data[i];
        end else if ((fifo_pop) && commit_idx == i[$clog2(DEPTH)-1:0]) begin
          data_valid[i] <= 1'b0;
        end else if (update_res && cdb_data_i.rob_idx == i[Len5Cfg.ROB_IDX_LEN-1:0]) begin
          data[i].res_ready     <= 1'b1;
          data[i].res_value     <= cdb_data_i.res_value;
          data[i].except_raised <= cdb_data_i.except_raised;
          data[i].except_code   <= cdb_data_i.except_code;
          data[i].flags         <= cdb_data_i.flags;
        end
      end

      // Clear status update
      if (data_valid[clear_idx]) begin
        data[clear_idx].mem_clear <= 1'b1;
      end
    end
  end

  // ------------
  // ROB COUNTERS
  // ------------
  // Head register
  always_ff @(posedge clk_i or negedge rst_ni) begin : head_index_register
    if (!rst_ni) begin
      head_idx <= 0;
    end else if (head_reg_clr) begin
      head_idx <= 0;
    end else if (head_reg_en) begin
      head_idx <= work_idx;
    end
  end

  // Tail counter
  // Tracks the first available empty entry in the ROB
  modn_counter_special #(
      .N(DEPTH),
      .I($clog2(Len5Cfg.ISSUE_WIDTH))
  ) u_tail_counter (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .en_i          (tail_cnt_en),
      .clr_i         (tail_cnt_clr),
      .increase_val_i(alloc_count),
      .count_o       (tail_idx)
  );

  // Clear counter for store instructions
  // Tracks the oldest instruction that is NOT "clear to commit"
  modn_counter #(
      .N(DEPTH)
  ) u_clear_counter (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .en_i   (clear_cnt_en),
      .clr_i  (clear_cnt_clr),
      .count_o(clear_idx),
      .tc_o   ()                // not needed
  );

  // Work counter for out-of-order commit
  // Tracks the oldest instruction that is NOT "clear to commit"
  modn_counter #(
      .N   (DEPTH),
      .INIT(1)
  ) u_work_counter (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .en_i   (work_cnt_en),
      .clr_i  (work_cnt_clr),
      .count_o(work_idx),
      .tc_o   ()               // not needed
  );

  // --------------
  // OUTPUT NETWORK
  // --------------
  // CDB
  // NOTE: since the ROB entries are allocated at issue time, the ROB is
  // always ready to get the results from the CDB.
  assign cdb_ready_o = 1'b1;

  // Store buffer
  assign sb_mem_clear_o    = data_valid[sb_mem_idx_i] & (data[sb_mem_idx_i].mem_clear | clear_idx == sb_mem_idx_i);

  // Commit stage
  assign comm_valid_o = commit_valid;
  assign comm_data_o = comm_valid_in_order ? data[head_idx] :  data[work_idx] ;  // Give higher priority to in-order commit
  assign comm_idx_o = commit_idx;
  // Power-of-two ROB depth makes every encoded tag a valid array index.
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_lookup_lanes
    assign opfwd_rs1_valid_o[i] = data_valid[issue_rs1_rob_idx_i[i]];
    assign opfwd_rs1_ready_o[i] = data[issue_rs1_rob_idx_i[i]].res_ready;
    assign opfwd_rs1_value_o[i] = data[issue_rs1_rob_idx_i[i]].res_value;

    assign opfwd_rs2_valid_o[i] = data_valid[issue_rs2_rob_idx_i[i]];
    assign opfwd_rs2_ready_o[i] = data[issue_rs2_rob_idx_i[i]].res_ready;
    assign opfwd_rs2_value_o[i] = data[issue_rs2_rob_idx_i[i]].res_value;

    assign opfwd_rs3_valid_o[i] = data_valid[issue_rs3_rob_idx_i[i]];
    assign opfwd_rs3_ready_o[i] = data[issue_rs3_rob_idx_i[i]].res_ready;
    assign opfwd_rs3_value_o[i] = data[issue_rs3_rob_idx_i[i]].res_value;
  end

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
`ifndef VERILATOR
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_check_alloc
    property p_fifo_push;
      @(posedge clk_i) disable iff (!rst_ni) sync_accept_on (flush_i)
        issue_accept[i] |-> ##1 data_valid[$past(issue_tail_idx_o[i])] &&
        data[$past(issue_tail_idx_o[i])] == $past(issue_data_i[i]);
    endproperty
    a_fifo_push :
    assert property (p_fifo_push)
    else $error("%t: invalid ROB allocation in lane %0d", $time, i);
  end

  property p_fifo_pop;
    @(posedge clk_i) disable iff (!rst_ni) sync_accept_on (flush_i)
      comm_valid_o && comm_ready_i |-> ##1 issue_ready_o[0] == 1'b1 && data_valid[$past(
        head_idx
    )] == 1'b0;
  endproperty
  a_fifo_pop :
  assert property (p_fifo_pop);

  property p_ready_n;
    @(posedge clk_i) disable iff (!rst_ni) sync_accept_on (flush_i) !comm_ready_i && comm_valid_o |=> comm_valid_o;
  endproperty
  a_ready_n :
  assert property (p_ready_n);

  property p_push_pop;
    @(posedge clk_i) disable iff (!rst_ni) fifo_push && fifo_pop |-> head_idx != tail_idx;
  endproperty
  a_push_pop :
  assert property (p_push_pop);

  property p_cdb_valid;
    @(posedge clk_i) disable iff (!rst_ni) cdb_valid_i |-> data_valid[cdb_data_i.rob_idx];
  endproperty
  a_cdb_valid :
  assert property (p_cdb_valid);

  property p_flush;
    @(posedge clk_i) disable iff (!rst_ni) $rose(
        flush_i
    ) |=> comm_valid_o == 1'b0 && issue_ready_o[0] == 1'b1;
  endproperty
  a_flush :
  assert property (p_flush);
`endif  /* VERILATOR */
`endif  /* SYNTHESIS */

endmodule
