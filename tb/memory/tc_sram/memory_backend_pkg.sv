// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
package memory_backend_pkg;
  import len5_pkg::*;

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
