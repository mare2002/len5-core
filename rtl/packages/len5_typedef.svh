// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Type expressions, evaluated in each module with its selected Len5Cfg.
`ifndef LEN5_TYPEDEF_SVH_
`define LEN5_TYPEDEF_SVH_

`define LEN5_MEM_IF_ANS_REG_T(Cfg) struct packed { \
logic [Cfg.LEN5_MULTIPLE_ISSUES-1:0][len5_pkg::ILEN-1:0] instr; \
fetch_pkg::prediction_t [Cfg.LEN5_MULTIPLE_ISSUES-1:0] pred_data; \
logic [Cfg.LEN5_MULTIPLE_ISSUES-1:0] except_raised; \
len5_pkg::except_code_t [Cfg.LEN5_MULTIPLE_ISSUES-1:0] except_code; \
logic [Cfg.LEN5_MULTIPLE_ISSUES-1:0] valid_instr; \
}

`define LEN5_ROB_IDX_T(Cfg) logic [Cfg.ROB_IDX_LEN-1:0]

`define LEN5_CDB_DATA_T(Cfg) struct packed { \
`LEN5_ROB_IDX_T(Cfg)        rob_idx; \
logic [len5_pkg::XLEN-1:0] res_value; \
logic            except_raised; \
len5_pkg::except_code_t    except_code; \
expipe_pkg::flags_t          flags; \
}

`define LEN5_OP_DATA_T(Cfg) struct packed { \
logic            ready; \
`LEN5_ROB_IDX_T(Cfg)        rob_idx; \
logic [len5_pkg::XLEN-1:0] value; \
}

`define LEN5_ADDER_REQ_T(Cfg) struct packed { \
logic [Cfg.BUFF_IDX_LEN-1:0] tag; \
expipe_pkg::ldst_width_t             ls_type; \
logic [len5_pkg::XLEN-1:0]         base; \
logic [len5_pkg::XLEN-1:0]         offs; \
}

`define LEN5_ADDER_ANS_T(Cfg) struct packed { \
logic [Cfg.BUFF_IDX_LEN-1:0] tag; \
logic [len5_pkg::XLEN-1:0]         result; \
logic                    except_raised; \
len5_pkg::except_code_t            except_code; \
}

`define LEN5_MEM_REQ_T(Cfg) struct packed { \
logic [Cfg.BUFF_IDX_LEN-1:0]   tag; \
memory_pkg::mem_acc_t acc_type; \
expipe_pkg::ldst_width_t               ls_type; \
logic [len5_pkg::XLEN-1:0] addr; \
logic [len5_pkg::XLEN-1:0] value; \
}

`define LEN5_MEM_ANS_T(Cfg) struct packed { \
logic [Cfg.BUFF_IDX_LEN-1:0]   tag; \
memory_pkg::mem_acc_t acc_type; \
logic [len5_pkg::XLEN-1:0] addr; \
logic [len5_pkg::XLEN-1:0] value; \
logic                      except_raised; \
len5_pkg::except_code_t              except_code; \
}

`endif
