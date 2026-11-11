`include "len5_typedef.svh"
// Copyright 2022 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: arith_rs.sv
// Author: Michele Caon
// Date: 19/08/2022

module arith_rs #(
  parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
  parameter expipe_pkg::issue_eu_t EU = expipe_pkg::EU_INT_ALU,
  localparam type cdb_data_t = `LEN5_CDB_DATA_T(Len5Cfg),
  localparam type op_data_t = `LEN5_OP_DATA_T(Len5Cfg),
  localparam type rob_idx_t = `LEN5_ROB_IDX_T(Len5Cfg),
  localparam int unsigned DEPTH = EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_RS_DEPTH :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_RS_DEPTH : Len5Cfg.DIV_RS_DEPTH,
  localparam int unsigned EU_CTL_LEN = expipe_pkg::MAX_EU_CTL_LEN,
  localparam bit RR_ARBITER = EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_RR_ARBITER :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_RR_ARBITER : Len5Cfg.DIV_RR_ARBITER,
  localparam int unsigned ConfiguredUnits = EU == expipe_pkg::EU_INT_ALU ? Len5Cfg.ALU_NUM_UNITS :
        EU == expipe_pkg::EU_INT_MULT ? Len5Cfg.MULT_NUM_UNITS : Len5Cfg.DIV_NUM_UNITS,
  localparam int unsigned NUM_UNITS = ConfiguredUnits > 0 ? ConfiguredUnits : 1,
  localparam int unsigned UnitIdxLen = NUM_UNITS > 1 ? $clog2(NUM_UNITS) : 1,
  localparam int unsigned RsIdxLen = DEPTH > 1 ? $clog2(DEPTH) : 1,
  localparam type rs_idx_t = logic [RsIdxLen-1:0]
) (
  input logic clk_i,
  input logic rst_ni,
  input logic flush_i,


  // Ordered insertion prefix; readiness reports the available free-entry prefix.
  input  logic     [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_valid_i,
  output logic     [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_ready_o,
  input  logic     [Len5Cfg.ISSUE_WIDTH-1:0][EU_CTL_LEN-1:0] issue_eu_ctl_i,
  input  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_rs1_i,
  input  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_rs2_i,
  input  rob_idx_t [Len5Cfg.ISSUE_WIDTH-1:0]                 issue_dest_rob_idx_i,

  // CDB
  input  logic      cdb_ready_i,
  input  logic      cdb_valid_i,  // to know if the CDB is carrying valid data
  output logic      cdb_valid_o,
  input  cdb_data_t cdb_data_i,
  output cdb_data_t cdb_data_o,

  // Execution unit
  input  logic                   [NUM_UNITS-1:0]                     eu_ready_i,
  input  logic                   [NUM_UNITS-1:0]                     eu_valid_i,
  output logic                   [NUM_UNITS-1:0]                     eu_valid_o,
  output logic                   [NUM_UNITS-1:0]                     eu_ready_o,
  input  rs_idx_t               [NUM_UNITS-1:0]                     eu_rs_idx_i,
  input  logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_result_i,
  input  logic                   [NUM_UNITS-1:0]                     eu_except_raised_i,
  input  len5_pkg::except_code_t [NUM_UNITS-1:0]                     eu_except_code_i,
  output logic                   [NUM_UNITS-1:0][    EU_CTL_LEN-1:0] eu_ctl_o,
  output logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_rs1_o,
  output logic                   [NUM_UNITS-1:0][len5_pkg::XLEN-1:0] eu_rs2_o,
  output rs_idx_t               [NUM_UNITS-1:0]                     eu_rs_idx_o
);

  import len5_config_pkg::*;
  import len5_pkg::*;
  import expipe_pkg::*;

  if (!(EU inside {EU_INT_ALU, EU_INT_MULT, EU_INT_DIV})) begin : gen_invalid_eu
    $fatal(1, "arith_rs supports the ALU, multiplier and divider roles");
  end

  // DATA TYPES
  // ----------
  // Generic arithmetic reservation station content
  typedef struct packed {
    logic [EU_CTL_LEN-1:0] eu_ctl;  // Control signals for the EU
    rob_idx_t rs1_rob_idx;  // The entry of the rob that will contain the required operand.
    logic [XLEN-1:0] rs1_value;  // The value of the first operand
    rob_idx_t rs2_rob_idx;  // The entry of the rob that will contain the required operand.
    logic [XLEN-1:0] rs2_value;  // The value of the second operand
    rob_idx_t dest_rob_idx;  // The entry of the ROB where the result will be stored
    logic [XLEN-1:0] res_value;
    logic except_raised;
    except_code_t except_code;
  } arith_rs_data_t;

  // Arithmetic unit state
  typedef enum logic [2:0] {
    ARITH_S_EMPTY,         // empty
    ARITH_S_RS1_PENDING,   // waiting for rs1 forwarding
    ARITH_S_RS2_PENDING,   // waiting for rs2 forwarding
    ARITH_S_RS12_PENDING,  // waiting for rs1 and rs2 forwarding
    ARITH_S_EX_REQ,        // requesting execution to execution unit
    ARITH_S_EX_WAIT,       // waiting for the BU result
    ARITH_S_COMPLETED,     // ready to write the result on the CDB
    ARITH_S_HALT           // for debug
  } arith_state_t;

  // Arithmetic unit operations
  typedef enum logic [2:0] {
    ARITH_OP_NONE,
    ARITH_OP_INSERT,
    ARITH_OP_SAVE_RS12,
    ARITH_OP_SAVE_RS1,
    ARITH_OP_SAVE_RS2,
    ARITH_OP_SAVE_RES
  } arith_op_t;

  // INTERNAL SIGNALS
  // ----------------
  // New, execution, and CDB write pointers
  logic [ RsIdxLen-1:0]               cdb_idx;
  logic [NUM_UNITS-1:0][RsIdxLen-1:0] ex_idx;
  logic [NUM_UNITS-1:0] ex_valid, ex_ready;
  logic [NUM_UNITS-1:0] selected_valid, selected_accepted;
  logic [NUM_UNITS-1:0][RsIdxLen-1:0] selected_idx;
  logic [Len5Cfg.ISSUE_WIDTH-1:0][RsIdxLen-1:0] new_idx;
  logic [Len5Cfg.ISSUE_WIDTH-1:0] alloc_valid, issue_accept;
  logic [DEPTH-1:0][EU_CTL_LEN-1:0] insert_eu_ctl;
  op_data_t [Len5Cfg.ISSUE_WIDTH-1:0] issue_rs1_fwd, issue_rs2_fwd;
  op_data_t [DEPTH-1:0] insert_rs1;
  op_data_t [DEPTH-1:0] insert_rs2;
  rob_idx_t [DEPTH-1:0] insert_dest_rob_idx;
  logic [DEPTH-1:0] empty, ready_ex, ready_cdb;

  // Arithmetic reservation station data
  arith_rs_data_t [DEPTH-1:0] data;
  arith_state_t [DEPTH-1:0] curr_state, next_state;

  logic             cdb_selected_valid;

  // Reservation station control
  logic [DEPTH-1:0] insert;
  logic             remove;
  logic [NUM_UNITS-1:0] ex_accepted, save_res, completion_valid;
  logic [DEPTH-1:0] dispatched, completed;
  logic [    DEPTH-1:0][UnitIdxLen-1:0] completion_unit;
  rob_idx_t [NUM_UNITS-1:0] completion_rob_idx;
  logic [DEPTH-1:0] fwd_rs1_eu, fwd_rs2_eu;
  logic [DEPTH-1:0] fwd_rs1_cdb, fwd_rs2_cdb;
  logic [DEPTH-1:0] fwd_rs1, fwd_rs2;
  logic [DEPTH-1:0][UnitIdxLen-1:0] fwd_rs1_unit, fwd_rs2_unit;
  arith_op_t [DEPTH-1:0]           arith_op;

  // Ready signals for the selectors
  always_comb begin : p_enc_signals
    foreach (curr_state[i]) begin
      empty[i]     = curr_state[i] == ARITH_S_EMPTY;
      ready_ex[i]  = curr_state[i] == ARITH_S_EX_REQ;
      ready_cdb[i] = curr_state[i] == ARITH_S_COMPLETED;
    end
  end

  // -------------------------------------------
  // ARITHMETIC RESERVATION STATION CONTROL UNIT
  // -------------------------------------------

  // Control signals
  for (genvar k = 0; k < Len5Cfg.ISSUE_WIDTH; k++) begin : gen_accept
    assign issue_accept[k] = issue_valid_i[k] && issue_ready_o[k];
  end

  // Issue operands already include CDB forwarding; retain any ready value.
  always_comb begin : p_insert_fwd
    issue_rs1_fwd = issue_rs1_i;
    issue_rs2_fwd = issue_rs2_i;
    foreach (issue_rs1_fwd[k]) begin
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (!issue_rs1_i[k].ready && completion_valid[u] && completion_rob_idx[u] == issue_rs1_i[k].rob_idx) begin
          issue_rs1_fwd[k].ready = 1'b1;
          issue_rs1_fwd[k].value = eu_result_i[u];
        end
        if (!issue_rs2_i[k].ready && completion_valid[u] && completion_rob_idx[u] == issue_rs2_i[k].rob_idx) begin
          issue_rs2_fwd[k].ready = 1'b1;
          issue_rs2_fwd[k].value = eu_result_i[u];
        end
      end
    end
  end

  always_comb begin : gen_insert
    insert              = '0;
    insert_eu_ctl       = '0;
    insert_rs1          = '0;
    insert_rs2          = '0;
    insert_dest_rob_idx = '0;

    // Unused encoder outputs may repeat a valid entry's index.
    foreach (new_idx[k]) begin
      if (alloc_valid[k]) begin
        insert[new_idx[k]]              = issue_accept[k];
        insert_eu_ctl[new_idx[k]]       = issue_eu_ctl_i[k];
        insert_rs1[new_idx[k]]          = issue_rs1_fwd[k];
        insert_rs2[new_idx[k]]          = issue_rs2_fwd[k];
        insert_dest_rob_idx[new_idx[k]] = issue_dest_rob_idx_i[k];
      end
    end
  end
  assign remove      = cdb_valid_o & cdb_ready_i;
  assign ex_accepted = eu_valid_o & eu_ready_i;
  assign save_res    = eu_valid_i & eu_ready_o;

  always_comb begin : p_dispatch_demux
    dispatched = '0;
    for (int u = 0; u < NUM_UNITS; u++) begin
      if (ex_accepted[u]) dispatched[ex_idx[u]] = 1'b1;
    end
  end

  // Returned RS indices route all accepted completions, including zero-latency ones.
  always_comb begin : p_completion_demux
    completed          = '0;
    completion_unit    = '0;
    completion_valid   = '0;
    completion_rob_idx = '0;
    for (int u = 0; u < NUM_UNITS; u++) begin
      if (save_res[u]) begin
        completed[eu_rs_idx_i[u]]       = 1'b1;
        completion_unit[eu_rs_idx_i[u]] = UnitIdxLen'(u);
        completion_valid[u]            = 1'b1;
        completion_rob_idx[u]          = data[eu_rs_idx_i[u]].dest_rob_idx;
      end
    end
  end

  // Every operand selects its forwarding source independently.
  always_comb begin : p_fwd_rs_eu
    foreach (data[i]) begin
      fwd_rs1_eu[i]   = 1'b0;
      fwd_rs2_eu[i]   = 1'b0;
      fwd_rs1_unit[i] = '0;
      fwd_rs2_unit[i] = '0;
      for (int u = 0; u < NUM_UNITS; u++) begin
        if (completion_valid[u] && completion_rob_idx[u] == data[i].rs1_rob_idx) begin
          fwd_rs1_eu[i]   = 1'b1;
          fwd_rs1_unit[i] = UnitIdxLen'(u);
        end
        if (completion_valid[u] && completion_rob_idx[u] == data[i].rs2_rob_idx) begin
          fwd_rs2_eu[i]   = 1'b1;
          fwd_rs2_unit[i] = UnitIdxLen'(u);
        end
      end
    end
  end

  always_comb begin : p_fwd_rs_cdb
    foreach (data[i]) begin
      fwd_rs1_cdb[i] = cdb_valid_i && !flush_i && cdb_data_i.rob_idx == data[i].rs1_rob_idx;
      fwd_rs2_cdb[i] = cdb_valid_i && !flush_i && cdb_data_i.rob_idx == data[i].rs2_rob_idx;
    end
  end

  assign fwd_rs1 = fwd_rs1_eu | fwd_rs1_cdb;
  assign fwd_rs2 = fwd_rs2_eu | fwd_rs2_cdb;

  // State progression
  // NOTE: Mealy to avoid resampling data
  always_comb begin : p_state_prog
    // Default operation (no operation)
    foreach (arith_op[i]) arith_op[i] = ARITH_OP_NONE;

    foreach (curr_state[i]) begin
      unique case (curr_state[i])
        ARITH_S_EMPTY: begin  // insert a new instruction
          if (insert[i]) begin
            arith_op[i] = ARITH_OP_INSERT;
            case ({
              insert_rs1[i].ready, insert_rs2[i].ready
            })
              2'b11:   next_state[i] = ARITH_S_EX_REQ;
              2'b01:   next_state[i] = ARITH_S_RS1_PENDING;
              2'b10:   next_state[i] = ARITH_S_RS2_PENDING;
              default: next_state[i] = ARITH_S_RS12_PENDING;
            endcase
          end else next_state[i] = ARITH_S_EMPTY;
        end
        ARITH_S_RS12_PENDING: begin  // save rs1 and/or rs2 value from CDB
          if (fwd_rs1[i] && fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS12;
            next_state[i] = ARITH_S_EX_REQ;
          end else if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_RS2_PENDING;
          end else if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_RS1_PENDING;
          end else next_state[i] = ARITH_S_RS12_PENDING;
        end
        ARITH_S_RS1_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs1[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS1;
            next_state[i] = ARITH_S_EX_REQ;
          end else next_state[i] = ARITH_S_RS1_PENDING;
        end
        ARITH_S_RS2_PENDING: begin  // save rs2 value from CDB
          if (fwd_rs2[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RS2;
            next_state[i] = ARITH_S_EX_REQ;
          end else next_state[i] = ARITH_S_RS2_PENDING;
        end
        ARITH_S_EX_REQ: begin  // request execution to EU
          if (completed[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RES;
            next_state[i] = ARITH_S_COMPLETED;
          end else if (dispatched[i]) next_state[i] = ARITH_S_EX_WAIT;
          else next_state[i] = ARITH_S_EX_REQ;
        end
        ARITH_S_EX_WAIT: begin  // wait for execution completion
          if (completed[i]) begin
            arith_op[i]   = ARITH_OP_SAVE_RES;
            next_state[i] = ARITH_S_COMPLETED;
          end else next_state[i] = ARITH_S_EX_WAIT;
        end
        ARITH_S_COMPLETED: begin
          if (remove && cdb_idx == i[RsIdxLen-1:0]) next_state[i] = ARITH_S_EMPTY;
          else next_state[i] = ARITH_S_COMPLETED;
        end
        default: next_state[i] = ARITH_S_HALT;
      endcase
    end
  end

  // State update
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_state_update
    if (!rst_ni) foreach (curr_state[i]) curr_state[i] <= ARITH_S_EMPTY;
    else if (flush_i) foreach (curr_state[i]) curr_state[i] <= ARITH_S_EMPTY;
    else curr_state <= next_state;
  end

  // ------------------
  // ARITH UNIT BUFFER
  // ------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_rs_update
    if (!rst_ni) begin
      foreach (data[i]) begin
        data[i] <= '0;
      end
    end else begin
      // Performed the required action for each instruction
      foreach (arith_op[i]) begin
        unique case (arith_op[i])
          ARITH_OP_INSERT: begin
            data[i].eu_ctl       <= insert_eu_ctl[i];
            data[i].rs1_rob_idx  <= insert_rs1[i].rob_idx;
            data[i].rs1_value    <= insert_rs1[i].value;
            data[i].rs2_rob_idx  <= insert_rs2[i].rob_idx;
            data[i].rs2_value    <= insert_rs2[i].value;
            data[i].dest_rob_idx <= insert_dest_rob_idx[i];
          end
          ARITH_OP_SAVE_RS12: begin
            if (fwd_rs1_eu[i]) begin
              data[i].rs1_value <= eu_result_i[fwd_rs1_unit[i]];
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value;
            end
            if (fwd_rs2_eu[i]) begin
              data[i].rs2_value <= eu_result_i[fwd_rs2_unit[i]];
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value;
            end
          end
          ARITH_OP_SAVE_RS1: begin
            if (fwd_rs1_eu[i]) begin
              data[i].rs1_value <= eu_result_i[fwd_rs1_unit[i]];
            end else begin
              data[i].rs1_value <= cdb_data_i.res_value;
            end
          end
          ARITH_OP_SAVE_RS2: begin
            if (fwd_rs2_eu[i]) begin
              data[i].rs2_value <= eu_result_i[fwd_rs2_unit[i]];
            end else begin
              data[i].rs2_value <= cdb_data_i.res_value;
            end
          end
          ARITH_OP_SAVE_RES: begin
            data[i].res_value     <= eu_result_i[completion_unit[i]];
            data[i].except_raised <= eu_except_raised_i[completion_unit[i]];
            data[i].except_code   <= eu_except_code_i[completion_unit[i]];
          end
          default: ;
        endcase
      end
    end
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------

  // Issue Stage
  assign issue_ready_o            = alloc_valid & {Len5Cfg.ISSUE_WIDTH{!flush_i}};

  // CDB
  assign cdb_valid_o              = cdb_selected_valid && !flush_i;
  assign cdb_data_o.rob_idx       = data[cdb_idx].dest_rob_idx;
  assign cdb_data_o.res_value     = data[cdb_idx].res_value;
  assign cdb_data_o.except_raised = data[cdb_idx].except_raised;
  assign cdb_data_o.except_code   = data[cdb_idx].except_code;
  assign cdb_data_o.flags.raw     = '0;  // no flags set

  // Execution unit request interfaces.
  assign eu_ready_o               = {NUM_UNITS{!flush_i && rst_ni}};
  logic [NUM_UNITS-1:0]               active_q;
  logic [NUM_UNITS-1:0][RsIdxLen-1:0] ex_idx_hold;
  for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_requests
    logic [RsIdxLen-1:0] data_idx;
    if (EU == EU_INT_MULT && Len5Cfg.LEN5_MULT_SERIAL) begin : gen_serial_context
      // Serial multipliers read their operands throughout execution. Do not
      // present another request until the held operation has completed.
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          active_q[u]    <= 1'b0;
          ex_idx_hold[u] <= '0;
        end else if (flush_i) begin
          active_q[u]    <= 1'b0;
          ex_idx_hold[u] <= '0;
        end else begin
          if (save_res[u]) active_q[u] <= 1'b0;
          if (ex_accepted[u]) begin
            active_q[u]    <= 1'b1;
            ex_idx_hold[u] <= ex_idx[u];
          end
        end
      end
      assign data_idx      = active_q[u] ? ex_idx_hold[u] : ex_idx[u];
      assign eu_valid_o[u] = ex_valid[u] && !active_q[u];
      // Inactive held context means the serial unit is idle. Use registered
      // availability instead of its operand-dependent ready for lane selection.
      assign ex_ready[u]   = !active_q[u];
    end else begin : gen_sampled_inputs
      assign active_q[u]    = 1'b0;
      assign ex_idx_hold[u] = '0;
      assign data_idx       = ex_idx[u];
      assign eu_valid_o[u]  = ex_valid[u];
      assign ex_ready[u]    = eu_ready_i[u];
    end
    assign eu_ctl_o[u]     = data[data_idx].eu_ctl;
    assign eu_rs1_o[u]     = data[data_idx].rs1_value;
    assign eu_rs2_o[u]     = data[data_idx].rs2_value;
    assign eu_rs_idx_o[u] = data_idx;
  end

  // ---------------
  // ENTRY SELECTORS
  // ---------------
  // NOTE: round-robin arbiters mitigate starvation at increased area cost

  // Free-entry allocation preserves the ordered insertion prefix.
  prio_enc_multi #(
    .N          (DEPTH),
    .NUM_RESULTS(Len5Cfg.ISSUE_WIDTH)
  ) new_sel (
    .lines_i(empty),
    .enc_o  (new_idx),
    .valid_o(alloc_valid)
  );

  generate
    if (NUM_UNITS == 1) begin : gen_single_unit_match
      // Present valid independently of operation-dependent unit readiness.
	  assign ex_valid = selected_valid;
	  assign ex_idx = selected_idx;
      assign selected_accepted[0] = ex_accepted[0];
    end else begin : gen_multi_unit_match
      logic [NUM_UNITS-1:0][NUM_UNITS-1:0] ready_channel;
      logic [NUM_UNITS-1:0][NUM_UNITS-1:0] channel_select;

      // Ready units get the first channels, regardless of their physical position.
      always_comb begin : ready_channel_assignment
        ready_channel    = '0;
        ready_channel[0] = NUM_UNITS'(1);
        for (int u = 1; u < NUM_UNITS; u++) begin
          ready_channel[u] = ex_ready[u-1] ?
              ready_channel[u-1] << 1 : ready_channel[u-1];
        end
      end

      always_comb begin : channel_select_mux
        channel_select = '0;
        for (int u = 0; u < NUM_UNITS; u++) begin
          if (ex_ready[u]) channel_select[u] = ready_channel[u];
        end
      end

      for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_unit_routes
        always_comb begin : request_valid
          ex_valid[u] = 1'b0;
          if (ex_ready[u]) ex_valid[u] = |(channel_select[u] & selected_valid);
        end

        always_comb begin : request_index_mux
          ex_idx[u] = '0;
          for (int k = 0; k < NUM_UNITS; k++) begin
            ex_idx[u] |= selected_idx[k] &
                {RsIdxLen{channel_select[u][k] && selected_valid[k]}};
          end
        end
      end

      // Return each physical unit's acceptance to its assigned selection channel.
      for (genvar k = 0; k < NUM_UNITS; k++) begin : gen_acceptance
        logic [NUM_UNITS-1:0] unit_select;

        always_comb begin : acceptance_mux
          unit_select = '0;
          for (int u = 0; u < NUM_UNITS; u++) begin
            unit_select[u] = channel_select[u][k];
          end
        end

        assign selected_accepted[k] = |(unit_select & ex_accepted);
      end
    end

    if (RR_ARBITER) begin : gen_rr_arbiters
      // The arbiter selects RS entries; this station assigns physical units.
      rr_arbiter_multi #(
        .N          (DEPTH),
        .NUM_OUTPUTS(NUM_UNITS)
      ) u_ex_sel (
        .clk_i,
        .rst_ni,
        .flush_i,
        .valid_i (ready_ex),
        .ready_o (),
        .valid_o (selected_valid),
        .ready_i (selected_accepted),
        .served_o(selected_idx)
      );

      // CDB access
      rr_arbiter #(
        .N(DEPTH)
      ) u_cdb_sel (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .flush_i (flush_i),
        .valid_i (ready_cdb & {DEPTH{!flush_i}}),
        .ready_o (),                               // cdb_ready_i used instead
        .valid_o (cdb_selected_valid),
        .ready_i (cdb_ready_i),
        .served_o(cdb_idx)
      );
    end else begin : gen_prio_arbiters
      prio_enc_multi #(
        .N          (DEPTH),
        .NUM_RESULTS(NUM_UNITS)
      ) u_ex_sel (
        .lines_i(ready_ex),
        .enc_o  (selected_idx),
        .valid_o(selected_valid)
      );

      // CDB access
      prio_enc #(
        .N(DEPTH)
      ) u_cdb_sel (
        .lines_i(ready_cdb),
        .enc_o  (cdb_idx),
        .valid_o()
      );
      assign cdb_selected_valid = curr_state[cdb_idx] == ARITH_S_COMPLETED && !flush_i;
    end
  endgenerate

  // ----------
  // ASSERTIONS
  // ----------
`ifndef SYNTHESIS
  if (NUM_UNITS > 1) begin : gen_routing_assertions
    for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_unit
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        $onehot0(gen_multi_unit_match.channel_select[u]));
    end
    for (genvar k = 0; k < NUM_UNITS; k++) begin : gen_channel
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        $onehot0(gen_multi_unit_match.gen_acceptance[k].unit_select));
    end
  end

  for (genvar i = 0; i < DEPTH; i++) begin : gen_state_assertions
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      curr_state[i] != ARITH_S_HALT);
  end

  for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_completion_assertions
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      save_res[u] |-> int'(eu_rs_idx_i[u]) < DEPTH);
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      save_res[u] && int'(eu_rs_idx_i[u]) < DEPTH |->
      curr_state[eu_rs_idx_i[u]] == ARITH_S_EX_WAIT ||
      (curr_state[eu_rs_idx_i[u]] == ARITH_S_EX_REQ && dispatched[eu_rs_idx_i[u]]));
    for (genvar v = u + 1; v < NUM_UNITS; v++) begin : gen_distinct_completions
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        save_res[u] && save_res[v] |-> eu_rs_idx_i[u] != eu_rs_idx_i[v]);
    end
  end
  for (genvar u = 0; u < NUM_UNITS; u++) begin : gen_request_assertions
    assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
      EU == EU_INT_MULT && Len5Cfg.LEN5_MULT_SERIAL && eu_valid_o[u] |-> eu_ready_i[u]);
    for (genvar v = u + 1; v < NUM_UNITS; v++) begin : gen_distinct
      assert property (@(posedge clk_i) disable iff (!rst_ni || flush_i)
        ex_valid[u] && ex_valid[v] |-> ex_idx[u] != ex_idx[v]);
    end
  end
`endif

endmodule
