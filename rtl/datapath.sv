module datapath #(
  parameter int unsigned FETCH_MEMIF_FIFO_DEPTH = 2,
  parameter longint unsigned BOOT_PC = '0,
  parameter logic [63:0] SERIAL_ADDR = len5_config_pkg::SERIAL_ADDR,
  parameter logic [63:0] EXIT_ADDR = len5_config_pkg::EXIT_ADDR
) (
  // Clock and reset
  input logic clk_i,
  input logic rst_ni,

  output logic mem_flush_o,

  // Instruction memory interface
  output logic                                        instr_req_o,
  input  logic                                        instr_gnt_i,
  input  logic                                        instr_rvalid_i,
  output logic                                        instr_rready_o,
  output logic                                        instr_we_o,
  output logic                   [len5_pkg::XLEN-1:0] instr_addr_o,
  input  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] [len5_pkg::ILEN-1:0] instr_rdata_i,
  // manca instr_be_o perchè è sempre LWORD
  input  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_except_raised_i,
  input  len5_pkg::except_code_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] instr_except_code_i,

  // ----------------------
  // Data memory interface
  // ----------------------
  // Load interface
  output logic                                                data_load_req_o,
  input  logic                                                data_load_gnt_i,
  input  logic                                                data_load_rvalid_i,
  output logic                                                data_load_rready_o,
  output logic                                                data_load_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] data_load_addr_o,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] data_load_tag_o,
  output logic                   [                       7:0] data_load_be_o,
  input  logic                   [        len5_pkg::XLEN-1:0] data_load_rdata_i,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] data_load_tag_i,
  input  logic                                                data_load_except_raised_i,
  input  len5_pkg::except_code_t                              data_load_except_code_i,
  // Store interface
  output logic                                                data_store_req_o,
  input  logic                                                data_store_gnt_i,
  input  logic                                                data_store_rvalid_i,
  output logic                                                data_store_rready_o,
  output logic                                                data_store_we_o,
  output logic                   [        len5_pkg::XLEN-1:0] data_store_addr_o,
  output logic                   [len5_pkg::BUFF_IDX_LEN-1:0] data_store_tag_o,
  output logic                   [                       7:0] data_store_be_o,
  output logic                   [        len5_pkg::XLEN-1:0] data_store_wdata_o,
  input  logic                   [len5_pkg::BUFF_IDX_LEN-1:0] data_store_tag_i,
  input  logic                                                data_store_except_raised_i,
  input  len5_pkg::except_code_t                              data_store_except_code_i,

  // Native SRAM connection; inactive in the legacy configuration.
  input logic sram_initialized_i,
  output logic [2:0] sram_req_o, sram_we_o,
  output logic [2:0][memory_backend_pkg::SRAM_ADDR_WIDTH-1:0] sram_addr_o,
  output logic [2:0][63:0] sram_wdata_o,
  output logic [2:0][7:0] sram_be_o,
  input logic [2:0][63:0] sram_rdata_i,
  output memory_backend_pkg::memory_response_t memory_response_o /* verilator split_var */,
  output logic mmio_write_o,
  output logic [2:0][1:0] memory_outstanding_o, memory_occupancy_o,

  // Interrupt inputs ---> TODO: implement
  input  logic [31:0] irq_i,      // CLINT interrupts + CLINT extension interrupts
  output logic        irq_ack_o,  //
  output logic [ 4:0] irq_id_o,

  // CPU Control Signals ---> TODO: implement
  input  logic fetch_enable_i,
  output logic core_sleep_o
);

  import len5_pkg::*;
  import memory_pkg::*;
  import fetch_pkg::*;
  import csr_pkg::csr_priv_t;

  // ----------------
  // INTERNAL SIGNALS
  // ----------------

  // Frontend <--> backend
  // ---------------------
  logic                    fe_be_valid;
  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fe_be_valid_instr;
  logic                    be_fe_ready;
  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] [ILEN-1:0] fe_be_instr;
  prediction_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fe_be_pred;
  logic [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fe_be_except_raised;
  except_code_t [len5_config_pkg::LEN5_MULTIPLE_ISSUES-1:0] fe_be_except_code;
  logic                    be_fe_mis_flush;
  logic                    be_fe_except_flush;
  logic                    be_fe_bpu_valid;
  logic                    be_fe_pcgen_valid;
  resolution_t             be_fe_res;
  logic                    be_fe_call_confirm;
  logic                    be_fe_ret_confirm;
  logic [ALEN-1:0]         be_fe_link_addr;
  logic                    be_fe_except_raised;
  logic         [XLEN-1:0] be_fe_except_pc;
  logic                    fe_be_bu_pcgen_ready;
  logic                    early_jump_mem_flush;

  // ---------
  // FRONT-END
  // ---------
  fetch_stage #(
    .HLEN            (HLEN),
    .BTB_BITS        (BTB_BITS),
    .BOOT_PC         (BOOT_PC),
    .MEMIF_FIFO_DEPTH(FETCH_MEMIF_FIFO_DEPTH)
  ) u_fetch_stage (
    .clk_i                 (clk_i),
    .rst_ni                (rst_ni),
    .flush_i               (be_fe_mis_flush | be_fe_except_flush),
    .flush_bpu_i           (be_fe_except_flush),
    .instr_valid_i         (memory_response_o.instr_valid),
    .instr_ready_i         (memory_response_o.instr_gnt),
    .instr_ready_o         (instr_rready_o),
    .instr_valid_o         (instr_req_o),
    .instr_we_o            (instr_we_o),
    .instr_rdata_i         (memory_response_o.instr_data),
    .instr_addr_o          (instr_addr_o),
    .early_jump_mem_flush_o(early_jump_mem_flush),
    .instr_except_raised_i (memory_response_o.instr_except),
    .instr_except_code_i   (memory_response_o.instr_code),
    .issue_ready_i         (be_fe_ready),
    .issue_valid_o         (fe_be_valid),
    .issue_valid_instr_o   (fe_be_valid_instr),
    .issue_instr_o         (fe_be_instr),
    .issue_pred_o          (fe_be_pred),
    .issue_except_raised_o (fe_be_except_raised),
    .issue_except_code_o   (fe_be_except_code),
    .bu_pcgen_ready_o      (fe_be_bu_pcgen_ready),
    .bu_bpu_valid_i        (be_fe_bpu_valid),
    .bu_pcgen_valid_i      (be_fe_pcgen_valid),
    .bu_res_i              (be_fe_res),
    .bu_call_confirm_i     (be_fe_call_confirm),
    .bu_ret_confirm_i      (be_fe_ret_confirm),
    .bu_link_addr_i        (be_fe_link_addr),
    .comm_except_raised_i  (be_fe_except_raised),
    .comm_except_pc_i      (be_fe_except_pc)
  );

  // --------
  // BACK-END
  // --------
  backend u_backend (
    .clk_i (clk_i),
    .rst_ni(rst_ni),

    .fetch_valid_i        (fe_be_valid),
    .fetch_ready_o        (be_fe_ready),
    .fetch_valid_instr_i  (fe_be_valid_instr),
    .fetch_instr_i        (fe_be_instr),
    .fetch_pred_i         (fe_be_pred),
    .fetch_except_raised_i(fe_be_except_raised),
    .fetch_except_code_i  (fe_be_except_code),
    .fetch_pcgen_ready_i  (fe_be_bu_pcgen_ready),
    .fetch_bpu_valid_o    (be_fe_bpu_valid),
    .fetch_pcgen_valid_o  (be_fe_pcgen_valid),
    .fetch_mis_flush_o    (be_fe_mis_flush),
    .fetch_except_flush_o (be_fe_except_flush),
    .fetch_res_o          (be_fe_res),
    .fetch_call_confirm_o (be_fe_call_confirm),
    .fetch_ret_confirm_o  (be_fe_ret_confirm),
    .fetch_link_addr_o    (be_fe_link_addr),
    .fetch_except_raised_o(be_fe_except_raised),
    .fetch_except_pc_o    (be_fe_except_pc),

    .mem_load_valid_o        (data_load_req_o),
    .mem_load_ready_i        (memory_response_o.load_gnt),
    .mem_load_valid_i        (memory_response_o.load_valid),
    .mem_load_ready_o        (data_load_rready_o),
    .mem_load_we_o           (data_load_we_o),
    .mem_load_addr_o         (data_load_addr_o),
    .mem_load_be_o           (data_load_be_o),
    .mem_load_tag_o          (data_load_tag_o),
    .mem_load_rdata_i        (memory_response_o.load_data),
    .mem_load_tag_i          (memory_response_o.load_tag),
    .mem_load_except_raised_i(memory_response_o.load_except),
    .mem_load_except_code_i  (memory_response_o.load_code),

    .mem_store_valid_o        (data_store_req_o),
    .mem_store_ready_i        (memory_response_o.store_gnt),
    .mem_store_valid_i        (memory_response_o.store_valid),
    .mem_store_ready_o        (data_store_rready_o),
    .mem_store_we_o           (data_store_we_o),
    .mem_store_addr_o         (data_store_addr_o),
    .mem_store_be_o           (data_store_be_o),
    .mem_store_wdata_o        (data_store_wdata_o),
    .mem_store_tag_o          (data_store_tag_o),
    .mem_store_tag_i          (memory_response_o.store_tag),
    .mem_store_except_raised_i(memory_response_o.store_except),
    .mem_store_except_code_i  (memory_response_o.store_code)
  );

  // -------------
  // MEMORY-SYSTEM
  // -------------
  // NOTE: in the bare-metal version, the load-store unit and the fetch stage are
  // directly connected to the memory.
  if (len5_config_pkg::MEMORY_BACKEND == len5_config_pkg::MEM_BACKEND_LEGACY) begin : gen_legacy
    wire unused_native = &{1'b0, sram_initialized_i, sram_rdata_i};
    assign memory_response_o.instr_gnt = instr_gnt_i;
    assign memory_response_o.instr_valid = instr_rvalid_i;
    assign memory_response_o.instr_data = instr_rdata_i;
    assign memory_response_o.instr_except = instr_except_raised_i;
    assign memory_response_o.instr_code = instr_except_code_i;
    assign memory_response_o.load_gnt = data_load_gnt_i;
    assign memory_response_o.load_valid = data_load_rvalid_i;
    assign memory_response_o.load_data = data_load_rdata_i;
    assign memory_response_o.load_tag = data_load_tag_i;
    assign memory_response_o.load_except = data_load_except_raised_i;
    assign memory_response_o.load_code = data_load_except_code_i;
    assign memory_response_o.store_gnt = data_store_gnt_i;
    assign memory_response_o.store_valid = data_store_rvalid_i;
    assign memory_response_o.store_tag = data_store_tag_i;
    assign memory_response_o.store_except = data_store_except_raised_i;
    assign memory_response_o.store_code = data_store_except_code_i;
    assign sram_req_o = '0;
    assign sram_we_o = '0;
    assign sram_addr_o = '0;
    assign sram_wdata_o = '0;
    assign sram_be_o = '0;
    assign mmio_write_o = 1'b0;
    assign memory_outstanding_o = '0;
    assign memory_occupancy_o = '0;
  end else if (len5_config_pkg::MEMORY_BACKEND == len5_config_pkg::MEM_BACKEND_TC_SRAM) begin : gen_tc_sram
    wire unused_legacy = &{1'b0, instr_gnt_i, instr_rvalid_i, instr_rdata_i, instr_except_raised_i, instr_except_code_i, data_load_gnt_i, data_load_rvalid_i, data_load_rdata_i, data_load_tag_i, data_load_except_raised_i, data_load_except_code_i, data_store_gnt_i, data_store_rvalid_i, data_store_tag_i, data_store_except_raised_i, data_store_except_code_i};
    tc_sram_adapter #(.SERIAL_ADDR(SERIAL_ADDR), .EXIT_ADDR(EXIT_ADDR)) u_adapter (
      .clk_i, .rst_ni, .instr_flush_i(mem_flush_o), .initialized_i(sram_initialized_i),
      .instr_req_i(instr_req_o), .instr_ready_i(instr_rready_o), .instr_addr_i(instr_addr_o),
      .load_req_i(data_load_req_o), .load_ready_i(data_load_rready_o),
      .load_addr_i(data_load_addr_o), .load_be_i(data_load_be_o), .load_tag_i(data_load_tag_o),
      .store_req_i(data_store_req_o), .store_ready_i(data_store_rready_o), .store_we_i(data_store_we_o),
      .store_addr_i(data_store_addr_o), .store_data_i(data_store_wdata_o),
      .store_be_i(data_store_be_o), .store_tag_i(data_store_tag_o),
      .response_o(memory_response_o), .sram_req_o, .sram_we_o, .sram_addr_o, .sram_wdata_o,
      .sram_be_o, .sram_rdata_i, .mmio_write_o,
      .outstanding_o(memory_outstanding_o), .occupancy_o(memory_occupancy_o)
    );
  end else begin : gen_unsupported_backend
    assign memory_response_o = '0;
    assign sram_req_o = '0;
    assign sram_we_o = '0;
    assign sram_addr_o = '0;
    assign sram_wdata_o = '0;
    assign sram_be_o = '0;
    assign mmio_write_o = 1'b0;
    assign memory_outstanding_o = '0;
    assign memory_occupancy_o = '0;
    if (len5_config_pkg::MEMORY_BACKEND == len5_config_pkg::MEM_BACKEND_AXI_SIM) begin : gen_axi_error
      $fatal(1, "MEM_BACKEND_AXI_SIM is reserved and not implemented");
    end else begin : gen_selection_error
      $fatal(1, "Invalid MEMORY_BACKEND selection");
    end
  end

  // -----------------
  // OUTPUT EVALUATION
  // -----------------
  // Memory misprediction flush
  assign mem_flush_o = be_fe_mis_flush | be_fe_except_flush | early_jump_mem_flush;

endmodule
