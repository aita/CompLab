# isa.s — one instruction per line, for tests/compare-with-gnu-as.sh.
#
# Every RV64GC mnemonic and pseudo-instruction the assembler knows, chosen so
# that GNU as and rvemu can be pointed at the same file and diffed.

        .text
        .globl _start
_start:
        lui     a0, 0x12345
        auipc   a1, 0x1
        jal     ra, target
        jalr    a0, 8(a1)
        beq     a0, a1, target
        bne     a2, a3, target
        blt     a4, a5, target
        bge     a6, a7, target
        bltu    s0, s1, target
        bgeu    s2, s3, target
        lb      t0, -12(sp)
        lh      t1, 4(gp)
        lw      t2, 0(tp)
        ld      s4, 2040(sp)
        lbu     s5, 1(s6)
        lhu     s7, 2(s8)
        lwu     s9, 4(s10)
        sb      t3, -1(sp)
        sh      t4, 2(sp)
        sw      t5, 4(sp)
        sd      t6, 8(sp)
        addi    a0, a1, -2048
        slti    a0, a1, 100
        sltiu   a0, a1, 100
        xori    a0, a1, -1
        ori     a0, a1, 15
        andi    a0, a1, 255
        slli    a0, a1, 37
        srli    a0, a1, 63
        srai    a0, a1, 1
        add     a0, a1, a2
        sub     a0, a1, a2
        sll     a0, a1, a2
        slt     a0, a1, a2
        sltu    a0, a1, a2
        xor     a0, a1, a2
        srl     a0, a1, a2
        sra     a0, a1, a2
        or      a0, a1, a2
        and     a0, a1, a2
        addiw   a0, a1, -5
        slliw   a0, a1, 31
        srliw   a0, a1, 7
        sraiw   a0, a1, 7
        addw    a0, a1, a2
        subw    a0, a1, a2
        sllw    a0, a1, a2
        srlw    a0, a1, a2
        sraw    a0, a1, a2
        fence
        fence.i
        ecall
        ebreak
        csrrw   a0, fcsr, a1
        csrrs   a0, cycle, zero
        csrrc   a0, frm, a1
        csrrwi  a0, fflags, 3
        csrrsi  a0, instret, 1
        csrrci  a0, time, 31
        mul     a0, a1, a2
        mulh    a0, a1, a2
        mulhsu  a0, a1, a2
        mulhu   a0, a1, a2
        div     a0, a1, a2
        divu    a0, a1, a2
        rem     a0, a1, a2
        remu    a0, a1, a2
        mulw    a0, a1, a2
        divw    a0, a1, a2
        divuw   a0, a1, a2
        remw    a0, a1, a2
        remuw   a0, a1, a2
        lr.w    a0, (a1)
        lr.d.aq a0, (a1)
        sc.w    a0, a2, (a1)
        sc.d.aqrl a0, a2, (a1)
        amoswap.w a0, a2, (a1)
        amoadd.d a0, a2, (a1)
        amoxor.w a0, a2, (a1)
        amoand.d a0, a2, (a1)
        amoor.w a0, a2, (a1)
        amomin.d a0, a2, (a1)
        amomax.w a0, a2, (a1)
        amominu.d a0, a2, (a1)
        amomaxu.w a0, a2, (a1)
        flw     ft0, 8(sp)
        fld     ft1, 16(sp)
        fsw     ft2, 24(sp)
        fsd     ft3, 32(sp)
        fadd.s  fa0, fa1, fa2
        fsub.d  fa0, fa1, fa2
        fmul.s  fa0, fa1, fa2, rtz
        fdiv.d  fa0, fa1, fa2, rdn
        fsqrt.s fa0, fa1
        fsqrt.d fa0, fa1, rup
        fsgnj.s fa0, fa1, fa2
        fsgnjn.d fa0, fa1, fa2
        fsgnjx.s fa0, fa1, fa2
        fmin.s  fa0, fa1, fa2
        fmax.d  fa0, fa1, fa2
        fmadd.s fa0, fa1, fa2, fa3
        fmsub.d fa0, fa1, fa2, fa3
        fnmsub.s fa0, fa1, fa2, fa3, rmm
        fnmadd.d fa0, fa1, fa2, fa3
        feq.s   a0, fa1, fa2
        flt.d   a0, fa1, fa2
        fle.s   a0, fa1, fa2
        fclass.d a0, fa1
        fmv.x.w a0, fa1
        fmv.x.d a0, fa1
        fmv.w.x fa0, a1
        fmv.d.x fa0, a1
        fcvt.w.s a0, fa1
        fcvt.wu.d a0, fa1, rtz
        fcvt.l.s a0, fa1
        fcvt.lu.d a0, fa1
        fcvt.s.w fa0, a1
        fcvt.s.wu fa0, a1
        fcvt.d.l fa0, a1
        fcvt.d.lu fa0, a1
        fcvt.s.d fa0, fa1
        fcvt.d.s fa0, fa1
        nop
        mv      a0, a1
        not     a0, a1
        neg     a0, a1
        negw    a0, a1
        sext.w  a0, a1
        seqz    a0, a1
        snez    a0, a1
        sltz    a0, a1
        sgtz    a0, a1
        beqz    a0, target
        bnez    a0, target
        blez    a0, target
        bgez    a0, target
        bltz    a0, target
        bgtz    a0, target
        bgt     a0, a1, target
        ble     a0, a1, target
        bgtu    a0, a1, target
        bleu    a0, a1, target
        j       target
        jr      a0
        ret
        li      a0, 0
        li      a1, 2047
        li      a2, -2048
        li      a3, 0x12345
        li      a4, 0x7fffffff
        li      a5, -0x80000000
        li      a6, 0x123456789
        li      a7, 0xffffffffffff0000
        la      s0, target
        call    target
        tail    target
        fmv.s   fa0, fa1
        fneg.d  fa0, fa1
        fabs.s  fa0, fa1
        csrr    a0, fcsr
        csrw    fcsr, a0
        rdcycle a0
        rdinstret a1
target:
        ret
