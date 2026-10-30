//This
module gen_valid_instr #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG
) (
    input logic [len5_pkg::XLEN-1:0] pc_i,
    input fetch_pkg::prediction_t [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] pred_i,
    output logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] valid_o,
    output fetch_pkg::prediction_t pred_o
);

  import len5_pkg::*;
  import len5_config_pkg::*;
  generate
    if (Len5Cfg.LEN5_MULTIPLE_ISSUES == 1) begin : gen_single_issue

      assign valid_o = 1'b1;
      assign pred_o  = pred_i;

    end else begin : gen_multiple_issues

      logic [Len5Cfg.LEN5_MULTIPLE_ISSUES-1:0] predicted_taken, selected_taken, skipped_n;
      logic [Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS-1:0] pc_lsbs;
      //check whether the instruction has been preditced to be taken and it has its pc in btb
      for (genvar i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin : gen_predicted_taken
        assign predicted_taken[i] = pred_i[i].hit & pred_i[i].taken;
      end

      //%TODO check with Michele,
      // it's either this way, or nested loop
      always_comb begin : gen_selected_taken
        logic selected;
        selected = 1'b1;
        for (int unsigned i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin
          selected_taken[i] = selected;
          if (predicted_taken[i] && skipped_n[i]) begin
            selected = 1'b0;
          end
        end
      end

      // detect which instructions are skipped because pc counter didn't land on 00 address
      assign pc_lsbs = pc_i[Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS-1+2:2];
      always_comb begin : geskipped_n
        logic skipped_var_n;
        skipped_var_n = 1'b0;
        for (int unsigned i = 0; i < Len5Cfg.LEN5_MULTIPLE_ISSUES; i++) begin
          if (pc_lsbs == i[Len5Cfg.LEN5_MULTIPLE_ISSUES_BITS-1:0]) begin
            skipped_var_n = 1'b1;
          end
          skipped_n[i] = skipped_var_n;
        end
      end

      // generate valid_o
      assign valid_o = skipped_n & selected_taken;

      //generate selected prediction
      always_comb begin : gen_sel_pred
        pred_o = '0;
        for (int i = Len5Cfg.LEN5_MULTIPLE_ISSUES - 1; i >= 0; i--) begin
          if (predicted_taken[i] && skipped_n[i]) begin
            pred_o = pred_i[i];
          end
        end
      end
    end
  endgenerate
endmodule
