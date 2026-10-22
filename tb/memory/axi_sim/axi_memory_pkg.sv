// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
`include "axi/typedef.svh"
package axi_memory_pkg;
  localparam int unsigned AddrWidth = len5_pkg::XLEN;
  localparam int unsigned InstrDataWidth = len5_config_pkg::LEN5_MULTIPLE_ISSUES > 2 ?
      32 * len5_config_pkg::LEN5_MULTIPLE_ISSUES : 64;
  localparam int unsigned TagCount = 1 << len5_pkg::BUFF_IDX_LEN;
  localparam int unsigned CountWidth = $clog2(
      (TagCount > len5_config_pkg::FETCH_MEMIF_FIFO_DEPTH ? TagCount : len5_config_pkg::FETCH_MEMIF_FIFO_DEPTH) + 1
  );
  typedef logic [AddrWidth-1:0] addr_t;
  typedef logic [len5_pkg::BUFF_IDX_LEN-1:0] id_t;
  typedef logic [0:0] user_t;
  typedef logic [InstrDataWidth-1:0] instr_data_t;
  typedef logic [InstrDataWidth/8-1:0] instr_strb_t;
  typedef logic [63:0] data_t;
  typedef logic [7:0] strb_t;
  `AXI_TYPEDEF_ALL(imem_axi, addr_t, id_t, instr_data_t, instr_strb_t, user_t)
  `AXI_TYPEDEF_ALL(dmem_axi, addr_t, id_t, data_t, strb_t, user_t)
endpackage
