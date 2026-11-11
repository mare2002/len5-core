`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module fpu_units_multi_tb #(
  parameter int unsigned NUM_UNITS = 1,
  parameter bit RR = 1'b0,
  parameter bit DOUBLE_PRECISION = 1'b1,
  parameter int unsigned PIPE_DEPTH = 4
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  function automatic len5_cfg test_config();
    len5_user_cfg_t cfg;
    cfg                = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH    = 8;
    cfg.ROB_DEPTH      = 64;
    cfg.FPU_RS_DEPTH   = 16;
    cfg.FPU_NUM_UNITS  = NUM_UNITS;
    cfg.FPU_RR_ARBITER = RR;
    cfg.FPU_PIPE_DEPTH = PIPE_DEPTH;
    cfg.FPU_SPILL_SKIP = 1'b1;
    cfg.LEN5_D_EN      = DOUBLE_PRECISION;
    return build_config(cfg);
  endfunction

  localparam len5_cfg Cfg = test_config();
  localparam int unsigned ForwardProducers = NUM_UNITS > 1 ? 2 : 1;
  // Allocation is high-index first; RR dispatch starts at the low index.
  localparam int unsigned FastDivideTag = RR ? 39 : 32;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_data_t;
  typedef `LEN5_OP_DATA_T(Cfg) op_data_t;
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  localparam int unsigned RsIdxLen = $clog2(Cfg.FPU_RS_DEPTH);
  typedef logic [RsIdxLen-1:0] rs_idx_t;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;
  logic flush = 1'b0;
  logic [7:0] issue_valid, issue_ready;
  fpu_ctl_t [7:0]      issue_ctl;
  logic     [7:0][2:0] issue_frm;
  op_data_t [7:0] issue_rs1, issue_rs2, issue_rs3;
  rob_idx_t [7:0] issue_tag;
  logic     [2:0] csr_frm;
  logic cdb_ready, cdb_valid_in, cdb_valid_out;
  cdb_data_t cdb_in, cdb_out;
  bit pending[64], dispatched[64], completed[64], written[64];
  logic [63:0] expected_result[64];
  logic [ 4:0] expected_flags [64];
  logic [ 2:0] instruction_rm [64];
  int completion_count, written_count, max_dispatch_count, max_completion_count;
  int dispatch_sequence, dispatch_order[64];
  int in_flight[NUM_UNITS];
  int stalled_requests = 0, independent_accepts = 0, dynamic_stall_changes = 0;
  int                       reassigned_requests = 0;
  bit                       offered                 [64];
  bit                       dynamic_divide          [64];
  bit                       out_of_order = 1'b0;
  logic     [NUM_UNITS-1:0] last_stalled = '0;
  rs_idx_t [NUM_UNITS-1:0] prior_request_idx;
  rob_idx_t [NUM_UNITS-1:0] request_rob_tag, completion_rob_tag;
  logic     [          2:0] prior_csr_frm = '0;

  fpu_unit #(
    .Len5Cfg(Cfg)
  ) dut (
    .clk_i               (clk),
    .rst_ni              (rst_n),
    .flush_i             (flush),
    .issue_valid_i       (issue_valid),
    .issue_ready_o       (issue_ready),
    .issue_eu_ctl_i      (issue_ctl),
    .issue_frm_i         (issue_frm),
    .issue_rs1_i         (issue_rs1),
    .issue_rs2_i         (issue_rs2),
    .issue_rs3_i         (issue_rs3),
    .issue_dest_rob_idx_i(issue_tag),
    .csr_frm_i           (csr_frm),
    .cdb_ready_i         (cdb_ready),
    .cdb_valid_i         (cdb_valid_in),
    .cdb_valid_o         (cdb_valid_out),
    .cdb_data_i          (cdb_in),
    .cdb_data_o          (cdb_out)
  );

  for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
    assign request_rob_tag[u] = dut.u_fpu_rs.data[dut.rs_fpu_idx[u]].dest_rob_idx;
    assign completion_rob_tag[u] = dut.u_fpu_rs.data[dut.fpu_rs_idx[u]].dest_rob_idx;
  end

  function automatic logic [63:0] fp32(logic [31:0] value);
    return {DOUBLE_PRECISION ? 32'hffffffff : 32'h0, value};
  endfunction

  function automatic op_data_t operand(logic [63:0] value);
    return '{ready: 1'b1, rob_idx: '0, value: value};
  endfunction

  // Exact IEEE encodings for integers one through ten; independent of DUT arithmetic.
  function automatic logic [63:0] small_float(int value);
    case (value)
      1:       return DOUBLE_PRECISION ? 64'h3ff0000000000000 : fp32(32'h3f800000);
      2:       return DOUBLE_PRECISION ? 64'h4000000000000000 : fp32(32'h40000000);
      3:       return DOUBLE_PRECISION ? 64'h4008000000000000 : fp32(32'h40400000);
      4:       return DOUBLE_PRECISION ? 64'h4010000000000000 : fp32(32'h40800000);
      5:       return DOUBLE_PRECISION ? 64'h4014000000000000 : fp32(32'h40a00000);
      6:       return DOUBLE_PRECISION ? 64'h4018000000000000 : fp32(32'h40c00000);
      7:       return DOUBLE_PRECISION ? 64'h401c000000000000 : fp32(32'h40e00000);
      8:       return DOUBLE_PRECISION ? 64'h4020000000000000 : fp32(32'h41000000);
      9:       return DOUBLE_PRECISION ? 64'h4022000000000000 : fp32(32'h41100000);
      default: return DOUBLE_PRECISION ? 64'h4024000000000000 : fp32(32'h41200000);
    endcase
  endfunction

  always @(posedge clk) begin : p_scoreboard
    int tag, dispatches, completions;
    logic [63:0] completing_tags;
    logic [ 2:0] expected_mode;
    dispatches      = 0;
    completions     = 0;
    completing_tags = '0;
    if (rst_n && !flush) begin
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (dut.fpu_rs_valid[u] && dut.rs_fpu_ready[u])
          completing_tags[completion_rob_tag[u]] = 1'b1;
      end
      if (|(dut.rs_fpu_valid & ~dut.fpu_rs_ready)) stalled_requests++;
      if (|(dut.rs_fpu_valid & ~dut.fpu_rs_ready) && |(dut.rs_fpu_valid & dut.fpu_rs_ready))
        independent_accepts++;
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (last_stalled[u] && csr_frm != prior_csr_frm && dut.rs_fpu_rm[u] == 3'b111)
          dynamic_stall_changes++;
        if (dut.rs_fpu_valid[u]) begin
          tag = int'(request_rob_tag[u]);
          assert (pending[tag])
          else $fatal(1, "unknown FPU offer %0d", tag);
          if (last_stalled[u] && dut.rs_fpu_idx[u] != prior_request_idx[u])
            reassigned_requests++;
          // RR resolves the accepted instruction; fixed priority retains its first-offer mode.
          if ((RR && dut.fpu_rs_ready[u]) || (!RR && !offered[tag])) begin
            expected_mode = instruction_rm[tag] == 3'b111 ? csr_frm : instruction_rm[tag];
            assert (dut.fpu_rm[u] == expected_mode)
            else
              $fatal(
                  1,
                  "rounding mode/tag mismatch tag=%0d got=%b expected=%b",
                  tag,
                  dut.fpu_rm[u],
                  expected_mode
              );
            if (dynamic_divide[tag] && tag != FastDivideTag) begin
              if (DOUBLE_PRECISION)
                expected_result[tag] = expected_mode == 3'b011 ? 64'h3fd5555555555556 : 64'h3fd5555555555555;
              else
                expected_result[tag] = fp32(expected_mode == 3'b011 ? 32'h3eaaaaab : 32'h3eaaaaaa);
            end
          end
          offered[tag] = 1'b1;
        end
        if (dut.rs_fpu_valid[u] && dut.fpu_rs_ready[u]) begin
          tag = int'(request_rob_tag[u]);
          assert (pending[tag] && !dispatched[tag])
          else $fatal(1, "duplicate/unknown FPU request %0d", tag);
          dispatched[tag] = 1'b1;
          in_flight[u]++;
          dispatch_order[tag] = dispatch_sequence;
          dispatch_sequence++;
          if (tag == 26 || tag == 27) begin
            assert (dut.rs_fpu_rs1_value[u] == small_float(
                2
            ) && dut.rs_fpu_rs2_value[u] == small_float(
                3
            ) && dut.rs_fpu_rs3_value[u] == small_float(
                4
            ))
            else $fatal(1, "three-source forwarding mismatch for tag %0d", tag);
          end
          dispatches++;
        end
        if (dut.fpu_rs_valid[u] && dut.rs_fpu_ready[u]) begin
          tag = int'(completion_rob_tag[u]);
          assert (pending[tag] && dispatched[tag] && !completed[tag])
          else $fatal(1, "duplicate/unknown FPU completion %0d", tag);
          assert (dut.fpu_rs_result[u] == expected_result[tag] &&
                  dut.fpu_rs_flags[u] == expected_flags[tag] && !dut.fpu_rs_except_raised[u] &&
                  dut.fpu_rs_except_code[u] == E_UNKNOWN)
          else
            $fatal(
                1,
                "FPU result tag=%0d got=%h flags=%h expected=%h flags=%h",
                tag,
                dut.fpu_rs_result[u],
                dut.fpu_rs_flags[u],
                expected_result[tag],
                expected_flags[tag]
            );
          for (int earlier = 0; earlier < 64; earlier++) begin
            if (dispatched[earlier] && !completed[earlier] && !completing_tags[earlier] &&
                dispatch_order[earlier] < dispatch_order[tag])
              out_of_order = 1'b1;
          end
          completed[tag] = 1'b1;
          in_flight[u]--;
          completion_count++;
          completions++;
        end
      end
      if (dispatches > max_dispatch_count) max_dispatch_count = dispatches;
      if (completions > max_completion_count) max_completion_count = completions;
      if (cdb_valid_out && cdb_ready) begin
        tag = int'(cdb_out.rob_idx);
        assert (pending[tag] && completed[tag] && !written[tag])
        else $fatal(1, "duplicate/unknown FPU writeback %0d", tag);
        assert (cdb_out.res_value == expected_result[tag] && cdb_out.flags.fflags == expected_flags[tag] &&
                !cdb_out.except_raised && cdb_out.except_code == E_UNKNOWN)
        else $fatal(1, "FPU writeback metadata mismatch %0d", tag);
        written[tag] = 1'b1;
        written_count++;
      end
    end
    last_stalled      = rst_n && !flush ? dut.rs_fpu_valid & ~dut.fpu_rs_ready : '0;
    prior_request_idx = dut.rs_fpu_idx;
    prior_csr_frm     = csr_frm;
  end

  for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_request_stability
    assert property (@(posedge clk) disable iff (!rst_n || flush)
      !RR && dut.rs_fpu_valid[u] && !dut.fpu_rs_ready[u] |=> dut.rs_fpu_valid[u] &&
      $stable(
        {dut.rs_fpu_idx[u], dut.rs_fpu_ctl[u], dut.rs_fpu_rm[u], dut.fpu_rm[u],
               dut.rs_fpu_rs1_value[u], dut.rs_fpu_rs2_value[u], dut.rs_fpu_rs3_value[u]}
    ));
  end

  task automatic clear_scoreboard();
    foreach (pending[tag]) begin
      pending[tag]         = 1'b0;
      dispatched[tag]      = 1'b0;
      completed[tag]       = 1'b0;
      written[tag]         = 1'b0;
      expected_result[tag] = '0;
      expected_flags[tag]  = '0;
      instruction_rm[tag]  = '0;
      offered[tag]         = 1'b0;
      dynamic_divide[tag]  = 1'b0;
      dispatch_order[tag]  = 0;
    end
    completion_count  = 0;
    written_count     = 0;
    dispatch_sequence = 0;
    foreach (in_flight[u]) in_flight[u] = 0;
  endtask

  task automatic prepare_slot(int slot, int tag, fpu_ctl_t ctl, logic [63:0] a, logic [63:0] b,
                              logic [63:0] c, logic [63:0] result, logic [4:0] flags = '0,
                              logic [2:0] rm = '0);
    issue_tag[slot]      = rob_idx_t'(tag);
    issue_ctl[slot]      = ctl;
    issue_rs1[slot]      = operand(a);
    issue_rs2[slot]      = operand(b);
    issue_rs3[slot]      = operand(c);
    issue_frm[slot]      = rm;
    pending[tag]         = 1'b1;
    expected_result[tag] = result;
    expected_flags[tag]  = flags;
    instruction_rm[tag]  = rm;
  endtask

  task automatic insert_batch(int count);
    logic [7:0] mask;
    mask = 8'((1 << count) - 1);
    // Let falling-edge input/flush changes settle before sampling ready.
    #1;
    assert ((issue_ready & mask) == mask)
    else $fatal(1, "FPU RS lacks empty insertion prefix");
    issue_valid = mask;
    @(negedge clk);
    issue_valid = '0;
  endtask

  task automatic wait_completions(int count);
    int cycles;
    cycles = 0;
    while (completion_count < count && cycles < 400) begin
      @(negedge clk);
      cycles++;
    end
    assert (completion_count == count)
    else $fatal(1, "FPU completion timeout got=%0d expected=%0d", completion_count, count);
  endtask

  task automatic drain_results(int count);
    int cycles;
    repeat (5) @(negedge clk);
    assert (written_count == 0)
    else $fatal(1, "FPU wrote through CDB backpressure");
    cdb_ready = 1'b1;
    cycles    = 0;
    while (written_count < count && cycles < 100) begin
      @(negedge clk);
      cycles++;
    end
    assert (written_count == count)
    else $fatal(1, "FPU CDB drain timeout");
    cdb_ready = 1'b0;
    repeat (2) @(negedge clk);
  endtask

  task automatic add_batch();
    clear_scoreboard();
    for (int k = 0; k < NUM_UNITS; k++) begin
      prepare_slot(k, k, DOUBLE_PRECISION ? FPU_ADD_D : FPU_ADD_S, small_float(1), small_float(k + 1
                   ), '0, small_float(k + 2));
      issue_rs1[k].ready   = 1'b0;
      issue_rs1[k].rob_idx = rob_idx_t'(63);
    end
    insert_batch(NUM_UNITS);
    // Wake every entry together to exercise simultaneous physical dispatch/completion.
    cdb_valid_in     = 1'b1;
    cdb_in.rob_idx   = rob_idx_t'(63);
    cdb_in.res_value = small_float(1);
    @(negedge clk);
    cdb_valid_in = 1'b0;
    wait_completions(NUM_UNITS);
    drain_results(NUM_UNITS);
  endtask

  task automatic mixed_batch(bit round_up);
    clear_scoreboard();
    csr_frm = round_up ? 3'b011 : 3'b001;
    prepare_slot(0, 8, FPU_MADD_S, fp32(32'h40000000), fp32(32'h40400000), fp32(32'h40800000), fp32(
                 32'h41200000));
    prepare_slot(1, 9, FPU_DIV_S, fp32(32'h3f800000), fp32(32'h00000000), '0, fp32(32'h7f800000),
                 5'b01000);
    prepare_slot(2, 10, FPU_SQRT_S, fp32(32'hbf800000), '0, '0, fp32(32'h7fc00000), 5'b10000);
    prepare_slot(3, 11, FPU_S2I, fp32(32'h3fc00000), '0, '0, round_up ? 64'd2 : 64'd1, 5'b00001,
                 3'b111);
    prepare_slot(4, 12, FPU_S2I, fp32(32'h3fc00000), '0, '0, 64'd2, 5'b00001, 3'b011);
    prepare_slot(5, 13, FPU_S2I, fp32(32'hbfc00000), '0, '0, 64'hfffffffffffffffe, 5'b00001,
                 3'b010);
    prepare_slot(6, 14, FPU_MUL_S, fp32(32'h7f7fffff), fp32(32'h40000000), '0, fp32(32'h7f800000),
                 5'b00101);
    prepare_slot(7, 15, FPU_MUL_S, fp32(32'h00000001), fp32(32'h3f000000), '0, fp32(32'h00000000),
                 5'b00011);
    insert_batch(8);
    wait_completions(8);
    drain_results(8);
  endtask

  task automatic out_of_order_batch();
    int cycles;
    clear_scoreboard();
    prepare_slot(0, 40, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1), small_float(3),
                 '0, DOUBLE_PRECISION ? 64'h3fd5555555555555 : fp32(32'h3eaaaaab), 5'b00001);
    insert_batch(1);
    cycles = 0;
    while (!dispatched[40] && cycles < 100) begin
      @(negedge clk);
      cycles++;
    end
    assert (dispatched[40])
    else $fatal(1, "slow divide did not dispatch");
    prepare_slot(0, 41, DOUBLE_PRECISION ? FPU_ADD_D : FPU_ADD_S, small_float(2), small_float(3),
                 '0, small_float(5));
    insert_batch(1);
    cycles = 0;
    while (!completed[41] && cycles < 100) begin
      @(negedge clk);
      cycles++;
    end
    assert (completed[41] && !completed[40])
    else $fatal(1, "fast add did not complete ahead of the older divide");
    wait_completions(2);
    drain_results(2);
  endtask

  task automatic forwarding_batch();
    int cycles;
    clear_scoreboard();
    for (int k = 0; k < ForwardProducers; k++) begin
      prepare_slot(k, 24 + k, DOUBLE_PRECISION ? FPU_ADD_D : FPU_ADD_S, small_float(1), small_float(
                   k + 1), '0, small_float(k + 2));
      issue_rs1[k].ready   = 1'b0;
      issue_rs1[k].rob_idx = rob_idx_t'(62);
    end
    prepare_slot(ForwardProducers, 26, DOUBLE_PRECISION ? FPU_MADD_D : FPU_MADD_S, '0, small_float(3
                 ), '0, small_float(10));
    issue_rs1[ForwardProducers].ready   = 1'b0;
    issue_rs1[ForwardProducers].rob_idx = rob_idx_t'(24);
    if (NUM_UNITS > 1) begin
      issue_rs2[ForwardProducers].ready   = 1'b0;
      issue_rs2[ForwardProducers].rob_idx = rob_idx_t'(25);
    end
    issue_rs3[ForwardProducers].ready   = 1'b0;
    issue_rs3[ForwardProducers].rob_idx = rob_idx_t'(63);
    insert_batch(ForwardProducers + 1);
    cdb_valid_in     = 1'b1;
    cdb_in.rob_idx   = rob_idx_t'(62);
    cdb_in.res_value = small_float(1);
    @(negedge clk);
    cdb_valid_in = 1'b0;
    cycles       = 0;
    while ($countones(
        dut.fpu_rs_valid & dut.rs_fpu_ready
    ) != ForwardProducers && cycles < 100) begin
      @(negedge clk);
      cycles++;
    end
    assert (cycles < 100)
    else $fatal(1, "simultaneous producer completions not observed");
    // Resident operands consume local results and CDB in the same cycle.
    // The new FMA receives its CDB operand already resolved by the issue path.
    prepare_slot(0, 27, DOUBLE_PRECISION ? FPU_MADD_D : FPU_MADD_S, '0, small_float(3), small_float(4),
                 small_float(10));
    issue_rs1[0].ready   = 1'b0;
    issue_rs1[0].rob_idx = rob_idx_t'(24);
    if (NUM_UNITS > 1) begin
      issue_rs2[0].ready   = 1'b0;
      issue_rs2[0].rob_idx = rob_idx_t'(25);
    end
    issue_rs3[0].rob_idx = rob_idx_t'(63);
    cdb_valid_in         = 1'b1;
    cdb_in.rob_idx       = rob_idx_t'(63);
    cdb_in.res_value     = small_float(4);
    insert_batch(1);
    cdb_valid_in = 1'b0;
    wait_completions(ForwardProducers + 2);
    drain_results(ForwardProducers + 2);
  endtask

  task automatic reassigned_rounding_batch();
    int cycles;
    logic [63:0] truncated_third, rounded_third;
    clear_scoreboard();
    truncated_third = DOUBLE_PRECISION ? 64'h3fd5555555555555 : fp32(32'h3eaaaaaa);
    rounded_third   = DOUBLE_PRECISION ? 64'h3fd5555555555556 : fp32(32'h3eaaaaab);
    // Leave two RS entries free after filling the input pipelines and spill cells.
    for (int batch = 0; batch < 2; batch++) begin
      for (int k = 0; k < (batch == 0 ? 8 : 6); k++) begin
        prepare_slot(k, 32 + batch * 8 + k, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1
                     ), small_float(3), '0, truncated_third, 5'b00001, 3'b001);
      end
      insert_batch(batch == 0 ? 8 : 6);
    end
    cycles = 0;
    while ((dispatch_sequence != 14 || dut.fpu_rs_ready != '0) && cycles < 200) begin
      @(negedge clk);
      cycles++;
    end
    assert (dispatch_sequence == 14 && dut.fpu_rs_ready == '0)
    else
      $fatal(1, "FPUs did not fill: dispatched=%0d ready=%b", dispatch_sequence, dut.fpu_rs_ready);

    prepare_slot(0, 46, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1), small_float(3),
                 '0, truncated_third, 5'b00001, 3'b001);
    insert_batch(1);
    @(negedge clk);
    assert (dut.fpu_rs_ready == '0 && dut.rs_fpu_valid[0] && request_rob_tag[0] == 46)
    else $fatal(1, "missing first stalled rounding-mode offer");

    // The later insertion occupies a lower RS index and replaces lane zero's offer.
    prepare_slot(0, 47, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1), small_float(3),
                 '0, rounded_third, 5'b00001, 3'b011);
    insert_batch(1);
    #1;
    assert (dut.fpu_rs_ready == '0 && dut.rs_fpu_valid[0] && request_rob_tag[0] == 47)
    else $fatal(1, "higher-priority request did not replace stalled offer");
    wait_completions(16);
    drain_results(16);
  endtask

  task automatic stalled_divides();
    int cycles, prior_stalls;
    clear_scoreboard();
    csr_frm      = 3'b001;
    prior_stalls = stalled_requests;
    // Fill all 16 RS entries: two pipelined FPUs can absorb eight requests
    // without stalling, including the mandatory per-unit input spill cells.
    for (int batch = 0; batch < 2; batch++) begin
      for (int k = 0; k < 8; k++) begin
        int          tag;
        logic [ 2:0] rm;
        logic [63:0] result;
        tag = 32 + batch * 8 + k;
        case (k % 4)
          1:       rm = 3'b001;
          2:       rm = 3'b011;
          default: rm = 3'b111;
        endcase
        if (DOUBLE_PRECISION) result = rm == 3'b011 ? 64'h3fd5555555555556 : 64'h3fd5555555555555;
        else result = fp32(rm == 3'b011 ? 32'h3eaaaaab : 32'h3eaaaaaa);
        prepare_slot(k, tag, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1),
                     tag == FastDivideTag ? '0 : small_float(3), '0,
                     tag == FastDivideTag ? (DOUBLE_PRECISION ? 64'h7ff0000000000000 : fp32(
                     32'h7f800000)) : result, tag == FastDivideTag ? 5'b01000 : 5'b00001, rm);
        dynamic_divide[tag] = rm == 3'b111;
      end
      insert_batch(8);
    end
    cycles = 0;
    while (completion_count < 16 && cycles < 600) begin
      if (stalled_requests > prior_stalls) csr_frm = csr_frm == 3'b001 ? 3'b011 : 3'b001;
      @(negedge clk);
      cycles++;
    end
    assert (completion_count == 16 && stalled_requests > prior_stalls)
    else
      $fatal(
          1,
          "FPU backpressure scenario failed: completed=%0d stalls=%0d",
          completion_count,
          stalled_requests - prior_stalls
      );
    drain_results(16);
  endtask

  initial begin
    int active_units;
    issue_valid          = '0;
    issue_ctl            = '0;
    issue_frm            = '0;
    issue_rs1            = '0;
    issue_rs2            = '0;
    issue_rs3            = '0;
    issue_tag            = '0;
    csr_frm              = '0;
    cdb_ready            = 1'b0;
    cdb_valid_in         = 1'b0;
    cdb_in               = '0;
    max_dispatch_count   = 0;
    max_completion_count = 0;
    clear_scoreboard();
    repeat (3) @(negedge clk);
    rst_n = 1'b1;
    repeat (3) @(negedge clk);
    add_batch();
    assert (max_dispatch_count == NUM_UNITS && max_completion_count == NUM_UNITS)
    else
      $fatal(
          1,
          "FPU parallelism not observed dispatch=%0d completion=%0d expected=%0d",
          max_dispatch_count,
          max_completion_count,
          NUM_UNITS
      );
    mixed_batch(1'b0);
    mixed_batch(1'b1);
    out_of_order_batch();
    forwarding_batch();
    if (RR && NUM_UNITS == 2) reassigned_rounding_batch();
    stalled_divides();

    clear_scoreboard();
    prepare_slot(0, 16, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1), small_float(3),
                 '0, DOUBLE_PRECISION ? 64'h3fd5555555555555 : fp32(32'h3eaaaaab), 5'b00001);
    for (int k = 1; k < 8; k++) begin
      if (k < 2)
        prepare_slot(k, 16 + k, DOUBLE_PRECISION ? FPU_DIV_D : FPU_DIV_S, small_float(1),
                     small_float(3), '0, DOUBLE_PRECISION ? 64'h3fd5555555555555 : fp32(32'h3eaaaaab
                     ), 5'b00001);
      else
        prepare_slot(k, 16 + k, DOUBLE_PRECISION ? FPU_ADD_D : FPU_ADD_S, small_float(1),
                     small_float(k + 1), '0, small_float(k + 2));
    end
    insert_batch(8);
    for (int cycles = 0; completion_count == 0 && cycles < 400; cycles++) @(negedge clk);
    assert (completion_count > 0 && completion_count < 8)
    else $fatal(1, "missing active/completed flush window");
    active_units = 0;
    for (int u = 0; u < NUM_UNITS; u++) begin
      if (in_flight[u] > 0) active_units++;
    end
    assert (active_units >= ForwardProducers)
    else $fatal(1, "insufficient active FPUs in flush window");
    flush = 1'b1;
    @(negedge clk);
    clear_scoreboard();
    flush = 1'b0;
    // Reuse flushed ROB tags immediately, with different operations/results.
    for (int k = 0; k < NUM_UNITS; k++) begin
      prepare_slot(k, 16 + k, DOUBLE_PRECISION ? FPU_ADD_D : FPU_ADD_S, small_float(5), small_float(
                   1), '0, small_float(6));
    end
    insert_batch(NUM_UNITS);
    wait_completions(NUM_UNITS);
    drain_results(NUM_UNITS);
    repeat (80) begin
      @(negedge clk);
      assert (!cdb_valid_out && dut.fpu_rs_valid == '0)
      else $fatal(1, "flushed FPU result escaped");
    end
    assert (out_of_order && stalled_requests > 0 && dynamic_stall_changes > 0)
    else
      $fatal(
          1,
          "missing coverage: ooo=%0b stalls=%0d dynamic_changes=%0d",
          out_of_order,
          stalled_requests,
          dynamic_stall_changes
      );
    if (NUM_UNITS == 2) begin
      assert (independent_accepts > 0)
      else $fatal(1, "no independent progress while another FPU stalled");
      if (RR)
        assert (reassigned_requests > 0)
        else $fatal(1, "missing stalled-request reassignment coverage");
    end
    $display(
        "PASS real FPU N=%0d RR=%0b D=%0b PIPE=%0d dispatch=%0d completion=%0d stalls=%0d independent=%0d dynamic=%0d ooo=%0b reassigned=%0d",
        NUM_UNITS, RR, DOUBLE_PRECISION, PIPE_DEPTH, max_dispatch_count, max_completion_count,
        stalled_requests, independent_accepts, dynamic_stall_changes, out_of_order,
        reassigned_requests);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "real FPU test timeout");
  end
endmodule
