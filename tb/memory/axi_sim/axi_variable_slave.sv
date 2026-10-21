// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Verification-only AXI slave: independent channel stalls and cross-ID reordering.
// Requests are sampled on rising edges; responses are driven between edges.
// Inject DECERR here; native-model tests separately exercise SLVERR.
module axi_variable_slave #(
  parameter logic [63:0] I_BASE = tb_config_pkg::IMEM_BASE_ADDR,
  parameter logic [63:0] D_BASE = tb_config_pkg::DMEM_BASE_ADDR,
  parameter int unsigned SIZE = 256
) (
  input logic clk_i,
  rst_ni,
  input logic [6:0] block_i,  // instruction AR/R, load AR/R, store AW/W/B
  input axi_memory_pkg::imem_axi_req_t imem_req_i,
  output axi_memory_pkg::imem_axi_resp_t imem_rsp_o,
  input axi_memory_pkg::dmem_axi_req_t [1:0] dmem_req_i,
  output axi_memory_pkg::dmem_axi_resp_t [1:0] dmem_rsp_o
);
  /* verilator lint_off BLKSEQ */
  timeunit 1ps; timeprecision 1ps;
  import axi_memory_pkg::*;
  typedef struct packed {
    addr_t addr;
    id_t id;
    axi_pkg::size_t size;
    int due;
  } read_t;
  typedef struct packed {
    dmem_axi_b_chan_t data;
    int due;
  } write_response_t;
  read_t instructions[$], loads[$];
  dmem_axi_aw_chan_t addresses    [   $];
  dmem_axi_w_chan_t  writes       [   $];
  write_response_t   completions  [   $];
  byte unsigned      data_mem     [SIZE];
  int                cycle_no;
  int unsigned       random_state;
  bit instr_held, load_held, store_held;
  imem_axi_r_chan_t instr_result;
  dmem_axi_r_chan_t load_result;
  dmem_axi_b_chan_t store_result;
  function automatic int unsigned random32();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  initial begin
    int seed;
    seed         = 1;
    cycle_no     = 0;
    instr_held   = 0;
    load_held    = 0;
    store_held   = 0;
    random_state = 32'h9e3779b9;
    void'($value$plusargs("seed=%d", seed));
    random_state ^= 32'(seed);
    foreach (data_mem[b]) data_mem[b] = 8'(b ^ 8'ha5);
    imem_rsp_o = '0;
    dmem_rsp_o = '0;
  end
  always @(posedge clk_i) begin : accept_requests
    read_t             request;
    dmem_axi_aw_chan_t aw;
    dmem_axi_w_chan_t  w;
    write_response_t   completion;
    cycle_no++;
    if (!rst_ni) begin
      instructions.delete();
      loads.delete();
      addresses.delete();
      writes.delete();
      completions.delete();
      instr_held = 0;
      load_held  = 0;
      store_held = 0;
    end else begin
      if (imem_rsp_o.r_valid && imem_req_i.r_ready) instr_held = 0;
      if (dmem_rsp_o[0].r_valid && dmem_req_i[0].r_ready) load_held = 0;
      if (dmem_rsp_o[1].b_valid && dmem_req_i[1].b_ready) store_held = 0;
      if (imem_req_i.ar_valid && imem_rsp_o.ar_ready) begin
        assert (imem_req_i.ar.id == 0 && imem_req_i.ar.len == 0);
        request = '{
            addr: imem_req_i.ar.addr,
            id: imem_req_i.ar.id,
            size: imem_req_i.ar.size,
            due: cycle_no + 1 + int'(random32() % 20)
        };
        instructions.push_back(request);
      end
      if (dmem_req_i[0].ar_valid && dmem_rsp_o[0].ar_ready) begin
        assert (dmem_req_i[0].ar.len == 0);
        request = '{
            addr: dmem_req_i[0].ar.addr,
            id: dmem_req_i[0].ar.id,
            size: dmem_req_i[0].ar.size,
            due: cycle_no + 1 + int'(random32() % 20)
        };
        loads.push_back(request);
      end
      if (dmem_req_i[1].aw_valid && dmem_rsp_o[1].aw_ready) addresses.push_back(dmem_req_i[1].aw);
      if (dmem_req_i[1].w_valid && dmem_rsp_o[1].w_ready) writes.push_back(dmem_req_i[1].w);
      if (addresses.size() != 0 && writes.size() != 0) begin
        aw = addresses.pop_front();
        w  = writes.pop_front();
        assert (aw.len == 0 && w.last);
        for (int b = 0; b < 8; b++)
        if (w.strb[b]) data_mem[int'((aw.addr&~64'd7)-D_BASE)+b] = w.data[b*8+:8];
        completion = '{
            data: '{
                id: aw.id,
                resp: (aw.addr == D_BASE + 248 ? axi_pkg::RESP_DECERR : axi_pkg::RESP_OKAY),
                user: '0
            },
            due: cycle_no + 1 + int'(random32() % 20)
        };
        completions.push_back(completion);
      end
    end
  end
  always @(negedge clk_i) begin : drive_responses
    read_t           request;
    write_response_t completion;
    addr_t           word_addr;
    int              index;
    #1;
    imem_rsp_o = '0;
    dmem_rsp_o = '0;
    if (rst_ni) begin
      imem_rsp_o.ar_ready    = !block_i[0] && random32() % 4 != 0;
      dmem_rsp_o[0].ar_ready = !block_i[2] && random32() % 4 != 0;
      dmem_rsp_o[1].aw_ready = !block_i[4] && random32() % 4 != 0;
      dmem_rsp_o[1].w_ready  = !block_i[5] && random32() % 4 != 0;
      if(!instr_held && !block_i[1] && instructions.size()!=0 && instructions[0].due<=cycle_no) begin
        request           = instructions.pop_front();
        instr_result      = '0;
        instr_result.id   = request.id;
        instr_result.last = 1;
        for (int b = 0; b < InstrDataWidth / 8; b++) begin
          index                     = int'(request.addr - I_BASE) + b;
          instr_result.data[b*8+:8] = 8'((index * 37) ^ ((index / 4) * 13) ^ 8'h5a);
        end
        instr_result.resp = request.addr == I_BASE + 64 ? axi_pkg::RESP_DECERR : axi_pkg::RESP_OKAY;
        instr_held = 1;
      end
      if (!load_held && !block_i[3]) begin
        // Different IDs may pass one another; a tag has at most one owned read.
        index = -1;
        for (int i = 0; i < loads.size(); i++) if (loads[i].due <= cycle_no) index = i;
        if (index >= 0) begin
          request = loads[index];
          loads.delete(index);
          load_result      = '0;
          load_result.id   = request.id;
          load_result.last = 1;
          word_addr        = request.addr & ~64'd7;
          for (int b = 0; b < 8; b++) load_result.data[b*8+:8] = data_mem[int'(word_addr-D_BASE)+b];
          load_result.resp=request.addr==D_BASE+112 ? axi_pkg::RESP_DECERR : axi_pkg::RESP_OKAY;
          load_held = 1;
        end
      end
      if (!store_held && !block_i[6]) begin
        index = -1;
        for (int i = 0; i < completions.size(); i++) if (completions[i].due <= cycle_no) index = i;
        if (index >= 0) begin
          completion = completions[index];
          completions.delete(index);
          store_result = completion.data;
          store_held   = 1;
        end
      end
      imem_rsp_o.r          = instr_result;
      imem_rsp_o.r_valid    = instr_held;
      dmem_rsp_o[0].r       = load_result;
      dmem_rsp_o[0].r_valid = load_held;
      dmem_rsp_o[1].b       = store_result;
      dmem_rsp_o[1].b_valid = store_held;
    end
  end
endmodule
