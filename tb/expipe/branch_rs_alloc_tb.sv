`include "len5_typedef.svh"
module branch_rs_alloc_case #(parameter bit USE_FIFO = 0)(input logic clk, output logic done);
  import len5_config_pkg::*;
  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = 4;
    cfg.BU_ISSUE_WIDTH = 2;
    cfg.BU_USE_FIFO = USE_FIFO;
    cfg.BU_FIFO_DEPTH = 4;
    cfg.BU_RS_DEPTH = 4;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  typedef `LEN5_OP_DATA_T(Cfg) operand_t;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_t;
  typedef `LEN5_ROB_IDX_T(Cfg) tag_t;
  logic rst_n = 0, flush = 0;
  logic [3:0] valid_in, ready_out;
  operand_t [3:0] rs1, rs2;
  tag_t [3:0] tags;
  logic [3:0][63:0] pcs;
  expipe_pkg::branch_ctl_t [3:0] controls;
  logic cdb_valid, cdb_out_valid, cdb_ready;
  cdb_t cdb, result;
  logic execute_valid, execute_ready, result_ready;
  tag_t execute_tag;
  logic [63:0] execute_rs1, execute_rs2, execute_pc;
  int execution_queue[$], retirement_queue[$];
  int next_tag = 1, multi = 0, blocked = 0, retired = 0;
  branch_rs #(.Len5Cfg(Cfg)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .issue_valid_i(valid_in), .issue_ready_o(ready_out),
    .issue_branch_type_i(controls), .issue_rs1_i(rs1), .issue_rs2_i(rs2),
    .issue_imm_value_i('0), .issue_dest_rob_idx_i(tags), .issue_curr_pc_i(pcs),
    .issue_pred_target_i('0), .issue_pred_taken_i('0),
    .cdb_ready_i(cdb_ready), .cdb_valid_i(cdb_valid), .cdb_valid_o(cdb_out_valid), .cdb_data_i(cdb), .cdb_data_o(result),
    .bu_valid_i(execute_valid && execute_ready && !flush), .bu_ready_i(execute_ready),
    .bu_valid_o(execute_valid), .bu_ready_o(result_ready), .bu_rob_idx_i(execute_tag),
    .bu_res_mis_i(1'b0), .bu_link_addr_i(64'(execute_tag) + 1000), .bu_except_raised_i(1'b0),
    .bu_rob_idx_o(execute_tag), .bu_rs1_o(execute_rs1), .bu_rs2_o(execute_rs2), .bu_imm_o(),
    .bu_curr_pc_o(execute_pc), .bu_pred_target_o(), .bu_pred_taken_o(), .bu_branch_type_o()
  );
  initial begin
    done = 0; valid_in = '0; rs1 = '0; rs2 = '0; tags = '0; pcs = '0;
    controls = '0; cdb_valid = 0; cdb = '0; cdb_ready = 0; execute_ready = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int cycle = 0; cycle < 200; cycle++) begin
      int accepted, expected;
      flush = cycle == 30;
      if (flush) begin
        execution_queue.delete(); retirement_queue.delete(); next_tag = 1;
      end
      cdb_valid = cycle % 3 == 1;
      cdb.rob_idx = 31;
      cdb.res_value = 99;
      execute_ready = cycle > 12 && cycle % 5 != 0;
      cdb_ready = cycle > 18 && cycle % 7 != 0;
      for (int k = 0; k < 4; k++) begin
        tags[k] = tag_t'(next_tag + k);
        valid_in[k] = next_tag + k <= 20;
        pcs[k] = 64'(next_tag + k) * 4;
        rs1[k] = '{ready: 1'b1, rob_idx: '0, value: 64'(next_tag + k)};
        rs2[k] = '{ready: (next_tag + k) % 3 != 0, rob_idx: tag_t'(31), value: 64'(next_tag + k)};
      end
      #1;
      assert (ready_out[3:2] == 0) else $fatal(1, "inactive branch channels");
      if (!flush) begin
        if (cdb_out_valid && cdb_ready) begin
          assert (retirement_queue.size() != 0) else $fatal(1, "unexpected branch completion");
          expected = retirement_queue.pop_front();
          assert (int'(result.rob_idx) == expected && result.res_value == 64'(expected + 1000))
            else $fatal(1, "branch completion order/data");
          retired++;
        end
        if (execute_valid && execute_ready) begin
          assert (execution_queue.size() != 0 && result_ready) else $fatal(1, "unexpected branch execution");
          expected = execution_queue.pop_front();
          assert (int'(execute_tag) == expected && execute_pc == 64'(expected * 4) && execute_rs1 == 64'(expected) &&
                  execute_rs2 == 64'(expected % 3 == 0 ? 99 : expected)) else $fatal(1, "branch execution order/data");
          retirement_queue.push_back(expected);
        end
        accepted = 0;
        for (int k = 0; k < 4; k++) begin
          if (valid_in[k] && ready_out[k]) begin
            execution_queue.push_back(int'(tags[k])); accepted++;
          end
        end
        if (accepted > 1) multi++;
        if (valid_in[0] && !ready_out[0]) blocked++;
        next_tag += accepted;
      end
      @(negedge clk);
    end
    assert (next_tag == 21 && execution_queue.size() == 0 && retirement_queue.size() == 0 && multi > 0 && blocked > 0 && retired >= 20)
      else $fatal(1, "branch coverage/drain failure");
    $display("PASS branch allocation fifo=%0d multi=%0d blocked=%0d retired=%0d", USE_FIFO, multi, blocked, retired);
    done = 1;
  end
endmodule
module branch_rs_alloc_tb;
  logic clk = 0;
  always #5 clk = !clk;
  wire [1:0] done;
  branch_rs_alloc_case #(.USE_FIFO(0)) direct_case(.clk, .done(done[0]));
  branch_rs_alloc_case #(.USE_FIFO(1)) fifo_case(.clk, .done(done[1]));
  initial begin wait (&done); $finish; end
  initial begin #10000; $fatal(1, "timeout"); end
endmodule
