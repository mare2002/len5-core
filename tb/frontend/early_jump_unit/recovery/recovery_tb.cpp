// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Clock/logger pattern reused from tb/verilator/len5_tb.cpp. Analysis is external.
#include "Vrecovery_tb.h"
#include "tb_macros.hh"
#include <verilated_fst_c.h>
#include <cstdlib>
TbLogger logger;
int main(int argc, char** argv) {
    VerilatedContext context;
    context.commandArgs(argc, argv);
    context.traceEverOn(true);
    logger.setSimContext(&context);
    logger.setLogLvl(LOG_LOW);
    Vrecovery_tb dut{&context};
    VerilatedFstC waves;
    dut.trace(&waves, 99);
    waves.open("waves.fst");
    TB_CONFIG("Full-core recovery capture; read-only internal telemetry; no forced state");
    for (unsigned cycle=0; cycle<300 && !context.gotFinish(); ++cycle) {
        dut.cycle_i=cycle;
        dut.rst_ni=cycle>=10;
        dut.clk_i=0; dut.eval(); waves.dump(context.time()); context.timeInc(1);
        dut.clk_i=1; dut.eval(); waves.dump(context.time()); context.timeInc(1);
    }
    dut.final(); waves.close();
    TB_LOG(LOG_LOW, "Full-core trace captured; Python analysis determines reproduction status\n");
    return 0;
}
