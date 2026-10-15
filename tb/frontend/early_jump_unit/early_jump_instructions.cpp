// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// Architectural raw-word encoder/decoder, independent of DUT types and decode expressions.
#include "early_jump_instructions.hh"
#include <stdexcept>

namespace len5::early {
const char* name(Kind k) {
    static const char* names[]={"call","jal","return","jalr","branch","arithmetic","immediate",
        "load","store","upper","fence","system","multiply","floating","invalid"};
    const unsigned n=static_cast<unsigned>(k);
    if(n>=sizeof(names)/sizeof(*names)) throw std::logic_error("invalid instruction class");
    return names[n];
}
static int64_t sign_extend(uint32_t value,unsigned bits) {
    return value & (uint32_t(1)<<(bits-1)) ? int64_t(value)-(int64_t(1)<<bits) : int64_t(value);
}
Decoded decode(uint32_t word) {
    Decoded d;
    d.rd=(word>>7)&31; d.rs1=(word>>15)&31; d.rs2=(word>>20)&31; d.funct3=(word>>12)&7;
    const unsigned opcode=word&127, funct7=word>>25;
    switch(opcode) {
    case 0x6f: {
        const uint32_t displacement=((word>>31)&1)*1048576u + ((word>>12)&255)*4096u
            + ((word>>20)&1)*2048u + ((word>>21)&1023)*2u;
        d.immediate=sign_extend(displacement,21); d.kind=d.rd==1?Kind::Call:Kind::Jal; d.valid=true; break;
    }
    case 0x67:
        if(d.funct3==0) {
            d.immediate=sign_extend(word>>20,12); d.valid=true;
            d.kind=d.rd==0 && d.rs1==1 && d.immediate==0?Kind::Return:Kind::Jalr;
        }
        break;
    case 0x63:
        if(d.funct3!=2 && d.funct3!=3) {
            const uint32_t imm=((word>>31)&1)*4096u+((word>>7)&1)*2048u
                +((word>>25)&63)*32u+((word>>8)&15)*2u;
            d.kind=Kind::Branch; d.immediate=sign_extend(imm,13); d.valid=true;
        }
        break;
    case 0x33: case 0x3b:
        if(funct7==1) { d.kind=Kind::Multiply; d.valid=opcode==0x33 || d.funct3==0 || d.funct3>=4; }
        else if(funct7==0 || (funct7==32 && (d.funct3==0 || d.funct3==5))) {
            d.kind=Kind::Arithmetic; d.valid=opcode==0x33 || d.funct3==0 || d.funct3==1 || d.funct3==5;
        }
        break;
    case 0x13: case 0x1b:
        d.kind=Kind::Immediate; d.immediate=sign_extend(word>>20,12);
        d.valid=opcode==0x13 || d.funct3==0 || d.funct3==1 || d.funct3==5;
        if(d.funct3==1) d.valid=d.valid && (word>>26)==0;
        if(d.funct3==5) d.valid=d.valid && ((word>>26)==0 || (word>>26)==16);
        if(opcode==0x1b && (d.funct3==1 || d.funct3==5)) d.valid=d.valid && ((word>>25)&1)==0;
        break;
    case 0x03:
        d.kind=Kind::Load; d.valid=d.funct3<=6; d.immediate=sign_extend(word>>20,12); break;
    case 0x23:
        d.kind=Kind::Store; d.valid=d.funct3<=3; d.immediate=sign_extend(((word>>25)<<5)|((word>>7)&31),12); break;
    case 0x17: case 0x37: d.kind=Kind::Upper; d.valid=true; d.immediate=sign_extend(word&0xfffff000u,32); break;
    case 0x0f: d.kind=Kind::Fence; d.valid=d.funct3<=1; break;
    case 0x73:
        d.kind=Kind::System;
        d.valid=d.funct3==1 || d.funct3==2 || d.funct3==3 || d.funct3>=5
            || word==0x00000073 || word==0x00100073 || word==0x30200073 || word==0x10500073;
        break;
    case 0x53:
        // Generator uses FADD.S/FADD.D with legal rounding modes, not a full FP execution decoder.
        d.kind=Kind::Floating; d.valid=(funct7==0 || funct7==1) && (d.funct3<=4 || d.funct3==7); break;
    default: break;
    }
    if(!d.valid) d.kind=Kind::Invalid;
    return d;
}
static void regs(unsigned a,unsigned b=0,unsigned c=0) {
    if(a>31 || b>31 || c>31) throw std::invalid_argument("register index outside x0..x31");
}
Outcome outcome(uint32_t word,uint64_t pc,uint64_t a,uint64_t b) {
    const auto d=decode(word);
    if(d.rs1==0) a=0;
    if(d.rs2==0) b=0;
    if(d.kind==Kind::Call || d.kind==Kind::Jal) return {true,pc+uint64_t(d.immediate)};
    if(d.kind==Kind::Return || d.kind==Kind::Jalr) return {true,(a+uint64_t(d.immediate))&~UINT64_C(1)};
    if(d.kind!=Kind::Branch) return {};
    bool taken=false;
    const auto signed_less=[](uint64_t x,uint64_t y) { return (x^UINT64_C(0x8000000000000000))<(y^UINT64_C(0x8000000000000000)); };
    switch(d.funct3) {
    case 0: taken=a==b; break;
    case 1: taken=a!=b; break;
    case 4: taken=signed_less(a,b); break;
    case 5: taken=!signed_less(a,b); break;
    case 6: taken=a<b; break;
    case 7: taken=a>=b; break;
    default: throw std::logic_error("invalid conditional branch");
    }
    return {taken,pc+uint64_t(d.immediate)};
}
uint32_t jal(unsigned rd,int64_t displacement) {
    regs(rd);
    if(displacement < -1048576 || displacement > 1048574 || displacement%2)
        throw std::invalid_argument("JAL displacement is not an encodable signed J immediate");
    const uint32_t imm=uint32_t(displacement)&0x1fffff;
    return ((imm>>20)<<31) | (((imm>>1)&1023)<<21) | (((imm>>11)&1)<<20)
        | (((imm>>12)&255)<<12) | (rd<<7) | 0x6f;
}
uint32_t jalr(unsigned rd,unsigned rs1,int64_t displacement) {
    regs(rd,rs1);
    if(displacement < -2048 || displacement > 2047) throw std::invalid_argument("JALR I immediate out of range");
    return ((uint32_t(displacement)&4095)<<20)|(rs1<<15)|(rd<<7)|0x67;
}
uint32_t branch(unsigned funct3,unsigned rs1,unsigned rs2,int64_t displacement) {
    regs(rs1,rs2);
    if(funct3>7 || funct3==2 || funct3==3 || displacement < -4096 || displacement > 4094 || displacement%2)
        throw std::invalid_argument("invalid branch encoding parameters");
    const uint32_t imm=uint32_t(displacement)&8191;
    return ((imm>>12)<<31)|(((imm>>5)&63)<<25)|(rs2<<20)|(rs1<<15)|(funct3<<12)
        |(((imm>>1)&15)<<8)|(((imm>>11)&1)<<7)|0x63;
}
uint32_t ordinary(std::mt19937_64& rng,unsigned family) {
    const unsigned rd=rng()%32, rs1=rng()%32, rs2=rng()%32;
    const uint32_t imm=rng()&4095;
    switch(family%11) {
    case 0: return (rs2<<20)|(rs1<<15)|(unsigned(rng()%8)<<12)|(rd<<7)|0x33;
    case 1: { const unsigned f[]={0,2,3,4,6,7}; return (imm<<20)|(rs1<<15)|(f[rng()%6]<<12)|(rd<<7)|0x13; }
    case 2: return (imm<<20)|(rs1<<15)|(unsigned(rng()%7)<<12)|(rd<<7)|0x03;
    case 3: return ((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(unsigned(rng()%4)<<12)|((imm&31)<<7)|0x23;
    case 4: return (uint32_t(rng())&0xfffff000u)|(rd<<7)|(rng()%2?0x17:0x37);
    case 5: return 0x0ff0000f; // FENCE iorw,iorw
    case 6: return (0x340u<<20)|(rs1<<15)|(unsigned(1+rng()%3)<<12)|(rd<<7)|0x73; // mscratch CSR
    case 7: return 0x02000033|(rs2<<20)|(rs1<<15)|(unsigned(rng()%8)<<12)|(rd<<7);
    case 8: return (unsigned(rng()%2)<<25)|(rs2<<20)|(rs1<<15)|(rd<<7)|0x53; // FADD.S/D, RNE
    case 9: return (imm<<20)|(rs1<<15)|(rd<<7)|0x1b; // ADDIW
    default: return (rs2<<20)|(rs1<<15)|(rd<<7)|0x3b; // ADDW
    }
}
uint32_t near_miss(std::mt19937_64& rng) {
    switch(rng()%5) {
    case 0: return jalr(0,5,0);
    case 1: return jalr(1,1,0);
    case 2: return jalr(0,1,1+int64_t(rng()%2047));
    case 3: return (unsigned(rng()%32)<<15)|0x00000093; // ADDI with rd=x1
    default: return 0x00008067 ^ (uint32_t(1) << (7+rng()%25));
    }
}
} // namespace len5::early
