.option norvc
.section .text
.globl _start
_start:
    csrrwi t0, mscratch, 7
    csrr t1, mscratch
    csrrsi t2, mscratch, 16
    csrrci t3, mscratch, 1
    csrr t4, mscratch
    csrrwi zero, mtvec, 1
    csrr t1, mtvec
    li a0, 0x20000100
    sb zero, 0(a0)
1:  j 1b
    .rept 32
    nop
    .endr
