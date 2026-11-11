// Copyright Politecnico di Torino.
// Solderpad Hardware License, Version 2.1, see LICENSE.md for details.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// File: alu_tb.cpp
// Author: Mattia Mirigaldi
// Date: 21/02/2024
// Description: testbench for LEN5 ALU

#include <cstdlib>
#include <cstdio>
#include <verilated.h>      // Include Verilator common routines
#include <verilated_fst_c.h>    // Include the FST tracing class
#include <random>
#include <getopt.h>

#include "Valu_tb.h"
#include "Valu_tb_expipe_pkg.h"
#include "tb_components.hh"
#include "tb_macros.hh"

#define END_OF_RESET_TIME 4
#define MAX_SIM_TIME 1e7
#define FST_FILENAME "logs/waves.fst"

#define array_size(x) (sizeof(x) / sizeof(x[0]))

// Testbench logger
TbLogger logger;

vluint64_t sim_cycles = 0;

void clkGen(Valu_tb *dut);
void rstDut(Valu_tb *dut, vluint64_t sim_time);

// Generate an input transaction
ReqTx *genReqTx(unsigned int rs_depth);

int main(int argc, char* argv[])
{
    unsigned long prg_seed = time(NULL);
    // Define command line options
    const option longopts[] = {
        {"max_cycles",  required_argument, NULL, 'c'},
        {"dump_waves",  required_argument, NULL, 'w'},
        {"log_level",   required_argument, NULL, 'l'},
        {"seed",        required_argument, NULL, 's'},
        {"help",        no_argument,       NULL, 'h'},
        {NULL, 0, NULL, 0}
    };

    // Parse command line options
    // --------------------------
    bool              dump_waves = false;
    unsigned long int max_cycles = ((unsigned long int) MAX_SIM_TIME) >> 1;
    int     opt;
    while ((opt = getopt_long(argc, argv, "c:l:w:s:h", longopts, NULL)) >= 0) {
        switch (opt) {
            case 'c':
                max_cycles = strtoul(optarg, NULL, 0);
                break;
            case 'l':
                logger.setLogLvl(optarg);
                break;
            case 's':
                prg_seed = strtoul(optarg, NULL, 0);
                break;
            case 'w':
                if (!strcmp(optarg, "true") || !strcmp(optarg, "1")) {
                    dump_waves = true;
                }
                break;
            case 'h':
                printf("Usage: %s [OPTIONS]\n", argv[0]);
                printf("Options:\n");
                printf("  -c, --max_cycles <cycles>        Set maximum simulation cycles\n");
                printf("  -l, --log_level <level>          Set log level (0-3)\n");
                printf("  -s, --seed <seed>                Set the random seed\n");
                printf("  -h, --help                       Show this help message\n");
                exit(EXIT_SUCCESS);
                break;
            default:
                // Skip SystemVerilog arguments
                fprintf(stderr, "ERROR: Unrecognized option. Use -h or --help for help\n", argv[optind]);
                exit(EXIT_FAILURE);
        }
    }

    // Print testbench configuration
    TB_CONFIG("Simulation cycles: %lu", max_cycles);
    TB_CONFIG("Log level set to %u", logger.getLogLvl());

    // Simulation options

    // Create log directory
    Verilated::mkdir("logs");

    // Create simulation context
    VerilatedContext *cntx = new VerilatedContext;
    if (dump_waves) cntx->traceEverOn(true); // Enable wave tracing

    // Pass the simulation context to the logger
    logger.setSimContext(cntx);
    logger.setLogLvl(LOG_LOW);

    // Instatiate DUT
    Valu_tb *dut = new Valu_tb(cntx); // Create instance of module
    dut->clk_i = 0;

    // VCD file where to store waveforms
    VerilatedFstC* m_trace = new VerilatedFstC;
    if (dump_waves) {
        dut->trace(m_trace, 5); //Limit trace depth to 5
        m_trace->open(FST_FILENAME);
    }

    // TB components
    Drv *drv = new Drv(dut);    // Driver
    Scb *scb = new Scb();    // Scoreboard
    ReqMonitor *reqMon = new ReqMonitor(dut, scb);
    RspMonitor *rspMon = new RspMonitor(dut, scb);

    // Request transaction
    ReqTx *req = NULL;

    // Initialiaze PRG
    TB_CONFIG("PRG seed: %u", prg_seed);
    srand(prg_seed);
    cntx->randSeed(prg_seed);

    // Test sequence
    // -------------+
    TB_LOG(LOG_LOW, "Starting simulation...");
    while (!cntx->gotFinish() && cntx->time() < (max_cycles << 1)) {
        // Reset DUT
        rstDut(dut, sim_cycles);

        // Generate clock

        clkGen(dut);

        // Drive on falling edges and leave four cycles to drain the scoreboard.
        if (dut->clk_i == 0 && dut->rst_ni)
        {
            if (sim_cycles + 4 < max_cycles)
                req = genReqTx(dut->config_rs_depth_o);
            drv->drive(req);
            delete req;
            req = NULL;
        }
        // Sample the handshakes before the rising edge updates DUT state.
        if (dut->clk_i == 1 && dut->rst_ni)
        {
            reqMon->monitor();
            rspMon->monitor();
        }
        dut->eval();

        // Dump waveforms and advance simulation time
        m_trace->dump(cntx->time());
        if (dut->clk_i == 1) sim_cycles++;
        cntx->timeInc(1);
    }

    // Simulation complete
    dut->final();

    // Print simulation summary
    const bool failed = scb->getErrNum() != 0 || scb->getTxNum() == 0 || !scb->isDone();
    if (failed)
    {
        TB_ERR("TEST FAILED > errors: %u/%u", scb->getErrNum(), scb->getTxNum());
    }
    else
    {
        TB_SUCCESS(LOG_LOW, "TEST SUCCEEDED > errors: %u/%u", scb->getErrNum(), scb->getTxNum());
    }

    // Clean up and exit
    m_trace->close();
    delete dut;
    delete cntx;
    return failed ? EXIT_FAILURE : EXIT_SUCCESS;
}


