// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Buffer-tag-dependent VM records; evaluated with the owning module configuration.
`ifndef LEN5_MEMORY_TYPEDEF_SVH_
`define LEN5_MEMORY_TYPEDEF_SVH_

`define LEN5_VM_LSQ_ADDR_T(Cfg) logic [Cfg.BUFF_IDX_LEN-1:0]

`define LEN5_VM_LSQ_L1DC_REQ_T(Cfg) struct packed { \
memory_pkg::dcache_L1_addr_t           paddr; \
logic [len5_pkg::XLEN-1:0] data; \
lsq_d0_req_type_e          req_type; \
memory_pkg::store_width_e              store_width; \
`LEN5_VM_LSQ_ADDR_T(Cfg)                 lsq_addr; \
logic                      valid; \
}

`define LEN5_VM_L1DC_LSQ_ANS_T(Cfg) struct packed { \
logic [len5_pkg::XLEN-1:0] data; \
logic                      was_store; \
`LEN5_VM_LSQ_ADDR_T(Cfg)                 lsq_addr; \
logic                      valid; \
}

`define LEN5_VM_D1_REQ_INFO_T(Cfg) struct packed { \
memory_pkg::d0_d1_req_type_e           req_type; \
memory_pkg::dcache_L1_addr_t           paddr; \
logic [len5_pkg::XLEN-1:0] data; \
memory_pkg::dcache_line_t              line; \
memory_pkg::store_width_e              store_width; \
memory_pkg::wbb_tag_t                  wbb_tag; \
`LEN5_VM_LSQ_ADDR_T(Cfg)                 lsq_addr; \
logic                      valid; \
}

`define LEN5_VM_D0_D1_REQ_T(Cfg) struct packed { \
`LEN5_VM_D1_REQ_INFO_T(Cfg) info; \
memory_pkg::d1_mem_out_t  mem_out; \
}

`define LEN5_VM_D1_D0_REQ_T(Cfg) struct packed { \
memory_pkg::d1_d0_req_type_e           req_type; \
memory_pkg::dcache_L1_addr_t           paddr; \
logic [len5_pkg::XLEN-1:0] data; \
memory_pkg::dcache_line_t              line; \
memory_pkg::store_width_e              store_width; \
`LEN5_VM_LSQ_ADDR_T(Cfg)                 lsq_addr; \
memory_pkg::hit_vec_t                  hit_vec; \
memory_pkg::dirty_vec_t                dirty_vec; \
memory_pkg::repl_vec_t                 replace_vec; \
logic                      valid; \
}

`define LEN5_VM_L1DC_REPLAY_T(Cfg) struct packed { \
memory_pkg::d1_d0_req_type_e           req_type; \
memory_pkg::dcache_L1_addr_t           paddr; \
logic [len5_pkg::XLEN-1:0] doubleword; \
`LEN5_VM_LSQ_ADDR_T(Cfg)                 lsq_addr; \
memory_pkg::store_width_e              store_width; \
}

`define LEN5_VM_LSQ_DTLB_REQ_T(Cfg) struct packed { \
logic [memory_pkg::VPN_LEN-1:0] vpn; \
logic               is_store; \
`LEN5_VM_LSQ_ADDR_T(Cfg)          lsq_addr; \
logic               valid; \
}

`define LEN5_VM_DTLB_LSQ_ANS_T(Cfg) struct packed { \
logic [memory_pkg::PPN_LEN-1:0] ppn; \
memory_pkg::exception_e         exception; \
logic               was_store; \
`LEN5_VM_LSQ_ADDR_T(Cfg)          lsq_addr; \
logic               valid; \
}

`endif
