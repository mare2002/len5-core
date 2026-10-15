// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Read-only full-core debug monitor; not part of the standalone golden oracle.
module recovery_tb(input logic clk_i, rst_ni, input int unsigned cycle_i);
  tb_bare #(.BOOT_PC(64'h1000)) system_under_test(.clk_i, .rst_ni, .trace_en_i(1'b0));
  `define DP system_under_test.u_datapath
  `define FE `DP.u_fetch_stage
  `define BE `DP.u_backend
  `define BU `BE.u_exec_stage.u_branch_unit
  `define CS `BE.u_commit_stage
  `define ROB `CS.u_rob
  `define EJU `FE.u_early_jump_unit
  `define RAS `EJU.u_ras
  integer fd;
  initial begin
    fd=$fopen("cycles.csv", "w");
    $fwrite(fd, "phase,width,eju_pc,cycle,reset,fetch_pc,issue_valid,issue_pc,bu_valid,bu_pc,bu_mis,bu_target,bu_state,call_confirm,ret_confirm,confirm_pc,link,mis_flush,exception_flush,backend_flush,redirect_valid,redirect_pc,commit_valid,commit_pc,commit_rd_valid,commit_except,commit_code,rob_pop,rob_pc,rob_exception,head_pc,head_ready,head_except,eju_valid,eju_ready,early,early_target,p_push,p_pop,p_valid,c_valid,p_top,p0,c0,p1,c1,p2,c2,p3,c3");
    for (int k=0;k<len5_config_pkg::ROB_DEPTH;k++) $fwrite(fd,",rob%0d_valid,rob%0d_pc",k,k);
    $fwrite(fd,"\n");
  end
  task automatic sample(input string phase);
    $fwrite(fd,"%s,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",phase,
      len5_config_pkg::LEN5_MULTIPLE_ISSUES,
      `EJU.mem_if_pred_i[`EJU.jump_location].pc,
      cycle_i,
      !rst_ni,
      `DP.instr_addr_o,
      `BE.issue_comm_valid,
      `BE.issue_comm_rob_data.instr_pc,
      `BU.rs_bu_valid,
      `BU.rs_bu_curr_pc,
      `BU.res_mispredicted,
      `BU.res_target,
      `BU.u_branch_cu.curr_state,
      `DP.be_fe_call_confirm,
      `DP.be_fe_ret_confirm,
      `DP.be_fe_res.pc,
      `DP.be_fe_link_addr,
      `DP.be_fe_mis_flush,
      `DP.be_fe_except_flush,
      `BU.flush_i,
      `DP.be_fe_except_raised,
      `DP.be_fe_except_pc,
      `CS.comm_reg_valid,
      `CS.comm_reg_data.data.instr_pc,
      `BE.comm_intrf_valid,
      `CS.comm_reg_data.data.except_raised,
      `CS.comm_reg_data.data.except_code,
      (`CS.rob_reg_valid && `CS.reg_rob_ready),
      `CS.rob_reg_head_entry.instr_pc,
      `CS.rob_reg_head_entry.except_raised,
      `ROB.data[`ROB.head_idx].instr_pc,
      `ROB.data[`ROB.head_idx].res_ready,
      `ROB.data[`ROB.head_idx].except_raised,
      `EJU.instr_valid_i,
      `EJU.issue_ready_i,
      `FE.early_jump_valid,
      `FE.early_jump_target,
      `RAS.push_i,
      `RAS.pop_i,
      `RAS.ras_valid_q,
      `RAS.ras_valid_confirmed_q,
      `RAS.ret_addr_o,
      `RAS.ras_addr_q[0],
      `RAS.ras_addr_confirmed_q[0],
      `RAS.ras_addr_q[1],
      `RAS.ras_addr_confirmed_q[1],
      `RAS.ras_addr_q[2],
      `RAS.ras_addr_confirmed_q[2],
      `RAS.ras_addr_q[3],
      `RAS.ras_addr_confirmed_q[3]);
    for (int k=0;k<len5_config_pkg::ROB_DEPTH;k++) $fwrite(fd,",%h,%h",`ROB.data_valid[k],`ROB.data[k].instr_pc);
    $fwrite(fd,"\n");
  endtask
  always @(posedge clk_i) sample("pre");
  always @(negedge clk_i) sample("post_previous");
  final $fclose(fd);
  `undef DP
  `undef FE
  `undef BE
  `undef BU
  `undef CS
  `undef ROB
  `undef EJU
  `undef RAS
endmodule
