`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module issue_offer_tb #(
  parameter int unsigned ISSUE_WIDTH = 4,
  parameter bit DECODE_SPILL = 0
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  localparam int unsigned FetchWidth = 8;
  localparam int unsigned SecondLane = ISSUE_WIDTH > 1 ? 1 : 0;

  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.LEN5_MULTIPLE_ISSUES  = FetchWidth;
    cfg.ISSUE_WIDTH           = ISSUE_WIDTH;
    cfg.ISSUE_DECODE_SPILL_EN = DECODE_SPILL;
    cfg.IQ_DEPTH              = 32;
    cfg.ROB_DEPTH             = 64;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  typedef `LEN5_ROB_IDX_T(Cfg) tag_t;
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef struct packed {
    logic [31:0] instruction;
    logic [63:0] pc;
  } expected_t;

  logic clk = 0, rst_n = 0, flush = 0, resume = 0;
  logic fetch_valid = 0, fetch_ready, fetch_flush;
  logic                   [FetchWidth-1:0]       fetch_mask = '0;
  logic                   [FetchWidth-1:0][31:0] instructions = '0;
  fetch_pkg::prediction_t [FetchWidth-1:0]       predictions = '0;
  logic [ISSUE_WIDTH-1:0] execute_ready = '0, requests, offers, rob_ready = '0, grants;
  logic [ISSUE_WIDTH-1:0] int_updates, fp_updates;
  logic [ISSUE_WIDTH-1:0][REG_IDX_LEN-1:0] destination, rs1_index, rs2_index;
  logic [ISSUE_WIDTH-1:0][REG_IDX_LEN-1:0] rf_rs1_index, rf_rs2_index;
  tag_t [ISSUE_WIDTH-1:0] destination_tag, tail_tags, execute_tags, rs1_tags, rs2_tags;
  tag_t [ISSUE_WIDTH-1:0] query1, query2, query3;
  logic [ISSUE_WIDTH-1:0] busy1, busy2, forward_ready1, forward_ready2, forward_ready3;
  logic [ISSUE_WIDTH-1:0][63:0]
      rf_value1, rf_value2, forward_value1, forward_value2, forward_value3;
  operand_t [ISSUE_WIDTH-1:0] operands1, operands2;
  issue_eu_t  [  ISSUE_WIDTH-1:0]       assigned_units;
  logic       [  ISSUE_WIDTH-1:0][63:0] execute_pc;
  rob_entry_t [  ISSUE_WIDTH-1:0]       rob_data;
  tag_t                                 tail = '0;
  bit         [             31:0]       register_busy = '0;
  tag_t                                 register_tag       [           32];
  logic       [             63:0]       register_value     [           32];
  bit         [Cfg.ROB_DEPTH-1:0]       result_ready = '0;
  logic       [             63:0]       result_value       [Cfg.ROB_DEPTH];
  expected_t                            expected           [            $];
  int accepted = 0, accepted_execution = 0, stalled_offers = 0, cycles = 0;
  logic [63:0] next_pc = 64'h10000;

  for (genvar k = 0; k < ISSUE_WIDTH; k++) begin : gen_mock_lookups
    assign tail_tags[k]      = tail + tag_t'(k);
    assign busy1[k]          = register_busy[rs1_index[k]] && rs1_index[k] != 0;
    assign busy2[k]          = register_busy[rs2_index[k]] && rs2_index[k] != 0;
    assign rs1_tags[k]       = register_tag[rs1_index[k]];
    assign rs2_tags[k]       = register_tag[rs2_index[k]];
    assign rf_value1[k]      = register_value[rf_rs1_index[k]];
    assign rf_value2[k]      = register_value[rf_rs2_index[k]];
    assign forward_ready1[k] = result_ready[query1[k]];
    assign forward_ready2[k] = result_ready[query2[k]];
    assign forward_ready3[k] = result_ready[query3[k]];
    assign forward_value1[k] = result_value[query1[k]];
    assign forward_value2[k] = result_value[query2[k]];
    assign forward_value3[k] = result_value[query3[k]];
  end

  issue_stage #(
    .Len5Cfg(Cfg)
  ) dut (
    .clk_i                    (clk),
    .rst_ni                   (rst_n),
    .flush_i                  (flush),
    .fetch_valid_i            (fetch_valid),
    .fetch_ready_o            (fetch_ready),
    .fetch_valid_instr_i      (fetch_mask),
    .fetch_instr_i            (instructions),
    .fetch_pred_i             (predictions),
    .fetch_except_raised_i    ('0),
    .fetch_except_code_i      ('0),
    .fetch_mis_flush_o        (fetch_flush),
    .int_regstat_valid_o      (int_updates),
    .int_regstat_rs1_busy_i   (busy1),
    .int_regstat_rs1_rob_idx_i(rs1_tags),
    .int_regstat_rs2_busy_i   (busy2),
    .int_regstat_rs2_rob_idx_i(rs2_tags),
    .int_regstat_rd_idx_o     (destination),
    .int_regstat_rob_idx_o    (destination_tag),
    .int_regstat_rs1_idx_o    (rs1_index),
    .int_regstat_rs2_idx_o    (rs2_index),
    .intrf_rs1_value_i        (rf_value1),
    .intrf_rs2_value_i        (rf_value2),
    .intrf_rs1_idx_o          (rf_rs1_index),
    .intrf_rs2_idx_o          (rf_rs2_index),
    .fp_regstat_valid_o       (fp_updates),
    .fp_regstat_rs1_busy_i    ('0),
    .fp_regstat_rs1_rob_idx_i ('0),
    .fp_regstat_rs2_busy_i    ('0),
    .fp_regstat_rs2_rob_idx_i ('0),
    .fp_regstat_rs3_busy_i    ('0),
    .fp_regstat_rs3_rob_idx_i ('0),
    .fp_regstat_rd_idx_o      (),
    .fp_regstat_rob_idx_o     (),
    .fp_regstat_rs1_idx_o     (),
    .fp_regstat_rs2_idx_o     (),
    .fp_regstat_rs3_idx_o     (),
    .fprf_rs1_value_i         ('0),
    .fprf_rs2_value_i         ('0),
    .fprf_rs3_value_i         ('0),
    .fprf_rs1_idx_o           (),
    .fprf_rs2_idx_o           (),
    .fprf_rs3_idx_o           (),
    .ex_ready_i               (execute_ready),
    .ex_mis_i                 (1'b0),
    .ex_req_o                 (requests),
    .ex_valid_o               (offers),
    .ex_assigned_eu_o         (assigned_units),
    .ex_eu_ctl_o              (),
    .ex_frm_o                 (),
    .ex_rs1_o                 (operands1),
    .ex_rs2_o                 (operands2),
    .ex_rs3_o                 (),
    .ex_imm_value_o           (),
    .ex_rob_idx_o             (execute_tags),
    .ex_curr_pc_o             (execute_pc),
    .ex_pred_target_o         (),
    .ex_pred_taken_o          (),
    .comm_ready_i             (rob_ready),
    .comm_valid_o             (grants),
    .comm_resume_i            (resume),
    .comm_tail_idx_i          (tail_tags),
    .comm_data_o              (rob_data),
    .comm_rs1_rob_idx_o       (query1),
    .comm_rs1_ready_i         (forward_ready1),
    .comm_rs1_value_i         (forward_value1),
    .comm_rs2_rob_idx_o       (query2),
    .comm_rs2_ready_i         (forward_ready2),
    .comm_rs2_value_i         (forward_value2),
    .comm_rs3_rob_idx_o       (query3),
    .comm_rs3_ready_i         (forward_ready3),
    .comm_rs3_value_i         (forward_value3),
    .csr_priv_mode_i          (csr_pkg::PRIV_MODE_M),
    .csr_fp_enabled_i         (1'b1)
  );

  task automatic tick;
    logic [ISSUE_WIDTH-1:0] saved_grants, saved_updates;
    rob_entry_t [ISSUE_WIDTH-1:0] saved_data;
    tag_t       [ISSUE_WIDTH-1:0] saved_tags;
    int                           count;
    #4;
    saved_grants  = grants;
    saved_updates = int_updates;
    saved_data    = rob_data;
    saved_tags    = tail_tags;
    count         = $countones(grants);
    if (!rst_n || flush) begin
      expected.delete();
      assert (offers == '0 && grants == '0 && int_updates == '0 && fp_updates == '0)
      else $fatal(1, "Reset/flush allowed an offer or architectural allocation");
    end else begin
      if (fetch_valid && fetch_ready)
        for (int k = 0; k < FetchWidth; k++)
        if (fetch_mask[k])
          expected.push_back('{instruction: instructions[k], pc: predictions[k].pc});
      assert ((grants & ~rob_ready) == '0)
      else $fatal(1, "ROB allocation ignored readiness");
      assert ((offers & execute_ready) == (grants & requests))
      else $fatal(1, "EU acceptance and ROB allocation disagree");
      assert (dut.iq_accepted == grants)
      else $fatal(1, "IQ popped an unaccepted offer");
      assert ((int_updates & ~grants) == '0 && fp_updates == '0)
      else $fatal(1, "Register status updated without acceptance");
      for (int k = 0; k < ISSUE_WIDTH; k++) begin
        if (offers[k]) begin
          assert (rob_ready[k] && (k == 0 || grants[k-1]))
          else $fatal(1, "Offer crossed ROB backpressure or an unaccepted older lane");
          assert (expected.size() > k && rob_data[k].instruction.raw == expected[k].instruction && execute_pc[k] == expected[k].pc)
          else $fatal(1, "Offered instruction moved or changed under backpressure");
          if (!execute_ready[k]) stalled_offers++;
        end
        if (grants[k]) begin
          assert (int_updates[k] == rob_data[k].rd_upd && destination_tag[k] == tail_tags[k])
          else $fatal(1, "Accepted register-status identity differs from ROB allocation");
          if (k != 0)
            assert (grants[k-1])
            else $fatal(1, "Grant is not a program-order prefix");
        end
      end
      for (int k = 0; k < ISSUE_WIDTH; k++)
      if (grants[k]) begin
        expected_t entry;
        assert (expected.size() != 0)
        else $fatal(1, "Duplicate or unrequested ROB allocation");
        entry = expected.pop_front();
        assert (entry.instruction == rob_data[k].instruction.raw && entry.pc == rob_data[k].instr_pc)
        else $fatal(1, "Accepted instructions lost program order");
        accepted++;
        if (offers[k] && execute_ready[k]) accepted_execution++;
      end
    end
    clk = 1;
    #1;
    if (!rst_n || flush) begin
      tail          = '0;
      register_busy = '0;
      result_ready  = '0;
      for (int r = 0; r < 32; r++) begin
        register_tag[r] = '0;
        if (!rst_n) register_value[r] = r == 0 ? 0 : 64'h1000 + 64'(r * 16);
      end
      foreach (result_value[i]) result_value[i] = '0;
    end else begin
      for (int k = 0; k < ISSUE_WIDTH; k++)
      if (saved_grants[k]) begin
        result_ready[saved_tags[k]] = saved_data[k].res_ready;
        result_value[saved_tags[k]] = saved_data[k].res_value;
        if (saved_updates[k] && saved_data[k].rd_idx != 0) begin
          register_busy[saved_data[k].rd_idx] = 1;
          register_tag[saved_data[k].rd_idx]  = saved_tags[k];
        end
      end
      tail = tail + tag_t'(count);
    end
    #5;
    clk = 0;
    cycles++;
  endtask

  function automatic logic [31:0] addi(int destination_reg, int source_reg, int immediate);
    return (32'(immediate) << 20) | (32'(source_reg) << 15) | (32'(destination_reg) << 7) | 32'h13;
  endfunction

  task automatic send_bundle(input int count, input logic [FetchWidth-1:0][31:0] words);
    bit sent;
    sent         = 0;
    instructions = words;
    fetch_mask   = FetchWidth'((1 << count) - 1);
    for (int k = 0; k < FetchWidth; k++) begin
      predictions[k]    = '0;
      predictions[k].pc = next_pc + 64'(4 * k);
    end
    fetch_valid = 1;
    for (int tries = 0; tries < 80 && !sent; tries++) begin
      #1;
      sent = fetch_ready;
      tick();
    end
    assert (sent)
    else $fatal(1, "Fetch bundle never accepted");
    fetch_valid = 0;
    next_pc += 64'(4 * count);
  endtask

  task automatic wait_queued(input int count);
    for (int tries = 0; tries < 80 && $countones(dut.iq_valid) < count; tries++) tick();
    assert ($countones(dut.iq_valid) >= count)
    else $fatal(1, "Decode/IQ never exposed expected instructions");
  endtask

  task automatic drain(input int goal);
    execute_ready = '1;
    rob_ready     = '1;
    for (int tries = 0; tries < 80 && accepted != goal; tries++) tick();
    assert (accepted == goal && expected.size() == 0)
    else $fatal(1, "Accepted count/IQ drain mismatch");
    repeat (5) tick();
    assert (offers == '0 && grants == '0)
    else $fatal(1, "Consumed instructions reappeared");
  endtask

  task automatic clear_pipeline;
    flush       = 1;
    fetch_valid = 0;
    resume      = 0;
    tick();
    flush         = 0;
    execute_ready = '0;
    rob_ready     = '0;
    tick();
  endtask

  initial begin
    logic [FetchWidth-1:0][31:0] words;
    int                          before_count;
    tag_t                        producer_tag;
    repeat (2) tick();
    rst_n = 1;
    tick();

    // Mixed ALU/load/store candidates include a same-bundle producer chain.
    words        = '0;
    words[0]     = addi(5, 1, 1);
    words[1]     = addi(6, 5, 2);
    words[2]     = 32'h00033383;  // LD x7,0(x6)
    words[3]     = 32'h00733423;  // SD x7,8(x6)
    words[4]     = addi(8, 7, 3);
    words[5]     = 32'h00833483;  // LD x9,8(x6)
    words[6]     = 32'h00833823;  // SD x8,16(x6)
    words[7]     = addi(10, 9, 4);
    before_count = accepted;
    send_bundle(FetchWidth, words);
    wait_queued(ISSUE_WIDTH);
    repeat (3) begin
      tick();
      assert (offers == '0 && grants == '0 && int_updates == '0)
      else $fatal(1, "ROB backpressure did not suppress offers");
    end
    // Old contents of the candidate ROB tags must not satisfy a bundle dependency.
    result_ready = '1;
    foreach (result_value[i]) result_value[i] = 64'hbad;
    rob_ready        = '1;
    execute_ready    = '1;
    execute_ready[0] = 0;
    #1;
    assert (offers == ISSUE_WIDTH'(1) && grants == '0)
    else $fatal(1, "Head offer depends on its own EU readiness");
    if (ISSUE_WIDTH > 1)
      assert (!dut.rs1_bundle[SecondLane])
      else $fatal(1, "Dependency used an unaccepted older ROB tag");
    repeat (5) tick();
    if (ISSUE_WIDTH > 1) begin
      execute_ready[0]          = 1;
      execute_ready[SecondLane] = 0;
      producer_tag              = tail_tags[0];
      #1;
      assert (offers == ISSUE_WIDTH'(3) && grants == ISSUE_WIDTH'(1))
      else $fatal(1, "Younger stalled offer did not follow older acceptance");
      assert (!operands1[SecondLane].ready && operands1[SecondLane].rob_idx == producer_tag)
      else $fatal(1, "Bundle consumer used stale data instead of accepted producer identity");
      tick();
      execute_ready = '0;
      #1;
      assert (offers[0] && !operands1[0].ready && operands1[0].rob_idx == producer_tag)
      else $fatal(1, "Stalled consumer lost the accepted older producer tag after IQ pop");
      repeat (2) tick();
    end
    drain(before_count + FetchWidth);

    // ROB readiness also gates the stalled lane after an older acceptance.
    clear_pipeline();
    words = '0;
    for (int k = 0; k < FetchWidth; k++) words[k] = addi(k + 8, 1, k);
    before_count = accepted;
    send_bundle(ISSUE_WIDTH, words);
    wait_queued(ISSUE_WIDTH);
    rob_ready     = '1;
    execute_ready = '1;
    if (ISSUE_WIDTH > 1) begin
      rob_ready[SecondLane] = 0;
      #1;
      assert (offers == ISSUE_WIDTH'(1) && grants == ISSUE_WIDTH'(1))
      else $fatal(1, "Offer crossed a blocked ROB lane");
      tick();
    end
    drain(before_count + ISSUE_WIDTH);

    // Every physical lane must offer independently of its own execution readiness.
    for (int blocked = 0; blocked < ISSUE_WIDTH; blocked++) begin
      clear_pipeline();
      before_count = accepted;
      send_bundle(ISSUE_WIDTH, words);
      wait_queued(ISSUE_WIDTH);
      rob_ready              = '1;
      execute_ready          = '1;
      execute_ready[blocked] = 0;
      #1;
      assert (offers == ISSUE_WIDTH'((1 << (blocked + 1)) - 1) &&
              grants == ISSUE_WIDTH'((1 << blocked) - 1))
      else $fatal(1, "Offer/acceptance prefix changed at blocked lane %0d", blocked);
      tick();
      execute_ready = '0;
      #1;
      assert (offers == ISSUE_WIDTH'(1) && grants == '0)
      else $fatal(1, "Blocked instruction was consumed when older lanes advanced");
      tick();
      drain(before_count + ISSUE_WIDTH);
    end

    // A direct LUI allocation releases its dependent EU offer even with EU lane zero stalled.
    clear_pipeline();
    words        = '0;
    words[0]     = 32'h123452b7;  // LUI x5,0x12345
    words[1]     = addi(6, 5, 7);
    before_count = accepted;
    send_bundle(2, words);
    wait_queued(ISSUE_WIDTH > 1 ? 2 : 1);
    rob_ready     = '1;
    execute_ready = '0;
    #1;
    assert (grants[0] && !offers[0] && rob_data[0].res_ready && rob_data[0].res_value == 64'h12345000)
    else $fatal(1, "Direct-result instruction incorrectly waited for EU readiness");
    if (ISSUE_WIDTH > 1)
      assert (offers[SecondLane] && !grants[SecondLane] && operands1[SecondLane].ready && operands1[SecondLane].value == 64'h12345000)
      else $fatal(1, "Direct-result producer did not forward to a stalled bundle consumer");
    tick();
    #1;
    assert (offers[0] && !grants[0] && operands1[0].ready && operands1[0].value == 64'h12345000)
    else $fatal(1, "Direct-result consumer did not retain its value across IQ pop");
    repeat (3) tick();
    drain(before_count + 2);

    // CSR uses serialized allocation, then keeps its successor stalled until commit resumes it.
    clear_pipeline();
    words        = '0;
    words[0]     = 32'h305093f3;  // CSRRW x7,mtvec,x1
    words[1]     = addi(8, 7, 1);
    before_count = accepted;
    send_bundle(2, words);
    wait_queued(ISSUE_WIDTH > 1 ? 2 : 1);
    repeat (6) tick();
    assert (offers == '0 && grants == '0)
    else $fatal(1, "CSR ignored ROB backpressure");
    rob_ready = '1;
    for (int tries = 0; tries < 20 && accepted == before_count; tries++) tick();
    assert (accepted == before_count + 1 && offers == '0)
    else $fatal(1, "Serialized CSR allocation failed");
    repeat (5) tick();
    assert (accepted == before_count + 1 && offers == '0)
    else $fatal(1, "CSR successor issued before commit resume");
    // Model the CSR's architectural read result becoming visible at commit.
    register_value[7] = 64'hcafe;
    register_busy[7]  = 0;
    resume            = 1;
    tick();
    resume = 0;
    for (int tries = 0; tries < 10 && !offers[0]; tries++) tick();
    assert (offers[0] && operands1[0].ready && operands1[0].value == 64'hcafe && grants == '0)
    else $fatal(1, "CSR successor did not resume with the committed operand");
    drain(before_count + 2);

    // A pending offer is canceled by flush and never pops or updates status.
    clear_pipeline();
    words        = '0;
    words[0]     = addi(9, 1, 9);
    before_count = accepted;
    send_bundle(1, words);
    wait_queued(1);
    rob_ready     = '1;
    execute_ready = '0;
    #1;
    assert (offers[0] && !grants[0]);
    clear_pipeline();
    rob_ready     = '1;
    execute_ready = '1;
    repeat (8) tick();
    assert (accepted == before_count && expected.size() == 0 && offers == '0 && grants == '0)
    else $fatal(1, "Flushed offer was later accepted");
    assert (stalled_offers >= 8 && accepted_execution > 0)
    else
      $fatal(
          1, "Missing offer coverage: stalled=%0d accepted=%0d", stalled_offers, accepted_execution
      );
    $display(
        "PASS issue offer ISSUE_WIDTH=%0d DECODE_SPILL=%0d accepted=%0d stalled_offers=%0d cycles=%0d",
        ISSUE_WIDTH, DECODE_SPILL, accepted, stalled_offers, cycles);
    $finish;
  end
endmodule
