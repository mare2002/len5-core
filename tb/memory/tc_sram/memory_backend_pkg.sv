// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
package memory_backend_pkg;
  import len5_pkg::*;
  import len5_config_pkg::*;
  import tb_config_pkg::*;

  // Native addresses index words; instruction words hold one complete fetch bundle.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_DATA_WIDTH = LEN5_MULTIPLE_ISSUES > 2 ? 32 * LEN5_MULTIPLE_ISSUES : 64;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_WORD_BYTES = IMEM_DATA_WIDTH / 8;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned IMEM_ADDR_WIDTH = IMEM_SIZE_BYTES / IMEM_WORD_BYTES > 1 ? $clog2(
      IMEM_SIZE_BYTES / IMEM_WORD_BYTES
  ) : 1;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned DMEM_ADDR_WIDTH = DMEM_SIZE_BYTES / 8 > 1 ? $clog2(
      DMEM_SIZE_BYTES / 8
  ) : 1;

  // One extra reservation avoids a full-buffer bubble during steady one-request-per-cycle reads.
  // verilog_lint: waive parameter-name-style
  localparam int unsigned SRAM_RESPONSE_DEPTH = (DMEM_LATENCY > 0 ? DMEM_LATENCY : 1) + 1;
  // verilog_lint: waive parameter-name-style
  localparam int unsigned SRAM_COUNT_WIDTH = $clog2(SRAM_RESPONSE_DEPTH + 1);

  // Preserve channel and field order: this packed type is the shared backend interface.
  typedef struct packed {
    // Instruction bundle response.
    logic instr_gnt;
    logic instr_valid;
    logic [LEN5_MULTIPLE_ISSUES-1:0][31:0] instr_data;
    logic [LEN5_MULTIPLE_ISSUES-1:0] instr_except;
    except_code_t [LEN5_MULTIPLE_ISSUES-1:0] instr_code;

    // Load response, identified by its load-buffer tag.
    logic load_gnt;
    logic load_valid;
    logic [63:0] load_data;
    logic [BUFF_IDX_LEN-1:0] load_tag;
    logic load_except;
    except_code_t load_code;

    // Store completion, identified by its store-buffer tag.
    logic store_gnt;
    logic store_valid;
    logic [BUFF_IDX_LEN-1:0] store_tag;
    logic store_except;
    except_code_t store_code;
  } memory_response_t;

  // CPU masks encode access size before the adapter positions the native byte lanes.
  function automatic int unsigned access_bytes(logic [7:0] mask);
    case (mask)
      8'h01:   return 1;
      8'h03:   return 2;
      8'h0f:   return 4;
      8'hff:   return 8;
      default: return 0;
    endcase
  endfunction

  // Check the complete access without an overflowing address-plus-size calculation.
  function automatic logic in_region(logic [63:0] addr, int unsigned bytes, logic [63:0] base,
                                     longint unsigned size);
    return (bytes != 0) && (64'(bytes) <= size) && (addr >= base) &&
           ((addr - base) <= (size - 64'(bytes)));
  endfunction

  // Subtract bases rather than adding sizes, so validation cannot overflow.
  function automatic logic regions_overlap(logic [63:0] first_base, longint unsigned first_size,
                                           logic [63:0] second_base, longint unsigned second_size);
    return first_size != 0 && second_size != 0 &&
           (first_base <= second_base ? second_base - first_base < first_size :
                                       first_base - second_base < second_size);
  endfunction
endpackage
