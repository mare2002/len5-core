// Copyright 2019 Politecnico di Torino.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File: len5_config_pkg.sv
// Author: Michele Caon
// Date: 04/11/2021

package len5_config_pkg;
  // --------------------
  // GLOBAL CONFIGURATION
  // --------------------
  // Boot memory translation mode
  typedef enum logic [1:0] {
    BARE,
    SV39,
    SV48
  } boot_mode_t;
  typedef struct packed {
    boot_mode_t BOOT_VM_MODE;  // BARE|SV39|SV48

    // Boot program counter
    logic [63:0] BOOT_PC;

    // -----------------
    // FEATURES SWITCHES
    // -----------------

    // Multi-issue architecture
    // ------------------------
    int unsigned LEN5_MULTIPLE_ISSUES;  //maximum number of issues per cycle

    // Enable M extension support
    // --------------------------
    bit LEN5_M_EN;    // integer hardware multiplication and division
    bit LEN5_DIV_EN;  // integer division (not compliant if set to 0)

    // Enable floating-point support (F,D extensions)
    // ----------------------------------------------
    bit LEN5_F_EN;  // single-precision instructions
    bit LEN5_D_EN;  // double-precision instructions

    // Enable C extension support
    // --------------------------
    // NOTE: CURRENTLY UNSUPPORTED
    bit LEN5_C_EN;  // compressed instructions

    // Enable A extension support
    // --------------------------
    // NOTE: CURRENTLY UNSUPPORTED
    bit LEN5_A_EN;  // atomic instructions

    // Enable store-to-load forwarding
    // -------------------------------
    // This switch instantiates a small cache with the same size as store buffer
    // inside the Load-Store Unit. This cache records the store buffer entry
    // containing the latest instruction that wrote a certain memory location.
    // When a load instruction accesses the same location, the forwarding of the
    // stored result is attempted.
    // IMPORTANT: this feature breaks reads from memory-mapped devices, therefore
    // it is only applied to memory addresses outside of the region masked by
    // 'MMAP_MASK' (defined above).
    bit LEN5_STORE_LOAD_FWD_EN;

    // Maximum number of execution units :
    // load buffer, store buffer, branch unit, ALU, MULT, DIV, FPU
    int unsigned MAX_EU_N;

    // Memory
    // ------
    // If defined, instantiate a byte selector in the load buffer. All memory
    // accesses are aligned on 64 bits, and the selector picks the correct
    // word/halfword/byte from it the fetched doubleword.
    bit ONLY_DOUBLEWORD_MEM_ACCESSES;

    // CSRs
    // ----
    // If defined, instantiate additional performance counters (mcycle and
    // minstret are always instantiated). See 'csrs.sv' to see what counters are
    // available in LEN5.
    bit LEN5_CSR_HPMCOUNTERS_EN;

    // MEMORY-MAPPED DEVICES
    // ---------------------
    // Address mask for memory-mapped devices
    // This mask defines the address range that is reserved to memory-mapped
    // devices. Store-to-load forwarding (see below) in this region is not
    // performed. This must be consistent with PERI_BASE in `len5.h`.
    logic [63:0] MMAP_MASK;  // above 512MB

    // FRONTEND PARAMETERS
    // -------------------
    // BPU g-share predictor global history length
    int unsigned BPU_HLEN;
    // BPU Branch Target Buffer (BTB) addressing bits (the remaining ones are used
    // as tag)
    int unsigned BPU_BTB_BITS;

    // -------------------
    // PIPELINE PARAMETERS
    // -------------------
    // The following switches enable or disable some of the sequential elements
    // inside some functional units, therefore reducing the latency at the
    // expense of increased delay on the involved lines. The increased delay
    // may impact on the operation frequency if the combinational unit enters
    // the processor critical path. The pipeline of the processor can handle
    // functional units with arbitrary latency, including 0-cycle, so this
    // changes do not require any modification.

    // FETCH STAGE
    // -----------
    // Return Address Stack (RAS) depth
    int unsigned RAS_DEPTH;

    // Fetch memory interface
    int unsigned FETCH_MEMIF_FIFO_DEPTH;  // completion queue entries (positive power of two)
    // Drain ordered fetch responses when memory cannot cancel accepted requests.
    bit FETCH_MEM_DRAIN_ON_FLUSH;
    // Retain accepted load tags across flush when the memory cannot cancel requests.
    bit LOAD_BUFFER_DRAIN_ON_FLUSH;
    // NOTE: if the memory is 0-latency, at least one of the fetch unit registers
    // must be enabled (i.e., not skipped). Therefore, at least one of the
    // following switches must be commented in this case.
    bit FETCH_REQ_SPILL_SKIP; // memory requests from the fetch unit are directly passed to the memory
    bit FETCH_ANS_SPILL_SKIP;  // fetched instructions are directly passed to the issue stage

    // EXECUTION PIPELINE
    // ------------------
    // ISSUE QUEUE
    int unsigned IQ_DEPTH;  // number of entries in the issue queue (power of 2)

    // LOAD/STORE UNIT
    int unsigned LDBUFF_DEPTH;  // number of entries in the load buffer
    int unsigned STBUFF_DEPTH;  // number of entries in the store buffer
    bit LSU_SPILL_SKIP;  // make address adder fully combinational

    // ALU UNIT
    int unsigned ALU_RS_DEPTH;
    bit ALU_SPILL_SKIP;  // make the ALU fully combinational
    bit ALU_RR_ARBITER;  // round-robin arbiter for the reservation station

    // MULT UNIT
    int unsigned MULT_RS_DEPTH;
    bit LEN5_MULT_SERIAL;
    int unsigned MULT_PIPE_DEPTH;  // pipeline stages (only if 'LEN5_MULT_SERIAL' is 0)
    bit MULT_RR_ARBITER;  // round-robin arbiter for the reservation station

    // DIV UNIT
    int unsigned DIV_RS_DEPTH;
    bit DIV_RR_ARBITER;  // round-robin arbiter for the reservation station

    // FPU UNIT
    int unsigned FPU_RS_DEPTH;
    bit FPU_RR_ARBITER;  // round-robin arbiter for the reservation station
    int unsigned FPU_PIPE_DEPTH;  // pipeline stages
    bit FPU_SPILL_SKIP;  // skip input registers

    // BRANCH UNIT
    int unsigned BU_RS_DEPTH;
    bit BU_SPILL_SKIP;  // make the target address adder fully combinational

    // COMMIT STAGE
    int unsigned ROB_DEPTH;  // Number of entries in the ROB
    bit COMMIT_SPILL_SKIP;  // directly connect the commit CU to the ROB output
    logic [1:0] BPU_INIT_C2B;
  } len5_user_cfg_t;

  typedef struct packed {
    boot_mode_t BOOT_VM_MODE;
    logic [63:0] BOOT_PC;
    int unsigned LEN5_MULTIPLE_ISSUES;
    bit LEN5_M_EN;
    bit LEN5_DIV_EN;
    bit LEN5_F_EN;
    bit LEN5_D_EN;
    bit LEN5_C_EN;
    bit LEN5_A_EN;
    bit LEN5_STORE_LOAD_FWD_EN;
    int unsigned MAX_EU_N;
    bit ONLY_DOUBLEWORD_MEM_ACCESSES;
    bit LEN5_CSR_HPMCOUNTERS_EN;
    logic [63:0] MMAP_MASK;
    int unsigned BPU_HLEN;
    int unsigned BPU_BTB_BITS;
    int unsigned RAS_DEPTH;
    int unsigned FETCH_MEMIF_FIFO_DEPTH;
    bit FETCH_MEM_DRAIN_ON_FLUSH;
    bit LOAD_BUFFER_DRAIN_ON_FLUSH;
    bit FETCH_REQ_SPILL_SKIP;
    bit FETCH_ANS_SPILL_SKIP;
    int unsigned IQ_DEPTH;
    int unsigned LDBUFF_DEPTH;
    int unsigned STBUFF_DEPTH;
    bit LSU_SPILL_SKIP;
    int unsigned ALU_RS_DEPTH;
    bit ALU_SPILL_SKIP;
    bit ALU_RR_ARBITER;
    int unsigned MULT_RS_DEPTH;
    bit LEN5_MULT_SERIAL;
    int unsigned MULT_PIPE_DEPTH;
    bit MULT_RR_ARBITER;
    int unsigned DIV_RS_DEPTH;
    bit DIV_RR_ARBITER;
    int unsigned FPU_RS_DEPTH;
    bit FPU_RR_ARBITER;
    int unsigned FPU_PIPE_DEPTH;
    bit FPU_SPILL_SKIP;
    int unsigned BU_RS_DEPTH;
    bit BU_SPILL_SKIP;
    int unsigned ROB_DEPTH;
    bit COMMIT_SPILL_SKIP;
    logic [1:0] BPU_INIT_C2B;

    // Computed once by build_config; consumers reuse these fields.
    int unsigned LEN5_MULTIPLE_ISSUES_BITS;
    int unsigned LWIDTH;
    int unsigned FLEN;
    int unsigned LDBUFF_TAG_W;
    int unsigned STBUFF_TAG_W;
    int unsigned BUFF_IDX_LEN;
    int unsigned ROB_IDX_LEN;
    int unsigned COMMIT_UNIT_DEPTH;
    int unsigned IQ_IDX_LEN;
    int unsigned MULT_EU_N;
    int unsigned DIV_EU_N;
    int unsigned FP_EU_N;
    int unsigned EU_N;
    int unsigned REGSTAT_CNT_W;
    int unsigned IMEM_DATA_WIDTH;
    int unsigned TAG_COUNT;
    int unsigned AXI_COUNT_WIDTH;
  } len5_cfg_t;
  typedef len5_cfg_t len5_cfg;

  localparam len5_user_cfg_t DEFAULT_LEN5_USER_CFG = '{
      BOOT_VM_MODE: BARE,
      BOOT_PC: 64'h180,
      LEN5_MULTIPLE_ISSUES: 32'd8,
      LEN5_M_EN: 1'b1,
      LEN5_DIV_EN: 1'b1,
      LEN5_F_EN: 1'b1,
      LEN5_D_EN: 1'b1,
      LEN5_C_EN: 1'b0,
      LEN5_A_EN: 1'b0,
      LEN5_STORE_LOAD_FWD_EN: 1'b1,
      MAX_EU_N: 32'd7,
      ONLY_DOUBLEWORD_MEM_ACCESSES: 1'b0,
      LEN5_CSR_HPMCOUNTERS_EN: 1'b1,
      MMAP_MASK: 64'hffffffffe0000000,
      BPU_HLEN: 32'd4,
      BPU_BTB_BITS: 32'd4,
      RAS_DEPTH: 32'd4,
      FETCH_MEMIF_FIFO_DEPTH: 32'd8,
      FETCH_MEM_DRAIN_ON_FLUSH: 1'b1,
      LOAD_BUFFER_DRAIN_ON_FLUSH: 1'b1,
      FETCH_REQ_SPILL_SKIP: 1'b1,
      FETCH_ANS_SPILL_SKIP: 1'b0,
      IQ_DEPTH: 32'd16,
      LDBUFF_DEPTH: 32'd8,
      STBUFF_DEPTH: 32'd16,
      LSU_SPILL_SKIP: 1'b1,
      ALU_RS_DEPTH: 32'd8,
      ALU_SPILL_SKIP: 1'b1,
      ALU_RR_ARBITER: 1'b1,
      MULT_RS_DEPTH: 32'd4,
      LEN5_MULT_SERIAL: 1'b0,
      MULT_PIPE_DEPTH: 32'd1,
      MULT_RR_ARBITER: 1'b1,
      DIV_RS_DEPTH: 32'd4,
      DIV_RR_ARBITER: 1'b1,
      FPU_RS_DEPTH: 32'd8,
      FPU_RR_ARBITER: 1'b1,
      FPU_PIPE_DEPTH: 32'd4,
      FPU_SPILL_SKIP: 1'b1,
      BU_RS_DEPTH: 32'd4,
      BU_SPILL_SKIP: 1'b1,
      ROB_DEPTH: 32'd32,
      COMMIT_SPILL_SKIP: 1'b1,
      BPU_INIT_C2B: 2'd2
  };

  function automatic len5_cfg build_config(len5_user_cfg_t user_cfg);
    len5_cfg cfg;
    cfg.BOOT_VM_MODE = user_cfg.BOOT_VM_MODE;
    cfg.BOOT_PC = user_cfg.BOOT_PC;
    cfg.LEN5_MULTIPLE_ISSUES = user_cfg.LEN5_MULTIPLE_ISSUES;
    cfg.LEN5_M_EN = user_cfg.LEN5_M_EN;
    cfg.LEN5_DIV_EN = user_cfg.LEN5_DIV_EN;
    cfg.LEN5_F_EN = user_cfg.LEN5_F_EN;
    cfg.LEN5_D_EN = user_cfg.LEN5_D_EN;
    cfg.LEN5_C_EN = user_cfg.LEN5_C_EN;
    cfg.LEN5_A_EN = user_cfg.LEN5_A_EN;
    cfg.LEN5_STORE_LOAD_FWD_EN = user_cfg.LEN5_STORE_LOAD_FWD_EN;
    cfg.MAX_EU_N = user_cfg.MAX_EU_N;
    cfg.ONLY_DOUBLEWORD_MEM_ACCESSES = user_cfg.ONLY_DOUBLEWORD_MEM_ACCESSES;
    cfg.LEN5_CSR_HPMCOUNTERS_EN = user_cfg.LEN5_CSR_HPMCOUNTERS_EN;
    cfg.MMAP_MASK = user_cfg.MMAP_MASK;
    cfg.BPU_HLEN = user_cfg.BPU_HLEN;
    cfg.BPU_BTB_BITS = user_cfg.BPU_BTB_BITS;
    cfg.RAS_DEPTH = user_cfg.RAS_DEPTH;
    cfg.FETCH_MEMIF_FIFO_DEPTH = user_cfg.FETCH_MEMIF_FIFO_DEPTH;
    cfg.FETCH_MEM_DRAIN_ON_FLUSH = user_cfg.FETCH_MEM_DRAIN_ON_FLUSH;
    cfg.LOAD_BUFFER_DRAIN_ON_FLUSH = user_cfg.LOAD_BUFFER_DRAIN_ON_FLUSH;
    cfg.FETCH_REQ_SPILL_SKIP = user_cfg.FETCH_REQ_SPILL_SKIP;
    cfg.FETCH_ANS_SPILL_SKIP = user_cfg.FETCH_ANS_SPILL_SKIP;
    cfg.IQ_DEPTH = user_cfg.IQ_DEPTH;
    cfg.LDBUFF_DEPTH = user_cfg.LDBUFF_DEPTH;
    cfg.STBUFF_DEPTH = user_cfg.STBUFF_DEPTH;
    cfg.LSU_SPILL_SKIP = user_cfg.LSU_SPILL_SKIP;
    cfg.ALU_RS_DEPTH = user_cfg.ALU_RS_DEPTH;
    cfg.ALU_SPILL_SKIP = user_cfg.ALU_SPILL_SKIP;
    cfg.ALU_RR_ARBITER = user_cfg.ALU_RR_ARBITER;
    cfg.MULT_RS_DEPTH = user_cfg.MULT_RS_DEPTH;
    cfg.LEN5_MULT_SERIAL = user_cfg.LEN5_MULT_SERIAL;
    cfg.MULT_PIPE_DEPTH = user_cfg.MULT_PIPE_DEPTH;
    cfg.MULT_RR_ARBITER = user_cfg.MULT_RR_ARBITER;
    cfg.DIV_RS_DEPTH = user_cfg.DIV_RS_DEPTH;
    cfg.DIV_RR_ARBITER = user_cfg.DIV_RR_ARBITER;
    cfg.FPU_RS_DEPTH = user_cfg.FPU_RS_DEPTH;
    cfg.FPU_RR_ARBITER = user_cfg.FPU_RR_ARBITER;
    cfg.FPU_PIPE_DEPTH = user_cfg.FPU_PIPE_DEPTH;
    cfg.FPU_SPILL_SKIP = user_cfg.FPU_SPILL_SKIP;
    cfg.BU_RS_DEPTH = user_cfg.BU_RS_DEPTH;
    cfg.BU_SPILL_SKIP = user_cfg.BU_SPILL_SKIP;
    cfg.ROB_DEPTH = user_cfg.ROB_DEPTH;
    cfg.COMMIT_SPILL_SKIP = user_cfg.COMMIT_SPILL_SKIP;
    cfg.BPU_INIT_C2B = user_cfg.BPU_INIT_C2B;
    cfg.LEN5_MULTIPLE_ISSUES_BITS = $clog2(user_cfg.LEN5_MULTIPLE_ISSUES);
    cfg.LWIDTH = 32 * user_cfg.LEN5_MULTIPLE_ISSUES;
    cfg.FLEN = user_cfg.LEN5_D_EN ? 64 : 32;
    cfg.LDBUFF_TAG_W = $clog2(user_cfg.LDBUFF_DEPTH);
    cfg.STBUFF_TAG_W = $clog2(user_cfg.STBUFF_DEPTH);
    cfg.BUFF_IDX_LEN = cfg.LDBUFF_TAG_W > cfg.STBUFF_TAG_W ? cfg.LDBUFF_TAG_W : cfg.STBUFF_TAG_W;
    cfg.ROB_IDX_LEN = $clog2(user_cfg.ROB_DEPTH);
    cfg.COMMIT_UNIT_DEPTH = user_cfg.ROB_DEPTH + 3;
    cfg.IQ_IDX_LEN = $clog2(user_cfg.IQ_DEPTH);
    cfg.MULT_EU_N = user_cfg.LEN5_M_EN ? 1 : 0;
    cfg.DIV_EU_N = user_cfg.LEN5_DIV_EN ? 1 : 0;
    cfg.FP_EU_N = (user_cfg.LEN5_D_EN | user_cfg.LEN5_F_EN) ? 1 : 0;
    cfg.EU_N = 4 + cfg.MULT_EU_N + cfg.DIV_EU_N + cfg.FP_EU_N;
    cfg.REGSTAT_CNT_W = $clog2(cfg.COMMIT_UNIT_DEPTH);
    cfg.IMEM_DATA_WIDTH = user_cfg.LEN5_MULTIPLE_ISSUES > 2 ? 32 * user_cfg.LEN5_MULTIPLE_ISSUES : 64;
    cfg.TAG_COUNT = 1 << cfg.BUFF_IDX_LEN;
    cfg.AXI_COUNT_WIDTH = $clog2((cfg.TAG_COUNT > user_cfg.FETCH_MEMIF_FIFO_DEPTH ? cfg.TAG_COUNT : user_cfg.FETCH_MEMIF_FIFO_DEPTH) + 1
        );
    return cfg;
  endfunction

  // Use explicit fatal checks so constant evaluation also rejects invalid builds without --assert.
  function automatic bit check_build(len5_cfg cfg);
    int unsigned depths[6];
    int unsigned max_outstanding;
    bit derived_valid;
    if ($isunknown(cfg)) $fatal(1, "check_build: LEN5 configuration contains unknown bits");
    if (!(cfg.LEN5_MULTIPLE_ISSUES inside {1, 2, 4, 8}))
      $fatal(1, "check_build: LEN5_MULTIPLE_ISSUES must be 1, 2, 4 or 8");
    if (cfg.BOOT_VM_MODE > SV48) $fatal(1, "check_build: invalid BOOT_VM_MODE");
    if (cfg.LEN5_C_EN || cfg.LEN5_A_EN)
      $fatal(1, "check_build: compressed and atomic instructions are currently unsupported");
    if (cfg.FETCH_MEMIF_FIFO_DEPTH == 0 ||
        (cfg.FETCH_MEMIF_FIFO_DEPTH & (cfg.FETCH_MEMIF_FIFO_DEPTH - 1)) != 0)
      $fatal(1, "check_build: FETCH_MEMIF_FIFO_DEPTH must be a positive power of two");
    if (cfg.IQ_DEPTH < 2 || (cfg.IQ_DEPTH & (cfg.IQ_DEPTH - 1)) != 0)
      $fatal(1, "check_build: IQ_DEPTH must be a power of two of at least two");
    depths = '{
        cfg.RAS_DEPTH,
        cfg.LDBUFF_DEPTH,
        cfg.STBUFF_DEPTH,
        cfg.ALU_RS_DEPTH,
        cfg.BU_RS_DEPTH,
        cfg.ROB_DEPTH
    };
    foreach (depths[i]) begin
      if (depths[i] < 2)
        $fatal(
            1, "check_build: RAS, ROB, buffer and reservation-station depths must be at least two"
        );
    end
    if ((cfg.LEN5_M_EN && cfg.MULT_RS_DEPTH < 2) ||
        (cfg.LEN5_DIV_EN && cfg.DIV_RS_DEPTH < 2) ||
        ((cfg.LEN5_F_EN || cfg.LEN5_D_EN) && cfg.FPU_RS_DEPTH < 2))
      $fatal(
          1,
          "check_build: enabled execution units require reservation-station depths of at least two"
      );
    if (cfg.MAX_EU_N < 7)
      $fatal(
          1,
          "check_build: MAX_EU_N must accommodate all seven architectural execution-unit identifiers"
      );
    if (cfg.BPU_HLEN <= cfg.LEN5_MULTIPLE_ISSUES_BITS || cfg.BPU_HLEN >= 32 ||
        cfg.BPU_BTB_BITS == 0 || cfg.BPU_BTB_BITS >= 32)
      $fatal(1, "check_build: invalid BPU_HLEN or BPU_BTB_BITS");
    derived_valid = cfg.LEN5_MULTIPLE_ISSUES_BITS == $clog2(cfg.LEN5_MULTIPLE_ISSUES);
    derived_valid &= cfg.LWIDTH == 32 * cfg.LEN5_MULTIPLE_ISSUES;
    derived_valid &= cfg.FLEN == (cfg.LEN5_D_EN ? 64 : 32);
    derived_valid &= cfg.LDBUFF_TAG_W == $clog2(cfg.LDBUFF_DEPTH);
    derived_valid &= cfg.STBUFF_TAG_W == $clog2(cfg.STBUFF_DEPTH);
    derived_valid &= cfg.BUFF_IDX_LEN == (cfg.LDBUFF_TAG_W > cfg.STBUFF_TAG_W ? cfg.LDBUFF_TAG_W : cfg.STBUFF_TAG_W);
    derived_valid &= cfg.ROB_IDX_LEN == $clog2(cfg.ROB_DEPTH);
    derived_valid &= cfg.COMMIT_UNIT_DEPTH == cfg.ROB_DEPTH + 3;
    derived_valid &= cfg.IQ_IDX_LEN == $clog2(cfg.IQ_DEPTH);
    derived_valid &= cfg.REGSTAT_CNT_W == $clog2(cfg.COMMIT_UNIT_DEPTH);
    derived_valid &= cfg.MULT_EU_N == (cfg.LEN5_M_EN ? 1 : 0);
    derived_valid &= cfg.DIV_EU_N == (cfg.LEN5_DIV_EN ? 1 : 0);
    derived_valid &= cfg.FP_EU_N == ((cfg.LEN5_F_EN || cfg.LEN5_D_EN) ? 1 : 0);
    derived_valid &= cfg.EU_N == 4 + cfg.MULT_EU_N + cfg.DIV_EU_N + cfg.FP_EU_N;
    derived_valid &= cfg.IMEM_DATA_WIDTH == (cfg.LEN5_MULTIPLE_ISSUES > 2 ? 32 * cfg.LEN5_MULTIPLE_ISSUES : 64);
    derived_valid &= cfg.TAG_COUNT == (1 << cfg.BUFF_IDX_LEN);
    max_outstanding = cfg.TAG_COUNT > cfg.FETCH_MEMIF_FIFO_DEPTH ? cfg.TAG_COUNT : cfg.FETCH_MEMIF_FIFO_DEPTH;
    derived_valid &= cfg.AXI_COUNT_WIDTH == $clog2(max_outstanding + 1);
    if (!derived_valid)
      $fatal(
          1, "check_build: inconsistent derived LEN5 fields; construct Len5Cfg with build_config()"
      );
    return 1'b1;
  endfunction

  localparam len5_cfg DEFAULT_LEN5_CFG = build_config(DEFAULT_LEN5_USER_CFG);
endpackage
