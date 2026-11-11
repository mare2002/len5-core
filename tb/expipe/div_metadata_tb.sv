`include "len5_typedef.svh"

module div_metadata_tb;
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;
  function automatic len5_cfg test_config();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.DIV_RS_DEPTH = 8;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = test_config();
  localparam int unsigned RsIdxLen = $clog2(Cfg.DIV_RS_DEPTH);
  typedef logic [RsIdxLen-1:0] rs_idx_t;

  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0;
  logic request_valid = 0, request_ready, result_valid, result_ready = 0;
  logic [MAX_EU_CTL_LEN-1:0] ctl = '0;
  rs_idx_t request_tag = '0, result_tag;
  logic [XLEN-1:0] operand_a = '0, operand_b = '0, result;
  logic except_raised;
  except_code_t except_code;

  div #(.Len5Cfg(Cfg)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
    .valid_i(request_valid), .ready_o(request_ready),
    .valid_o(result_valid), .ready_i(result_ready),
    .ctl_i(ctl), .rs_idx_i(request_tag),
    .rs1_value_i(operand_a), .rs2_value_i(operand_b),
    .rs_idx_o(result_tag), .result_o(result),
    .except_raised_o(except_raised), .except_code_o(except_code)
  );

  task automatic tick;
    @(posedge clk);
    #1;
  endtask

  task automatic send(input logic [MAX_EU_CTL_LEN-1:0] operation,
                      input logic [XLEN-1:0] a, b, input int tag);
    @(negedge clk);
    ctl = operation;
    operand_a = a;
    operand_b = b;
    request_tag = rs_idx_t'(tag);
    request_valid = 1;
    do @(posedge clk); while (!request_ready);
    @(negedge clk);
    request_valid = 0;
  endtask

  task automatic receive(input int tag, input logic [XLEN-1:0] expected,
                         input bit expected_exception, check_value = 1);
    while (!result_valid) tick();
    // A queued operation must not alter metadata while this result is stalled.
    repeat (4) begin
      assert (result_valid && result_tag == rs_idx_t'(tag) &&
              except_raised == expected_exception && (!check_value || result == expected))
        else $fatal(1, "tag %0d: result=%h exception=%b", tag, result, except_raised);
      tick();
    end
    @(negedge clk);
    result_ready = 1;
    tick();
    @(negedge clk);
    result_ready = 0;
  endtask

  initial begin
    repeat (2) tick();
    rst_n = 1;
    send(DIV_DIVU, 64'h1_0000_0000, 1, 1);
    send(DIV_DIVUW, 64'h8000_0000, 1, 2);
    receive(1, 64'h1_0000_0000, 0);
    receive(2, 64'hffff_ffff_8000_0000, 0);

    send('1, 0, 0, 3);
    send(DIV_DIVW, -64'd8, 2, 4);
    receive(3, '0, 1, 0);
    receive(4, -64'd4, 0);

    send(DIV_DIVU, 64'hffff_ffff_ffff_ffff, 3, 5);
    send(DIV_DIVUW, 17, 2, 6);
    flush = 1;
    tick();
    flush = 0;
    result_ready = 1;
    repeat (80) begin
      tick();
      assert (!result_valid) else $fatal(1, "flushed result escaped");
    end
    result_ready = 0;
    send(DIV_REMUW, 19, 4, 7);
    receive(7, 3, 0);
    $display("PASS divider metadata: queued word/full/illegal operations, stalls, flush");
    $finish;
  end

  initial begin
    repeat (1000) tick();
    $fatal(1, "divider metadata test timed out");
  end
endmodule
