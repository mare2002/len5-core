// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.

module rr_arbiter_multi #(
  parameter int unsigned N = 4,
  parameter int unsigned NUM_OUTPUTS = 1,
  localparam int unsigned IDX_LEN = N > 1 ? $clog2(N) : 1
) (
  input  logic                               clk_i,
  input  logic                               rst_ni,
  input  logic                               flush_i,
  input  logic [          N-1:0]             valid_i,
  output logic [          N-1:0]             ready_o,
  output logic [NUM_OUTPUTS-1:0]             valid_o,
  // Acceptance feedback for selection slots, not physical execution units.
  input  logic [NUM_OUTPUTS-1:0]             ready_i,
  output logic [NUM_OUTPUTS-1:0][IDX_LEN-1:0] served_o
);
  logic [N-1:0] rem_valid_q, rem_valid_d;
  logic [N-1:0] pending_requests, new_requests;
  logic [N-1:0] accepted_requests;
  logic [NUM_OUTPUTS-1:0] pending_valid, new_valid;
  logic [NUM_OUTPUTS-1:0][IDX_LEN-1:0] pending_idx, new_idx;
  logic [NUM_OUTPUTS-1:0] new_shift_select, aligned_new_valid;
  logic [NUM_OUTPUTS-1:0][     IDX_LEN-1:0]             aligned_new_idx;
  logic [NUM_OUTPUTS-1:0][NUM_OUTPUTS-1:0]             shifted_new_valid;
  logic [NUM_OUTPUTS-1:0][NUM_OUTPUTS-1:0][IDX_LEN-1:0] shifted_new_idx;

  always_comb begin : eligible_request_masks
    pending_requests = rem_valid_q & valid_i;
    new_requests     = valid_i & ~pending_requests;
  end

  prio_enc_multi #(
    .N          (N),
    .NUM_RESULTS(NUM_OUTPUTS),
    .INV        (1'b1)
  ) u_pending_sel (
      .lines_i(pending_requests),
      .enc_o  (pending_idx),
      .valid_o(pending_valid)
  );

  prio_enc_multi #(
    .N          (N),
    .NUM_RESULTS(NUM_OUTPUTS),
    .INV        (1'b1)
  ) u_new_sel (
      .lines_i(new_requests),
      .enc_o  (new_idx),
      .valid_o(new_valid)
  );

  // The end of the pending-valid prefix selects one constant shift.
  // If every output is pending, no new selection is needed.
  for (genvar s = 0; s < NUM_OUTPUTS; s++) begin : gen_new_shifts
    if (s == 0) begin : gen_no_pending
      assign new_shift_select[s] = !pending_valid[0];
    end else begin : gen_pending_boundary
      assign new_shift_select[s] = pending_valid[s-1] && !pending_valid[s];
    end

    assign shifted_new_valid[s] = (new_valid << s) & {NUM_OUTPUTS{new_shift_select[s]}};
    assign shifted_new_idx[s] = (new_idx << (s * IDX_LEN)) & {(NUM_OUTPUTS * IDX_LEN){new_shift_select[s]}};
  end

  always_comb begin : new_alignment_mux
    aligned_new_valid = '0;
    aligned_new_idx   = '0;
    foreach (new_shift_select[s]) begin
      aligned_new_valid |= shifted_new_valid[s];
      aligned_new_idx |= shifted_new_idx[s];
    end
  end

  // Selection order is independent of the caller's acceptance feedback.
  always_comb begin : request_mux
    for (int k = 0; k < NUM_OUTPUTS; k++) begin
      if (!flush_i) begin
        if (pending_valid[k]) begin
          valid_o[k]  = 1'b1;
          served_o[k] = pending_idx[k];
        end else begin
          valid_o[k]  = aligned_new_valid[k];
          served_o[k] = aligned_new_idx[k];
        end
      end else begin
        valid_o[k]  = 1'b0;
        served_o[k] = '0;
      end
    end
  end

  always_comb begin : accepted_request_decode
    accepted_requests = '0;
    for (int k = 0; k < NUM_OUTPUTS; k++) begin
      if (valid_o[k] && ready_i[k]) accepted_requests[served_o[k]] = 1'b1;
    end
  end

  assign ready_o = accepted_requests;

  // Snapshot a new round only when a request outside the saved round is accepted.
  always_comb begin : remaining_request_mask
    if (|(accepted_requests & ~rem_valid_q)) begin
      rem_valid_d = valid_i & ~accepted_requests;
    end else begin
      rem_valid_d = pending_requests & ~accepted_requests;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : remaining_request_register
    if (!rst_ni) rem_valid_q <= '0;
    else if (flush_i) rem_valid_q <= '0;
    else rem_valid_q <= rem_valid_d;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i) $onehot0(new_shift_select));
  for (genvar u = 0; u < NUM_OUTPUTS; u++) begin : gen_assertions
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      valid_o[u] |-> int'(served_o[u]) < N && valid_i[served_o[u]]);
    for (genvar v = u + 1; v < NUM_OUTPUTS; v++) begin : gen_distinct
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        valid_o[u] && valid_o[v] |-> served_o[u] != served_o[v]);
    end
  end
`endif
endmodule
