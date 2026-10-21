// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Included only by the simulation wrapper. u_sram.sram is the authoritative array.
function automatic void put_byte(logic [63:0] address, logic [7:0] value);
  if (memory_backend_pkg::in_region(address, 1, BASE_ADDR, 64'(SIZE_BYTES))) begin
    // Initialization precedes requests; each instance deposits only its own absolute addresses.
    /* verilator lint_off BLKSEQ */
    u_sram.sram[ADDR_WIDTH'((address-BASE_ADDR)/64'(WORD_BYTES))]
        [int'((address-BASE_ADDR)%64'(WORD_BYTES))*8+:8] = value;
    /* verilator lint_on BLKSEQ */
  end else if (!memory_backend_pkg::in_region(address, 1, OTHER_BASE_ADDR, 64'(OTHER_SIZE_BYTES))) begin
    $fatal(1, "Firmware byte at 0x%h is outside IMEM/DMEM", address);
  end
endfunction

`include "firmware_loader.svh"
