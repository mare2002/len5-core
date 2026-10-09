.option norvc
.section .text
.globl _start
_start:
    li t0, 7
    li t1, 3
    add t2, t0, t1
    sub t3, t2, t1
    mul t4, t3, t2
    div t5, t4, t0
    add t6, t5, t1
    li a0, 0x20000100
    sb zero, 0(a0)
1:  j 1b
    .rept 32
    nop
    .endr
