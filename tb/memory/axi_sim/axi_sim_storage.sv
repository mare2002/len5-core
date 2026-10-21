// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Native AXI model and firmware deposits. No protocol conversion or array clearing.
module axi_sim_storage #(
  parameter logic [63:0] BASE_ADDR = tb_config_pkg::IMEM_BASE_ADDR,
  parameter int unsigned SIZE_BYTES = tb_config_pkg::IMEM_SIZE_BYTES,
  parameter logic [63:0] OTHER_BASE_ADDR = tb_config_pkg::DMEM_BASE_ADDR,
  parameter int unsigned OTHER_SIZE_BYTES = tb_config_pkg::DMEM_SIZE_BYTES,
  parameter int unsigned DATA_WIDTH = 64,
  parameter int unsigned NUM_PORTS = 1,
  parameter type AXI_REQ_T = axi_memory_pkg::dmem_axi_req_t,
  parameter type AXI_RESP_T = axi_memory_pkg::dmem_axi_resp_t,
  parameter bit LOAD_FIRMWARE = 1
) (
  input logic clk_i,
  input logic rst_ni,  // one-time AXI power-on reset; CPU reset is handled by the adapter
  input AXI_REQ_T [NUM_PORTS-1:0] req_i,
  output AXI_RESP_T [NUM_PORTS-1:0] rsp_o,
  output bit initialized_o
);
  timeunit 1ps; timeprecision 1ps;
  localparam string FirmwareBackend = "AXI_SIM";
  localparam string FirmwareStorage = "AXI memory";
  AXI_REQ_T [NUM_PORTS-1:0] model_req_q;

  // The model applies responses before the CPU edge and acquires actual CPU-edge
  // handshakes afterward. Sampling avoids predicting READY across asynchronous reset.
  always_ff @(posedge clk_i or negedge rst_ni) begin : sample_handshakes
    if (!rst_ni) model_req_q <= '0;
    else begin
      model_req_q <= req_i;
      for (int port_id = 0; port_id < NUM_PORTS; port_id++) begin
        model_req_q[port_id].ar_valid <= req_i[port_id].ar_valid && rsp_o[port_id].ar_ready;
        model_req_q[port_id].aw_valid <= req_i[port_id].aw_valid && rsp_o[port_id].aw_ready;
        model_req_q[port_id].w_valid  <= req_i[port_id].w_valid && rsp_o[port_id].w_ready;
        model_req_q[port_id].r_ready  <= req_i[port_id].r_ready && rsp_o[port_id].r_valid;
        model_req_q[port_id].b_ready  <= req_i[port_id].b_ready && rsp_o[port_id].b_valid;
      end
    end
  end
  axi_sim_mem #(
    .AddrWidth(64),
    .DataWidth(DATA_WIDTH),
    .IdWidth  (len5_pkg::BUFF_IDX_LEN),
    .UserWidth(1),
    .NumPorts (NUM_PORTS),
    .axi_req_t(AXI_REQ_T),
    .axi_rsp_t(AXI_RESP_T),
    .ApplDelay(1),
    .AcqDelay (time'(tb_config_pkg::AXI_CLOCK_HALF_PERIOD_PS) + 2)
  ) u_mem (
    .clk_i             (!clk_i),
    .rst_ni,
    .axi_req_i         (model_req_q),
    .axi_rsp_o         (rsp_o),
    .mon_w_valid_o     (),
    .mon_w_addr_o      (),
    .mon_w_data_o      (),
    .mon_w_id_o        (),
    .mon_w_user_o      (),
    .mon_w_beat_count_o(),
    .mon_w_last_o      (),
    .mon_r_valid_o     (),
    .mon_r_addr_o      (),
    .mon_r_data_o      (),
    .mon_r_id_o        (),
    .mon_r_user_o      (),
    .mon_r_beat_count_o(),
    .mon_r_last_o      ()
  );

  function automatic void put_byte(logic [63:0] address, logic [7:0] value);
    if (memory_backend_pkg::in_region(address, 1, BASE_ADDR, 64'(SIZE_BYTES))) begin
      /* verilator lint_off BLKSEQ */
      u_mem.mem[address] = value;
      /* verilator lint_on BLKSEQ */
    end else if (!memory_backend_pkg::in_region(
            address, 1, OTHER_BASE_ADDR, 64'(OTHER_SIZE_BYTES)
        )) begin
      $fatal(1, "Firmware byte at 0x%h is outside IMEM/DMEM", address);
    end
  endfunction
  `include "firmware_loader.svh"
  initial begin
    if (tb_config_pkg::AXI_CLOCK_HALF_PERIOD_PS < 3)
      $fatal(1, "AXI_CLOCK_HALF_PERIOD_PS must exceed the model phase margins");
    initialized_o = 0;
    if (LOAD_FIRMWARE) load_firmware();
    initialized_o = 1;
  end
endmodule
