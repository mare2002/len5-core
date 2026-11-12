`include "len5_typedef.svh"

module exec_units_multi_case #(
  parameter int NUM_UNITS = 3,
  parameter bit ROUND_ROBIN = 0,
  parameter int KIND = 0,  // ALU, parallel multiply, serial multiply, divide
  parameter int ISSUE_WIDTH = 4,
  parameter int VARIANT = 0
) (
  output bit done
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  localparam int Instructions = 12;

  function automatic len5_cfg make_config();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.LEN5_MULTIPLE_ISSUES = ISSUE_WIDTH;
    cfg.ISSUE_WIDTH          = ISSUE_WIDTH;
    cfg.ALU_ISSUE_WIDTH = ISSUE_WIDTH;
    cfg.MULT_ISSUE_WIDTH = ISSUE_WIDTH;
    cfg.DIV_ISSUE_WIDTH = ISSUE_WIDTH;
    cfg.FPU_ISSUE_WIDTH = ISSUE_WIDTH;

    cfg.ROB_DEPTH            = 64;
    cfg.ALU_RS_DEPTH         = 16;
    cfg.MULT_RS_DEPTH        = 16;
    cfg.DIV_RS_DEPTH         = 16;
    cfg.ALU_NUM_UNITS        = NUM_UNITS;
    cfg.MULT_NUM_UNITS       = NUM_UNITS;
    cfg.DIV_NUM_UNITS        = NUM_UNITS;
    cfg.ALU_RR_ARBITER       = ROUND_ROBIN;
    cfg.MULT_RR_ARBITER      = ROUND_ROBIN;
    cfg.DIV_RR_ARBITER       = ROUND_ROBIN;
    cfg.ALU_SPILL_SKIP       = VARIANT != 0;
    cfg.LEN5_MULT_SERIAL     = KIND == 2;
    cfg.MULT_PIPE_DEPTH      = VARIANT;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = make_config();
  typedef `LEN5_ROB_IDX_T(Cfg) rob_idx_t;
  localparam int unsigned RsIdxLen = $clog2(Cfg.ALU_RS_DEPTH);
  typedef logic [RsIdxLen-1:0] rs_idx_t;
  typedef `LEN5_OP_DATA_T(Cfg) op_data_t;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_data_t;

  bit clk;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0, score_clear = 0;
  logic [ISSUE_WIDTH-1:0] issue_valid = '0, issue_ready;
  logic [ISSUE_WIDTH-1:0][MAX_EU_CTL_LEN-1:0] issue_control = '0;
  op_data_t [ISSUE_WIDTH-1:0] source_a = '0, source_b = '0;
  rob_idx_t [ISSUE_WIDTH-1:0] destination = '0;
  logic cdb_valid, cdb_ready = 0, forward_valid = 0;
  cdb_data_t cdb_data, forward_data = '0;
  logic [NUM_UNITS-1:0] dispatch, completion;
  rs_idx_t [NUM_UNITS-1:0] dispatch_idx, completion_idx;
  rob_idx_t [NUM_UNITS-1:0] dispatch_tag, completion_tag;
  logic [NUM_UNITS-1:0][XLEN-1:0] execution_a, execution_b;
  logic [NUM_UNITS-1:0][MAX_EU_CTL_LEN-1:0] execution_control;

  if (KIND == 0) begin : gen_alu
    alu_ctl_t [ISSUE_WIDTH-1:0] controls;
    for (genvar k = 0; k < ISSUE_WIDTH; k++) begin : gen_controls
      assign controls[k] = alu_ctl_t'(issue_control[k]);
    end
    alu_unit #(
      .Len5Cfg(Cfg)
    ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .flush_i             (flush),
      .issue_valid_i       (issue_valid),
      .issue_ready_o       (issue_ready),
      .issue_eu_ctl_i      (controls),
      .issue_rs1_i         (source_a),
      .issue_rs2_i         (source_b),
      .issue_dest_rob_idx_i(destination),
      .cdb_ready_i         (cdb_ready),
      .cdb_valid_i         (forward_valid),
      .cdb_valid_o         (cdb_valid),
      .cdb_data_i          (forward_data),
      .cdb_data_o          (cdb_data)
    );
    assign dispatch          = dut.rs_alu_valid & dut.alu_rs_ready;
    assign completion        = dut.alu_rs_valid & dut.rs_alu_ready;
    assign dispatch_idx      = dut.rs_alu_idx;
    assign completion_idx    = dut.alu_rs_idx;
    assign execution_a       = dut.rs_alu_rs1_value;
    assign execution_b       = dut.rs_alu_rs2_value;
    assign execution_control = dut.rs_alu_ctl;
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
      assign dispatch_tag[u] = dut.u_arith_rs.data[dispatch_idx[u]].dest_rob_idx;
      assign completion_tag[u] = dut.u_arith_rs.data[completion_idx[u]].dest_rob_idx;
    end
  end else if (KIND == 1 || KIND == 2) begin : gen_mult
    mult_ctl_t [ISSUE_WIDTH-1:0] controls;
    for (genvar k = 0; k < ISSUE_WIDTH; k++) begin : gen_controls
      assign controls[k] = mult_ctl_t'(issue_control[k]);
    end
    mult_unit #(
      .Len5Cfg(Cfg)
    ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .flush_i             (flush),
      .issue_valid_i       (issue_valid),
      .issue_ready_o       (issue_ready),
      .issue_eu_ctl_i      (controls),
      .issue_rs1_i         (source_a),
      .issue_rs2_i         (source_b),
      .issue_dest_rob_idx_i(destination),
      .cdb_ready_i         (cdb_ready),
      .cdb_valid_i         (forward_valid),
      .cdb_valid_o         (cdb_valid),
      .cdb_data_i          (forward_data),
      .cdb_data_o          (cdb_data)
    );
    assign dispatch          = dut.rs_mult_valid & dut.mult_rs_ready;
    assign completion        = dut.mult_rs_valid & dut.rs_mult_ready;
    assign dispatch_idx      = dut.rs_mult_idx;
    assign completion_idx    = dut.mult_rs_idx;
    assign execution_a       = dut.rs_mult_rs1_value;
    assign execution_b       = dut.rs_mult_rs2_value;
    assign execution_control = dut.rs_mult_ctl;
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
      if (KIND == 2) begin : gen_serial
        assign dispatch_tag[u] = dut.gen_serial_mult_unit.u_mult_rs.data[dispatch_idx[u]].dest_rob_idx;
        assign completion_tag[u] = dut.gen_serial_mult_unit.u_mult_rs.data[completion_idx[u]].dest_rob_idx;
      end else begin : gen_parallel
        assign dispatch_tag[u] = dut.gen_parallel_mult_unit.u_mult_rs.data[dispatch_idx[u]].dest_rob_idx;
        assign completion_tag[u] = dut.gen_parallel_mult_unit.u_mult_rs.data[completion_idx[u]].dest_rob_idx;
      end
    end
  end else begin : gen_div
    div_ctl_t [ISSUE_WIDTH-1:0] controls;
    for (genvar k = 0; k < ISSUE_WIDTH; k++) begin : gen_controls
      assign controls[k] = div_ctl_t'(issue_control[k]);
    end
    div_unit #(
      .Len5Cfg(Cfg)
    ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .flush_i             (flush),
      .issue_valid_i       (issue_valid),
      .issue_ready_o       (issue_ready),
      .issue_eu_ctl_i      (controls),
      .issue_rs1_i         (source_a),
      .issue_rs2_i         (source_b),
      .issue_dest_rob_idx_i(destination),
      .cdb_ready_i         (cdb_ready),
      .cdb_valid_i         (forward_valid),
      .cdb_valid_o         (cdb_valid),
      .cdb_data_i          (forward_data),
      .cdb_data_o          (cdb_data)
    );
    assign dispatch          = dut.rs_div_valid & dut.div_rs_ready;
    assign completion        = dut.div_rs_valid & dut.rs_div_ready;
    assign dispatch_idx      = dut.rs_div_idx;
    assign completion_idx    = dut.div_rs_idx;
    assign execution_a       = dut.rs_div_rs1_value;
    assign execution_b       = dut.rs_div_rs2_value;
    assign execution_control = dut.rs_div_ctl;
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_reference_tags
      assign dispatch_tag[u] = dut.u_div_rs.data[dispatch_idx[u]].dest_rob_idx;
      assign completion_tag[u] = dut.u_div_rs.data[completion_idx[u]].dest_rob_idx;
    end
  end

  function automatic logic [MAX_EU_CTL_LEN-1:0] operation(input int tag);
    if (KIND == 0) begin
      case (tag % 6)
        0:       return ALU_ADD;
        1:       return ALU_SUB;
        2:       return ALU_XOR;
        3:       return ALU_ADDW;
        4:       return ALU_SLL;
        default: return ALU_SRA;
      endcase
    end else if (KIND == 1 || KIND == 2) return MAX_EU_CTL_LEN'(tag % 5);
    else return MAX_EU_CTL_LEN'(tag % 8);
  endfunction

  function automatic logic [XLEN-1:0] operand_a(input int phase);
    return phase == 1 ? 64'hffff_ffff_8000_0045 : 64'h0000_0001_8000_0067;
  endfunction

  function automatic logic [XLEN-1:0] operand_b(input int tag);
    case (tag % 4)
      0:       return 3;
      1:       return 1;
      2:       return 0;
      default: return 64'hffff_ffff_ffff_ffff;
    endcase
  endfunction

  function automatic logic [XLEN-1:0] expected_result(input int tag, input int phase);
    logic [63:0] a, b, result;
    logic [ 31:0] word_result;
    logic [127:0] product;
    logic signed [127:0] signed_a, signed_b;
    logic [MAX_EU_CTL_LEN-1:0] ctl;
    a           = operand_a(phase);
    b           = operand_b(tag);
    ctl         = operation(tag);
    word_result = '0;
    result      = '0;
    product     = '0;
    signed_a    = {{64{a[63]}}, a};
    signed_b    = {{64{b[63]}}, b};
    if (KIND == 0) begin
      case (alu_ctl_t'(ctl))
        ALU_ADD: result = a + b;
        ALU_SUB: result = a - b;
        ALU_XOR: result = a ^ b;
        ALU_ADDW: begin
          word_result = a[31:0] + b[31:0];
          result      = {{32{word_result[31]}}, word_result};
        end
        ALU_SLL: result = a << b[5:0];
        ALU_SRA: result = $signed(a) >>> b[5:0];
        default: $fatal(1, "test ALU operation missing");
      endcase
    end else if (KIND == 1 || KIND == 2) begin
      case (mult_ctl_t'(ctl))
        MULT_MUL: result = a * b;
        MULT_MULW: begin
          word_result = a[31:0] * b[31:0];
          result      = {{32{word_result[31]}}, word_result};
        end
        MULT_MULH: begin
          product = 128'(signed_a * signed_b);
          result  = product[127:64];
        end
        MULT_MULHU: begin
          product = 128'(a) * 128'(b);
          result  = product[127:64];
        end
        MULT_MULHSU: begin
          product = 128'(signed_a * $signed({64'b0, b}));
          result  = product[127:64];
        end
        default:  $fatal(1, "test multiply operation missing");
      endcase
    end else begin
      case (div_ctl_t'(ctl))
        DIV_DIVU:  result = b == 0 ? '1 : a / b;
        DIV_DIV:   result = b == 0 ? '1 : 64'($signed(a) / $signed(b));
        DIV_REMU:  result = b == 0 ? a : a % b;
        DIV_REM:   result = b == 0 ? a : 64'($signed(a) % $signed(b));
        DIV_DIVUW: word_result = b[31:0] == 0 ? '1 : a[31:0] / b[31:0];
        DIV_DIVW:  word_result = b[31:0] == 0 ? '1 : 32'($signed(a[31:0]) / $signed(b[31:0]));
        DIV_REMUW: word_result = b[31:0] == 0 ? a[31:0] : a[31:0] % b[31:0];
        DIV_REMW:  word_result = b[31:0] == 0 ? a[31:0] : 32'($signed(a[31:0]) % $signed(b[31:0]));
        default:   $fatal(1, "test divide operation missing");
      endcase
      if (ctl[2]) result = {{32{word_result[31]}}, word_result};
    end
    return result;
  endfunction

  int current_phase = 1;
  int retired, dispatches, max_dispatches, max_completions;
  bit [Instructions:1] issued, dispatched, executed, seen;
  int                       dispatch_order[Instructions:1];
  bit                       out_of_order;
  logic     [NUM_UNITS-1:0] lane_busy;
  rs_idx_t [NUM_UNITS-1:0] held_tag;
  logic [NUM_UNITS-1:0][XLEN-1:0] held_a, held_b;
  logic [NUM_UNITS-1:0][MAX_EU_CTL_LEN-1:0] held_control;

  always @(posedge clk) begin : scoreboard
    int tag;
    if (!rst_n || flush || score_clear) begin
      retired         = 0;
      dispatches      = 0;
      max_dispatches  = 0;
      max_completions = 0;
      issued          = '0;
      dispatched      = '0;
      executed        = '0;
      seen            = '0;
      out_of_order    = 0;
      lane_busy       = '0;
      held_tag        = '0;
      held_a          = '0;
      held_b          = '0;
      held_control    = '0;
      foreach (dispatch_order[i]) dispatch_order[i] = 0;
    end else begin
      for (int k = 0; k < ISSUE_WIDTH; k++) begin
        if (issue_valid[k] && issue_ready[k]) begin
          tag = int'(destination[k]);
          assert (tag >= 1 && tag <= Instructions && !issued[tag])
          else $fatal(1, "duplicate issue");
          issued[tag] = 1;
        end
      end
      if ($countones(dispatch) > max_dispatches) max_dispatches = $countones(dispatch);
      if ($countones(completion) > max_completions) max_completions = $countones(completion);
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (KIND == 2 && lane_busy[u]) begin
          assert (execution_a[u] == held_a[u] && execution_b[u] == held_b[u] &&
                  execution_control[u] == held_control[u] && dispatch_idx[u] == held_tag[u])
          else $fatal(1, "serial multiplier lane %0d changed active context", u);
        end
        if (dispatch[u]) begin
          tag = int'(dispatch_tag[u]);
          assert (tag >= 1 && tag <= Instructions && issued[tag] && !dispatched[tag])
          else $fatal(1, "duplicate/unissued execution dispatch");
          dispatched[tag]     = 1;
          dispatch_order[tag] = dispatches;
          dispatches++;
          if (KIND == 2)
            assert (!lane_busy[u])
            else $fatal(1, "serial multiplier lane overwritten");
          lane_busy[u]    = 1;
          held_tag[u]     = dispatch_idx[u];
          held_a[u]       = execution_a[u];
          held_b[u]       = execution_b[u];
          held_control[u] = execution_control[u];
        end
      end
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (completion[u]) begin
          tag = int'(completion_tag[u]);
          assert (tag >= 1 && tag <= Instructions && dispatched[tag] && !executed[tag])
          else $fatal(1, "duplicate/unmatched execution completion");
          for (int i = 1; i <= Instructions; i++) begin
            if (dispatched[i] && !executed[i] && dispatch_order[i] < dispatch_order[tag])
              out_of_order = 1;
          end
          executed[tag] = 1;
          lane_busy[u]  = 0;
        end
      end
      if (cdb_valid && cdb_ready) begin
        tag = int'(cdb_data.rob_idx);
        assert (tag >= 1 && tag <= Instructions && executed[tag] && !seen[tag])
        else $fatal(1, "duplicate/stale category CDB writeback");
        assert (cdb_data.res_value == expected_result(
            tag, current_phase
        ) && !cdb_data.except_raised && cdb_data.flags.raw == '0)
        else
          $fatal(
              1,
              "kind=%0d units=%0d RR=%b variant=%0d phase=%0d tag=%0d got=%h expected=%h exception=%b",
              KIND,
              NUM_UNITS,
              ROUND_ROBIN,
              VARIANT,
              current_phase,
              tag,
              cdb_data.res_value,
              expected_result(
                  tag, current_phase
              ),
              cdb_data.except_raised
          );
        seen[tag] = 1;
        retired++;
      end
    end
  end

  task automatic tick;
    @(posedge clk);
    #1;
  endtask

  task automatic send_batch;
    int next_tag, accepted_count;
    next_tag = 1;
    while (next_tag <= Instructions) begin
      @(negedge clk);
      issue_valid = '0;
      for (int k = 0; k < ISSUE_WIDTH; k++) begin
        if (next_tag + k <= Instructions) begin
          issue_valid[k]      = 1;
          issue_control[k]    = operation(next_tag + k);
          destination[k]      = rob_idx_t'(next_tag + k);
          source_a[k].ready   = 0;
          source_a[k].rob_idx = rob_idx_t'(63);
          source_a[k].value   = '0;
          source_b[k].ready   = 1;
          source_b[k].rob_idx = '0;
          source_b[k].value   = operand_b(next_tag + k);
        end
      end
      #1;
      accepted_count = $countones(issue_valid & issue_ready);
      tick();
      next_tag += accepted_count;
    end
    @(negedge clk);
    issue_valid            = '0;
    forward_data           = '0;
    forward_data.rob_idx   = rob_idx_t'(63);
    forward_data.res_value = operand_a(current_phase);
    forward_valid          = 1;
    tick();
    @(negedge clk);
    forward_valid = 0;
  endtask

  task automatic drain;
    int cycles;
    cycles = 0;
    while (retired < Instructions && cycles < 2000) begin
      @(negedge clk);
      cdb_ready = (cycles % 3) != 0;
      tick();
      cycles++;
    end
    assert (retired == Instructions && issued == '1 && dispatched == '1 && executed == '1 && seen == '1)
    else
      $fatal(
          1,
          "kind=%0d U=%0d RR=%b variant=%0d lost instruction: issued=%h dispatched=%h executed=%h seen=%h",
          KIND,
          NUM_UNITS,
          ROUND_ROBIN,
          VARIANT,
          issued,
          dispatched,
          executed,
          seen
      );
    assert (max_dispatches == (NUM_UNITS < Instructions ? NUM_UNITS : Instructions))
    else $fatal(1, "physical units did not dispatch simultaneously");
    if (NUM_UNITS > 1 && KIND < 2) begin
      assert (max_completions > 1)
      else $fatal(1, "parallel physical units did not complete simultaneously");
    end
    if (NUM_UNITS > 1 && KIND == 3) begin
      assert (out_of_order)
      else $fatal(1, "divider out-of-order completion scenario not reached");
    end
  endtask

  initial begin : run
    int execution_cycles;
    done = 0;
    repeat (2) tick();
    @(negedge clk);
    rst_n = 1;
    send_batch();
    // All execution results must stay in the shared RS during CDB backpressure.
    execution_cycles = 0;
    while (executed != '1 && execution_cycles < 2000) begin
      tick();
      execution_cycles++;
    end
    repeat (8) tick();
    assert (retired == 0 && cdb_valid && executed == '1)
    else $fatal(1, "buffered execution completion lost under CDB backpressure");
    drain();

    @(negedge clk);
    cdb_ready   = 0;
    score_clear = 1;
    tick();
    @(negedge clk);
    score_clear = 0;
    send_batch();
    repeat (2) tick();
    // Flush with EUs active and/or completed results waiting for the single CDB.
    @(negedge clk);
    flush = 1;
    tick();
    @(negedge clk);
    flush         = 0;
    current_phase = 2;
    // Reuse the same ROB tags immediately, with different expected values.
    send_batch();
    drain();
    @(negedge clk);
    cdb_ready = 1;
    repeat (80) begin
      tick();
      assert (!cdb_valid)
      else $fatal(1, "late duplicate writeback after restart");
    end
    done = 1;
  end
endmodule

// Build one physical-unit configuration at a time to bound compiler memory.
module exec_units_multi_tb #(
  parameter int NUM_UNITS = 1,
  parameter bit ROUND_ROBIN = 1'b0,
  parameter int KIND = 1,
  parameter int ISSUE_WIDTH = 2,
  parameter int VARIANT = 1
);
  bit done;
  exec_units_multi_case #(
    .NUM_UNITS(NUM_UNITS),
    .ROUND_ROBIN(ROUND_ROBIN),
    .KIND(KIND),
    .ISSUE_WIDTH(ISSUE_WIDTH),
    .VARIANT(VARIANT)
  ) test_case (.done(done));

  initial begin
    wait (done);
    $display("PASS physical execution wrapper: kind=%0d units=%0d rr=%0d variant=%0d",
             KIND, NUM_UNITS, ROUND_ROBIN, VARIANT);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "physical execution wrapper test timed out");
  end
endmodule

// Retain the original broad matrix for an explicitly requested larger run.
module exec_units_multi_matrix_tb;
  logic [1:0][4:0][3:0] done;
  logic [1:0][1:0]      extra_done;
  for (genvar rr = 0; rr < 2; rr++) begin : gen_modes
    for (genvar k = 0; k < 5; k++) begin : gen_counts
      localparam int Units = k == 0 ? 1 : k == 1 ? 2 : k == 2 ? 3 : k == 3 ? 4 : 8;
      for (genvar kind = 0; kind < 4; kind++) begin : gen_categories
        localparam int Variant = kind == 0 ? k % 2 : kind == 1 ? 1 + k % 2 : 0;
        exec_units_multi_case #(
          .NUM_UNITS  (Units),
          .ROUND_ROBIN(rr != 0),
          .KIND       (kind),
          .ISSUE_WIDTH(k % 2 == 0 ? 2 : 4),
          .VARIANT    (Variant)
        ) test_case (
          .done(done[rr][k][kind])
        );
      end
    end
    exec_units_multi_case #(
      .NUM_UNITS  (3),
      .ROUND_ROBIN(rr != 0),
      .KIND       (0),
      .VARIANT    (1)
    ) alu_bypass (
      .done(extra_done[rr][0])
    );
    exec_units_multi_case #(
      .NUM_UNITS  (3),
      .ROUND_ROBIN(rr != 0),
      .KIND       (1),
      .VARIANT    (2)
    ) mult_two_pipe (
      .done(extra_done[rr][1])
    );
  end
  initial begin
    wait (&done && &extra_done);
    $display("PASS physical execution wrappers: 44 ALU/parallel/serial/divider configurations");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "physical execution wrapper regression timed out");
  end
endmodule
