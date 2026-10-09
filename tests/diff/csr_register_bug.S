.option norvc
.section .text
.globl _start
_start:
    li t0, 0x100
    csrw mscratch, t0
    csrr t1, mscratch
    csrrsi t2, mscratch, 3
    csrrci t3, mscratch, 1
    csrrwi t4, mscratch, 7
    csrr t5, mscratch
    la t0, _start
    csrw mtvec, t0
    csrr t1, mtvec
    li a0, 0x20000100
    sb zero, 0(a0)
1:  j 1b
    .rept 32
    nop
    .endr
