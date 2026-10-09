.option norvc
.section .text
.globl _start
_start:
    rdcycle t0
    nop
1:  j 1b
    .rept 32
    nop
    .endr
