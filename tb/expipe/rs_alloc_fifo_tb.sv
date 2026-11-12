`include "len5_typedef.svh"
module rs_alloc_fifo_case #(
    parameter int WIDTH = 4,
    parameter int DEPTH = 3,
    parameter int LIMIT = 2,
    parameter expipe_pkg::issue_eu_t EU = expipe_pkg::EU_FPU,
    parameter bit ENABLED = 1
) (
    input  logic clk,
    output logic done
);
  function automatic len5_config_pkg::len5_cfg configuration();
    len5_config_pkg::len5_user_cfg_t cfg = len5_config_pkg::DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = WIDTH;
    cfg.ALU_USE_FIFO = ENABLED;
    cfg.ALU_FIFO_DEPTH = DEPTH;
    cfg.ALU_ISSUE_WIDTH = LIMIT;
    cfg.LSU_USE_FIFO = ENABLED;
    cfg.LSU_FIFO_DEPTH = DEPTH;
    cfg.LSU_ISSUE_WIDTH = LIMIT;
    cfg.FPU_USE_FIFO = ENABLED;
    cfg.FPU_FIFO_DEPTH = DEPTH;
    cfg.FPU_ISSUE_WIDTH = LIMIT;
    return len5_config_pkg::build_config(cfg);
  endfunction
  localparam len5_config_pkg::len5_cfg Cfg = configuration();
  localparam bit IsLsu = EU inside {expipe_pkg::EU_LOAD_BUFFER, expipe_pkg::EU_STORE_BUFFER};
  localparam int OPERANDS = EU == expipe_pkg::EU_FPU ? 3 : 2;
  localparam int PayloadWidth = Cfg.ROB_IDX_LEN + (EU == expipe_pkg::EU_FPU ?
      expipe_pkg::FPU_CTL_LEN + csr_pkg::FCSR_FRM_LEN :
      IsLsu ? $bits(
      expipe_pkg::ldst_width_t
  ) + len5_pkg::XLEN + 1 : expipe_pkg::MAX_EU_CTL_LEN);
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_t;
  typedef struct packed {
    int id;
    operand_t [OPERANDS-1:0] operands;
  } entry_t;
  logic rst_n = 0, flush = 0, cdb_valid;
  logic [WIDTH-1:0] valid_in, ready_in, valid_out, ready_out;
  typedef logic [PayloadWidth-1:0] payload_t;
  payload_t [WIDTH-1:0] data_in, data_out;
  operand_t [WIDTH-1:0][OPERANDS-1:0] ops_in, ops_out;
  cdb_t cdb;
  entry_t model[$];
  int serial = 0;
  int unsigned rng = 32'hba5e + WIDTH * 101 + DEPTH * 17 + LIMIT;
  function automatic int unsigned random_value();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction
  function automatic entry_t wake(entry_t entry);
    entry_t result;
    result = entry;
    for (int o = 0; o < OPERANDS; o++) begin
      if (!entry.operands[o].ready && cdb_valid && entry.operands[o].rob_idx == cdb.rob_idx) begin
        result.operands[o].ready = 1;
        result.operands[o].value = cdb.res_value;
      end
    end
    return result;
  endfunction
  for (genvar k = LIMIT; k < WIDTH; k++) begin : gen_unused_allocation
    assign ready_out[k] = 1'b0;
    assign valid_out[k] = 1'b0;
    assign data_out[k] = '0;
    assign ops_out[k] = '0;
  end
  rs_alloc_fifo #(
      .Len5Cfg(Cfg),
      .EU(EU)
  ) dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .flush_i(flush),
      .valid_i(valid_in[LIMIT-1:0]),
      .ready_o(ready_out[LIMIT-1:0]),
      .payload_i(data_in[LIMIT-1:0]),
      .operands_i(ops_in[LIMIT-1:0]),
      .valid_o(valid_out[LIMIT-1:0]),
      .ready_i(ready_in[LIMIT-1:0]),
      .payload_o(data_out[LIMIT-1:0]),
      .operands_o(ops_out[LIMIT-1:0]),
      .cdb_valid_i(cdb_valid),
      .cdb_data_i(cdb)
  );
  initial begin
    done = 0;
    valid_in = 0;
    ready_in = 0;
    cdb_valid = 0;
    cdb = '0;
    ops_in = '0;
    data_in = '0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int cycle = 0; cycle < 600; cycle++) begin
      int old_size, popped;
      entry_t expected, discarded, forwarded;
      if (cycle == 310) begin
        rst_n = 0;
        valid_in = '0;
        model.delete();
        #1;
        assert (valid_out == '0)
        else $fatal(1, "reset retained entries");
        @(negedge clk);
        rst_n = 1;
      end
      flush = cycle % 73 == 30;
      // Deterministic full/stall/drain phases, then randomized transfers.
      valid_in = cycle < 12 ? '1 : WIDTH'((1 << (random_value() % (WIDTH + 1))) - 1);
      ready_in = cycle < 6 ? '0 : cycle < 12 ? '1 : WIDTH'((1 << (random_value() % (WIDTH + 1))) - 1);
      if (cycle > 570) begin
        valid_in = '0;
        ready_in = '1;
      end
      cdb_valid = cycle % 3 != 0;
      cdb.rob_idx = Cfg.ROB_IDX_LEN'(cycle % 4);
      cdb.res_value = 64'(cycle + 1000);
      for (int k = 0; k < WIDTH; k++) begin
        data_in[k] = PayloadWidth'(serial++);
        for (int o = 0; o < OPERANDS; o++) begin
          ops_in[k][o].ready   = (random_value() % 4 == 0);
          ops_in[k][o].rob_idx = Cfg.ROB_IDX_LEN'(random_value() % 4);
          ops_in[k][o].value   = 64'(serial + o);
        end
        // Commit-side forwarding resolves current CDB matches before FIFO insertion.
        forwarded = wake('{int'(data_in[k]), ops_in[k]});
        ops_in[k] = forwarded.operands;
      end
      old_size = model.size();
      popped   = 0;
      #1;
      for (int k = 0; k < WIDTH; k++) begin
        if (ENABLED) begin
          assert (ready_out[k] == (k < LIMIT && k < DEPTH - old_size))
          else $fatal(1, "capacity/reuse");
          assert (valid_out[k] == ((!IsLsu || !flush) && k < LIMIT && k < old_size))
          else $fatal(1, "ordered valid");
          if (valid_out[k]) begin
            expected = wake(model[k]);
            assert (data_out[k] == PayloadWidth'(expected.id) && ops_out[k] == expected.operands)
            else $fatal(1, "FIFO data/forwarding");
          end
          if (valid_out[k] && ready_in[k]) popped++;
        end else begin
          assert (ready_out[k] == (k < LIMIT && ready_in[k]));
          assert (valid_out[k] == ((!IsLsu || !flush) && k < LIMIT && valid_in[k]));
          if (valid_out[k]) begin
            expected = wake('{int'(data_in[k]), ops_in[k]});
            assert (data_out[k] == PayloadWidth'(expected.id) && ops_out[k] == expected.operands)
            else $fatal(1, "bypass forwarding");
          end
        end
        if (k >= LIMIT)
          assert (!ready_out[k] && !valid_out[k] && data_out[k] == 0 && ops_out[k] == '0);
      end
      if (flush) model.delete();
      else if (ENABLED) begin
        for (int i = 0; i < popped; i++) discarded = model.pop_front();
        foreach (model[i]) model[i] = wake(model[i]);
        for (int k = 0; k < WIDTH; k++) begin
          if (valid_in[k] && ready_out[k]) model.push_back(wake('{int'(data_in[k]), ops_in[k]}));
        end
      end
      @(negedge clk);
    end
    assert (model.size() == 0)
    else $fatal(1, "failed to drain");
    done = 1;
  end
endmodule

module rs_alloc_fifo_tb;
  logic clk = 0;
  always #5 clk = !clk;
  wire [3:0][4:0][1:0][1:0] done;
  wire [1:0] lsu_done, odd_width_done;
  for (genvar enabled = 0; enabled < 2; enabled++) begin : gen_odd_width
    rs_alloc_fifo_case #(.WIDTH(4), .DEPTH(4), .LIMIT(3),
        .EU(expipe_pkg::EU_INT_ALU), .ENABLED(enabled != 0)) test_case (
      .clk, .done(odd_width_done[enabled])
    );
  end
  for (genvar enabled = 0; enabled < 2; enabled++) begin : gen_lsu_flush
    rs_alloc_fifo_case #(
        .WIDTH(2),
        .DEPTH(4),
        .LIMIT(1),
        .EU(expipe_pkg::EU_LOAD_BUFFER),
        .ENABLED(enabled != 0)
    ) test_case (
        .clk,
        .done(lsu_done[enabled])
    );
  end
  for (genvar w = 0; w < 4; w++) begin : gen_width
    for (genvar d = 0; d < 5; d++) begin : gen_depth
      for (genvar narrow = 0; narrow < 2; narrow++) begin : gen_limit
        for (genvar enabled = 0; enabled < 2; enabled++) begin : gen_enable
          rs_alloc_fifo_case #(
              .WIDTH(1 << w),
              .DEPTH(1 << d),
              .LIMIT(narrow ? 1 : (1 << w)),
              .EU(narrow ? expipe_pkg::EU_INT_ALU : expipe_pkg::EU_FPU),
              .ENABLED(enabled != 0)
          ) test_case (
              .clk,
              .done(done[w][d][narrow][enabled])
          );
        end
      end
    end
  end
  initial begin
    wait ((&done) && (&lsu_done) && (&odd_width_done));
    $display("PASS rs_alloc_fifo: 84 configurations, 600 cycles each");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
