// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Observational metrics only; identical sampling for all memory backends.
module memory_protocol_monitor #(
    parameter int unsigned COUNT_WIDTH = memory_backend_pkg::SRAM_COUNT_WIDTH
) (
    input logic clk_i,
    rst_ni,
    flush_i,
    load_flush_i,
    stop_i,
    retire_i,
    input logic [2:0] req_i,
    gnt_i,
    valid_i,
    ready_i,
    input logic [2:0][COUNT_WIDTH-1:0] occupancy_i
);
  // Separate queues avoid Verilator 5.040's indexed queue mutation bug.
  longint unsigned instr_times[$], load_times[$], store_times[$];
  function automatic int queue_size(int p);
    case (p)
      0: return instr_times.size();
      1: return load_times.size();
      default: return store_times.size();
    endcase
  endfunction
  function automatic void clear_queue(int p);
    case (p)
      0: instr_times.delete();
      1: load_times.delete();
      default: store_times.delete();
    endcase
  endfunction
  function automatic void push_time(int p, longint unsigned value);
    case (p)
      0: instr_times.push_back(value);
      1: load_times.push_back(value);
      default: store_times.push_back(value);
    endcase
  endfunction
  function automatic longint unsigned pop_time(int p);
    case (p)
      0: return instr_times.pop_front();
      1: return load_times.pop_front();
      default: return store_times.pop_front();
    endcase
  endfunction
  longint unsigned cycles, retired, accepted[3], completed[3], latency[3];
  longint unsigned sum_out[3], max_out[3], sum_occ[3], max_occ[3], req_stall[3], rsp_stall[3];
  bit finished;
  longint unsigned start_cycle;
  string report_path;
  int fd;
  longint unsigned buffer_count;
  // Blocking assignments are intentional for ordered scoreboard/report sampling.
  /* verilator lint_off BLKSEQ */
  always @(posedge clk_i) begin
    if (!rst_ni) begin
      cycles   = 0;
      retired  = 0;
      finished = 0;
      for (int p = 0; p < 3; p++) begin
        clear_queue(p);
        accepted[p]  = 0;
        completed[p] = 0;
        latency[p]   = 0;
        sum_out[p]   = 0;
        max_out[p]   = 0;
        sum_occ[p]   = 0;
        max_occ[p]   = 0;
        req_stall[p] = 0;
        rsp_stall[p] = 0;
      end
    end else if (!finished) begin
      if (flush_i) clear_queue(0);
      if (load_flush_i) clear_queue(1);
      cycles++;
      retired += 64'(retire_i);
      for (int p = 0; p < 3; p++) begin
        sum_out[p] += 64'(queue_size(p));
        if (64'(queue_size(p)) > max_out[p]) max_out[p] = 64'(queue_size(p));
        // Legacy PIPE_NUM=0: every pending response resides in the spill/output
        // registers. TC_SRAM reports only occupied skid slots, excluding in-flight reads.
        buffer_count = tb_config_pkg::MEMORY_BACKEND == tb_config_pkg::MEM_BACKEND_LEGACY ?
                       64'(queue_size(p)) : 64'(occupancy_i[p]);
        sum_occ[p] += buffer_count;
        if (buffer_count > max_occ[p]) max_occ[p] = buffer_count;
        req_stall[p] += 64'(req_i[p] && !gnt_i[p]);
        rsp_stall[p] += 64'(valid_i[p] && !ready_i[p]);
        if (req_i[p] && gnt_i[p] && !(p == 0 && flush_i) && !(p == 1 && load_flush_i)) begin
          accepted[p]++;
          push_time(p, cycles);
        end
        if (valid_i[p] && ready_i[p] && !(p == 0 && flush_i) && !(p == 1 && load_flush_i) && queue_size(p) != 0) begin
          start_cycle = pop_time(p);
          completed[p]++;
          latency[p] += cycles - start_cycle;
        end
      end
      if (stop_i) begin
        finished = 1;
        $display("MEM_PERF cycles=%0d retired=%0d IPC=%f", cycles, retired,
                 real'(retired) / real'(cycles));
        report_path = "memory-performance.json";
        void'($value$plusargs("memory_report=%s", report_path));
        fd = $fopen(report_path, "w");
        if (fd == 0) $fatal(1, "Cannot write memory performance report");
        $fdisplay(fd, "{\"backend\":%0d,\"cycles\":%0d,\"retired\":%0d,\"ipc\":%f,\"ports\":[",
                  int'(tb_config_pkg::MEMORY_BACKEND), cycles, retired,
                  real'(retired) / real'(cycles));
        for (int p = 0; p < 3; p++) begin
          $fwrite(
              fd,
              "{\"port\":%0d,\"accepted\":%0d,\"completed\":%0d,\"requests_per_cycle\":%f,\"latency\":%f,",
              p, accepted[p], completed[p], real'(accepted[p]) / real'(cycles),
              completed[p] != 0 ? real'(latency[p]) / real'(completed[p]) : 0.0);
          $fwrite(
              fd,
              "\"max_outstanding\":%0d,\"average_outstanding\":%f,\"max_buffer\":%0d,\"average_buffer\":%f,",
              max_out[p], real'(sum_out[p]) / real'(cycles), max_occ[p],
              real'(sum_occ[p]) / real'(cycles));
          $fdisplay(fd, "\"request_stalls\":%0d,\"response_stalls\":%0d}%s", req_stall[p],
                    rsp_stall[p], p == 2 ? "" : ",");
        end
        $fdisplay(fd, "]}");
        $fclose(fd);
      end
    end
  end
  /* verilator lint_on BLKSEQ */
endmodule
