// Copyright 2026 Politecnico di Torino.
// SPDX-License-Identifier: SHL-2.0
`include "len5_typedef.svh"

// Ordered allocation queue. Only entries already invalid before the edge may
// accept pushes; a pop cannot make a slot available in the same cycle.
module rs_alloc_fifo #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  parameter expipe_pkg::issue_eu_t EU = expipe_pkg::EU_INT_ALU,
  localparam bit USE_FIFO =
        EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_USE_FIFO :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_USE_FIFO :
        EU == expipe_pkg::EU_INT_DIV ? Len5Cfg.DIV_USE_FIFO :
        EU == expipe_pkg::EU_FPU ? Len5Cfg.FPU_USE_FIFO :
        EU == expipe_pkg::EU_BRANCH_UNIT ? Len5Cfg.BU_USE_FIFO : Len5Cfg.LSU_USE_FIFO,
  localparam int unsigned FIFO_DEPTH =
        EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_FIFO_DEPTH :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_FIFO_DEPTH :
        EU == expipe_pkg::EU_INT_DIV ? Len5Cfg.DIV_FIFO_DEPTH :
        EU == expipe_pkg::EU_FPU ? Len5Cfg.FPU_FIFO_DEPTH :
        EU == expipe_pkg::EU_BRANCH_UNIT ? Len5Cfg.BU_FIFO_DEPTH : Len5Cfg.LSU_FIFO_DEPTH,
  localparam int unsigned WIDTH =
        EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_ISSUE_WIDTH :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_ISSUE_WIDTH :
        EU == expipe_pkg::EU_INT_DIV ? Len5Cfg.DIV_ISSUE_WIDTH :
        EU == expipe_pkg::EU_FPU ? Len5Cfg.FPU_ISSUE_WIDTH :
        EU == expipe_pkg::EU_BRANCH_UNIT ? Len5Cfg.BU_ISSUE_WIDTH : Len5Cfg.LSU_ISSUE_WIDTH,
  localparam int unsigned OPERANDS = EU == expipe_pkg::EU_FPU ? 3 : 2,
  // Source operands travel separately from these control/metadata payloads.
  localparam int unsigned ArithmeticPayloadWidth = expipe_pkg::MAX_EU_CTL_LEN + Len5Cfg.ROB_IDX_LEN,
  localparam int unsigned FpuPayloadWidth = expipe_pkg::FPU_CTL_LEN + csr_pkg::FCSR_FRM_LEN + Len5Cfg.ROB_IDX_LEN,
  localparam int unsigned BranchPayloadWidth = $bits(
      expipe_pkg::branch_ctl_t
  ) + 3 * len5_pkg::XLEN + Len5Cfg.ROB_IDX_LEN + 1,
  localparam int unsigned MemoryPayloadWidth = $bits(
      expipe_pkg::ldst_width_t
  ) + len5_pkg::XLEN + Len5Cfg.ROB_IDX_LEN + 1,
  localparam int unsigned PayloadWidth =
        EU == expipe_pkg::EU_FPU ? FpuPayloadWidth :
        EU == expipe_pkg::EU_BRANCH_UNIT ? BranchPayloadWidth :
        EU inside {expipe_pkg::EU_LOAD_BUFFER, expipe_pkg::EU_STORE_BUFFER} ? MemoryPayloadWidth : ArithmeticPayloadWidth,
  localparam type payload_t = logic [PayloadWidth-1:0],
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg)
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  logic                                flush_i,
  input  logic      [WIDTH-1:0]               valid_i,
  output logic      [WIDTH-1:0]               ready_o,
  input  payload_t  [WIDTH-1:0]               payload_i,
  input  op_data_t  [WIDTH-1:0][OPERANDS-1:0] operands_i,
  output logic      [WIDTH-1:0]               valid_o,
  input  logic      [WIDTH-1:0]               ready_i,
  output payload_t  [WIDTH-1:0]               payload_o,
  output op_data_t  [WIDTH-1:0][OPERANDS-1:0] operands_o,
  input  logic                                cdb_valid_i,
  input  cdb_data_t                           cdb_data_i
);
  // A cached store survives flush, so its allocation data must not be overwritten.
  localparam bit IsLsu = EU inside {expipe_pkg::EU_LOAD_BUFFER, expipe_pkg::EU_STORE_BUFFER};
  logic alloc_enable;
  assign alloc_enable = IsLsu ? !flush_i : 1'b1;

  if (!USE_FIFO) begin : gen_bypass
    logic unused_inputs;
    assign unused_inputs = ^{clk_i, rst_ni, cdb_valid_i, cdb_data_i};

    assign ready_o = ready_i;
    assign valid_o = valid_i & {WIDTH{alloc_enable}};
    assign payload_o = payload_i;
    assign operands_o = operands_i;
  end else begin : gen_fifo
    logic unused_cdb_fields;
    assign unused_cdb_fields = ^{cdb_data_i.except_raised, cdb_data_i.except_code, cdb_data_i.flags};

    localparam int unsigned PtrWidth = FIFO_DEPTH > 1 ? $clog2(FIFO_DEPTH) : 1;
    typedef logic [PtrWidth-1:0] ptr_t;
    ptr_t head_idx, tail_idx;
    ptr_t read_idx[WIDTH], write_idx[WIDTH];
    logic [FIFO_DEPTH-1:0] data_valid, entry_push, entry_pop;
    logic [WIDTH-1:0] push_en, pop_en;
    payload_t [FIFO_DEPTH-1:0] payload_q;
    op_data_t [FIFO_DEPTH-1:0][OPERANDS-1:0] operands_q, operands_fwd;
    typedef logic [$clog2(WIDTH+1)-1:0] count_t;
    count_t push_count, pop_count;
    logic unused_push_empty, unused_pop_empty;

    // Truncated addition wraps at FIFO_DEPTH; a depth-one queue always addresses entry zero.
    for (genvar i = 0; i < WIDTH; i++) begin : gen_slots
      assign read_idx[i]  = FIFO_DEPTH == 1 ? '0 : head_idx + ptr_t'(i);
      assign write_idx[i] = FIFO_DEPTH == 1 ? '0 : tail_idx + ptr_t'(i);
      if (i < FIFO_DEPTH) begin : gen_active
        assign ready_o[i]    = !data_valid[write_idx[i]];
        assign valid_o[i]    = data_valid[read_idx[i]] && alloc_enable;
        assign payload_o[i]  = payload_q[read_idx[i]];
        assign operands_o[i] = operands_fwd[read_idx[i]];
      end else begin : gen_unused
        logic unused_inputs;
        assign unused_inputs = ^{valid_i[i], ready_i[i], payload_i[i], operands_i[i]};
        assign ready_o[i]    = 1'b0;
        assign valid_o[i]    = 1'b0;
        assign payload_o[i]  = '0;
        assign operands_o[i] = '0;
      end
    end
    assign push_en = valid_i & ready_o;
    assign pop_en  = valid_o & ready_i;

    // Issue routing and RS allocation supply oldest-first acceptance prefixes.
    lzc #(
      .WIDTH(WIDTH + 1),
      .MODE (1'b0)
    ) u_push_count (
      .in_i   ({1'b1, ~push_en}),
      .cnt_o  (push_count),
      .empty_o(unused_push_empty)
    );
    lzc #(
      .WIDTH(WIDTH + 1),
      .MODE (1'b0)
    ) u_pop_count (
      .in_i   ({1'b1, ~pop_en}),
      .cnt_o  (pop_count),
      .empty_o(unused_pop_empty)
    );

    always_comb begin : transfer_demux
      entry_push = '0;
      entry_pop  = '0;
      for (int i = 0; i < WIDTH; i++) begin
        if (push_en[i]) entry_push[write_idx[i]] = 1'b1;
        if (pop_en[i]) entry_pop[read_idx[i]] = 1'b1;
      end
    end

    // Forward directly to outgoing allocations as well as retaining wakeups in storage.
    always_comb begin : stored_forwarding
      operands_fwd = operands_q;
      for (int i = 0; i < FIFO_DEPTH; i++) begin
        for (int j = 0; j < OPERANDS; j++) begin
          if (data_valid[i] && cdb_valid_i && !operands_q[i][j].ready &&
              operands_q[i][j].rob_idx == cdb_data_i.rob_idx) begin
            operands_fwd[i][j].ready = 1'b1;
            operands_fwd[i][j].value = cdb_data_i.res_value;
          end
        end
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin : update
      if (!rst_ni) begin
        head_idx   <= '0;
        tail_idx   <= '0;
        data_valid <= '0;
        payload_q  <= '0;
        operands_q <= '0;
      end else if (flush_i) begin
        head_idx   <= '0;
        tail_idx   <= '0;
        data_valid <= '0;
        operands_q <= '0;
      end else begin
        head_idx   <= FIFO_DEPTH == 1 ? '0 : head_idx + ptr_t'(pop_count);
        tail_idx   <= FIFO_DEPTH == 1 ? '0 : tail_idx + ptr_t'(push_count);
        data_valid <= (data_valid & ~entry_pop) | entry_push;
        operands_q <= operands_fwd;
        for (int i = 0; i < WIDTH; i++) begin
          if (push_en[i]) begin
            payload_q[write_idx[i]]  <= payload_i[i];
            operands_q[write_idx[i]] <= operands_i[i];
          end
        end
      end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin : queue_checks
      if (rst_ni && !flush_i) begin
        assert ((push_en & (push_en + 1'b1)) == '0)
        else $fatal(1, "RS FIFO pushes must be an oldest prefix");
        assert ((pop_en & (pop_en + 1'b1)) == '0)
        else $fatal(1, "RS FIFO acceptance must be an oldest prefix");
        assert ((entry_push & data_valid) == '0)
        else $fatal(1, "FIFO overwrote a valid slot");
        assert ((entry_pop & ~data_valid) == '0)
        else $fatal(1, "FIFO popped an invalid slot");
        assert ($countones(
            entry_push
        ) == int'(push_count) && $countones(
            entry_pop
        ) == int'(pop_count))
        else $fatal(1, "FIFO transfers must use distinct slots");
        assert (int'(push_count) <= FIFO_DEPTH - $countones(
            data_valid
        ) && int'(pop_count) <= $countones(
            data_valid
        ))
        else $fatal(1, "FIFO transfer accounting failure");
      end
    end
`endif
  end
endmodule
