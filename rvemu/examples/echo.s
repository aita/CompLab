# echo.s — argc and argv, straight off the initial stack.
#
# When a Linux process starts, sp points at argc; immediately above it are the
# argv pointers, then a NULL, then envp. rvemu builds exactly that block, so this
# is the same program you would write for real hardware.

        .section .rodata
space:  .string " "
nl:     .string "\n"

        .text
        .globl  _start

# write(1, a0, a1) — the two arguments are already where write wants them, one
# register over.
puts_n:
        mv      a2, a1
        mv      a1, a0
        li      a0, 1
        li      a7, 64
        ecall
        ret

# strlen(a0) -> a0
strlen:
        mv      t0, a0
1:      lbu     t1, 0(a0)
        beqz    t1, 2f
        addi    a0, a0, 1
        j       1b
2:      sub     a0, a0, t0
        ret

_start:
        ld      s0, 0(sp)               # argc
        addi    s1, sp, 8               # &argv[0]
        li      s2, 0                   # index

loop:
        bge     s2, s0, done
        slli    t0, s2, 3
        add     t0, t0, s1
        ld      s3, 0(t0)               # argv[i]

        mv      a0, s3
        call    strlen
        mv      a1, a0
        mv      a0, s3
        call    puts_n

        addi    s2, s2, 1
        bge     s2, s0, done            # no separator after the last one
        la      a0, space
        li      a1, 1
        call    puts_n
        j       loop

done:
        la      a0, nl
        li      a1, 1
        call    puts_n
        li      a0, 0
        li      a7, 93
        ecall