void clkGen(Valu_tb *dut)
{
    dut -> clk_i ^= 1;
}

void rstDut(Valu_tb *dut, vluint64_t sim_time)
{
    dut->rst_ni = sim_time >= END_OF_RESET_TIME;
    if (!dut->rst_ni)
    {
        dut->rst_ni = 0;
        dut->flush_i = 0;
        dut->valid_i = 0;
        dut->ready_i = 1;
        dut->ctl_i = 0;
        dut->rs_idx_i = 0;
        dut->rs1_i = 0;
        dut->rs2_i = 0;
    }
}

// Corner cases for the input transaction
const vluint64_t corner_cases[] = {
    0x0000000000000000, // zero
    0x0000000000000001, // 64 bits min_positive
    0x7FFFFFFFFFFFFFFF, // 64 bits max_positive
    0x8000000000000000, // 64 bits min_negative
    0xFFFFFFFFFFFFFFFF, // 64 bits max_negative
    0x000000007FFFFFFF, // least 32 bits max_positive
    0x0000000080000000, // least 32 bits min_negative
    0x00000000FFFFFFFF, // least 32 bits max_negative
    0x0000000100000000, // most 32 bits min_positive
    0x7FFFFFFF00000000, // most 32 bits max_positive
    0xFFFFFFFF00000000, // most 32 bits min_negative
    0xAAAAAAAAAAAAAAAA, // 64 bits even
    0x5555555555555555, // 64 bits odd
    0x00000000AAAAAAAA, // least 32 bits even
    0x0000000055555555, // least 32 bits odd
    0xAAAAAAAA00000000, // most 32 bits even
    0x5555555500000000 // most 32 bits odd
};

/* Generate an input transaction
   Return a request object*/
ReqTx *genReqTx(unsigned int rs_depth)
{
    // Generate transaction
    int p = rand() % 100;

    // Only drive the DUT with 80% probability
    if (p < 20)
    {
        return NULL;
    }

    // Create a new transaction
    ReqTx *req = new ReqTx;

    // Flush the DUT with 5% probability
    if (p < 25)
    {
        req->valid = 0;
        req->flush = 1;
        return req;
    }
    // Corner case with 1% probability
    if (p == 26)
    {
        req->valid = 1;
        req->flush = 0;
        req->rs1 = corner_cases[rand() % (array_size(corner_cases)-1)];
        req->rs2 = corner_cases[rand() % (array_size(corner_cases)-1)];
        // RS index travels with the result independently of the arithmetic.
        req->rs_idx = rand() % rs_depth;
        p = rand() % 14;
        req->alu_ctl= Valu_tb_expipe_pkg::alu_ctl_t(p);
        return req;
    }
    // Generate a valid transaction with 74% probability
    req->valid = 1;
    req->flush = 0;
    req->rs1 = vl_rand64();
    req->rs2 = vl_rand64();
    // RS index travels with the result independently of the arithmetic.
    req->rs_idx = rand() % rs_depth;
    p = rand() % 14;
    req->alu_ctl= Valu_tb_expipe_pkg::alu_ctl_t(p);
    return req;
}

