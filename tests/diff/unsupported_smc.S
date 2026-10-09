.section .text
.globl _start
_start:
    la t0, modified
    li t1, 0x13
    sw t1, 0(t0)
    jalr zero, t0, 0
modified:
    nop
    j modified
