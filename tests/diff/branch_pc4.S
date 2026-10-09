.option norvc
.section .text
.globl _start
_start:
    li t0, 4
loop:
    # A wrong taken prediction can flush instructions even though the next PC was right.
    beq zero, zero, 1f
1:  addi t1, t1, 1
    addi t0, t0, -1
    bnez t0, loop
    li a0, 0x20000100
    sb zero, 0(a0)
2:  j 2b
    .rept 32
    nop
    .endr
