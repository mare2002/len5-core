// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
package memory_backend_pkg;
  import len5_pkg::*;
  import len5_config_pkg::*;
  // Match LEN5's uppercase constant convention.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned SRAM_ADDR_WIDTH = SRAM_SIZE_BYTES / 8 > 1 ? $clog2(SRAM_SIZE_BYTES / 8) : 1;

  typedef struct packed {
    logic instr_gnt, instr_valid;
    logic [LEN5_MULTIPLE_ISSUES-1:0][31:0] instr_data;
    logic [LEN5_MULTIPLE_ISSUES-1:0] instr_except;
    except_code_t [LEN5_MULTIPLE_ISSUES-1:0] instr_code;
    logic load_gnt, load_valid;
    logic [63:0] load_data;
    logic [BUFF_IDX_LEN-1:0] load_tag;
    logic load_except;
    except_code_t load_code;
    logic store_gnt, store_valid;
    logic [BUFF_IDX_LEN-1:0] store_tag;
    logic store_except;
    except_code_t store_code;
  } memory_response_t;

  function automatic int unsigned access_bytes(logic [7:0] mask);
    case (mask)
      8'h01:   return 1;
      8'h03:   return 2;
      8'h0f:   return 4;
      8'hff:   return 8;
      default: return 0;
    endcase
  endfunction

  // Subtraction is evaluated only after the below-base test; no end-address sum.
  function automatic logic in_region(logic [63:0] addr, int unsigned bytes, logic [63:0] base,
                                     longint unsigned size);
    return bytes != 0 && 64'(bytes) <= size && addr >= base && (addr - base) <= (size - 64'(bytes));
  endfunction
endpackage
