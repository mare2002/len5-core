module instr_mixer (
    input logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_i,
    input len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instructions_i,
    output logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] valid_o,
    output len5_pkg::instr_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instructions_o
  ); 

    import len5_config_pkg::*;
    import len5_pkg::*;

    generate
        //in case of single issue there is no need to do anything
        if (LEN5_MULTIPLE_ISSUES==1) begin : gen_one_instr
            assign valid_o = valid_i;
            assign instructions_o = instructions_i;
        end else begin : gen_mult_instr
        //in case of multiple issues create a multiplexer network which shifts the outputs
            instr_t [LEN5_MULTIPLE_ISSUES-1:0][LEN5_MULTIPLE_ISSUES-1:0] intermediate_signals;
            logic [LEN5_MULTIPLE_ISSUES-1:0][LEN5_MULTIPLE_ISSUES-1:0] intermediate_valid;
            assign intermediate_signals[0] = instructions_i;
            assign intermediate_valid[0] = valid_i;
            always_comb begin: gen_muxes
                for(int i = 1; i<LEN5_MULTIPLE_ISSUES; i++) begin
                    for(int j=0; j<LEN5_MULTIPLE_ISSUES; j++) begin
                        if(j!=LEN5_MULTIPLE_ISSUES-1) begin
                            intermediate_signals[i][j] = (intermediate_valid[i-1][0]) ? intermediate_signals[i-1][j] : intermediate_signals[i-1][j+1];
                            intermediate_valid[i][j] = (intermediate_valid[i-1][0]) ? intermediate_valid[i-1][j] : intermediate_valid[i-1][j+1];
                        end else begin
                            intermediate_signals[i][j] = (intermediate_valid[i-1][0]) ? intermediate_signals[i-1][j] : '0;
                            intermediate_valid[i][j] = (intermediate_valid[i-1][0]) ? intermediate_valid[i-1][j] : '0;
                        end
                    end
                end
            end
            assign instructions_o = intermediate_signals[LEN5_MULTIPLE_ISSUES-1];
            assign valid_o = intermediate_valid[LEN5_MULTIPLE_ISSUES-1];
        end
    endgenerate
endmodule
