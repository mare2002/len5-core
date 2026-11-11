module ex_request_selector_case #(
  parameter int N = 11,
  parameter int NUM_OUTPUTS = 3,
  localparam bit ROUND_ROBIN = 1,
  localparam int IdxLen = N > 1 ? $clog2(N) : 1
) (output bit done);
  bit clk;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic [N-1:0] requests = '0, accepted;
  logic [NUM_OUTPUTS-1:0] ready = '0, valid;
  logic [NUM_OUTPUTS-1:0][IdxLen-1:0] served;
  logic [N-1:0] sampled_accept;
  logic [NUM_OUTPUTS-1:0] sampled_valid;
  logic [NUM_OUTPUTS-1:0][IdxLen-1:0] sampled_served;

  rr_arbiter_multi #(.N(N), .NUM_OUTPUTS(NUM_OUTPUTS)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(requests), .ready_o(accepted),
    .valid_o(valid), .ready_i(ready), .served_o(served)
  );

  task automatic cycle(input logic [N-1:0] request_mask,
                       input logic [NUM_OUTPUTS-1:0] ready_mask,
                       input bit do_flush = 0);
    logic [N-1:0] grants, expected_accept, previous_round;
    logic [NUM_OUTPUTS-1:0] offered_valid;
    logic [NUM_OUTPUTS-1:0][IdxLen-1:0] offered_idx;
    int eligible_requests, last_priority, request_priority;
    @(negedge clk);
    requests = request_mask;
    ready = '0;
    flush = do_flush;
    #1;
    offered_valid = valid;
    offered_idx = served;
    ready = ready_mask;
    #1;
    assert ({valid, served} == {offered_valid, offered_idx})
      else $fatal(1, "acceptance feedback changed selection order");
    grants = '0;
    expected_accept = '0;
    previous_round = dut.rem_valid_q;
    eligible_requests = $countones(request_mask);
    last_priority = -1;
    for (int u = 0; u < NUM_OUTPUTS; u++) begin
      if (!do_flush) assert (valid[u] == (u < eligible_requests))
        else $fatal(1, "selection slots are not a valid prefix");
      if (valid[u]) begin
        assert (!do_flush && int'(served[u]) < N && requests[served[u]])
          else $fatal(1, "invalid/ineligible grant");
        assert (!grants[served[u]]) else $fatal(1, "duplicate grant");
        request_priority = (previous_round[served[u]] ? 0 : N) + int'(served[u]);
        assert (request_priority > last_priority) else $fatal(1, "incorrect round priority order");
        last_priority = request_priority;
        grants[served[u]] = 1;
        if (ready[u]) expected_accept[served[u]] = 1;
      end
    end
    assert (accepted == expected_accept) else $fatal(1, "input acceptance mask mismatch");
    if (do_flush) begin
      assert (valid == '0 && accepted == '0) else $fatal(1, "grant during flush");
    end else begin
      assert ($countones(grants) == (eligible_requests < NUM_OUTPUTS ? eligible_requests : NUM_OUTPUTS))
        else $fatal(1, "eligible requests not offered");
      for (int i = 0; i < N; i++) begin
        request_priority = (previous_round[i] ? 0 : N) + i;
        if (requests[i] && !grants[i]) assert (request_priority > last_priority)
          else $fatal(1, "higher-priority request was skipped");
      end
    end
    sampled_accept = accepted;
    sampled_valid = valid;
    sampled_served = served;
    @(posedge clk);
    #1;
    if (do_flush) begin
      assert (dut.rem_valid_q == '0) else $fatal(1, "round state retained after flush");
    end else if (sampled_accept == '0) begin
      assert (dut.rem_valid_q == (previous_round & request_mask))
        else $fatal(1, "round advanced without acceptance");
    end
  endtask

  task automatic clear;
    cycle('0, '0, 1);
  endtask

  initial begin : run
    logic [N-1:0] pending, removed, initial_grants;
    logic [NUM_OUTPUTS-1:0] ready_mask;
    int age[N];
    int last_slot;
    done = 0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    cycle('1, '1);
    assert ($countones(sampled_accept) == (N < NUM_OUTPUTS ? N : NUM_OUTPUTS))
      else $fatal(1, "parallel dispatch count");
    for (int u = 0; u < NUM_OUTPUTS && u < N; u++) begin
      assert (int'(sampled_served[u]) == (ROUND_ROBIN ? u : N - 1 - u))
        else $fatal(1, "initial priority order");
    end

    // Only the acknowledged selection slot may advance the round.
    clear();
    last_slot = (N < NUM_OUTPUTS ? N : NUM_OUTPUTS) - 1;
    ready_mask = '0;
    ready_mask[last_slot] = 1;
    cycle('1, ready_mask);
    assert (sampled_served[last_slot] == IdxLen'(last_slot) && sampled_accept == (N'(1) << last_slot))
      else $fatal(1, "wrong request accepted for selection slot");

    // Feedback on an unused slot cannot move a request into that slot.
    if (NUM_OUTPUTS > N) begin
      clear();
      ready_mask = '0;
      ready_mask[NUM_OUTPUTS-1] = 1;
      cycle('1, ready_mask);
      assert (sampled_valid[0] && sampled_served[0] == 0 && sampled_accept == '0)
        else $fatal(1, "selection was routed using acceptance feedback");
    end

    // Unaccepted selections keep priority while other slots are accepted.
    clear();
    cycle('1, '0);
    ready_mask = '1;
    ready_mask[0] = 0;
    cycle('1, ready_mask);
    assert (sampled_valid[0] && sampled_served[0] == 0 && !sampled_accept[0])
      else $fatal(1, "unaccepted request lost priority");
    repeat (N + 2) cycle('1, ready_mask);
    cycle('1, '1);

    // Finite traffic: remove only accepted inputs and prove exactly-once drain.
    clear();
    pending = '1;
    removed = '0;
    for (int t = 0; t < N * 4 + 4 && pending != '0; t++) begin
      ready_mask = '1;
      for (int u = 0; u < NUM_OUTPUTS; u++) ready_mask[u] = ((t + u) % 3) != 0;
      cycle(pending, ready_mask);
      assert ((removed & sampled_accept) == '0) else $fatal(1, "request dispatched twice");
      removed |= sampled_accept;
      pending &= ~sampled_accept;
    end
    assert (pending == '0 && removed == '1) else $fatal(1, "request lost during partial acceptance");

    // A saved request that loses eligibility must not be granted.
    clear();
    cycle('1, '1);
    initial_grants = sampled_accept;
    pending = '1;
    for (int i = 0; i < N; i++) begin
      if (!initial_grants[i]) begin
        pending[i] = 0;
        break;
      end
    end
    cycle(pending, '1);
    assert ((sampled_accept & ~pending) == '0) else $fatal(1, "stale round-mask grant");

    if (ROUND_ROBIN) begin
      // The RS matches the first selections to available execution units.
      // Vary that accepted prefix across round boundaries, including stalls.
      clear();
      for (int i = 0; i < N; i++) age[i] = 0;
      for (int t = 0; t < N * 12 + 12; t++) begin
        ready_mask = '0;
        for (int u = 0; u < NUM_OUTPUTS; u++) ready_mask[u] = u < (t % (NUM_OUTPUTS + 1));
        cycle('1, ready_mask);
        for (int i = 0; i < N; i++) begin
          age[i] = sampled_accept[i] ? 0 : age[i] + 1;
          assert (age[i] <= N * 4 + NUM_OUTPUTS + 2)
            else $fatal(1, "RR starvation: N=%0d U=%0d request=%0d", N, NUM_OUTPUTS, i);
        end
      end
    end

    // Flush clears the round; one new request must execute independently.
    clear();
    cycle('1, '0);
    clear();
    pending = '0;
    pending[N-1] = 1;
    cycle(pending, '1);
    assert (sampled_accept == pending) else $fatal(1, "stale assignment after flush");
    clear();
    cycle('1, '0);
    @(negedge clk);
    rst_n = 0;
    requests = '0;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    cycle(pending, '1);
    assert (sampled_accept == pending) else $fatal(1, "stale assignment after reset");
    clear();
    done = 1;
  end
endmodule

module ex_request_selector_tb;
  logic [11:0] done;
  for (genvar k = 0; k < 5; k++) begin : gen_counts
    localparam int Units = k == 0 ? 1 : k == 1 ? 2 : k == 2 ? 3 : k == 3 ? 4 : 8;
    ex_request_selector_case #(.N(11), .NUM_OUTPUTS(Units)) test_case (.done(done[k]));
  end
  ex_request_selector_case #(.N(1), .NUM_OUTPUTS(1)) single (.done(done[5]));
  ex_request_selector_case #(.N(1), .NUM_OUTPUTS(3)) single_three (.done(done[6]));
  ex_request_selector_case #(.N(1), .NUM_OUTPUTS(8)) single_eight (.done(done[7]));
  ex_request_selector_case #(.N(3), .NUM_OUTPUTS(2)) three_two (.done(done[8]));
  ex_request_selector_case #(.N(3), .NUM_OUTPUTS(4)) three_four (.done(done[9]));
  ex_request_selector_case #(.N(3), .NUM_OUTPUTS(8)) three_eight (.done(done[10]));
  ex_request_selector_case #(.N(7), .NUM_OUTPUTS(3)) seven_three (.done(done[11]));
  initial begin
    wait (&done);
    $display("PASS execution request selection: 12 round-robin parameter cases");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "execution selector regression timed out");
  end
endmodule
