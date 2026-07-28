# fib.s — recursion, a stack frame, and enough of an itoa to see the answer.
#
# Worth stepping through under gdb:
#
#   rvemu -g 1234 examples/fib.s
#   gdb -ex 'target remote :1234' -ex 'break *0x10000' -ex continue
#
# There is no DWARF here, so gdb works at the instruction level: `stepi`,
# `x/8i $pc`, `info registers`, `p/x $sp`.

        .section .rodata
prefix: .string "fib("
mid:    .string ") = "
nl:     .string "\n"

        .bss
        .align  3
buf:    .zero   32

        .text
        .globl  _start

# fib(a0) -> a0, the naive recursion, so the call depth is worth watching.
fib:
        addi    sp, sp, -32
        sd      ra, 24(sp)
        sd      s0, 16(sp)              # n, across both recursive calls
        sd      s1, 8(sp)               # fib(n-1), across the second one
        li      t0, 2
        blt     a0, t0, ret_fib         # fib(0) = 0, fib(1) = 1: a0 is the answer
        mv      s0, a0
        addi    a0, s0, -1
        call    fib
        mv      s1, a0
        addi    a0, s0, -2
        call    fib
        add     a0, a0, s1
ret_fib:
        ld      ra, 24(sp)
        ld      s0, 16(sp)
        ld      s1, 8(sp)
        addi    sp, sp, 32
        ret

# write(1, a0, a1)
puts_n:
        mv      a2, a1
        mv      a1, a0
        li      a0, 1
        li      a7, 64
        ecall
        ret

# print_dec(a0): render a0 into buf, backwards, then write what we produced.
print_dec:
        addi    sp, sp, -16
        sd      ra, 8(sp)
        la      t0, buf
        addi    t1, t0, 31              # write backwards from the end
        li      t2, 10
        beqz    a0, zero_case
1:      remu    t3, a0, t2
        addi    t3, t3, '0'
        addi    t1, t1, -1
        sb      t3, 0(t1)
        divu    a0, a0, t2
        bnez    a0, 1b
        j       emit
zero_case:
        addi    t1, t1, -1
        li      t3, '0'
        sb      t3, 0(t1)
emit:
        la      t0, buf
        addi    t0, t0, 31
        sub     a1, t0, t1              # how many digits we wrote
        mv      a0, t1
        call    puts_n
        ld      ra, 8(sp)
        addi    sp, sp, 16
        ret

        .equ    N, 20

_start:
        la      a0, prefix
        li      a1, 4
        call    puts_n
        li      a0, N
        call    print_dec
        la      a0, mid
        li      a1, 4
        call    puts_n

        li      a0, N
        call    fib
        call    print_dec

        la      a0, nl
        li      a1, 1
        call    puts_n

        li      a0, 0
        li      a7, 93
        ecall
