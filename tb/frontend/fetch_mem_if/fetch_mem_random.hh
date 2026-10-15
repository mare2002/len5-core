// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include "fetch_mem_driver.hh"
#include <random>
namespace len5::fetchmem {
struct Weights {
    unsigned request=65,response=75,grant=80,ready=65,error=25,flush=3,reset=1;
    void parse(const std::string&);
    std::string text() const;
};
void run_random(Simulator&,const RunOptions&);
} // namespace len5::fetchmem
