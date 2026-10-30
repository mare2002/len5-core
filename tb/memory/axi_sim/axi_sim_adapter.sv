`include "tb_typedef.svh"
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// LEN5 requests are single-beat AXI transactions. CPU acceptance reserves ownership
// before AXI acceptance; a stalled AXI VALID is never withdrawn on a CPU flush.
module axi_sim_adapter #(
    parameter len5_config_pkg::len5_cfg Len5Cfg = len5_config_pkg::DEFAULT_LEN5_CFG,
    localparam type dmem_axi_aw_chan_t = `LEN5_DMEM_AXI_AW_CHAN_T(Len5Cfg),
    localparam type dmem_axi_w_chan_t = `LEN5_DMEM_AXI_W_CHAN_T(Len5Cfg),
    localparam type dmem_axi_ar_chan_t = `LEN5_DMEM_AXI_AR_CHAN_T(Len5Cfg),
    localparam type dmem_axi_b_chan_t = `LEN5_DMEM_AXI_B_CHAN_T(Len5Cfg),
    localparam type dmem_axi_r_chan_t = `LEN5_DMEM_AXI_R_CHAN_T(Len5Cfg),
    localparam type imem_axi_aw_chan_t = `LEN5_IMEM_AXI_AW_CHAN_T(Len5Cfg),
    localparam type imem_axi_w_chan_t = `LEN5_IMEM_AXI_W_CHAN_T(Len5Cfg),
    localparam type imem_axi_ar_chan_t = `LEN5_IMEM_AXI_AR_CHAN_T(Len5Cfg),
    localparam type imem_axi_b_chan_t = `LEN5_IMEM_AXI_B_CHAN_T(Len5Cfg),
    localparam type imem_axi_r_chan_t = `LEN5_IMEM_AXI_R_CHAN_T(Len5Cfg),
    localparam type dmem_axi_req_t =
    `AXI_DECL_REQ_T(dmem_axi_aw_chan_t, dmem_axi_w_chan_t, dmem_axi_ar_chan_t),
    localparam type dmem_axi_resp_t = `AXI_DECL_RESP_T(dmem_axi_b_chan_t, dmem_axi_r_chan_t),
    localparam type id_t = `LEN5_AXI_ID_T(Len5Cfg),
    localparam type imem_axi_req_t =
    `AXI_DECL_REQ_T(imem_axi_aw_chan_t, imem_axi_w_chan_t, imem_axi_ar_chan_t),
    localparam type imem_axi_resp_t = `AXI_DECL_RESP_T(imem_axi_b_chan_t, imem_axi_r_chan_t),
    localparam type memory_response_t = `LEN5_MEMORY_RESPONSE_T(Len5Cfg),
    parameter tb_config_pkg::tb_cfg_t TbCfg = tb_config_pkg::build_config(
        tb_config_pkg::DefaultTbUserCfg, Len5Cfg.IMEM_DATA_WIDTH
    ),
    parameter int unsigned N = Len5Cfg.LEN5_MULTIPLE_ISSUES,
    parameter logic [63:0] IMEM_BASE_ADDR = TbCfg.IMEM_BASE_ADDR,
    parameter int unsigned IMEM_SIZE_BYTES = TbCfg.IMEM_SIZE_BYTES,
    parameter logic [63:0] DMEM_BASE_ADDR = TbCfg.DMEM_BASE_ADDR,
    parameter int unsigned DMEM_SIZE_BYTES = TbCfg.DMEM_SIZE_BYTES,
    parameter logic [63:0] SERIAL_ADDR = TbCfg.SERIAL_ADDR,
    parameter logic [63:0] EXIT_ADDR = TbCfg.EXIT_ADDR,
    parameter int unsigned MAX_INSTR_OUTSTANDING = Len5Cfg.FETCH_MEMIF_FIFO_DEPTH,
    parameter int unsigned COUNT_WIDTH = Len5Cfg.AXI_COUNT_WIDTH
) (
    input logic clk_i,
    input logic rst_ni,
    input logic data_flush_i,
    input logic initialized_i,
    input logic instr_req_i,
    input logic instr_ready_i,
    input logic [63:0] instr_addr_i,
    input logic load_req_i,
    input logic load_ready_i,
    input logic [63:0] load_addr_i,
    input logic [7:0] load_be_i,
    input logic [Len5Cfg.BUFF_IDX_LEN-1:0] load_tag_i,
    input logic store_req_i,
    input logic store_ready_i,
    input logic store_we_i,
    input logic [63:0] store_addr_i,
    input logic [63:0] store_data_i,
    input logic [7:0] store_be_i,
    input logic [Len5Cfg.BUFF_IDX_LEN-1:0] store_tag_i,
    output memory_response_t response_o  /* verilator split_var */,
    output imem_axi_req_t imem_req_o  /* verilator split_var */,
    input imem_axi_resp_t imem_rsp_i,
    output dmem_axi_req_t [1:0] dmem_req_o  /* verilator split_var */,
    input dmem_axi_resp_t [1:0] dmem_rsp_i,
    output logic mmio_write_o,
    output logic [2:0][COUNT_WIDTH-1:0] outstanding_o,
    output logic [2:0][COUNT_WIDTH-1:0] occupancy_o
);
  import len5_pkg::*;
  import memory_backend_pkg::*;
  import axi_memory_pkg::*;
  localparam int unsigned InstrBytes = Len5Cfg.IMEM_DATA_WIDTH / 8;
  localparam int unsigned MetadataAddrWidth = MAX_INSTR_OUTSTANDING > 1 ? $clog2(
      MAX_INSTR_OUTSTANDING
  ) : 1;

  typedef struct packed {
    logic use_axi;
    logic upper_half;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } fetch_metadata_t;
  typedef struct packed {
    logic [N-1:0][31:0] data;
    logic [N-1:0] except;
    except_code_t [N-1:0] code;
  } fetch_response_t;
  typedef struct packed {
    logic [2:0] byte_offset;
    logic [7:0] byte_mask;
  } load_metadata_t;
  typedef struct packed {
    logic [63:0] data;
    id_t tag;
    logic except;
    except_code_t code;
  } data_response_t;

  logic cpu_active, cpu_reset, instr_active, store_cancel;
  logic [63:0] fetch_bundle_addr;
  logic        fetch_misaligned;
  logic [N-1:0] fetch_sram, fetch_mmio, fetch_except;
  except_code_t [N-1:0] fetch_code;
  fetch_metadata_t fetch_metadata, fetch_head;
  fetch_response_t fetch_result;
  logic metadata_full, metadata_empty, metadata_pop;
  logic [MetadataAddrWidth-1:0] metadata_usage;
  logic instr_accepted, instr_ar_fire;
  logic              instr_ar_valid_q;
  imem_axi_ar_chan_t instr_ar_q;

  logic load_sram, load_mmio, load_except;
  except_code_t load_code;
  logic load_accepted, load_ar_valid_q, load_ar_fire, load_r_fire;
  dmem_axi_ar_chan_t load_ar_q;
  load_metadata_t load_metadata_q[Len5Cfg.TAG_COUNT];
  logic [Len5Cfg.TAG_COUNT-1:0] load_busy_q, load_discard_q;
  logic load_response_valid_q, load_response_space, load_response_fire;
  data_response_t load_response_q, load_result;

  logic store_sram, store_mmio, store_except;
  except_code_t store_code;
  logic store_accepted, store_aw_valid_q, store_w_valid_q;
  logic store_aw_fire, store_w_fire, store_b_fire, store_slot_free;
  dmem_axi_aw_chan_t store_aw_q;
  dmem_axi_w_chan_t  store_w_q;
  logic [Len5Cfg.TAG_COUNT-1:0] store_busy_q, store_discard_q;
  logic store_response_valid_q, store_response_space, store_response_fire;
  data_response_t store_response_q;

  function automatic axi_pkg::size_t axi_size(logic [7:0] mask);
    case (mask)
      8'h01:   return 3'd0;
      8'h03:   return 3'd1;
      8'h0f:   return 3'd2;
      default: return 3'd3;
    endcase
  endfunction

  assign cpu_reset         = !rst_ni;
  assign cpu_active        = rst_ni && initialized_i;
  assign instr_active      = rst_ni && initialized_i;
  assign store_cancel      = data_flush_i || cpu_reset;
  assign fetch_bundle_addr = N == 1 ? instr_addr_i : instr_addr_i & ~64'(N * 4 - 1);
  assign fetch_misaligned  = instr_addr_i[1:0] != 0;
  for (genvar lane = 0; lane < N; lane++) begin : gen_instruction_checks
    memory_access_check #(
        .TbCfg     (TbCfg),
        .BASE_ADDR (IMEM_BASE_ADDR),
        .SIZE_BYTES(IMEM_SIZE_BYTES),
        .KIND      (0)
    ) u_check (
        .addr_i  (fetch_bundle_addr + 64'(lane * 4)),
        .bytes_i (4),
        .sram_o  (fetch_sram[lane]),
        .mmio_o  (fetch_mmio[lane]),
        .except_o(fetch_except[lane]),
        .code_o  (fetch_code[lane])
    );
  end
  assign fetch_metadata.use_axi    = !fetch_misaligned && fetch_sram[0];
  assign fetch_metadata.upper_half = instr_addr_i[2];
  assign fetch_metadata.except     = fetch_misaligned ? '1 : fetch_except;
  assign fetch_metadata.code       = fetch_misaligned ? {N{E_I_ADDR_MISALIGNED}} : fetch_code;

  // This queue holds request metadata only. Instruction data stays on AXI until
  // its frontend accepts or drains it. Every accepted request returns, including
  // across flush; locally detected faults use the same order. System reset
  // cancels both memory transactions and their metadata.
  fifo_v3 #(
      .dtype(fetch_metadata_t),
      .DEPTH(MAX_INSTR_OUTSTANDING)
  ) u_fetch_metadata (
      .clk_i,
      .rst_ni,
      .flush_i   (1'b0),
      .testmode_i(1'b0),
      .full_o    (metadata_full),
      .empty_o   (metadata_empty),
      .usage_o   (metadata_usage),
      .data_i    (fetch_metadata),
      .push_i    (instr_accepted),
      .data_o    (fetch_head),
      .pop_i     (metadata_pop)
  );
  assign response_o.instr_gnt = instr_active && !metadata_full &&
      (!fetch_metadata.use_axi || !instr_ar_valid_q || imem_rsp_i.ar_ready);
  assign instr_accepted = instr_req_i && response_o.instr_gnt;
  assign instr_ar_fire = instr_ar_valid_q && imem_rsp_i.ar_ready;

  assign imem_req_o.aw = '0;
  assign imem_req_o.aw_valid = 1'b0;
  assign imem_req_o.w = '0;
  assign imem_req_o.w_valid = 1'b0;
  assign imem_req_o.b_ready = 1'b0;
  assign imem_req_o.ar = instr_ar_q;
  assign imem_req_o.ar_valid = instr_ar_valid_q;
  assign imem_req_o.r_ready = !metadata_empty && fetch_head.use_axi &&
                            (!imem_rsp_i.r.last || instr_ready_i);
  assign response_o.instr_valid = instr_active && !metadata_empty &&
      (!fetch_head.use_axi || (imem_rsp_i.r_valid && imem_rsp_i.r.last));
  assign metadata_pop = response_o.instr_valid && instr_ready_i;
  assign {response_o.instr_data, response_o.instr_except, response_o.instr_code} = fetch_result;

  always_comb begin : select_instruction_response
    fetch_result.data   = '0;
    fetch_result.except = fetch_head.except;
    fetch_result.code   = fetch_head.code;
    for (int lane = 0; lane < N; lane++) begin
      if (fetch_head.use_axi && imem_rsp_i.r.resp[1]) begin
        fetch_result.except[lane] = 1'b1;
        fetch_result.code[lane]   = E_I_ACCESS_FAULT;
      end else if (fetch_head.use_axi && !fetch_head.except[lane]) begin
        fetch_result.data[lane] = 32'(imem_rsp_i.r.data >>
            (32 * (lane + (N == 1 ? int'(fetch_head.upper_half) : 0))));
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : update_instruction_port
    if (!rst_ni) begin
      instr_ar_valid_q <= 1'b0;
      instr_ar_q       <= '0;
    end else begin
      if (instr_ar_fire) instr_ar_valid_q <= 1'b0;
      if (instr_accepted && fetch_metadata.use_axi) begin
        instr_ar_valid_q <= 1'b1;
        instr_ar_q       <= '0;
        instr_ar_q.addr  <= fetch_bundle_addr & ~64'(InstrBytes - 1);
        instr_ar_q.size  <= axi_pkg::size_t'($clog2(InstrBytes));
        instr_ar_q.burst <= axi_pkg::BURST_INCR;
        // ID zero orders every instruction response, including canceled reads.
        instr_ar_q.id    <= '0;
      end
    end
  end

  memory_access_check #(

      .TbCfg      (TbCfg),
      .BASE_ADDR  (DMEM_BASE_ADDR),
      .SIZE_BYTES (DMEM_SIZE_BYTES),
      .SERIAL_ADDR(SERIAL_ADDR),
      .EXIT_ADDR  (EXIT_ADDR),
      .KIND       (1)
  ) u_load_check (
      .addr_i  (load_addr_i),
      .bytes_i (access_bytes(load_be_i)),
      .sram_o  (load_sram),
      .mmio_o  (load_mmio),
      .except_o(load_except),
      .code_o  (load_code)
  );
  memory_access_check #(
      .TbCfg      (TbCfg),
      .BASE_ADDR  (DMEM_BASE_ADDR),
      .SIZE_BYTES (DMEM_SIZE_BYTES),
      .SERIAL_ADDR(SERIAL_ADDR),
      .EXIT_ADDR  (EXIT_ADDR),
      .KIND       (2)
  ) u_store_check (
      .addr_i  (store_addr_i),
      .bytes_i (access_bytes(store_be_i)),
      .sram_o  (store_sram),
      .mmio_o  (store_mmio),
      .except_o(store_except),
      .code_o  (store_code)
  );

  // Loads accepted by LEN5 remain owned through flush, including an unaccepted AR.
  // System reset clears their ownership together with the memory system.
  assign load_response_space = !load_response_valid_q || load_ready_i;
  assign response_o.load_gnt = cpu_active && !load_busy_q[load_tag_i] && !(|store_discard_q) &&
      (load_sram ? (!load_ar_valid_q || dmem_rsp_i[0].ar_ready) :
                   (load_response_space && !dmem_rsp_i[0].r_valid));
  assign load_accepted = load_req_i && response_o.load_gnt;
  assign load_ar_fire = load_ar_valid_q && dmem_rsp_i[0].ar_ready;
  assign load_r_fire = dmem_rsp_i[0].r_valid && dmem_req_o[0].r_ready;
  assign response_o.load_valid = cpu_active && load_response_valid_q;
  assign load_response_fire = response_o.load_valid && load_ready_i;
  assign {response_o.load_data, response_o.load_tag, response_o.load_except, response_o.load_code} = load_response_q;

  assign dmem_req_o[0].aw = '0;
  assign dmem_req_o[0].aw_valid = 1'b0;
  assign dmem_req_o[0].w = '0;
  assign dmem_req_o[0].w_valid = 1'b0;
  assign dmem_req_o[0].b_ready = 1'b0;
  assign dmem_req_o[0].ar = load_ar_q;
  assign dmem_req_o[0].ar_valid = load_ar_valid_q;
  assign dmem_req_o[0].r_ready = cpu_reset || load_discard_q[dmem_rsp_i[0].r.id] || load_response_space;
  always_comb begin : select_load_response
    load_result = '{
        data: '0,
        tag: dmem_rsp_i[0].r.id,
        except: dmem_rsp_i[0].r.resp[1],
        code: dmem_rsp_i[0].r.resp[1] ? E_LD_ACCESS_FAULT : E_UNKNOWN
    };
    for (int b = 0; b < 8; b++) begin
      if (!load_result.except && load_metadata_q[load_result.tag].byte_mask[b])
        load_result.data[b*8+:8] = 8'(dmem_rsp_i[0].r.data >>
            (8 * (int'(load_metadata_q[load_result.tag].byte_offset) + b)));
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_load_port
    if (!rst_ni) begin
      load_ar_valid_q       <= 1'b0;
      load_ar_q             <= '0;
      load_busy_q           <= '0;
      load_discard_q        <= '0;
      load_response_valid_q <= 1'b0;
      load_response_q       <= '0;
    end else begin
      if (cpu_reset) begin
        load_discard_q        <= load_busy_q;
        load_response_valid_q <= 1'b0;
      end
      if (load_response_valid_q && (load_response_fire || cpu_reset)) begin
        load_response_valid_q               <= 1'b0;
        load_busy_q[load_response_q.tag]    <= 1'b0;
        load_discard_q[load_response_q.tag] <= 1'b0;
      end
      if (load_ar_fire) load_ar_valid_q <= 1'b0;
      if (load_r_fire && dmem_rsp_i[0].r.last) begin
        if (cpu_reset || load_discard_q[dmem_rsp_i[0].r.id]) begin
          load_busy_q[dmem_rsp_i[0].r.id]    <= 1'b0;
          load_discard_q[dmem_rsp_i[0].r.id] <= 1'b0;
        end else begin
          load_response_q       <= load_result;
          load_response_valid_q <= 1'b1;
        end
      end
      if (load_accepted) begin
        load_busy_q[load_tag_i]     <= 1'b1;
        load_discard_q[load_tag_i]  <= 1'b0;
        load_metadata_q[load_tag_i] <= '{byte_offset: load_addr_i[2:0], byte_mask: load_be_i};
        if (load_sram) begin
          load_ar_valid_q <= 1'b1;
          load_ar_q       <= '0;
          load_ar_q.id    <= load_tag_i;
          load_ar_q.addr  <= load_addr_i;
          load_ar_q.size  <= axi_size(load_be_i);
          load_ar_q.burst <= axi_pkg::BURST_INCR;
        end else begin
          load_response_q <= '{data: '0, tag: load_tag_i, except: load_except, code: load_code};
          load_response_valid_q <= 1'b1;
        end
      end
    end
  end

  // AW and W each hold their own VALID until accepted. Their order is the CPU
  // store order; completion may return independently on B for any outstanding ID.
  assign store_response_space = !store_response_valid_q || store_ready_i;
  assign store_slot_free = (!store_aw_valid_q || dmem_rsp_i[1].aw_ready) &&
                           (!store_w_valid_q || dmem_rsp_i[1].w_ready);
  assign response_o.store_gnt = cpu_active && !store_busy_q[store_tag_i] &&
      ((store_sram && store_we_i) ? store_slot_free :
       (!(|store_busy_q) && store_response_space && !dmem_rsp_i[1].b_valid));
  assign store_accepted = store_req_i && response_o.store_gnt;
  assign store_aw_fire = store_aw_valid_q && dmem_rsp_i[1].aw_ready;
  assign store_w_fire = store_w_valid_q && dmem_rsp_i[1].w_ready;
  assign store_b_fire = dmem_rsp_i[1].b_valid && dmem_req_o[1].b_ready;
  assign mmio_write_o = store_accepted && store_we_i && store_mmio;
  assign response_o.store_valid = cpu_active && !data_flush_i && store_response_valid_q;
  assign store_response_fire = response_o.store_valid && store_ready_i;
  assign {response_o.store_tag, response_o.store_except, response_o.store_code} = {
    store_response_q.tag, store_response_q.except, store_response_q.code
  };
  assign dmem_req_o[1].ar = '0;
  assign dmem_req_o[1].ar_valid = 1'b0;
  assign dmem_req_o[1].r_ready = 1'b0;
  assign dmem_req_o[1].aw = store_aw_q;
  assign dmem_req_o[1].aw_valid = store_aw_valid_q;
  assign dmem_req_o[1].w = store_w_q;
  assign dmem_req_o[1].w_valid = store_w_valid_q;
  assign dmem_req_o[1].b_ready = store_cancel || store_discard_q[dmem_rsp_i[1].b.id] || store_response_space;
  always_ff @(posedge clk_i or negedge rst_ni) begin : update_store_port
    if (!rst_ni) begin
      store_aw_valid_q       <= 1'b0;
      store_w_valid_q        <= 1'b0;
      store_aw_q             <= '0;
      store_w_q              <= '0;
      store_busy_q           <= '0;
      store_discard_q        <= '0;
      store_response_valid_q <= 1'b0;
      store_response_q       <= '0;
    end else begin
      if (store_cancel) begin
        store_discard_q        <= store_busy_q;
        store_response_valid_q <= 1'b0;
      end
      if (store_response_valid_q && (store_response_fire || store_cancel)) begin
        store_response_valid_q                <= 1'b0;
        store_busy_q[store_response_q.tag]    <= 1'b0;
        store_discard_q[store_response_q.tag] <= 1'b0;
      end
      if (store_aw_fire) store_aw_valid_q <= 1'b0;
      if (store_w_fire) store_w_valid_q <= 1'b0;
      if (store_b_fire) begin
        if (store_cancel || store_discard_q[dmem_rsp_i[1].b.id]) begin
          store_busy_q[dmem_rsp_i[1].b.id]    <= 1'b0;
          store_discard_q[dmem_rsp_i[1].b.id] <= 1'b0;
        end else begin
          store_response_valid_q <= 1'b1;
          store_response_q <= '{
              data: '0,
              tag: dmem_rsp_i[1].b.id,
              except: dmem_rsp_i[1].b.resp[1],
              code: dmem_rsp_i[1].b.resp[1] ? E_ST_ACCESS_FAULT : E_UNKNOWN
          };
        end
      end
      if (store_accepted) begin
        if (store_sram && store_we_i) begin
          store_busy_q[store_tag_i]    <= 1'b1;
          store_discard_q[store_tag_i] <= store_cancel;
          store_aw_valid_q             <= 1'b1;
          store_w_valid_q              <= 1'b1;
          store_aw_q                   <= '0;
          store_aw_q.id                <= store_tag_i;
          store_aw_q.addr              <= store_addr_i;
          store_aw_q.size              <= axi_size(store_be_i);
          store_aw_q.burst             <= axi_pkg::BURST_INCR;
          store_w_q                    <= '0;
          store_w_q.data               <= store_data_i << (8 * store_addr_i[2:0]);
          store_w_q.strb               <= store_be_i << store_addr_i[2:0];
          store_w_q.last               <= 1'b1;
        end else if (!store_cancel) begin
          store_busy_q[store_tag_i] <= 1'b1;
          store_discard_q[store_tag_i] <= 1'b0;
          store_response_valid_q <= 1'b1;
          store_response_q <= '{
              data: '0,
              tag: store_tag_i,
              except: store_except || !store_we_i,
              code: store_we_i ? store_code : E_ST_ACCESS_FAULT
          };
        end
      end
    end
  end

  assign outstanding_o[0] = metadata_full ? COUNT_WIDTH'(MAX_INSTR_OUTSTANDING) : COUNT_WIDTH'(metadata_usage);
  assign outstanding_o[1] = COUNT_WIDTH'($countones(load_busy_q));
  assign outstanding_o[2] = COUNT_WIDTH'($countones(store_busy_q));
  assign occupancy_o[0] = '0;
  assign occupancy_o[1] = COUNT_WIDTH'(load_response_valid_q);
  assign occupancy_o[2] = COUNT_WIDTH'(store_response_valid_q);
  wire unused_decode = &{1'b0, fetch_mmio, load_mmio,
                         imem_rsp_i, fetch_sram, store_response_q.data};

  initial begin : check_configuration
    if (N != Len5Cfg.LEN5_MULTIPLE_ISSUES || !(N == 1 || N == 2 || N == 4 || N == 8) ||
        MAX_INSTR_OUTSTANDING == 0 || COUNT_WIDTH < $clog2(
            MAX_INSTR_OUTSTANDING + 1
        ) || COUNT_WIDTH < $clog2(
            Len5Cfg.TAG_COUNT + 1
        ))
      $fatal(1, "Invalid AXI adapter dimensions");
    if (IMEM_SIZE_BYTES < InstrBytes || IMEM_SIZE_BYTES % InstrBytes != 0 || IMEM_BASE_ADDR % 64'(InstrBytes) != 0 ||
        IMEM_BASE_ADDR > 64'hffff_ffff_ffff_ffff - 64'(IMEM_SIZE_BYTES - 1) ||
        DMEM_SIZE_BYTES < 8 || DMEM_SIZE_BYTES % 8 != 0 || DMEM_BASE_ADDR[2:0] != 0 ||
        DMEM_BASE_ADDR > 64'hffff_ffff_ffff_ffff - 64'(DMEM_SIZE_BYTES - 1) ||
        regions_overlap(
            IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES), DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)
        ))
      $fatal(1, "Invalid or overlapping AXI memory regions");
    if (SERIAL_ADDR[2:0] != 0 || EXIT_ADDR[2:0] != 0 || SERIAL_ADDR == EXIT_ADDR || regions_overlap(
            SERIAL_ADDR, 8, IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES)
        ) || regions_overlap(
            EXIT_ADDR, 8, IMEM_BASE_ADDR, 64'(IMEM_SIZE_BYTES)
        ) || regions_overlap(
            SERIAL_ADDR, 8, DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)
        ) || regions_overlap(
            EXIT_ADDR, 8, DMEM_BASE_ADDR, 64'(DMEM_SIZE_BYTES)
        ) || (SERIAL_ADDR & Len5Cfg.MMAP_MASK) == 0 || (EXIT_ADDR & Len5Cfg.MMAP_MASK) == 0)
      $fatal(1, "Invalid AXI MMIO addresses");
    if (Len5Cfg.LEN5_C_EN || Len5Cfg.ONLY_DOUBLEWORD_MEM_ACCESSES)
      $fatal(1, "AXI_SIM requires uncompressed instructions and original data offsets");
  end
endmodule
