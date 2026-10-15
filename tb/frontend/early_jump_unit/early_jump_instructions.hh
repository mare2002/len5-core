// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
#pragma once
#include <cstdint>
#include <random>

namespace len5::early {
enum class Kind { Call, Jal, Return, Jalr, Branch, Arithmetic, Immediate, Load,
                  Store, Upper, Fence, System, Multiply, Floating, Invalid };
const char* name(Kind);
struct Decoded {
    Kind kind=Kind::Invalid;
    unsigned rd=0, rs1=0, rs2=0, funct3=0;
    int64_t immediate=0;
    bool valid=false;
    bool recognized() const { return kind==Kind::Call || kind==Kind::Jal || kind==Kind::Return; }
    bool control() const { return recognized() || kind==Kind::Jalr || kind==Kind::Branch; }
};
Decoded decode(uint32_t word);
struct Outcome { bool taken=false; uint64_t target=0; };
Outcome outcome(uint32_t word,uint64_t pc,uint64_t rs1_value,uint64_t rs2_value);
uint32_t jal(unsigned rd,int64_t displacement);
uint32_t jalr(unsigned rd,unsigned rs1,int64_t displacement);
uint32_t branch(unsigned funct3,unsigned rs1,unsigned rs2,int64_t displacement);
uint32_t ordinary(std::mt19937_64&,unsigned family);
uint32_t near_miss(std::mt19937_64&);
} // namespace len5::early
