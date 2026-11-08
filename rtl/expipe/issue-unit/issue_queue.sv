`include "len5_typedef.svh"
// Copyright 2019 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: issue_queue.sv
// Author: Michele Caon
// Date: 17/10/2019

module issue_queue #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type iq_idx_t = `LEN5_IQ_IDX_T(Len5Cfg),
  localparam type iq_dep_t = `LEN5_IQ_DEP_T(Len5Cfg),
  localparam type iq_entry_t = `LEN5_IQ_ENTRY_T(Len5Cfg),
  localparam type issue_count_t = `LEN5_ISSUE_COUNT_T(Len5Cfg)
) (
  input  logic                                                          clk_i,
  input  logic                                                          rst_ni,
  input  logic                                                          flush_i,
  input  logic                                                          fetch_valid_i,
  output logic                                                          fetch_ready_o,
  input  logic                       [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] fetch_valid_instr_i,
  input  expipe_pkg::decoded_instr_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] push_instr_i,
  input  logic                       [         Len5Cfg.ISSUE_WIDTH-1:0] issue_accepted_i,
  output logic                       [         Len5Cfg.ISSUE_WIDTH-1:0] issue_valid_o,
  output iq_entry_t                  [         Len5Cfg.ISSUE_WIDTH-1:0] pop_instr_o,
  output iq_idx_t                                                       head_idx_o
);
  import len5_pkg::*;
  import expipe_pkg::*;

  localparam int unsigned OLDEST_ISSUE_SIZE = Len5Cfg.ISSUE_WIDTH > 1 ? Len5Cfg.ISSUE_WIDTH - 1 : 1;

  typedef logic [$clog2(Len5Cfg.LEN5_MULTIPLE_ISSUES+1)-1:0] push_count_t;

  iq_entry_t data[Len5Cfg.IQ_DEPTH];
  logic [Len5Cfg.IQ_DEPTH-1:0] data_valid, entry_pop, entry_push;
  logic         [Len5Cfg.ISSUE_WIDTH-1:0] pop_en;
  issue_count_t                           pop_count;
  iq_idx_t head_idx, tail_idx;
  iq_idx_t                                      read_idx       [         Len5Cfg.ISSUE_WIDTH];
  iq_idx_t                                      push_idx       [Len5Cfg.LEN5_MULTIPLE_ISSUES];
  iq_idx_t                                      older_idx      [           OLDEST_ISSUE_SIZE];
  iq_entry_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] push_data;
  iq_entry_t                                    entry_push_data[            Len5Cfg.IQ_DEPTH];
  logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] push_busy, push_en;
  push_count_t push_count;
  logic        push;

  // IQ_DEPTH is a power of two: index-width arithmetic wraps naturally.
  assign head_idx_o = head_idx;
  for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin : gen_read
    assign read_idx[i]      = head_idx + iq_idx_t'(i);
    assign issue_valid_o[i] = data_valid[read_idx[i]] && !flush_i;
    // Keep the reference visible through dispatch for same-cycle ROB-tag bypass.
    assign pop_instr_o[i]   = data[read_idx[i]];
  end

  assign pop_en = issue_accepted_i & issue_valid_o;

  // The extra set bit makes full-width acceptance count as ISSUE_WIDTH.
  lzc #(
    .WIDTH(Len5Cfg.ISSUE_WIDTH + 1),
    .MODE (1'b0)
  ) u_pop_count (
    .in_i   ({1'b1, ~pop_en}),
    .cnt_o  (pop_count),
    .empty_o()
  );

  // Map accepted issue lanes to their physical queue entries.
  always_comb begin : pop_demux
    entry_pop = '0;
    for (int i = 0; i < Len5Cfg.ISSUE_WIDTH; i++) begin
      if (pop_en[i]) entry_pop[read_idx[i]] = 1'b1;
    end
  end

  // The frontend supplies an oldest-first valid prefix. Check registered validity
  // only: entries being popped cannot be reused at this edge.
  for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_push_slots
    assign push_idx[i]  = tail_idx + iq_idx_t'(i);
    assign push_busy[i] = data_valid[push_idx[i]];
  end

  lzc #(
    .WIDTH(Len5Cfg.LEN5_MULTIPLE_ISSUES + 1),
    .MODE (1'b0)
  ) u_push_count (
    .in_i   ({1'b1, ~fetch_valid_instr_i}),
    .cnt_o  (push_count),
    .empty_o()
  );

  // IQ_DEPTH exceeds the fetch width, so valid lanes always have distinct positions.
  assign fetch_ready_o = !flush_i && !(|(fetch_valid_instr_i & push_busy));
  assign push          = fetch_valid_i && fetch_ready_o;
  assign push_en       = fetch_valid_instr_i & {Len5Cfg.LEN5_MULTIPLE_ISSUES{push}};

  // Walk backwards from the tail; numerical slot order is not program order.
  if (Len5Cfg.ISSUE_WIDTH == 1) begin : gen_no_older_slots
    assign older_idx[0] = '0;
  end else begin : gen_older_entries
    for (genvar i = 0; i < Len5Cfg.ISSUE_WIDTH - 1; i++) begin : gen_older_slots
      assign older_idx[i] = tail_idx - iq_idx_t'(i + 1);
    end
  end

  for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_dependencies
    iq_dep_t rs1_dep, rs2_dep, rs3_dep;
    iq_dep_t queued_rs1_dep, queued_rs2_dep, queued_rs3_dep;
    iq_dep_t push_rs1_dep, push_rs2_dep, push_rs3_dep;
    localparam int unsigned FirstOlderPush = (i >= Len5Cfg.ISSUE_WIDTH-1) ?
        i-(Len5Cfg.ISSUE_WIDTH-1) : 0;
    logic [OLDEST_ISSUE_SIZE-1:0] queued_rs1_idx_match, queued_rs2_idx_match, queued_rs3_idx_match;
    logic [OLDEST_ISSUE_SIZE-1:0]
        queued_rs1_type_match, queued_rs2_type_match, queued_rs3_type_match;
    logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0]
        push_rs1_idx_match, push_rs2_idx_match, push_rs3_idx_match;
    logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0]
        push_rs1_type_match, push_rs2_type_match, push_rs3_type_match;
    logic rs1_int, rs1_fp, rs2_int, rs2_fp, rs3_fp;

    assign rs1_int = push_instr_i[i].rs1_sel == RS1_SEL_INT && (|push_instr_i[i].rs1_idx);
    assign rs1_fp  = push_instr_i[i].rs1_sel == RS1_SEL_FP;
    assign rs2_int = push_instr_i[i].rs2_sel == RS2_SEL_INT && (|push_instr_i[i].rs2_idx);
    assign rs2_fp  = push_instr_i[i].rs2_sel == RS2_SEL_FP;
    assign rs3_fp  = push_instr_i[i].rs3_sel == RS3_SEL_FP;

    for (genvar j = 0; j < OLDEST_ISSUE_SIZE; j++) begin : gen_queued_matches
      assign queued_rs1_idx_match[j] = data_valid[older_idx[j]] &&
          push_instr_i[i].rs1_idx == data[older_idx[j]].data.rd_idx;
      assign queued_rs2_idx_match[j] = data_valid[older_idx[j]] &&
          push_instr_i[i].rs2_idx == data[older_idx[j]].data.rd_idx;
      assign queued_rs3_idx_match[j] = data_valid[older_idx[j]] &&
          push_instr_i[i].rs3_idx == data[older_idx[j]].data.rd_idx;
      assign queued_rs1_type_match[j] = (rs1_int && data[older_idx[j]].data.dispatch.int_rd_write) ||
          (rs1_fp && data[older_idx[j]].data.dispatch.fp_rd_write);
      assign queued_rs2_type_match[j] = (rs2_int && data[older_idx[j]].data.dispatch.int_rd_write) ||
          (rs2_fp && data[older_idx[j]].data.dispatch.fp_rd_write);
      assign queued_rs3_type_match[j] = rs3_fp && data[older_idx[j]].data.dispatch.fp_rd_write;
    end

    for (genvar j = 0; j < Len5Cfg.LEN5_MULTIPLE_ISSUES; j++) begin : gen_push_matches
      assign push_rs1_idx_match[j] = fetch_valid_instr_i[j] && push_instr_i[i].rs1_idx == push_instr_i[j].rd_idx;
      assign push_rs2_idx_match[j] = fetch_valid_instr_i[j] && push_instr_i[i].rs2_idx == push_instr_i[j].rd_idx;
      assign push_rs3_idx_match[j] = fetch_valid_instr_i[j] && push_instr_i[i].rs3_idx == push_instr_i[j].rd_idx;
      assign push_rs1_type_match[j] = (rs1_int && push_instr_i[j].dispatch.int_rd_write) ||
          (rs1_fp && push_instr_i[j].dispatch.fp_rd_write);
      assign push_rs2_type_match[j] = (rs2_int && push_instr_i[j].dispatch.int_rd_write) ||
          (rs2_fp && push_instr_i[j].dispatch.fp_rd_write);
      assign push_rs3_type_match[j] = rs3_fp && push_instr_i[j].dispatch.fp_rd_write;
    end

    // Earlier input lanes reduce the queued portion of the ISSUE_WIDTH-1 window.
    // Visit oldest to youngest; a popping youngest match must also mask older writers.
    always_comb begin : queued_dependency_select
      queued_rs1_dep = '0;
      queued_rs2_dep = '0;
      queued_rs3_dep = '0;
      for (int j = Len5Cfg.ISSUE_WIDTH - 2 - i; j >= 0; j--) begin
        if (queued_rs1_idx_match[j] && queued_rs1_type_match[j])
          queued_rs1_dep = '{valid: !entry_pop[older_idx[j]], idx: older_idx[j]};
        if (queued_rs2_idx_match[j] && queued_rs2_type_match[j])
          queued_rs2_dep = '{valid: !entry_pop[older_idx[j]], idx: older_idx[j]};
        if (queued_rs3_idx_match[j] && queued_rs3_type_match[j])
          queued_rs3_dep = '{valid: !entry_pop[older_idx[j]], idx: older_idx[j]};
      end
    end

    always_comb begin : push_dependency_select
      push_rs1_dep = '0;
      push_rs2_dep = '0;
      push_rs3_dep = '0;
      for (int j = FirstOlderPush; j < i; j++) begin
        if (push_rs1_idx_match[j] && push_rs1_type_match[j])
          push_rs1_dep = '{valid: 1'b1, idx: push_idx[j]};
        if (push_rs2_idx_match[j] && push_rs2_type_match[j])
          push_rs2_dep = '{valid: 1'b1, idx: push_idx[j]};
        if (push_rs3_idx_match[j] && push_rs3_type_match[j])
          push_rs3_dep = '{valid: 1'b1, idx: push_idx[j]};
      end
    end

    // Matching input writers are younger than every queued writer.
    always_comb begin : dependency_select
      rs1_dep = queued_rs1_dep;
      rs2_dep = queued_rs2_dep;
      rs3_dep = queued_rs3_dep;
      if (push_rs1_dep.valid) rs1_dep = push_rs1_dep;
      if (push_rs2_dep.valid) rs2_dep = push_rs2_dep;
      if (push_rs3_dep.valid) rs3_dep = push_rs3_dep;
    end
    assign push_data[i] = '{
            data: push_instr_i[i],
            rs1_dep: rs1_dep,
            rs2_dep: rs2_dep,
            rs3_dep: rs3_dep
        };
  end

  always_comb begin : push_demux
    entry_push = '0;
    foreach (entry_push_data[e]) entry_push_data[e] = '0;
    for (int i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin
      entry_push[push_idx[i]]      = push_en[i];
      entry_push_data[push_idx[i]] = push_data[i];
    end
  end

  for (genvar e = 0; e < Len5Cfg.IQ_DEPTH; e++) begin : gen_entries
    always_ff @(posedge clk_i or negedge rst_ni) begin : entry_update
      if (!rst_ni) begin
        data_valid[e] <= 1'b0;
        data[e]       <= '0;
      end else if (flush_i) begin
        data_valid[e]         <= 1'b0;
        data[e].rs1_dep.valid <= 1'b0;
        data[e].rs2_dep.valid <= 1'b0;
        data[e].rs3_dep.valid <= 1'b0;
      end else if (entry_push[e]) begin
        data_valid[e] <= 1'b1;
        data[e]       <= entry_push_data[e];
      end else begin
        if (entry_pop[e]) data_valid[e] <= 1'b0;
        // Clearing is permanent: a later occupant of the slot cannot revive a reference.
        if (data[e].rs1_dep.valid && (!data_valid[data[e].rs1_dep.idx] || entry_pop[data[e].rs1_dep.idx]))
          data[e].rs1_dep.valid <= 1'b0;
        if (data[e].rs2_dep.valid && (!data_valid[data[e].rs2_dep.idx] || entry_pop[data[e].rs2_dep.idx]))
          data[e].rs2_dep.valid <= 1'b0;
        if (data[e].rs3_dep.valid && (!data_valid[data[e].rs3_dep.idx] || entry_pop[data[e].rs3_dep.idx]))
          data[e].rs3_dep.valid <= 1'b0;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : pointers
    if (!rst_ni) begin
      head_idx <= '0;
      tail_idx <= '0;
    end else if (flush_i) begin
      head_idx <= '0;
      tail_idx <= '0;
    end else begin
      head_idx <= head_idx + iq_idx_t'(pop_count);
      if (push) tail_idx <= tail_idx + iq_idx_t'(push_count);
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : queue_checks
    if (rst_ni && !flush_i) begin
      assert ((issue_accepted_i & (issue_accepted_i + 1'b1)) == '0)
      else $error("Issue queue acceptance must be an oldest prefix");
      assert ((issue_accepted_i & ~issue_valid_o) == '0)
      else $error("Cannot pop an invalid issue entry");
      for (int i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++)
      if (push && fetch_valid_instr_i[i])
        assert (!data_valid[push_idx[i]])
        else $error("Cannot overwrite a valid issue entry");
    end
  end
`endif
endmodule
