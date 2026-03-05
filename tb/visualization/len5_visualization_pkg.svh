// ------------------------------
// Package with C functions
// ------------------------------

package len5_visualization_pkg;
  // ----------------------------
  // DPI-C imports
  // ----------------------------
  import "DPI-C" function int dpi_init_database(
    input  string filename,
    output longint unsigned db_handle,
    output longint unsigned stmt_handle
  );

  import "DPI-C" function int dpi_insert_state(
    input longint unsigned db_handle,
    input longint unsigned stmt_handle,
    input longint unsigned traceC_handle
  );

  import "DPI-C" function int dpi_close_database(
    input longint unsigned db_handle,
    input longint unsigned stmt_handle
  );

  import "DPI-C" function int dpi_create_struct(
    output longint unsigned traceC_handle
  );

  import "DPI-C" function int dpi_delete_struct(
    input longint unsigned traceC_handle
  );

  import "DPI-C" function int dpi_update_trace_cycle(
    input longint unsigned traceC_handle,
    input longint unsigned cycle,
    input longint unsigned cur_time
  );

  import "DPI-C" function int dpi_update_trace_pc(
    input longint unsigned traceC_handle,
    input logic [71:0] pc_gen
  );

endpackage
