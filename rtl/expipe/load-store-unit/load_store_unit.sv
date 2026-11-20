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
// File: load_store_unit.sv
// Author: Michele Caon
// Date: 15/07/2022

// Ordered multi-issue allocation and the existing memory/completion channels.
module load_store_unit #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type adder_req_t = `LEN5_ADDER_REQ_T(Len5Cfg),
  localparam type adder_ans_t = `LEN5_ADDER_ANS_T(Len5Cfg),
  localparam int unsigned IW = Len5Cfg.ISSUE_WIDTH,
  localparam int unsigned WIDTH = Len5Cfg.LSU_ISSUE_WIDTH,
  localparam int unsigned LB_WIDTH = Len5Cfg.LDBUFF_ISSUE_WIDTH,
  localparam int unsigned SB_WIDTH = Len5Cfg.STBUFF_ISSUE_WIDTH,
  localparam int unsigned SB_DEPTH = Len5Cfg.STBUFF_DEPTH,
  localparam int unsigned SqIdxW = SB_DEPTH > 1 ? $clog2(SB_DEPTH) : 1
) (
  input logic clk_i,
  input logic rst_ni,
  input logic mis_flush_i,
  input logic except_flush_i,

  // Issue_stage
  input  logic                [IW-1:0]                     issue_valid_i,
  output logic                [IW-1:0]                     issue_ready_o,
  input  expipe_pkg::eu_ctl_t [IW-1:0]                     issue_eu_ctl_i,
  input  op_data_t            [IW-1:0]                     issue_rs1_i,
  input  op_data_t            [IW-1:0]                     issue_rs2_i,
  input  logic                [IW-1:0][len5_pkg::XLEN-1:0] issue_imm_i,
  input  rob_idx_t            [IW-1:0]                     issue_dest_rob_idx_i,

  // Commit_stage
  input  logic     comm_sb_mem_clear_i,
  output rob_idx_t comm_sb_mem_idx_o,

  // CDB
  input  logic      cdb_valid_i,
  input  logic      cdb_lb_ready_i,
  input  logic      cdb_sb_ready_i,
  output logic      cdb_lb_valid_o,
  output logic      cdb_sb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_lb_data_o,
  output cdb_data_t cdb_sb_data_o,

  // Memory_system (loads)
  output logic                                              mem_load_valid_o,
  input  logic                                              mem_load_ready_i,
  input  logic                                              mem_load_valid_i,
  output logic                                              mem_load_ready_o,
  output logic                                              mem_load_we_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_load_addr_o,
  output logic                   [                     7:0] mem_load_be_o,
  output logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_load_tag_o,
  input  logic                   [      len5_pkg::XLEN-1:0] mem_load_rdata_i,
  input  logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_load_tag_i,
  input  logic                                              mem_load_except_raised_i,
  input  len5_pkg::except_code_t                            mem_load_except_code_i,


  // Memory_system (stores)
  output logic                                              mem_store_valid_o,
  input  logic                                              mem_store_ready_i,
  input  logic                                              mem_store_valid_i,
  output logic                                              mem_store_ready_o,
  output logic                                              mem_store_we_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_store_addr_o,
  output logic                   [                     7:0] mem_store_be_o,
  output logic                   [      len5_pkg::XLEN-1:0] mem_store_wdata_o,
  output logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_store_tag_o,
  input  logic                   [Len5Cfg.BUFF_IDX_LEN-1:0] mem_store_tag_i,
  input  logic                                              mem_store_except_raised_i,
  input  len5_pkg::except_code_t                            mem_store_except_code_i
);

  import len5_pkg::*;
  import expipe_pkg::*;

  // ----------
  // DATA TYPES
  // ----------
  // Allocation FIFO payload
  typedef struct packed {
    ldst_width_t width;
    logic [XLEN-1:0] imm;
    rob_idx_t rob;
  } payload_t;

  // ----------------
  // INTERNAL SIGNALS
  // ----------------
  // Allocation FIFO data, operands, and handshakes
  payload_t [WIDTH-1:0] fifo_payload_in, fifo_payload_out;
  op_data_t [WIDTH-1:0][1:0] fifo_operands_in, fifo_operands_out;
  logic [WIDTH-1:0] fifo_push, fifo_ready, fifo_valid, fifo_pop_ready;

  // One-hot routing from the mixed stream to each buffer's allocation lanes
  localparam int unsigned LoadBuffer = 0;
  localparam int unsigned StoreBuffer = 1;
  logic [1:0][WIDTH-1:0] queue_valid, queue_ready, mapped_ready;
  logic [1:0][WIDTH-1:0][WIDTH:0] request_channel;
  payload_t [1:0][WIDTH-1:0] queue_payload;
  op_data_t [1:0][WIDTH-1:0][1:0] queue_operands;
  logic [WIDTH-1:0] lane_ready;
  logic [LB_WIDTH-1:0] lb_ready;
  logic [SB_WIDTH-1:0] sb_ready;
  ldst_width_t [LB_WIDTH-1:0] lb_type;
  ldst_width_t [SB_WIDTH-1:0] sb_type;
  op_data_t [LB_WIDTH-1:0] lb_rs1;
  op_data_t [SB_WIDTH-1:0] sb_rs1, sb_rs2;
  logic [LB_WIDTH-1:0][XLEN-1:0] lb_imm;
  logic [SB_WIDTH-1:0][XLEN-1:0] sb_imm;
  rob_idx_t [LB_WIDTH-1:0] lb_rob;
  rob_idx_t [SB_WIDTH-1:0] sb_rob;

  // Exclusive SQ boundaries captured for newly allocated loads
  logic [WIDTH-1:0][SqIdxW-1:0] load_sq_tail;
  logic [WIDTH-1:0]            older_stores_remain;
  logic [SB_WIDTH:0][SqIdxW-1:0] issue_sq_tail;
  logic [SB_WIDTH:0] issue_older_stores_remain;
  logic [WIDTH-1:0][SqIdxW-1:0] lane_sq_tail;
  logic [WIDTH-1:0] lane_older_stores_remain;

  // Load_buffer <--> Store_buffer
  logic [SqIdxW-1:0] sq_head;
  logic sq_removed;
  logic [SB_DEPTH-1:0] sq_addr_ready, sq_data_ready;
  logic [SB_DEPTH-1:0][XLEN-1:0] sq_addr, sq_data;
  ldst_width_t [SB_DEPTH-1:0] sq_type;

  // Load/store buffers <--> Address_adder
  logic lb_adder_valid, sb_adder_valid, lb_adder_ready, sb_adder_ready;
  logic adder_lb_valid, adder_sb_valid, adder_lb_ready, adder_sb_ready;
  adder_req_t lb_adder_req, sb_adder_req;
  adder_ans_t adder_lb_ans, adder_sb_ans;

  // Combined misprediction and exception flush
  logic flush;

  assign flush = mis_flush_i || except_flush_i;

  // ---------------------
  // ALLOCATION FIFO INPUT
  // ---------------------
  // The operation identifies each candidate independently of its valid/ready handshake.
  for (genvar k = 0; k < IW; k++) begin : gen_input
    if (k < WIDTH) begin : gen_active
      assign fifo_push[k]       = issue_valid_i[k];
      assign fifo_payload_in[k] = {issue_eu_ctl_i[k].lsu, issue_imm_i[k], issue_dest_rob_idx_i[k]};
      assign issue_ready_o[k]   = fifo_ready[k] && !flush;
      always_comb begin
        fifo_operands_in[k] = {issue_rs2_i[k], issue_rs1_i[k]};
        for (int op = 0; op < 2; op++) begin
          if (!fifo_operands_in[k][op].ready && cdb_valid_i &&
              fifo_operands_in[k][op].rob_idx == cdb_data_i.rob_idx) begin
            fifo_operands_in[k][op].ready = 1'b1;
            fifo_operands_in[k][op].value = cdb_data_i.res_value;
          end
        end
      end
    end else begin : gen_unused
      assign issue_ready_o[k] = 1'b0;
    end
  end

  rs_alloc_fifo #(
    .Len5Cfg(Len5Cfg),
    .EU     (EU_LSU)
  ) u_alloc_fifo (
    .clk_i,
    .rst_ni,
    .flush_i   (flush),
    .cdb_valid_i,
    .cdb_data_i,
    .valid_i   (fifo_push),
    .ready_o   (fifo_ready),
    .valid_o   (fifo_valid),
    .ready_i   (fifo_pop_ready),
    .payload_i (fifo_payload_in),
    .payload_o (fifo_payload_out),
    .operands_i(fifo_operands_in),
    .operands_o(fifo_operands_out)
  );

  // -----------------
  // ALLOCATION ROUTING
  // -----------------
  // Pad unavailable buffer lanes with zero readiness.
  assign queue_ready[LoadBuffer] = {{(WIDTH-LB_WIDTH){1'b0}}, lb_ready};
  assign queue_ready[StoreBuffer] = {{(WIDTH-SB_WIDTH){1'b0}}, sb_ready};

  // Rank candidates independently of grants, as in exec_stage.
  for (genvar u = 0; u < 2; u++) begin : gen_route
    logic [WIDTH-1:0] request;
    logic [WIDTH-1:0][WIDTH-1:0] channel_select;

    for (genvar i = 0; i < WIDTH; i++) begin : gen_requests
      assign request[i] = (fifo_payload_out[i].width inside {S_BYTE, S_HALFWORD, S_WORD, S_DOUBLEWORD}) == (u == StoreBuffer);
      assign channel_select[i] = request_channel[u][i][WIDTH-1:0] & {WIDTH{request[i]}};
      assign mapped_ready[u][i] = |(channel_select[i] & queue_ready[u]);
    end

    always_comb begin : request_channel_assignment
      request_channel[u] = '0;
      request_channel[u][0] = (WIDTH+1)'(1);
      for (int i = 1; i < WIDTH; i++) begin
        request_channel[u][i] = request[i-1] ? request_channel[u][i-1] << 1 : request_channel[u][i-1];
      end
    end

    for (genvar k = 0; k < WIDTH; k++) begin : gen_payload
      always_comb begin : payload_mux
        queue_valid[u][k] = 1'b0;
        queue_payload[u][k] = '0;
        queue_operands[u][k] = '0;
        for (int i = 0; i < WIDTH; i++) begin
          queue_valid[u][k] |= channel_select[i][k] && fifo_valid[i] && fifo_pop_ready[i];
          queue_payload[u][k] |= fifo_payload_out[i] & {$bits(payload_t){channel_select[i][k]}};
          queue_operands[u][k][0] |= fifo_operands_out[i][0] & {$bits(op_data_t){channel_select[i][k]}};
          if (u == StoreBuffer) begin
            queue_operands[u][k][1] |= fifo_operands_out[i][1] & {$bits(op_data_t){channel_select[i][k]}};
          end
        end
      end

      if (u == LoadBuffer) begin : gen_load_boundary
        always_comb begin : boundary_mux
          load_sq_tail[k] = '0;
          older_stores_remain[k] = 1'b0;
          for (int i = 0; i < WIDTH; i++) begin
            load_sq_tail[k] |= lane_sq_tail[i] & {SqIdxW{channel_select[i][k]}};
            older_stores_remain[k] |= lane_older_stores_remain[i] && channel_select[i][k];
          end
        end
      end
    end
  end

  for (genvar i = 0; i < WIDTH; i++) begin : gen_ready
    assign lane_ready[i] = mapped_ready[LoadBuffer][i] || mapped_ready[StoreBuffer][i];
    assign fifo_pop_ready[i] = !flush && (&lane_ready[i:0]);

    // The store rank before this mixed lane selects its exclusive SQ boundary.
    always_comb begin : boundary_mux
      lane_sq_tail[i] = '0;
      lane_older_stores_remain[i] = 1'b0;
      for (int s = 0; s <= SB_WIDTH; s++) begin
        lane_sq_tail[i] |= issue_sq_tail[s] & {SqIdxW{request_channel[StoreBuffer][i][s]}};
        lane_older_stores_remain[i] |= issue_older_stores_remain[s] && request_channel[StoreBuffer][i][s];
      end
    end
  end

  for (genvar k = 0; k < LB_WIDTH; k++) begin : gen_load_ports
    assign lb_type[k] = queue_payload[LoadBuffer][k].width;
    assign lb_imm[k] = queue_payload[LoadBuffer][k].imm;
    assign lb_rob[k] = queue_payload[LoadBuffer][k].rob;
    assign lb_rs1[k] = queue_operands[LoadBuffer][k][0];
  end

  for (genvar k = 0; k < SB_WIDTH; k++) begin : gen_store_ports
    assign sb_type[k] = queue_payload[StoreBuffer][k].width;
    assign sb_imm[k] = queue_payload[StoreBuffer][k].imm;
    assign sb_rob[k] = queue_payload[StoreBuffer][k].rob;
    assign sb_rs1[k] = queue_operands[StoreBuffer][k][0];
    assign sb_rs2[k] = queue_operands[StoreBuffer][k][1];
  end

  // --------------
  // LSU SUBSYSTEMS
  // --------------

  // LOAD BUFFER
  // -----------
  load_buffer #(
    .Len5Cfg(Len5Cfg)
  ) u_load_buffer (
    .clk_i,
    .rst_ni,
    .flush_i                    (flush),
    .issue_valid_i              (queue_valid[LoadBuffer][LB_WIDTH-1:0]),
    .issue_ready_o              (lb_ready),
    .issue_type_i               (lb_type),
    .issue_rs1_i                (lb_rs1),
    .issue_imm_i                (lb_imm),
    .issue_dest_rob_idx_i       (lb_rob),
    .issue_sq_tail_i            (load_sq_tail[LB_WIDTH-1:0]),
    .issue_older_stores_remain_i(older_stores_remain[LB_WIDTH-1:0]),
    .cdb_valid_i,
    .cdb_ready_i                (cdb_lb_ready_i),
    .cdb_valid_o                (cdb_lb_valid_o),
    .cdb_data_i,
    .cdb_data_o                 (cdb_lb_data_o),
    .sq_head_i                  (sq_head),
    .sq_removed_i               (sq_removed),
    .sq_addr_ready_i            (sq_addr_ready),
    .sq_data_ready_i            (sq_data_ready),
    .sq_addr_i                  (sq_addr),
    .sq_data_i                  (sq_data),
    .sq_type_i                  (sq_type),
    .adder_valid_i              (adder_lb_valid),
    .adder_ready_i              (adder_lb_ready),
    .adder_valid_o              (lb_adder_valid),
    .adder_ready_o              (lb_adder_ready),
    .adder_ans_i                (adder_lb_ans),
    .adder_req_o                (lb_adder_req),
    .mem_valid_o                (mem_load_valid_o),
    .mem_ready_i                (mem_load_ready_i),
    .mem_valid_i                (mem_load_valid_i),
    .mem_ready_o                (mem_load_ready_o),
    .mem_we_o                   (mem_load_we_o),
    .mem_addr_o                 (mem_load_addr_o),
    .mem_be_o                   (mem_load_be_o),
    .mem_tag_o                  (mem_load_tag_o),
    .mem_rdata_i                (mem_load_rdata_i),
    .mem_tag_i                  (mem_load_tag_i),
    .mem_except_raised_i        (mem_load_except_raised_i),
    .mem_except_code_i          (mem_load_except_code_i)
  );
  // STORE BUFFER
  // ------------
  store_buffer #(
    .Len5Cfg(Len5Cfg)
  ) u_store_buffer (
    .clk_i,
    .rst_ni,
    .flush_i             (flush),
    .issue_valid_i       (queue_valid[StoreBuffer][SB_WIDTH-1:0]),
    .issue_ready_o       (sb_ready),
    .issue_type_i        (sb_type),
    .issue_rs1_i         (sb_rs1),
    .issue_rs2_i         (sb_rs2),
    .issue_imm_i         (sb_imm),
    .issue_dest_rob_idx_i(sb_rob),
    .comm_mem_clear_i    (comm_sb_mem_clear_i),
    .comm_mem_idx_o      (comm_sb_mem_idx_o),
    .cdb_valid_i,
    .cdb_ready_i         (cdb_sb_ready_i),
    .cdb_valid_o         (cdb_sb_valid_o),
    .cdb_data_i,
    .cdb_data_o          (cdb_sb_data_o),
    .sq_head_o           (sq_head),
    .issue_sq_tail_o     (issue_sq_tail),
    .issue_older_stores_remain_o(issue_older_stores_remain),
    .sq_removed_o        (sq_removed),
    .sq_addr_ready_o     (sq_addr_ready),
    .sq_data_ready_o     (sq_data_ready),
    .sq_addr_o           (sq_addr),
    .sq_data_o           (sq_data),
    .sq_type_o           (sq_type),
    .adder_valid_i       (adder_sb_valid),
    .adder_ready_i       (adder_sb_ready),
    .adder_valid_o       (sb_adder_valid),
    .adder_ready_o       (sb_adder_ready),
    .adder_ans_i         (adder_sb_ans),
    .adder_req_o         (sb_adder_req),
    .mem_valid_o         (mem_store_valid_o),
    .mem_ready_i         (mem_store_ready_i),
    .mem_valid_i         (mem_store_valid_i),
    .mem_ready_o         (mem_store_ready_o),
    .mem_we_o            (mem_store_we_o),
    .mem_addr_o          (mem_store_addr_o),
    .mem_be_o            (mem_store_be_o),
    .mem_wdata_o         (mem_store_wdata_o),
    .mem_tag_o           (mem_store_tag_o),
    .mem_tag_i           (mem_store_tag_i),
    .mem_except_raised_i (mem_store_except_raised_i),
    .mem_except_code_i   (mem_store_except_code_i)
  );
  // LOAD ADDRESS ADDER
  // ------------------
  address_adder #(
    .Len5Cfg (Len5Cfg),
    .IS_STORE(1'b0)
  ) u_address_adder_load (
    .clk_i,
    .rst_ni,
    .flush_i(flush),
    .valid_i(lb_adder_valid),
    .ready_i(lb_adder_ready),
    .valid_o(adder_lb_valid),
    .ready_o(adder_lb_ready),
    .req_i  (lb_adder_req),
    .ans_o  (adder_lb_ans)
  );

  // STORE ADDRESS ADDER
  // -------------------
  address_adder #(
    .Len5Cfg (Len5Cfg),
    .IS_STORE(1'b1)
  ) u_address_adder_store (
    .clk_i,
    .rst_ni,
    .flush_i(flush),
    .valid_i(sb_adder_valid),
    .ready_i(sb_adder_ready),
    .valid_o(adder_sb_valid),
    .ready_o(adder_sb_ready),
    .req_i  (sb_adder_req),
    .ans_o  (adder_sb_ans)
  );

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
  for (genvar l = 0; l < Len5Cfg.LDBUFF_DEPTH; l++) begin : gen_check_older_stores
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush)
                     !u_load_buffer.free_slots[l] |->
                         (u_load_buffer.gen_dependencies[l].older_stores & ~u_store_buffer.occupied_slots) == '0)
    else $fatal(1, "LQ older-store interval includes an empty SQ slot");
  end

  always_ff @(posedge clk_i)
    if (rst_ni && !flush) begin
      assert ($countones(queue_valid[LoadBuffer]) <= LB_WIDTH)
      else $fatal(1, "load allocation exceeds its issue width");
      assert ($countones(queue_valid[StoreBuffer]) <= SB_WIDTH)
      else $fatal(1, "store allocation exceeds its issue width");
      assert ($countones(queue_valid[LoadBuffer]) + $countones(queue_valid[StoreBuffer]) ==
              $countones(fifo_valid & fifo_pop_ready))
      else $fatal(1, "LSU routing lost or duplicated an accepted instruction");
    end
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush)
                   cdb_lb_valid_o && !cdb_lb_ready_i |=> cdb_lb_valid_o)
  else $fatal(1, "LSU load completion withdrawn before acceptance");
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush)
                   cdb_sb_valid_o && !cdb_sb_ready_i |=> cdb_sb_valid_o && $stable(
      cdb_sb_data_o
  ))
  else $fatal(1, "LSU store completion changed under backpressure");
  always_ff @(posedge clk_i)
    if (rst_ni && !flush) begin
      for (int k = 0; k < WIDTH; k++) begin
        if (fifo_push[k] && fifo_ready[k])
          for (int j = 0; j < k; j++)
          assert (fifo_push[j] && fifo_ready[j])
          else $fatal(1, "LSU transfer skipped older offer");
      end
    end
`endif
endmodule
