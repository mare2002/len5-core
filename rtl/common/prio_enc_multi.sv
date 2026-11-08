// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0. See http://solderpad.org/licenses/SHL-2.0.

module prio_enc_multi #(
  parameter int unsigned N = 8,
  parameter int unsigned NUM_RESULTS = 1,
  parameter bit INV = 1'b0,  // 0: highest bit first; 1: lowest bit first
  localparam int unsigned IdxLen = N > 1 ? $clog2(N) : 1
) (
  input  logic [          N-1:0]             lines_i,
  output logic [NUM_RESULTS-1:0][IdxLen-1:0] enc_o,
  output logic [NUM_RESULTS-1:0]             valid_o
);
  localparam int unsigned NumActive = NUM_RESULTS < N ? NUM_RESULTS : N;

  // Result zero has the highest priority; each following encoder excludes it.
  for (genvar i = 0; i < NumActive; i++) begin : gen_results
    logic [     N-1:0] remaining;
    logic [IdxLen-1:0] index;
    logic              found;

    if (i == 0) begin : gen_first
      assign remaining = lines_i;
    end else begin : gen_mask
      always_comb begin
        remaining = gen_results[i-1].remaining;
        if (gen_results[i-1].found) remaining[gen_results[i-1].index] = 1'b0;
      end
    end

    if (N == 1) begin : gen_single_input
      assign index = '0;
      assign found = remaining[0];
    end else begin : gen_encoder
      prio_enc #(
        .N  (N),
        .INV(INV)
      ) u_prio_enc (
        .lines_i(remaining),
        .enc_o  (index),
        .valid_o(found)
      );
    end

    assign enc_o[i]   = index;
    assign valid_o[i] = found;
  end

  for (genvar i = NumActive; i < NUM_RESULTS; i++) begin : gen_unused_results
    assign enc_o[i]   = '0;
    assign valid_o[i] = 1'b0;
  end
endmodule
