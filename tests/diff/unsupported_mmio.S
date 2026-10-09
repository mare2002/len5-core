.section .text
.globl _start
_start:
    li t0, 0x20000000
    ld t1, 0(t0)
1:  j 1b
