// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Directed public-port checks for the source-selected native-memory protocol.
module fetch_mem_drain_tb #(
    parameter logic [31:0] BOOT_PC_HI = 32'((0) >> 32),
    parameter logic [31:0] BOOT_PC_LO = 32'(0),
    parameter longint unsigned BOOT_PC = {BOOT_PC_HI, BOOT_PC_LO},
    parameter int unsigned BOOT_VM_MODE = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BOOT_VM_MODE),
    parameter int unsigned LEN5_MULTIPLE_ISSUES = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULTIPLE_ISSUES,
    parameter bit LEN5_M_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_M_EN,
    parameter bit LEN5_DIV_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_DIV_EN,
    parameter bit LEN5_F_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_F_EN,
    parameter bit LEN5_D_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_D_EN,
    parameter bit LEN5_C_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_C_EN,
    parameter bit LEN5_A_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_A_EN,
    parameter bit LEN5_STORE_LOAD_FWD_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_STORE_LOAD_FWD_EN,
    parameter int unsigned MAX_EU_N = len5_config_pkg::DEFAULT_LEN5_CFG.MAX_EU_N,
    parameter bit ONLY_DOUBLEWORD_MEM_ACCESSES = len5_config_pkg::DEFAULT_LEN5_CFG.ONLY_DOUBLEWORD_MEM_ACCESSES,
    parameter bit LEN5_CSR_HPMCOUNTERS_EN = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_CSR_HPMCOUNTERS_EN,
    parameter logic [31:0] MMAP_MASK_HI = 32'((len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK) >> 32),
    parameter logic [31:0] MMAP_MASK_LO = 32'(len5_config_pkg::DEFAULT_LEN5_CFG.MMAP_MASK),
    parameter logic [63:0] MMAP_MASK = {MMAP_MASK_HI, MMAP_MASK_LO},
    parameter int unsigned BPU_HLEN = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_HLEN,
    parameter int unsigned BPU_BTB_BITS = len5_config_pkg::DEFAULT_LEN5_CFG.BPU_BTB_BITS,
    parameter int unsigned RAS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.RAS_DEPTH,
    parameter int unsigned FETCH_MEMIF_FIFO_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEMIF_FIFO_DEPTH,
    parameter bit FETCH_MEM_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_MEM_DRAIN_ON_FLUSH,
    parameter bit LOAD_BUFFER_DRAIN_ON_FLUSH = len5_config_pkg::DEFAULT_LEN5_CFG.LOAD_BUFFER_DRAIN_ON_FLUSH,
    parameter bit FETCH_REQ_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_REQ_SPILL_SKIP,
    parameter bit FETCH_ANS_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FETCH_ANS_SPILL_SKIP,
    parameter int unsigned IQ_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.IQ_DEPTH,
    parameter int unsigned LDBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.LDBUFF_DEPTH,
    parameter int unsigned STBUFF_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.STBUFF_DEPTH,
    parameter bit LSU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.LSU_SPILL_SKIP,
    parameter int unsigned ALU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RS_DEPTH,
    parameter bit ALU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_SPILL_SKIP,
    parameter bit ALU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.ALU_RR_ARBITER,
    parameter int unsigned MULT_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RS_DEPTH,
    parameter bit LEN5_MULT_SERIAL = len5_config_pkg::DEFAULT_LEN5_CFG.LEN5_MULT_SERIAL,
    parameter int unsigned MULT_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_PIPE_DEPTH,
    parameter bit MULT_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.MULT_RR_ARBITER,
    parameter int unsigned DIV_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RS_DEPTH,
    parameter bit DIV_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.DIV_RR_ARBITER,
    parameter int unsigned FPU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RS_DEPTH,
    parameter bit FPU_RR_ARBITER = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_RR_ARBITER,
    parameter int unsigned FPU_PIPE_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_PIPE_DEPTH,
    parameter bit FPU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.FPU_SPILL_SKIP,
    parameter int unsigned BU_RS_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.BU_RS_DEPTH,
    parameter bit BU_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.BU_SPILL_SKIP,
    parameter int unsigned ROB_DEPTH = len5_config_pkg::DEFAULT_LEN5_CFG.ROB_DEPTH,
    parameter bit COMMIT_SPILL_SKIP = len5_config_pkg::DEFAULT_LEN5_CFG.COMMIT_SPILL_SKIP,
    parameter int unsigned BPU_INIT_C2B = int'(len5_config_pkg::DEFAULT_LEN5_CFG.BPU_INIT_C2B),
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::build_config(
        '{
            BOOT_VM_MODE: len5_config_pkg::boot_mode_t'(BOOT_VM_MODE),
            BOOT_PC: BOOT_PC,
            LEN5_MULTIPLE_ISSUES: LEN5_MULTIPLE_ISSUES,
            LEN5_M_EN: LEN5_M_EN,
            LEN5_DIV_EN: LEN5_DIV_EN,
            LEN5_F_EN: LEN5_F_EN,
            LEN5_D_EN: LEN5_D_EN,
            LEN5_C_EN: LEN5_C_EN,
            LEN5_A_EN: LEN5_A_EN,
            LEN5_STORE_LOAD_FWD_EN: LEN5_STORE_LOAD_FWD_EN,
            MAX_EU_N: MAX_EU_N,
            ONLY_DOUBLEWORD_MEM_ACCESSES: ONLY_DOUBLEWORD_MEM_ACCESSES,
            LEN5_CSR_HPMCOUNTERS_EN: LEN5_CSR_HPMCOUNTERS_EN,
            MMAP_MASK: MMAP_MASK,
            BPU_HLEN: BPU_HLEN,
            BPU_BTB_BITS: BPU_BTB_BITS,
            RAS_DEPTH: RAS_DEPTH,
            FETCH_MEMIF_FIFO_DEPTH: FETCH_MEMIF_FIFO_DEPTH,
            FETCH_MEM_DRAIN_ON_FLUSH: FETCH_MEM_DRAIN_ON_FLUSH,
            LOAD_BUFFER_DRAIN_ON_FLUSH: LOAD_BUFFER_DRAIN_ON_FLUSH,
            FETCH_REQ_SPILL_SKIP: FETCH_REQ_SPILL_SKIP,
            FETCH_ANS_SPILL_SKIP: FETCH_ANS_SPILL_SKIP,
            IQ_DEPTH: IQ_DEPTH,
            LDBUFF_DEPTH: LDBUFF_DEPTH,
            STBUFF_DEPTH: STBUFF_DEPTH,
            LSU_SPILL_SKIP: LSU_SPILL_SKIP,
            ALU_RS_DEPTH: ALU_RS_DEPTH,
            ALU_SPILL_SKIP: ALU_SPILL_SKIP,
            ALU_RR_ARBITER: ALU_RR_ARBITER,
            MULT_RS_DEPTH: MULT_RS_DEPTH,
            LEN5_MULT_SERIAL: LEN5_MULT_SERIAL,
            MULT_PIPE_DEPTH: MULT_PIPE_DEPTH,
            MULT_RR_ARBITER: MULT_RR_ARBITER,
            DIV_RS_DEPTH: DIV_RS_DEPTH,
            DIV_RR_ARBITER: DIV_RR_ARBITER,
            FPU_RS_DEPTH: FPU_RS_DEPTH,
            FPU_RR_ARBITER: FPU_RR_ARBITER,
            FPU_PIPE_DEPTH: FPU_PIPE_DEPTH,
            FPU_SPILL_SKIP: FPU_SPILL_SKIP,
            BU_RS_DEPTH: BU_RS_DEPTH,
            BU_SPILL_SKIP: BU_SPILL_SKIP,
            ROB_DEPTH: ROB_DEPTH,
            COMMIT_SPILL_SKIP: COMMIT_SPILL_SKIP,
            BPU_INIT_C2B: 2'(BPU_INIT_C2B)
        }
    )
);
  timeunit 1ns; timeprecision 1ps;
  import len5_config_pkg::*;
  import len5_pkg::*;
  import fetch_pkg::*;
  localparam int N = Len5Cfg.LEN5_MULTIPLE_ISSUES;
  localparam int Depth = Len5Cfg.FETCH_MEMIF_FIFO_DEPTH;
  localparam int Limit = 4 * Depth + 16;

  bit clk, flush, early_flush;
  /* verilator lint_off SYNCASYNCNET */
  bit rst_n;
  /* verilator lint_on SYNCASYNCNET */
  initial clk = 0;
  always #5 clk = ~clk;
  bit fetch_valid, memory_ready, response_valid, issue_ready;
  logic fetch_ready, response_ready, request_valid, request_we, issue_valid;
  logic [ALEN-1:0] request_address;
  prediction_t [N-1:0] predictions, issued_predictions;
  instr_t [N-1:0]           issued_instructions;
  logic   [N-1:0][ILEN-1:0] response_words;
  logic [N-1:0] input_mask, issued_mask, response_faults, issued_faults;
  except_code_t [N-1:0] response_causes, issued_causes;
  int expected_ids[$];
  int accepted_requests, accepted_responses, delivered, early_consumed;

  fetch_mem_if #(

      .Len5Cfg                     (Len5Cfg),
      .MAX_MEM_OUTSTANDING_REQUESTS(Depth)
  ) dut (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .flush_i              (flush),
      .fetch_valid_i        (fetch_valid),
      .fetch_ready_o        (fetch_ready),
      .fetch_pred_i         (predictions),
      .valid_instr_i        (input_mask),
      .valid_instr_o        (issued_mask),
      .issue_valid_o        (issue_valid),
      .issue_ready_i        (issue_ready),
      .issue_instr_o        (issued_instructions),
      .issue_pred_o         (issued_predictions),
      .issue_except_raised_o(issued_faults),
      .issue_except_code_o  (issued_causes),
      .instr_valid_i        (response_valid),
      .instr_ready_i        (memory_ready),
      .instr_ready_o        (response_ready),
      .instr_valid_o        (request_valid),
      .instr_we_o           (request_we),
      .instr_rdata_i        (response_words),
      .instr_addr_o         (request_address),
      .instr_except_raised_i(response_faults),
      .instr_except_code_i  (response_causes)
  );

  function automatic prediction_t prediction(int id, int lane);
    return
    '{
        pc: 64'h10000 + 64'(id * N * 4 + lane * 4),
        hit: 1'((id + lane) % 2),
        target: 64'h80000 + 64'(id * 64 + lane * 4),
        taken: 1'((id + lane) % 3 == 0)
    }
    ;
  endfunction
  function automatic logic [31:0] word_value(int id, int lane);
    return 32'hcafe0000 ^ (32'(id) << 8) ^ 32'(lane * 37);
  endfunction
  function automatic bit lane_valid(int id, int lane);
    return lane == 0 || (id + lane) % 3 != 0;
  endfunction
  function automatic bit lane_fault(int id, int lane);
    return (id + lane) % 2 != 0;
  endfunction
  function automatic except_code_t cause(int id, int lane);
    return (id + lane) % 2 != 0 ? E_I_ACCESS_FAULT : E_I_ADDR_MISALIGNED;
  endfunction

  task automatic check_issue(int id);
    for (int lane = 0; lane < N; lane++) begin
      assert (issued_predictions[lane] === prediction(id, lane))
      else
        $fatal(
            1,
            "Metadata mismatch id=%0d lane=%0d got=%h expected=%h",
            id,
            lane,
            issued_predictions[lane],
            prediction(
                id, lane
            )
        );
      assert (issued_instructions[lane].raw === word_value(id, lane))
      else
        $fatal(
            1,
            "Payload mismatch id=%0d lane=%0d got=%h expected=%h",
            id,
            lane,
            issued_instructions[lane].raw,
            word_value(
                id, lane
            )
        );
      assert (issued_mask[lane] === lane_valid(
          id, lane
      ) && issued_faults[lane] === lane_fault(
          id, lane
      ) && issued_causes[lane] === cause(
          id, lane
      ))
      else $fatal(1, "Mask/fault mismatch id=%0d lane=%0d", id, lane);
    end
  endtask

  // All stimulus changes on falling edges; checks sample the consuming rising edge.
  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin
    if (rst_n) begin
      assert (!request_we)
      else $fatal(1, "Instruction write request");
      if (request_valid && memory_ready) accepted_requests++;
      if (response_valid && response_ready) accepted_responses++;
      if (flush && early_flush) begin
        assert (issue_valid && issue_ready && response_valid && response_ready && expected_ids.size() != 0)
        else $fatal(1, "Early flush lost current answer or stale return at the consuming edge");
        check_issue(expected_ids[0]);
        early_consumed++;
      end else if (!flush && issue_valid) begin
        assert (expected_ids.size() != 0)
        else $fatal(1, "Canceled/unexpected bundle published");
        check_issue(expected_ids[0]);
        if (issue_ready) begin
          void'(expected_ids.pop_front());
          delivered++;
        end
      end
    end
  end
  /* verilator lint_on BLKSEQ */

  task automatic cycles(int count = 1);
    repeat (count) @(negedge clk);
  endtask
  task automatic set_request(int id);
    foreach (predictions[lane]) begin
      predictions[lane] = prediction(id, lane);
      input_mask[lane]  = lane_valid(id, lane);
    end
  endtask
  task automatic set_response(int id);
    foreach (response_words[lane]) begin
      response_words[lane]  = word_value(id, lane);
      response_faults[lane] = lane_fault(id, lane);
      response_causes[lane] = cause(id, lane);
    end
  endtask
  task automatic request(int id);
    set_request(id);
    fetch_valid = 1;
    for (int wait_cycle = 0; wait_cycle < Limit; wait_cycle++) begin
      @(posedge clk);
      if (fetch_ready && request_valid && memory_ready) begin
        assert (request_address === (64'h10000 + 64'(id * N * 4)))
        else $fatal(1, "Request address mismatch id=%0d", id);
        @(negedge clk);
        expected_ids.push_back(id);
        fetch_valid = 0;
        return;
      end
      @(negedge clk);
    end
    $fatal(1, "Request id=%0d timed out", id);
  endtask
  task automatic respond(int id);
    set_response(id);
    response_valid = 1;
    for (int wait_cycle = 0; wait_cycle < Limit; wait_cycle++) begin
      @(posedge clk);
      if (response_ready) begin
        @(negedge clk);
        response_valid = 0;
        return;
      end
      @(negedge clk);
    end
    $fatal(1, "Response id=%0d stalled despite a reservation", id);
  endtask
  task automatic await_delivery(int count);
    issue_ready = 1;
    for (int wait_cycle = 0; wait_cycle < Limit; wait_cycle++) begin
      cycles();
      if (delivered == count && expected_ids.size() == 0) return;
    end
    $fatal(1, "Delivery timed out: got=%0d expected=%0d pending=%0d", delivered, count,
           expected_ids.size());
  endtask
  task automatic reset_dut();
    rst_n          = 0;
    flush          = 0;
    early_flush    = 0;
    fetch_valid    = 0;
    response_valid = 0;
    issue_ready    = 0;
    expected_ids.delete();
    cycles(3);
    assert (!issue_valid && !request_valid && !response_ready)
    else $fatal(1, "Reset retained an active transaction");
    rst_n = 1;
    cycles(2);
  endtask

  initial begin
    assert (Depth >= 4 && (Depth & (Depth - 1)) == 0 && Len5Cfg.FETCH_MEM_DRAIN_ON_FLUSH &&
            Len5Cfg.FETCH_REQ_SPILL_SKIP && !Len5Cfg.FETCH_ANS_SPILL_SKIP)
    else
      $fatal(
          1,
          "Drain test requires native-memory mode, depth>=4 and source-selected registered answers"
      );
    rst_n              = 0;
    flush              = 0;
    early_flush        = 0;
    fetch_valid        = 0;
    memory_ready       = 1;
    response_valid     = 0;
    issue_ready        = 0;
    accepted_requests  = 0;
    accepted_responses = 0;
    delivered          = 0;
    early_consumed     = 0;
    predictions        = '0;
    input_mask         = '0;
    response_words     = '0;
    response_faults    = '0;
    response_causes    = '0;
    cycles();
    reset_dut();

    // A full flush retains every reservation until its stale response returns.
    for (int id = 0; id < Depth; id++) request(id);
    flush = 1;
    expected_ids.delete();
    cycles();
    flush = 0;
    set_request(100);
    fetch_valid = 1;
    repeat (3) begin
      @(posedge clk);
      assert (!fetch_ready && !request_valid && !issue_valid)
      else $fatal(1, "Flush released an unreturned reservation");
      @(negedge clk);
    end
    // A returning head must drain even on a repeated flush with issue blocked.
    flush = 1;
    set_response(0);
    response_valid = 1;
    #1;
    assert (response_ready && !request_valid)
    else $fatal(1, "Flush blocked stale-head drain");
    cycles();
    flush          = 0;
    response_valid = 0;
    fetch_valid    = 0;
    request(100);  // One retired stale slot restores one credit, before total drain.
    for (int id = 1; id < Depth; id++) begin
      respond(id);
      assert (!issue_valid)
      else $fatal(1, "Stale response escaped under backpressure");
    end
    respond(100);
    cycles(4);  // Compare the held new-epoch bundle on every edge.
    await_delivery(1);

    // Flush mixed completed/pending slots while the final memory response arrives.
    issue_ready = 0;
    for (int id = 200; id < 200 + Depth; id++) request(id);
    for (int id = 200; id < 199 + Depth; id++) respond(id);
    flush = 1;
    expected_ids.delete();
    set_response(199 + Depth);
    response_valid = 1;
    #1;
    assert (response_ready)
    else $fatal(1, "Flush refused the final pending response");
    cycles();
    flush          = 0;
    response_valid = 0;
    cycles(Depth + 2);
    issue_ready = 1;
    cycles(3);
    request(400);
    respond(400);
    await_delivery(2);

    // An early-flush consumer can take the current answer while canceling younger work.
    issue_ready = 0;
    request(500);
    request(501);
    respond(500);
    #1;
    assert (issue_valid)
    else $fatal(1, "Current answer missing before early flush");
    check_issue(500);
    issue_ready = 1;
    flush       = 1;
    early_flush = 1;
    set_response(501);
    response_valid = 1;
    cycles();
    expected_ids.delete();
    flush          = 0;
    early_flush    = 0;
    response_valid = 0;
    cycles(Depth + 2);

    // Reset cancels both buffered and physically outstanding transactions.
    issue_ready = 0;
    for (int id = 600; id < 600 + Depth; id++) request(id);
    respond(600);
    reset_dut();
    cycles(3);
    request(700);
    respond(700);
    await_delivery(3);
    cycles(3);
    // A response may accompany allocation of its own reservation on an empty interface.
    set_request(800);
    set_response(800);
    expected_ids.push_back(800);
    fetch_valid    = 1;
    response_valid = 1;
    @(posedge clk);
    assert (request_valid && memory_ready && fetch_ready && response_ready)
    else $fatal(1, "Zero-latency allocation/response was not accepted together");
    assert (request_address === (64'h10000 + 64'(800 * N * 4)))
    else $fatal(1, "Zero-latency request address mismatch");
    @(negedge clk);
    fetch_valid    = 0;
    response_valid = 0;
    await_delivery(4);
    cycles(3);
    assert (expected_ids.size() == 0 && delivered == 4 && early_consumed == 1 &&
            accepted_requests == 3 * Depth + 6 && accepted_responses == 2 * Depth + 7)
    else
      $fatal(
          1,
          "Incomplete drain test: requests=%0d responses=%0d delivered=%0d early=%0d",
          accepted_requests,
          accepted_responses,
          delivered,
          early_consumed
      );
    $display(
        "PASS FETCH_MEM_DRAIN lanes=%0d depth=%0d requests=%0d responses=%0d delivered=%0d early=%0d",
        N, Depth, accepted_requests, accepted_responses, delivered, early_consumed);
    $finish;
  end
  initial begin
    cycles(1000 + 20 * Depth);
    $fatal(1, "Fetch drain regression timed out");
  end
endmodule
