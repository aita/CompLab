# hello.s — the smallest thing rvemu can run: no libc, just two syscalls.
#
# Linux/RV64 puts the syscall number in a7 and the arguments in a0..a5, and the
# result comes back in a0. write(2) is 64 and exit(2) is 93.

        .section .rodata
msg:    .string "hello from rvemu\n"
        .equ    msglen, . - msg - 1     # the string minus its NUL

        .text
        .globl  _start
_start:
        li      a0, 1                   # fd = stdout
        la      a1, msg
        li      a2, msglen
        li      a7, 64                  # write
        ecall

        li      a0, 0
        li      a7, 93                  # exit
        ecall
