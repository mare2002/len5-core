// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Type expressions, evaluated with the selected configuration at each instance.
`ifndef LEN5_TB_TYPEDEF_SVH_
`define LEN5_TB_TYPEDEF_SVH_

`include "axi/typedef.svh"
`include "len5_typedef.svh"

`define LEN5_MEMORY_RESPONSE_T(Cfg) struct packed { \
logic instr_gnt; \
logic instr_valid; \
logic [Cfg.LEN5_MULTIPLE_ISSUES-1:0][len5_pkg::ILEN-1:0] instr_data; \
logic [Cfg.LEN5_MULTIPLE_ISSUES-1:0] instr_except; \
len5_pkg::except_code_t [Cfg.LEN5_MULTIPLE_ISSUES-1:0] instr_code; \
logic load_gnt; \
logic load_valid; \
logic [len5_pkg::XLEN-1:0] load_data; \
logic [Cfg.BUFF_IDX_LEN-1:0] load_tag; \
logic load_except; \
len5_pkg::except_code_t load_code; \
logic store_gnt; \
logic store_valid; \
logic [Cfg.BUFF_IDX_LEN-1:0] store_tag; \
logic store_except; \
len5_pkg::except_code_t store_code; \
}

`define LEN5_AXI_ID_T(Cfg) logic [Cfg.BUFF_IDX_LEN-1:0]

`define LEN5_IMEM_AXI_AW_CHAN_T(Cfg) \
`AXI_DECL_AW_CHAN_T(axi_memory_pkg::addr_t, `LEN5_AXI_ID_T(Cfg), axi_memory_pkg::user_t)

`define LEN5_IMEM_AXI_W_CHAN_T(Cfg) \
`AXI_DECL_W_CHAN_T(logic [Cfg.IMEM_DATA_WIDTH-1:0], \
logic [Cfg.IMEM_DATA_WIDTH/8-1:0], axi_memory_pkg::user_t)

`define LEN5_IMEM_AXI_B_CHAN_T(Cfg) \
`AXI_DECL_B_CHAN_T(`LEN5_AXI_ID_T(Cfg), axi_memory_pkg::user_t)

`define LEN5_IMEM_AXI_AR_CHAN_T(Cfg) \
`AXI_DECL_AR_CHAN_T(axi_memory_pkg::addr_t, `LEN5_AXI_ID_T(Cfg), axi_memory_pkg::user_t)

`define LEN5_IMEM_AXI_R_CHAN_T(Cfg) \
`AXI_DECL_R_CHAN_T(logic [Cfg.IMEM_DATA_WIDTH-1:0], \
`LEN5_AXI_ID_T(Cfg), axi_memory_pkg::user_t)

`define LEN5_IMEM_AXI_REQ_T(
    Cfg) \
`AXI_DECL_REQ_T(`LEN5_IMEM_AXI_AW_CHAN_T(Cfg), `LEN5_IMEM_AXI_W_CHAN_T(Cfg), `LEN5_IMEM_AXI_AR_CHAN_T(Cfg))

`define LEN5_IMEM_AXI_RESP_T(Cfg) \
`AXI_DECL_RESP_T(`LEN5_IMEM_AXI_B_CHAN_T(Cfg), `LEN5_IMEM_AXI_R_CHAN_T(Cfg))

`define LEN5_DMEM_AXI_AW_CHAN_T(Cfg) `LEN5_IMEM_AXI_AW_CHAN_T(Cfg)

`define LEN5_DMEM_AXI_W_CHAN_T(Cfg) \
`AXI_DECL_W_CHAN_T(axi_memory_pkg::data_t, axi_memory_pkg::strb_t, axi_memory_pkg::user_t)

`define LEN5_DMEM_AXI_B_CHAN_T(Cfg) `LEN5_IMEM_AXI_B_CHAN_T(Cfg)

`define LEN5_DMEM_AXI_AR_CHAN_T(Cfg) `LEN5_IMEM_AXI_AR_CHAN_T(Cfg)

`define LEN5_DMEM_AXI_R_CHAN_T(Cfg) \
`AXI_DECL_R_CHAN_T(axi_memory_pkg::data_t, `LEN5_AXI_ID_T(Cfg), axi_memory_pkg::user_t)

`define LEN5_DMEM_AXI_REQ_T(
    Cfg) \
`AXI_DECL_REQ_T(`LEN5_DMEM_AXI_AW_CHAN_T(Cfg), `LEN5_DMEM_AXI_W_CHAN_T(Cfg), `LEN5_DMEM_AXI_AR_CHAN_T(Cfg))

`define LEN5_DMEM_AXI_RESP_T(Cfg) \
`AXI_DECL_RESP_T(`LEN5_DMEM_AXI_B_CHAN_T(Cfg), `LEN5_DMEM_AXI_R_CHAN_T(Cfg))

`endif
