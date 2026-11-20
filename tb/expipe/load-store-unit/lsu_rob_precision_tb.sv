`include "len5_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
module lsu_rob_precision_tb #(
  parameter int unsigned ISSUE_WIDTH = 4,
  parameter int unsigned ROB_DEPTH   = 16
);
  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  function automatic len5_cfg configuration();
    len5_user_cfg_t cfg = DEFAULT_LEN5_USER_CFG;
    cfg.ISSUE_WIDTH = ISSUE_WIDTH;
    cfg.ROB_DEPTH   = ROB_DEPTH;
    return build_config(cfg);
  endfunction
  localparam len5_cfg Cfg = configuration();
  typedef `LEN5_ROB_IDX_T(Cfg) tag_t;
  typedef `LEN5_CDB_DATA_T(Cfg) cdb_t;

  logic clk = 0, rst_n = 0, flush = 0;
  logic [ISSUE_WIDTH-1:0] issue_valid = '0, issue_ready;
  rob_entry_t [ISSUE_WIDTH-1:0] issue_data = '0;
  tag_t       [ISSUE_WIDTH-1:0] issue_tag;
  tag_t store_tag = '0, commit_tag;
  logic store_clear, commit_valid, commit_ready = 1, cdb_valid = 0, cdb_ready;
  rob_entry_t commit_data;
  cdb_t       cdb = '0;
  instr_t     instruction = '0;
  issue_eu_t  decoded_eu;
  eu_ctl_t decoded_ctl;
  logic decoded_mem_crit, decoded_order_crit, decoded_rd_upd;
  bit [ROB_DEPTH-1:0] live = '0, ready = '0, memory_critical = '0, faulted = '0;
  except_code_t expected_code  [ROB_DEPTH];
  int           sequence_number[ROB_DEPTH];
  int next_sequence = 0, next_tag = 0, retired[$], cycles = 0;

  rob #(
    .Len5Cfg(Cfg)
  ) u_rob (
    .clk_i              (clk),
    .rst_ni             (rst_n),
    .flush_i            (flush),
    .issue_valid_i      (issue_valid),
    .issue_ready_o      (issue_ready),
    .issue_data_i       (issue_data),
    .issue_tail_idx_o   (issue_tag),
    .issue_rs1_rob_idx_i('0),
    .opfwd_rs1_valid_o  (),
    .opfwd_rs1_ready_o  (),
    .opfwd_rs1_value_o  (),
    .issue_rs2_rob_idx_i('0),
    .opfwd_rs2_valid_o  (),
    .opfwd_rs2_ready_o  (),
    .opfwd_rs2_value_o  (),
    .issue_rs3_rob_idx_i('0),
    .opfwd_rs3_valid_o  (),
    .opfwd_rs3_ready_o  (),
    .opfwd_rs3_value_o  (),
    .sb_mem_idx_i       (store_tag),
    .sb_mem_clear_o     (store_clear),
    .comm_valid_o       (commit_valid),
    .comm_ready_i       (commit_ready),
    .comm_data_o        (commit_data),
    .comm_idx_o         (commit_tag),
    .cdb_valid_i        (cdb_valid),
    .cdb_data_i         (cdb),
    .cdb_ready_o        (cdb_ready)
  );
  issue_decoder #(
    .Len5Cfg(Cfg)
  ) u_decoder (
    .instruction_i  (instruction),
    .assigned_eu_o  (decoded_eu),
    .mem_crit_o     (decoded_mem_crit),
    .order_crit_o   (decoded_order_crit),
    .rd_upd_o       (decoded_rd_upd),
    .issue_type_o   (),
    .requires_fp_o  (),
    .required_priv_o(),
    .ecall_o        (),
    .dispatch_o     (),
    .except_code_o  (),
    .skip_eu_o      (),
    .eu_ctl_o       (decoded_ctl),
    .rs1_sel_o      (),
    .rs2_sel_o      (),
    .rs3_sel_o      (),
    .imm_format_o   ()
  );

  task automatic tick;
    #5;
    if (!rst_n || flush) begin
      live            = '0;
      ready           = '0;
      memory_critical = '0;
      faulted         = '0;
      next_tag        = 0;
    end else begin
      if (store_clear) begin
        assert (live[store_tag])
        else $fatal(1, "Permission names an empty ROB entry");
        for (int i = 0; i < ROB_DEPTH; i++)
        assert (!live[i] || sequence_number[i] >= sequence_number[store_tag])
        else $fatal(1, "Store permission bypassed an older instruction");
      end
      if (commit_valid && commit_ready) begin
        assert (live[commit_tag] && ready[commit_tag])
        else $fatal(1, "Unready or duplicate retirement");
        assert (commit_data.except_raised == faulted[commit_tag] &&
                (!faulted[commit_tag] || commit_data.except_code == expected_code[commit_tag]))
        else $fatal(1, "Retirement changed exception identity");
        for (int i = 0; i < ROB_DEPTH; i++)
        if (live[i] && sequence_number[i] < sequence_number[commit_tag] && memory_critical[i])
          assert (ready[i] && !faulted[i])
          else $fatal(1, "Younger retirement bypassed a pending/faulting memory operation");
        live[commit_tag] = 0;
        retired.push_back(int'(commit_tag));
      end
      if (cdb_valid && cdb_ready) begin
        assert (live[cdb.rob_idx])
        else $fatal(1, "Completion names an empty ROB entry");
        ready[cdb.rob_idx]         = 1;
        faulted[cdb.rob_idx]       = cdb.except_raised;
        expected_code[cdb.rob_idx] = cdb.except_code;
      end
      for (int k = 0; k < ISSUE_WIDTH; k++)
      if (issue_valid[k] && issue_ready[k]) begin
        assert (int'(issue_tag[k]) == next_tag && !live[issue_tag[k]])
        else $fatal(1, "ROB allocation wrap/overwrite");
        live[issue_tag[k]]            = 1;
        ready[issue_tag[k]]           = issue_data[k].res_ready;
        memory_critical[issue_tag[k]] = issue_data[k].mem_crit;
        faulted[issue_tag[k]]         = issue_data[k].except_raised;
        expected_code[issue_tag[k]]   = issue_data[k].except_code;
        sequence_number[issue_tag[k]] = next_sequence++;
        next_tag                      = next_tag + 1 == ROB_DEPTH ? 0 : next_tag + 1;
      end
    end
    clk = 1;
    #5;
    clk = 0;
    cycles++;
  endtask

  function automatic rob_entry_t alu_entry(bit result_ready, int destination);
    rob_entry_t entry = '0;
    entry.instruction.raw = 32'h00100093;
    entry.res_ready       = result_ready;
    entry.rd_upd          = 1;
    entry.rd_idx          = REG_IDX_LEN'(destination);
    entry.except_code     = E_UNKNOWN;
    return entry;
  endfunction

  task automatic decode_memory(input logic [31:0] raw, input bit store, output rob_entry_t entry);
    ldst_width_t expected_operation;
    if (store) begin
      case (raw[14:12])
        0:       expected_operation = S_BYTE;
        1:       expected_operation = S_HALFWORD;
        2:       expected_operation = S_WORD;
        3:       expected_operation = S_DOUBLEWORD;
        default: $fatal(1, "invalid store in decoder test");
      endcase
    end else begin
      case (raw[14:12])
        0:       expected_operation = L_BYTE;
        1:       expected_operation = L_HALFWORD;
        2:       expected_operation = L_WORD;
        3:       expected_operation = L_DOUBLEWORD;
        4:       expected_operation = L_BYTE_U;
        5:       expected_operation = L_HALFWORD_U;
        6:       expected_operation = L_WORD_U;
        default: $fatal(1, "invalid load in decoder test");
      endcase
    end
    instruction.raw = raw;
    #1;
    assert (decoded_eu == EU_LSU && decoded_mem_crit && decoded_ctl.lsu == expected_operation)
    else $fatal(1, "Decoder omitted memory exception barrier for %08x", raw);
    entry             = '0;
    entry.instruction = instruction;
    entry.mem_crit    = decoded_mem_crit;
    entry.order_crit  = decoded_order_crit;
    entry.rd_upd      = decoded_rd_upd;
    entry.rd_idx      = 1;
    entry.except_code = E_UNKNOWN;
  endtask

  task automatic allocate(input rob_entry_t entry, output tag_t tag);
    issue_valid   = 1;
    issue_data[0] = entry;
    #1;
    assert (issue_ready[0])
    else $fatal(1, "Unexpected ROB backpressure");
    tag = issue_tag[0];
    tick();
    issue_valid = '0;
  endtask

  task automatic complete(input tag_t tag, input bit fault = 0,
                          input except_code_t code = E_UNKNOWN);
    cdb_valid         = 1;
    cdb               = '0;
    cdb.rob_idx       = tag;
    cdb.res_value     = 64'h1234;
    cdb.except_raised = fault;
    cdb.except_code   = code;
    tick();
    cdb_valid = 0;
  endtask

  task automatic clear_pipeline;
    issue_valid = '0;
    cdb_valid   = 0;
    flush       = 1;
    tick();
    flush        = 0;
    commit_ready = 1;
    retired.delete();
    tick();
    assert (!commit_valid && (&issue_ready))
    else $fatal(1, "Flush did not empty ROB");
  endtask

  task automatic drain(input int count);
    commit_ready = 1;
    for (int tries = 0; tries < 4 * ROB_DEPTH && retired.size() != count; tries++) tick();
    assert (retired.size() == count && live == '0)
    else $fatal(1, "ROB failed to drain");
    repeat (3) tick();
    assert (!commit_valid && (&issue_ready))
    else $fatal(1, "Empty ROB exposed stale results");
  endtask

  initial begin
    rob_entry_t memory_entry, entry;
    tag_t memory_tag, younger_tag, older_tag, tag;
    repeat (2) tick();
    rst_n = 1;
    tick();
    // Exercise every integer memory width and both floating-point widths.
    for (int width = 0; width <= 6; width++)
    decode_memory(32'h00010083 | (32'(width) << 12), 0, entry);
    for (int width = 0; width <= 3; width++)
    decode_memory(32'h00310023 | (32'(width) << 12), 1, entry);
    for (int width = 2; width <= 3; width++) begin
      decode_memory(32'h00010087 | (32'(width) << 12), 0, entry);
      decode_memory(32'h00310027 | (32'(width) << 12), 1, entry);
    end

    for (int kind = 0; kind < 4; kind++) begin
      unique case (kind)
        0: decode_memory(32'h00013083, 0, memory_entry);  // LD
        1: decode_memory(32'h00313023, 1, memory_entry);  // SD
        2: decode_memory(32'h00013087, 0, memory_entry);  // FLD
        3: decode_memory(32'h00313027, 1, memory_entry);  // FSD
      endcase
      for (int fault = 0; fault < 2; fault++) begin
        clear_pipeline();
        allocate(memory_entry, memory_tag);
        store_tag = memory_tag;
        allocate(alu_entry(1, 2), younger_tag);
        repeat (ROB_DEPTH + 3) tick();
        assert (retired.size() == 0)
        else $fatal(1, "Younger ALU retired before memory completion");
        if (fault != 0) commit_ready = 0;
        complete(memory_tag, fault != 0, kind[0] ? E_ST_ACCESS_FAULT : E_LD_ACCESS_FAULT);
        if (fault != 0) begin
          repeat (ROB_DEPTH + 3) begin
            tick();
            assert (retired.size() == 0 && commit_valid && commit_tag == memory_tag && commit_data.except_raised)
            else $fatal(1, "Memory fault lost precision under result backpressure");
          end
        end else begin
          drain(2);
          assert (retired[0] == int'(memory_tag) && retired[1] == int'(younger_tag));
        end
      end
    end

    // Two out-of-order retirements leave holes between the head and a store.
    clear_pipeline();
    allocate(alu_entry(0, 4), older_tag);
    allocate(alu_entry(1, 5), tag);
    allocate(alu_entry(1, 6), tag);
    decode_memory(32'h00313023, 1, memory_entry);
    allocate(memory_entry, memory_tag);
    store_tag = memory_tag;
    repeat (ROB_DEPTH + 3) begin
      tick();
      assert (!store_clear)
      else $fatal(1, "Younger store authorized before head retired");
    end
    assert (retired.size() == 2)
    else $fatal(1, "Did not exercise out-of-order ROB holes");
    complete(older_tag);
    for (int tries = 0; tries < ROB_DEPTH && !store_clear; tries++) tick();
    assert (store_clear && retired.size() == 3)
    else $fatal(1, "Head store permission stalled after ROB holes");
    complete(memory_tag);
    drain(4);

    // Fill from a nonzero tail, retire, and reuse every wrapped transaction tag.
    retired.delete();
    for (int round = 0; round < 3; round++) begin
      commit_ready = 0;
      for (int total = 0; total < ROB_DEPTH;) begin
        int count;
        count       = ROB_DEPTH - total < ISSUE_WIDTH ? ROB_DEPTH - total : ISSUE_WIDTH;
        issue_valid = ISSUE_WIDTH'((1 << count) - 1);
        for (int k = 0; k < ISSUE_WIDTH; k++) issue_data[k] = alu_entry(1, k + 8);
        #1;
        assert ((issue_valid & issue_ready) == issue_valid);
        tick();
        issue_valid = '0;
        total += count;
      end
      #1;
      assert (issue_ready == '0 && $countones(live) == ROB_DEPTH)
      else $fatal(1, "Full ROB did not apply backpressure");
      drain((round + 1) * ROB_DEPTH);
    end
    $display("PASS LSU ROB precision ISSUE_WIDTH=%0d ROB_DEPTH=%0d cycles=%0d", ISSUE_WIDTH,
             ROB_DEPTH, cycles);
    $finish;
  end
endmodule
