`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module cdb_sources_case #(
  parameter int unsigned MAX_EU_N = 6
) (
  output logic done = 0
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.MAX_EU_N = MAX_EU_N;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  typedef `LEN5_CDB_DATA_T(Cfg) result_t;
  typedef `LEN5_ROB_IDX_T(Cfg) tag_t;

  logic clk = 0, rst_n = 0, flush = 0, rob_ready = 1;
  logic [CDB_SOURCE_COUNT-1:0] valid = '0, ready;
  result_t [CDB_SOURCE_COUNT-1:0] payload = '0;
  logic result_valid;
  result_t result;
  int offered[CDB_SOURCE_COUNT] = '{default: 0};
  int accepted[CDB_SOURCE_COUNT] = '{default: 0};
  int cancelled[CDB_SOURCE_COUNT] = '{default: 0};
  int next_serial = 1, cycles = 0, stalled_cycles = 0;

  cdb #(.Len5Cfg(Cfg)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .max_prio_valid_i(valid[CDB_STORE_BUFFER]), .max_prio_ready_o(ready[CDB_STORE_BUFFER]),
    .max_prio_data_i(payload[CDB_STORE_BUFFER]),
    .rs_valid_i(valid[CDB_SOURCE_COUNT-1:1]), .rs_ready_o(ready[CDB_SOURCE_COUNT-1:1]),
    .rs_data_i(payload[CDB_SOURCE_COUNT-1:1]),
    .rob_ready_i(rob_ready), .valid_o(result_valid), .data_o(result)
  );

  task automatic offer(input cdb_source_t source);
    assert (!valid[source]) else $fatal(1, "Test replaced an unserved CDB source");
    payload[source] = '0;
    payload[source].rob_idx = tag_t'(next_serial);
    payload[source].res_value = 64'hcdb0000000000000 | (64'(next_serial) << 8) | 64'(source);
    payload[source].except_raised = next_serial[0];
    payload[source].except_code = next_serial[0] ? E_ST_ACCESS_FAULT : E_UNKNOWN;
    payload[source].flags.raw = next_serial[0] ? '1 : '0;
    valid[source] = 1;
    offered[source]++;
    next_serial++;
  endtask

  task automatic tick;
    logic [CDB_SOURCE_COUNT-1:0] transfer;
    int selected;
    #5;
    transfer = '0;
    selected = -1;
    if (rst_n && !flush) begin
      // The existing maximum-priority input is always ready; use it only with a ready ROB.
      assert (!valid[CDB_STORE_BUFFER] || rob_ready) else $fatal(1, "Invalid store backpressure fixture");
      assert ($onehot0(ready[CDB_SOURCE_COUNT-1:1])) else $fatal(1, "Multiple low-priority sources notified");
      assert (result_valid == (|valid)) else $fatal(1, "Pending CDB result disappeared or became phantom");
      if (result_valid) begin
        for (int source = 0; source < CDB_SOURCE_COUNT; source++)
          if (valid[source] && result === payload[source]) begin
            assert (selected == -1) else $fatal(1, "Ambiguous result fixture");
            selected = source;
          end
        assert (selected >= 0) else $fatal(1, "CDB result data/tag/exception/flags do not match a pending source");
        if (valid[CDB_STORE_BUFFER]) begin
          assert (selected == int'(CDB_STORE_BUFFER) && ready[CDB_SOURCE_COUNT-1:1] == '0)
          else $fatal(1, "Store did not preempt low-priority sources");
        end
      end
      if (rob_ready) begin
        transfer = valid & ready;
        assert ($countones(transfer) == int'(result_valid)) else $fatal(1, "CDB acceptance was duplicated or dropped");
        if (result_valid)
          assert (transfer == (CDB_SOURCE_COUNT'(1) << selected)) else $fatal(1, "CDB notified a different source than its output");
      end else begin
        assert ((valid & ready) == '0 && ready[CDB_SOURCE_COUNT-1:1] == '0)
        else $fatal(1, "Low-priority source consumed while ROB was stalled");
        if (|valid) stalled_cycles++;
      end
    end
    clk = 1;
    #1;
    if (!rst_n || flush) begin
      for (int source = 0; source < CDB_SOURCE_COUNT; source++)
        if (valid[source]) cancelled[source]++;
      valid = '0;
    end else begin
      for (int source = 0; source < CDB_SOURCE_COUNT; source++)
        if (transfer[source]) accepted[source]++;
      valid &= ~transfer;
    end
    #4;
    clk = 0;
    cycles++;
  endtask

  task automatic drain;
    rob_ready = 1;
    for (int tries = 0; tries < 3 * CDB_SOURCE_COUNT && valid != '0; tries++) tick();
    assert (valid == '0) else $fatal(1, "Held CDB source never accepted");
    tick();
    assert (!result_valid && ready[CDB_SOURCE_COUNT-1:1] == '0)
    else $fatal(1, "Drained CDB retained a stale source");
  endtask

  initial begin
    int before_load;
    assert (CDB_SOURCE_COUNT == 7 && int'(CDB_STORE_BUFFER) == 0 && int'(CDB_LOAD_BUFFER) == 1 &&
            int'(CDB_BRANCH_UNIT) == 2 && int'(CDB_INT_ALU) == 3 && int'(CDB_INT_MULT) == 4 &&
            int'(CDB_INT_DIV) == 5 && int'(CDB_FPU) == 6)
    else $fatal(1, "CDB source identities changed");
    assert ($bits(dut.rs_valid_i) == CDB_SOURCE_COUNT - 1 &&
            $bits(dut.u_cdb_arbiter.valid_i) == CDB_SOURCE_COUNT - 1)
    else $fatal(1, "CDB source dimension depends on dispatch-unit rows");
    repeat (2) tick();
    rst_n = 1;
    tick();

    // Every source travels through its actual port, including the highest source index.
    for (int source = 0; source < CDB_SOURCE_COUNT; source++) begin
      offer(cdb_source_t'(source));
      tick();
      assert (!valid[source] && accepted[source] == 1) else $fatal(1, "Single-source identity was not accepted");
      drain();
    end

    // Simultaneously pending stores and loads use separate source identities.
    before_load = accepted[CDB_LOAD_BUFFER];
    offer(CDB_LOAD_BUFFER);
    offer(CDB_STORE_BUFFER);
    tick();
    assert (!valid[CDB_STORE_BUFFER] && valid[CDB_LOAD_BUFFER] && accepted[CDB_LOAD_BUFFER] == before_load)
    else $fatal(1, "Store acceptance lost the simultaneously pending load");
    tick();
    assert (!valid[CDB_LOAD_BUFFER] && accepted[CDB_LOAD_BUFFER] == before_load + 1);
    drain();

    // A renewed load waits behind the remainder of the current low-priority batch.
    for (int source = 1; source < CDB_SOURCE_COUNT; source++) offer(cdb_source_t'(source));
    tick();
    assert (!valid[CDB_LOAD_BUFFER]) else $fatal(1, "Load is not in the low-priority source group");
    offer(CDB_LOAD_BUFFER);
    before_load = accepted[CDB_LOAD_BUFFER];
    for (int source = 2; source < CDB_SOURCE_COUNT; source++) begin
      tick();
      assert (!valid[source] && valid[CDB_LOAD_BUFFER] && accepted[CDB_LOAD_BUFFER] == before_load)
      else $fatal(1, "New load bypassed an unserved source in the current batch");
    end
    drain();

    // Low-priority producers retain valid and payload until their own ready handshake.
    for (int source = 1; source < CDB_SOURCE_COUNT; source++) offer(cdb_source_t'(source));
    rob_ready = 0;
    repeat (3 * CDB_SOURCE_COUNT) tick();
    assert (&valid[CDB_SOURCE_COUNT-1:1]) else $fatal(1, "ROB backpressure consumed a source");
    drain();

    // A new store preempts a partially served low-priority batch without losing it.
    offer(CDB_LOAD_BUFFER);
    offer(CDB_BRANCH_UNIT);
    offer(CDB_FPU);
    tick();
    offer(CDB_STORE_BUFFER);
    tick();
    assert (!valid[CDB_STORE_BUFFER] && valid[CDB_BRANCH_UNIT] && valid[CDB_FPU]);
    drain();

    // Flush forgets the arbiter's old batch before accepting new source identities.
    offer(CDB_LOAD_BUFFER);
    offer(CDB_FPU);
    rob_ready = 0;
    tick();
    flush = 1;
    tick();
    flush = 0;
    rob_ready = 1;
    offer(CDB_INT_ALU);
    drain();

    for (int source = 0; source < CDB_SOURCE_COUNT; source++)
      assert (offered[source] == accepted[source] + cancelled[source])
      else $fatal(1, "CDB source %0d lost or duplicated a transaction", source);
    assert (stalled_cycles >= 3 * CDB_SOURCE_COUNT);
    $display("PASS CDB sources MAX_EU_N=%0d CDB_SOURCE_COUNT=%0d cycles=%0d", MAX_EU_N, CDB_SOURCE_COUNT, cycles);
    done = 1;
  end
endmodule

module cdb_sources_tb;
  logic [1:0] done;
  cdb_sources_case #(.MAX_EU_N(6)) six_dispatch_rows (.done(done[0]));
  cdb_sources_case #(.MAX_EU_N(8)) eight_dispatch_rows (.done(done[1]));
  initial begin
    wait (&done);
    $finish;
  end
  initial begin
    #50000;
    $fatal(1, "CDB source test timed out");
  end
endmodule
