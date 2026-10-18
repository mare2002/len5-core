// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Byte-address decoder shared by memory backends; alignment has priority.
module memory_access_check #(
    parameter logic [63:0] BASE_ADDR = len5_config_pkg::SRAM_BASE_ADDR,
    parameter int unsigned SIZE_BYTES = len5_config_pkg::SRAM_SIZE_BYTES,
    parameter logic [63:0] SERIAL_ADDR = len5_config_pkg::SERIAL_ADDR,
    parameter logic [63:0] EXIT_ADDR = len5_config_pkg::EXIT_ADDR,
    parameter int unsigned KIND = 0  // 0 instruction, 1 load, 2 store
) (
    input logic [63:0] addr_i,
    input int unsigned bytes_i,
    output logic sram_o,
    mmio_o,
    except_o,
    output len5_pkg::except_code_t code_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;
  always_comb begin
    sram_o   = 0;
    mmio_o   = 0;
    except_o = 1;
    code_o   = KIND == 0 ? E_I_ACCESS_FAULT : KIND == 1 ? E_LD_ACCESS_FAULT : E_ST_ACCESS_FAULT;
    if (bytes_i != 0 && (addr_i & (64'(bytes_i) - 1)) != 0) begin
      code_o = KIND == 0 ? E_I_ADDR_MISALIGNED : KIND == 1 ? E_LD_ADDR_MISALIGNED : E_ST_ADDR_MISALIGNED;
    end else if (KIND == 2 && bytes_i != 0 && bytes_i <= 8 &&
                 (addr_i == SERIAL_ADDR || addr_i == EXIT_ADDR)) begin
      mmio_o   = 1;
      except_o = 0;
      code_o   = E_UNKNOWN;
    end else if (in_region(addr_i, bytes_i, BASE_ADDR, 64'(SIZE_BYTES))) begin
      sram_o   = 1;
      except_o = 0;
      code_o   = E_UNKNOWN;
    end
  end
endmodule
