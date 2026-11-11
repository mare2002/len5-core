`include "len5_typedef.svh"

module arith_rs_multi_case #(
  parameter int unsigned NUM_UNITS = 1,
  parameter bit RR = 1'b0,
  parameter bit FPU = 1'b0
) (
  input logic clk_i,
  input logic rst_ni,
  output logic done_o
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  function automatic len5_cfg test_config();
    len5_user_cfg_t cfg;
    cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = 2;
    cfg.ROB_DEPTH = 64;
    cfg.ALU_RS_DEPTH = 16;
    cfg.FPU_RS_DEPTH = 16;
    cfg.ALU_NUM_UNITS = NUM_UNITS;
    cfg.FPU_NUM_UNITS = NUM_UNITS;
    cfg.ALU_RR_ARBITER = RR;
    cfg.FPU_RR_ARBITER = RR;
    return build_config(cfg);
  endfunction

  localparam len5_cfg Cfg = test_config();
  localparam int unsigned CtlLen = expipe_pkg::MAX_EU_CTL_LEN;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_data_t;
  typedef `LEN5_OP_DATA_T(Cfg) op_data_t;
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  localparam int unsigned RsIdxLen = $clog2(Cfg.ALU_RS_DEPTH);
  typedef logic [RsIdxLen-1:0] rs_idx_t;

  logic flush;
  logic [Cfg.ISSUE_WIDTH-1:0] issue_valid, issue_ready;
  logic [Cfg.ISSUE_WIDTH-1:0][CtlLen-1:0] issue_ctl;
  logic [Cfg.ISSUE_WIDTH-1:0][csr_pkg::FCSR_FRM_LEN-1:0] issue_frm;
  op_data_t [Cfg.ISSUE_WIDTH-1:0] issue_rs1, issue_rs2, issue_rs3;
  rob_idx_t [Cfg.ISSUE_WIDTH-1:0] issue_tag;
  logic cdb_ready, cdb_valid_in, cdb_valid_out;
  cdb_data_t cdb_in, cdb_out;
  logic [NUM_UNITS-1:0] request_ready, request_valid, completion_ready, completion_valid;
  logic [NUM_UNITS-1:0][CtlLen-1:0] request_ctl;
  logic [NUM_UNITS-1:0][csr_pkg::FCSR_FRM_LEN-1:0] request_frm;
  logic [NUM_UNITS-1:0][XLEN-1:0] request_rs1, request_rs2, request_rs3, completion_result;
  rs_idx_t [NUM_UNITS-1:0] request_tag, completion_tag;
  rob_idx_t [NUM_UNITS-1:0] request_rob_tag, completion_rob_tag;
  logic [NUM_UNITS-1:0] completion_except;
  except_code_t [NUM_UNITS-1:0] completion_code;
  csr_pkg::fcsr_fflags_t [NUM_UNITS-1:0] completion_flags;
  logic [NUM_UNITS-1:0] manual_valid;
  rs_idx_t [NUM_UNITS-1:0] manual_tag;
  rs_idx_t saved_rs_idx[64];
  logic zero_latency;
  logic [NUM_UNITS-1:0] selected_valid, selected_accepted;
  logic [NUM_UNITS-1:0][RsIdxLen-1:0] selected_idx;

  int issued[64], dispatched[64], completed[64], written[64], tag_lane[64];
  bit cancelled[64];
  logic [XLEN-1:0] expected_rs1[64], expected_rs2[64], expected_rs3[64];
  int last_dispatch_count, max_dispatch_count, last_completion_count;

  if (FPU) begin : gen_fpu
    arith_rs_fpu #(.Len5Cfg(Cfg)) dut (
      .clk_i, .rst_ni, .flush_i(flush), .issue_valid_i(issue_valid), .issue_ready_o(issue_ready),
      .issue_eu_ctl_i(issue_ctl), .issue_frm_i(issue_frm), .issue_rs1_i(issue_rs1),
      .issue_rs2_i(issue_rs2), .issue_rs3_i(issue_rs3), .issue_dest_rob_idx_i(issue_tag),
      .cdb_ready_i(cdb_ready), .cdb_valid_i(cdb_valid_in), .cdb_valid_o(cdb_valid_out),
      .cdb_data_i(cdb_in), .cdb_data_o(cdb_out), .eu_ready_i(request_ready),
      .eu_valid_i(completion_valid), .eu_valid_o(request_valid), .eu_ready_o(completion_ready),
      .eu_rs_idx_i(completion_tag), .eu_result_i(completion_result),
      .eu_except_raised_i(completion_except), .eu_except_code_i(completion_code),
      .eu_fflags_i(completion_flags), .eu_ctl_o(request_ctl), .eu_frm_o(request_frm),
      .eu_rs1_o(request_rs1), .eu_rs2_o(request_rs2), .eu_rs3_o(request_rs3),
      .eu_rs_idx_o(request_tag)
    );
    assign selected_valid = dut.selected_valid;
    assign selected_idx = dut.selected_idx;
    assign selected_accepted = dut.selected_accepted;
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
      assign request_rob_tag[u] = dut.data[request_tag[u]].dest_rob_idx;
      assign completion_rob_tag[u] = dut.data[completion_tag[u]].dest_rob_idx;
    end
  end else begin : gen_integer
    assign request_rs3 = '0;
    assign request_frm = '0;
    arith_rs #(.Len5Cfg(Cfg), .EU(EU_INT_ALU)) dut (
      .clk_i, .rst_ni, .flush_i(flush), .issue_valid_i(issue_valid), .issue_ready_o(issue_ready),
      .issue_eu_ctl_i(issue_ctl), .issue_rs1_i(issue_rs1), .issue_rs2_i(issue_rs2),
      .issue_dest_rob_idx_i(issue_tag), .cdb_ready_i(cdb_ready), .cdb_valid_i(cdb_valid_in),
      .cdb_valid_o(cdb_valid_out), .cdb_data_i(cdb_in), .cdb_data_o(cdb_out),
      .eu_ready_i(request_ready), .eu_valid_i(completion_valid), .eu_valid_o(request_valid),
      .eu_ready_o(completion_ready), .eu_rs_idx_i(completion_tag), .eu_result_i(completion_result),
      .eu_except_raised_i(completion_except), .eu_except_code_i(completion_code),
      .eu_ctl_o(request_ctl), .eu_rs1_o(request_rs1), .eu_rs2_o(request_rs2),
      .eu_rs_idx_o(request_tag)
    );
    assign selected_valid = dut.selected_valid;
    assign selected_idx = dut.selected_idx;
    assign selected_accepted = dut.selected_accepted;
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
      assign request_rob_tag[u] = dut.data[request_tag[u]].dest_rob_idx;
      assign completion_rob_tag[u] = dut.data[completion_tag[u]].dest_rob_idx;
    end
  end

  // The reference counts ready units; the RTL uses one-hot channel masks.
  task automatic check_request_routing();
    int channel;
    logic [NUM_UNITS-1:0] expected_accepted;
    channel = 0;
    expected_accepted = '0;
    if (NUM_UNITS > 1) begin
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (request_ready[u]) begin
          assert (request_valid[u] == selected_valid[channel])
            else $fatal(1, "valid routing mismatch unit=%0d channel=%0d", u, channel);
          if (request_valid[u]) begin
            assert (request_tag[u] == selected_idx[channel])
              else $fatal(1, "index routing mismatch unit=%0d channel=%0d", u, channel);
            expected_accepted[channel] = 1'b1;
          end
          channel++;
        end else begin
          assert (!request_valid[u]) else $fatal(1, "request offered to non-ready unit %0d", u);
        end
      end
      assert (selected_accepted == expected_accepted)
        else $fatal(1, "acceptance routed to incorrect selection channel");
    end
  endtask

  function automatic logic [XLEN-1:0] result_for(int tag);
    return 64'h1000 + 64'(tag) * 17;
  endfunction

  function automatic op_data_t operand(bit ready, int tag, logic [XLEN-1:0] value);
    return '{ready: ready, rob_idx: rob_idx_t'(tag), value: value};
  endfunction

  // Mock units return metadata derived independently from each instruction tag.
  always_comb begin
    completion_valid = manual_valid;
    completion_tag = manual_tag;
    if (zero_latency) begin
      completion_valid = request_valid & request_ready;
      completion_tag = request_tag;
    end
    for (int u = 0; u < NUM_UNITS; u++) begin
      completion_result[u] = result_for(int'(completion_rob_tag[u]));
      completion_except[u] = int'(completion_rob_tag[u]) % 3 == 0;
      completion_code[u] = completion_except[u] ? E_ILLEGAL_INSTRUCTION : E_UNKNOWN;
      completion_flags[u] = csr_pkg::fcsr_fflags_t'(completion_rob_tag[u]);
    end
  end

  always @(posedge clk_i) begin : p_scoreboard
    int tag;
    if (rst_ni && !flush) begin
      check_request_routing();
      last_dispatch_count = 0;
      last_completion_count = 0;
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (request_valid[u] && request_ready[u]) begin
          tag = int'(request_rob_tag[u]);
          assert (issued[tag] == 1 && dispatched[tag] == 0 && !cancelled[tag])
            else $fatal(1, "duplicate/unknown dispatch tag=%0d N=%0d RR=%0b FPU=%0b", tag, NUM_UNITS, RR, FPU);
          assert (request_rs1[u] == expected_rs1[tag] && request_rs2[u] == expected_rs2[tag])
            else $fatal(1, "operand mismatch tag=%0d got=%h,%h expected=%h,%h N=%0d RR=%0b FPU=%0b",
                        tag, request_rs1[u], request_rs2[u], expected_rs1[tag], expected_rs2[tag], NUM_UNITS, RR, FPU);
          assert (request_ctl[u] == CtlLen'(tag));
          if (FPU) begin
            assert (request_rs3[u] == expected_rs3[tag]) else $fatal(1, "rs3 mismatch tag=%0d", tag);
            assert (request_frm[u] == csr_pkg::FCSR_FRM_LEN'(tag));
          end
          dispatched[tag]++;
          tag_lane[tag] = u;
          saved_rs_idx[tag] = request_tag[u];
          last_dispatch_count++;
        end
      end
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (completion_valid[u] && completion_ready[u]) begin
          tag = int'(completion_rob_tag[u]);
          assert (dispatched[tag] == 1 && completed[tag] == 0 && !cancelled[tag])
            else $fatal(1, "duplicate/unknown completion tag=%0d", tag);
          completed[tag]++;
          last_completion_count++;
        end
      end
      if (cdb_valid_out && cdb_ready) begin
        tag = int'(cdb_out.rob_idx);
        assert (completed[tag] == 1 && written[tag] == 0 && !cancelled[tag])
          else $fatal(1, "duplicate/unknown CDB tag=%0d", tag);
        assert (cdb_out.res_value == result_for(tag));
        assert (cdb_out.except_raised == (tag % 3 == 0));
        assert (cdb_out.except_code == ((tag % 3 == 0) ? E_ILLEGAL_INSTRUCTION : E_UNKNOWN));
        if (FPU) begin
          assert (cdb_out.flags.fflags == csr_pkg::fcsr_fflags_t'(tag));
        end else begin
          assert (cdb_out.flags.raw == '0);
        end
        written[tag]++;
      end
      if (last_dispatch_count > max_dispatch_count) max_dispatch_count = last_dispatch_count;
    end
  end

  // Stimulus changes on falling edges; the scoreboard samples handshakes first.
  task automatic tick();
    @(posedge clk_i);
    #1;
    @(negedge clk_i);
  endtask

  task automatic set_issue(int lane, int tag, op_data_t a, op_data_t b, op_data_t c,
                           logic [XLEN-1:0] final_a, logic [XLEN-1:0] final_b, logic [XLEN-1:0] final_c);
    issue_valid[lane] = 1'b1;
    issue_tag[lane] = rob_idx_t'(tag);
    issue_ctl[lane] = CtlLen'(tag);
    issue_frm[lane] = csr_pkg::FCSR_FRM_LEN'(tag);
    issue_rs1[lane] = a;
    issue_rs2[lane] = b;
    issue_rs3[lane] = c;
    assert (issued[tag] == 0);
    issued[tag] = 1;
    expected_rs1[tag] = final_a;
    expected_rs2[tag] = final_b;
    expected_rs3[tag] = final_c;
  endtask

  task automatic enqueue(int tag);
    set_issue(0, tag, operand(1, 0, 64'(tag + 100)), operand(1, 0, 64'(tag + 200)),
              operand(1, 0, 64'(tag + 300)), 64'(tag + 100), 64'(tag + 200), 64'(tag + 300));
    #1;
    assert (issue_ready[0]) else $fatal(1, "unexpected full RS");
    tick();
    issue_valid = '0;
  endtask

  task automatic wait_dispatch(int first_tag, int count);
    bit all_dispatched;
    for (int cycle = 0; cycle < 40; cycle++) begin
      all_dispatched = 1'b1;
      for (int k = 0; k < count; k++) all_dispatched &= dispatched[first_tag+k] == 1;
      if (all_dispatched) return;
      tick();
    end
    $fatal(1, "dispatch timeout first=%0d N=%0d RR=%0b FPU=%0b", first_tag, NUM_UNITS, RR, FPU);
  endtask

  task automatic complete_one(int tag);
    manual_valid = '0;
    manual_valid[tag_lane[tag]] = 1'b1;
    manual_tag[tag_lane[tag]] = saved_rs_idx[tag];
    tick();
    manual_valid = '0;
  endtask

  task automatic drain();
    bit drained;
    cdb_ready = 1'b1;
    for (int cycle = 0; cycle < 80; cycle++) begin
      drained = 1'b1;
      for (int tag = 0; tag < 64; tag++) begin
        if (completed[tag] != 0 && !cancelled[tag] && written[tag] != 1) drained = 1'b0;
      end
      if (drained) begin
        tick();
        cdb_ready = 1'b0;
        return;
      end
      tick();
    end
    $fatal(1, "CDB drain timeout N=%0d RR=%0b FPU=%0b", NUM_UNITS, RR, FPU);
  endtask

  initial begin : p_test
    int accepted_on_last;
    done_o = 1'b0;
    flush = 1'b0;
    issue_valid = '0;
    issue_tag = '0;
    issue_ctl = '0;
    issue_frm = '0;
    issue_rs1 = '0;
    issue_rs2 = '0;
    issue_rs3 = '0;
    cdb_ready = 1'b0;
    cdb_valid_in = 1'b0;
    cdb_in = '0;
    request_ready = '0;
    manual_valid = '0;
    manual_tag = '0;
    zero_latency = 1'b0;
    max_dispatch_count = 0;
    last_dispatch_count = 0;
    last_completion_count = 0;
    for (int tag = 0; tag < 64; tag++) begin
      issued[tag] = 0;
      dispatched[tag] = 0;
      completed[tag] = 0;
      written[tag] = 0;
      tag_lane[tag] = 0;
      saved_rs_idx[tag] = '0;
      cancelled[tag] = 0;
    end
    wait (rst_ni);
    @(negedge clk_i);

    // Simultaneous requests and completions, with result buffering behind CDB stalls.
    for (int k = 0; k < NUM_UNITS; k++) enqueue(1 + k);
    if (NUM_UNITS > 1) begin
      // Sample every readiness pattern without accepting work at a clock edge.
      for (int mask = 0; mask < (1 << NUM_UNITS); mask++) begin
        request_ready = NUM_UNITS'(mask);
        #1;
        check_request_routing();
        request_ready = '0;
        @(negedge clk_i);
      end
    end
    request_ready = '1;
    tick();
    assert (last_dispatch_count == NUM_UNITS) else $fatal(1, "parallel dispatch missing");
    for (int k = 0; k < NUM_UNITS; k++) begin
      manual_valid[tag_lane[1+k]] = 1'b1;
      manual_tag[tag_lane[1+k]] = saved_rs_idx[1+k];
    end
    tick();
    assert (last_completion_count == NUM_UNITS);
    manual_valid = '0;
    repeat (4) tick();
    for (int k = 0; k < NUM_UNITS; k++) assert (written[1+k] == 0);
    drain();

    // A lone selection must reach the only ready physical unit, not unit zero.
    request_ready = '0;
    enqueue(63);
    request_ready[NUM_UNITS-1] = 1'b1;
    wait_dispatch(63, 1);
    assert (tag_lane[63] == NUM_UNITS - 1) else $fatal(1, "single request missed ready unit");
    complete_one(63);
    drain();

    // Only the final physical lane can accept; every accepted tag is tracked.
    request_ready = '0;
    for (int k = 0; k < NUM_UNITS + 2; k++) enqueue(NUM_UNITS + 1 + k);
    request_ready[NUM_UNITS-1] = 1'b1;
    accepted_on_last = 0;
    for (int cycle = 0; cycle < 12 && accepted_on_last < 3; cycle++) begin
      tick();
      accepted_on_last += last_dispatch_count;
    end
    assert (accepted_on_last == 3) else $fatal(1, "ready lane unnecessarily idle");
    request_ready = '1;
    wait_dispatch(NUM_UNITS + 1, NUM_UNITS + 2);
    for (int k = NUM_UNITS + 1; k >= 0; k--) complete_one(NUM_UNITS + 1 + k);
    repeat (3) tick();
    drain();

    // Different local completions and CDB wake resident operands independently.
    // New inserts arrive with CDB operands already resolved by the issue path.
    request_ready = '0;
    enqueue(19);
    enqueue(20);
    set_issue(0, 21, operand(0, 19, 0), operand(0, 20, 0), operand(0, 31, 0),
              result_for(19), result_for(20), 64'hcafe);
    tick();
    issue_valid = '0;
    set_issue(0, 24, operand(0, 19, 0), operand(0, 31, 0), operand(0, 20, 0),
              result_for(19), 64'hcafe, result_for(20));
    tick();
    issue_valid = '0;
    request_ready = '1;
    wait_dispatch(19, 2);
    manual_valid[tag_lane[19]] = 1'b1;
    manual_tag[tag_lane[19]] = saved_rs_idx[19];
    if (NUM_UNITS > 1) begin
      assert (tag_lane[19] != tag_lane[20]);
      manual_valid[tag_lane[20]] = 1'b1;
      manual_tag[tag_lane[20]] = saved_rs_idx[20];
    end
    cdb_valid_in = 1'b1;
    cdb_in.rob_idx = rob_idx_t'(31);
    cdb_in.res_value = 64'hcafe;
    set_issue(0, 22, operand(0, 19, 0), operand(0, 20, 0), operand(1, 31, 64'hcafe),
              result_for(19), result_for(20), 64'hcafe);
    set_issue(1, 23, operand(1, 19, 777), operand(1, 31, 64'hcafe), operand(1, 0, 888), 777, 64'hcafe, 888);
    #1;
    assert (&issue_ready);
    tick();
    issue_valid = '0;
    manual_valid = '0;
    cdb_valid_in = 1'b0;
    if (NUM_UNITS == 1) complete_one(20);
    wait_dispatch(21, 4);
    for (int tag = 24; tag >= 21; tag--) complete_one(tag);
    drain();

    // Combinational completion of the very request accepted on this edge.
    request_ready = '0;
    for (int k = 0; k < NUM_UNITS; k++) enqueue(32+k);
    zero_latency = 1'b1;
    request_ready = '1;
    tick();
    assert (last_dispatch_count == NUM_UNITS && last_completion_count == NUM_UNITS);
    zero_latency = 1'b0;
    drain();

    // Flush with active units, a queued result, and an unaccepted request.
    request_ready = '0;
    for (int k = 0; k < NUM_UNITS; k++) enqueue(44+k);
    request_ready = '1;
    wait_dispatch(44, NUM_UNITS);
    complete_one(44);
    request_ready = '0;
    enqueue(54);
    flush = 1'b1;
    if (NUM_UNITS > 1) begin
      manual_valid[tag_lane[45]] = 1'b1;
      manual_tag[tag_lane[45]] = saved_rs_idx[45];
    end
    tick();
    for (int k = 0; k < NUM_UNITS; k++) cancelled[44+k] = 1'b1;
    cancelled[54] = 1'b1;
    manual_valid = '0;
    flush = 1'b0;
    #1;
    assert (!cdb_valid_out && request_valid == '0) else $fatal(1, "flush retained work");
    enqueue(55);
    request_ready = '1;
    zero_latency = 1'b1;
    wait_dispatch(55, 1);
    zero_latency = 1'b0;
    drain();

    for (int tag = 0; tag < 64; tag++) begin
      if (issued[tag] != 0 && !cancelled[tag]) begin
        assert (dispatched[tag] == 1 && completed[tag] == 1 && written[tag] == 1)
          else $fatal(1, "lost instruction tag=%0d N=%0d RR=%0b FPU=%0b", tag, NUM_UNITS, RR, FPU);
      end
    end
    $display("PASS arith RS N=%0d RR=%0b FPU=%0b", NUM_UNITS, RR, FPU);
    done_o = 1'b1;
  end
endmodule

module arith_rs_multi_tb;
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic [19:0] done;
  always #5 clk = ~clk;
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    wait (&done);
    $display("PASS all integer/FPU RS directed cases");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "RS test watchdog");
  end
  for (genvar size = 0; size < 5; size++) begin : gen_sizes
    localparam int unsigned N = size < 4 ? size + 1 : 8;
    for (genvar rr = 0; rr < 2; rr++) begin : gen_modes
      for (genvar fp = 0; fp < 2; fp++) begin : gen_categories
        arith_rs_multi_case #(.NUM_UNITS(N), .RR(rr != 0), .FPU(fp != 0)) test_case (
          .clk_i(clk), .rst_ni(rst_n), .done_o(done[size*4+rr*2+fp])
        );
      end
    end
  end
endmodule

module arith_rs_single_tb #(
  parameter int unsigned NUM_UNITS = 1,
  parameter bit RR = 1'b0,
  parameter bit FPU = 1'b0
);
  logic clk = 1'b0;
  logic rst_n = 1'b0;
  logic done;
  always #5 clk = ~clk;
  arith_rs_multi_case #(.NUM_UNITS(NUM_UNITS), .RR(RR), .FPU(FPU)) test_case (
    .clk_i(clk), .rst_ni(rst_n), .done_o(done)
  );
  initial begin
    repeat (4) @(negedge clk);
    rst_n = 1'b1;
    wait (done);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "RS test watchdog");
  end
endmodule
