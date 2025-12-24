module instr_mixer (
    input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_i,
    input len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instructions_i,
    input fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_i,
    output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_o,
    output len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instructions_o,
    output fetch_pkg::prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] pred_o
  ); 

    import len5_config_pkg::*;
    import len5_pkg::*;
    import fetch_pkg::prediction_t;
    
    generate
        //in case of single issue there is no need to do anything
        if (LEN5_MULTIPLE_ISSUES==1) begin : gen_one_instr
            assign valid_o = valid_i;
            assign instructions_o = instructions_i;
            assign pred_o = pred_i;
        end else begin : gen_mult_instr
        //in case of multiple issues create a multiplexer network which shifts the outputs
            instr_t [LEN5_MULTIPLE_ISSUES-1:0][LEN5_MULTIPLE_ISSUES-1:0] intermediate_instr;
            logic [LEN5_MULTIPLE_ISSUES-1:0][LEN5_MULTIPLE_ISSUES-1:0] intermediate_valid;
            prediction_t [LEN5_MULTIPLE_ISSUES-1:0][LEN5_MULTIPLE_ISSUES-1:0] intermediate_prediction;
            assign intermediate_instr[0] = instructions_i;
            assign intermediate_prediction[0] = pred_i;
            assign intermediate_valid[0] = valid_i;
            always_comb begin: gen_muxes
                for(int i = 1; i<LEN5_MULTIPLE_ISSUES; i++) begin
                    for(int j=0; j<LEN5_MULTIPLE_ISSUES; j++) begin
                        if(j!=LEN5_MULTIPLE_ISSUES-1) begin
                            intermediate_instr[i][j] = (intermediate_valid[i-1][0]) ? intermediate_instr[i-1][j] : intermediate_instr[i-1][j+1];
                            intermediate_prediction[i][j] = (intermediate_valid[i-1][0]) ? intermediate_prediction[i-1][j] : intermediate_prediction[i-1][j+1];
                            intermediate_valid[i][j] = (intermediate_valid[i-1][0]) ? intermediate_valid[i-1][j] : intermediate_valid[i-1][j+1];
                        end else begin
                            intermediate_instr[i][j] = (intermediate_valid[i-1][0]) ? intermediate_instr[i-1][j] : '0;
                            intermediate_prediction[i][j] = (intermediate_valid[i-1][0]) ? intermediate_prediction[i-1][j] : '0;
                            intermediate_valid[i][j] = (intermediate_valid[i-1][0]) ? intermediate_valid[i-1][j] : '0;
                        end
                    end
                end
            end
            assign instructions_o = intermediate_instr[LEN5_MULTIPLE_ISSUES-1];
            assign pred_o = intermediate_prediction[LEN5_MULTIPLE_ISSUES-1];
            assign valid_o = intermediate_valid[LEN5_MULTIPLE_ISSUES-1];
        end
    endgenerate
endmodule
