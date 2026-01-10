//This module detects the misaligment in pc and whether the branch is predicted taken, it goes to FIFO in memory fetch unit later on

module gen_valid_instr (
    input logic [len5_pkg::XLEN-1:0] pc_i,
    input fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_i,
    output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_o,
    output fetch_pkg::prediction_t pred_o
);
    import len5_config_pkg::*;
    generate
        if (LEN5_MULTIPLE_ISSUES == 1) begin : gen_single_issue
        
            assign valid_o = 1'b1;
            assign pred_o = pred_i;
        
        end else begin : gen_multiple_issues
        
            logic [LEN5_MULTIPLE_ISSUES-1:0] predicted_taken, selected_taken, n_skipped;
            logic [LEN5_MULTIPLE_ISSUES_BITS-1:0] pc_lsbs;    
            //check whether the instruction has been preditced to be taken and it has its pc in btb
            for(genvar i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin : gen_predicted_taken
                assign predicted_taken[i] = pred_i[i].hit & pred_i[i].taken;
            end

            //%TODO check with Michele, 
            // it's either this way, or nested loop
            always_comb begin : gen_selected_taken
                logic selected = 1'b1;
                for(int unsigned i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin
                    selected_taken[i] = selected;
                    if (predicted_taken[i] & (~n_skipped[i])) begin
                        selected = 1'b0;
                    end
                end
            end

            // detect which instructions are skipped because pc counter didn't land on 00 address
            assign pc_lsbs = pc_i[LEN5_MULTIPLE_ISSUES_BITS-1+2:2];
            always_comb begin : gen_skipped
                logic n_skipped_var = 1'b0;
                for(int unsigned i = 0; i < LEN5_MULTIPLE_ISSUES; i++) begin
                    if(pc_lsbs == i[LEN5_MULTIPLE_ISSUES_BITS-1:0]) begin
                        n_skipped_var = 1'b1;
                    end
                    n_skipped[i] = n_skipped_var;
                end
            end

            // generate valid_o
            assign valid_o = n_skipped & selected_taken;

            //generate selected prediction
            always_comb begin : gen_sel_pred
                pred_o = '0;
                for(int i = LEN5_MULTIPLE_ISSUES-1; i >= 0; i--) begin
                    if (predicted_taken[i]) begin
                        pred_o = pred_i[i];
                    end
                end
            end
        end
    endgenerate
endmodule
