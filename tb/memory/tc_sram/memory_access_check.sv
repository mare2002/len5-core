// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Byte-address validation for a native memory region; alignment has priority.
module memory_access_check #(
  parameter logic [63:0] BASE_ADDR = tb_config_pkg::IMEM_BASE_ADDR,
  parameter int unsigned SIZE_BYTES = tb_config_pkg::IMEM_SIZE_BYTES,
  parameter logic [63:0] SERIAL_ADDR = tb_config_pkg::SERIAL_ADDR,
  parameter logic [63:0] EXIT_ADDR = tb_config_pkg::EXIT_ADDR,
  parameter int unsigned KIND = 0  // 0 instruction, 1 load, 2 store
) (
  input  logic                   [63:0] addr_i,
  input  int unsigned                   bytes_i,
  output logic                          sram_o,
  mmio_o,
  except_o,
  output len5_pkg::except_code_t        code_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;

  // KIND is static; retain the original load/store fallback for non-instruction accesses.
  // verilog_lint: waive parameter-name-style
  localparam except_code_t DATA_ACCESS_FAULT = KIND == 1 ? E_LD_ACCESS_FAULT : E_ST_ACCESS_FAULT;
  // verilog_lint: waive parameter-name-style
  localparam except_code_t DATA_MISALIGNED = KIND == 1 ? E_LD_ADDR_MISALIGNED : E_ST_ADDR_MISALIGNED;

  logic access_misaligned;
  logic access_in_sram;
  logic access_is_mmio_store;

  // A zero size denotes an unsupported mask. Each destination keeps its own size check.
  assign access_misaligned = (bytes_i != 0) && ((addr_i & (64'(bytes_i) - 1)) != 0);
  assign access_in_sram = in_region(addr_i, bytes_i, BASE_ADDR, 64'(SIZE_BYTES));
  assign access_is_mmio_store = (KIND == 2) && (bytes_i != 0) && (bytes_i <= 8) &&
                                ((addr_i == SERIAL_ADDR) || (addr_i == EXIT_ADDR));

  // Misalignment takes priority over both destination decoding and access faults.
  always_comb begin : decode_access
    sram_o   = 1'b0;
    mmio_o   = 1'b0;
    except_o = 1'b1;
    code_o   = KIND == 0 ? E_I_ACCESS_FAULT : DATA_ACCESS_FAULT;

    if (access_misaligned) begin
      code_o = KIND == 0 ? E_I_ADDR_MISALIGNED : DATA_MISALIGNED;
    end else if (access_is_mmio_store) begin
      mmio_o   = 1'b1;
      except_o = 1'b0;
      code_o   = E_UNKNOWN;
    end else if (access_in_sram) begin
      sram_o   = 1'b1;
      except_o = 1'b0;
      code_o   = E_UNKNOWN;
    end
  end
endmodule
