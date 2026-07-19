//go:build linux && amd64

#include "textflag.h"

// func callNativeRaw(entry uintptr, frame *CallFrame) uintptr
TEXT ·callNativeRaw(SB), NOSPLIT, $0-16
	MOVQ frame+8(FP), BX

	// 浮動小数点引数。
	MOVQ 48(BX), X0
	MOVQ 56(BX), X1
	MOVQ 64(BX), X2
	MOVQ 72(BX), X3
	MOVQ 80(BX), X4
	MOVQ 88(BX), X5
	MOVQ 96(BX), X6
	MOVQ 104(BX), X7

	// 整数・ポインタ引数。
	MOVQ 0(BX), DI
	MOVQ 8(BX), SI
	MOVQ 16(BX), DX
	MOVQ 24(BX), CX
	MOVQ 32(BX), R8
	MOVQ 40(BX), R9

	// ターゲットアドレスは引数設定後にロードする。
	MOVQ entry+0(FP), AX
	CALL AX

	// 整数戻り値。
	MOVQ AX, 112(BX)

	// 浮動小数点戻り値。
	MOVQ X0, 120(BX)

	RET


// func callJITRaw(entry uintptr, jit *JITContext) uintptr
//
// VM ABI — Goが所有するレジスタ(R14=g, R15, RBP, RSP)は温存する:
//   RBX = *JITContext (VM状態ブロック。真実はここ)
//   R12 = jit.SP  (&stack[sp])
//   R13 = jit.FP  (&stack[fp])
//   StackBase / Globals などは [RBX+off] 経由で読む。
// RAX = result
//
// Go ABIInternal には callee-saved GPレジスタが無く、呼び出し元は
// R14/RSP/RBP 以外の破壊を前提とする。よって退避は不要。R14(g)は触らない
// ので、この後に正しいABIでGoヘルパをCALLしても g が生きている。
TEXT ·callJITRaw(SB), NOSPLIT, $0-24
	MOVQ entry+0(FP), AX
	MOVQ jit+8(FP), BX     // RBX = *JITContext
	MOVQ 8(BX),  R12       // R12 = SP (&stack[sp])
	MOVQ 16(BX), R13       // R13 = FP (&stack[fp])
	// R14(g) / R15 / RBP は温存する。

	CALL AX

	MOVQ AX, ret+16(FP)
	RET
