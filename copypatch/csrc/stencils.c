/*
 * Copy-and-patch stencils for the copypatch baseline JIT.
 *
 * Every bytecode op has exactly one stencil function here.  clang compiles
 * this file to a relocatable object; build.rs slices each function's machine
 * code out of it and embeds the bytes in the Rust binary.  At run time the
 * JIT concatenates those byte blobs and fills in the "holes" -- the jump
 * targets and 32-bit immediates that clang left as relocations.
 *
 * Two rules keep the generated code patchable:
 *
 *   1. Every stencil leaves via `musttail`, so clang emits a direct
 *      `jmp rel32` / `jcc rel32` whose displacement is the only thing the
 *      Rust side has to rewrite.
 *   2. Runtime helpers are reached through function pointers in `Vm`, never
 *      by name, so no stencil ever needs a relocation against a Rust symbol.
 *
 * Value representation (see src/value.rs -- both sides must agree):
 *
 *   int n  ->  (n << 1) | 1      (63-bit, wrapping)
 *   false  ->  0b000
 *   true   ->  0b010
 *   fn #i  ->  (i << 3) | 0b100
 *
 * So `v & 1` is the "is int" test, tagged ints compare and add directly, and
 * bitwise equality is value equality across all three types. Beware that
 * "is bool" is not the negation of "is int": function references also have
 * bit 0 clear, so bools need their own test.
 */

#include <stdint.h>

typedef uint64_t Value;
typedef struct Vm Vm;

/* Mirrored by `Shared` in src/vm.rs. Must stay in sync. */
struct Vm {
    Value ret;        /* 0x00: return value of the whole chain */
    uint32_t error;   /* 0x08: 0 = ok, otherwise an ERR_* code */
    uint32_t err_pc;  /* 0x0c: bytecode index that faulted */
    Value (*rt_call)(Vm *vm, uint32_t func, Value *args, uint32_t argc); /* 0x10 */
    void (*rt_print)(Vm *vm, Value v);                                  /* 0x18 */
};

enum {
    ERR_TYPE = 1,
    ERR_DIV_ZERO = 2,
};

#define VAL_FALSE ((Value)0)
#define VAL_TRUE ((Value)2)

#define TAG_FUNC ((Value)0x4)
#define TAG_FUNC_MASK ((Value)0x7)
#define TAG_FUNC_SHIFT 3

/*
 * The holes.  None of these symbols exist; they only ever show up as
 * relocations, which is exactly what we want to harvest.
 */
extern void HOLE_NEXT(Value *sp, Value *locals, Vm *vm, const Value *consts);
extern void HOLE_TARGET(Value *sp, Value *locals, Vm *vm, const Value *consts);
extern const char HOLE_A[];  /* primary operand   */
extern const char HOLE_B[];  /* secondary operand */
extern const char HOLE_PC[]; /* bytecode index, for error reporting */

#define IMM_A ((uint32_t)(uintptr_t)HOLE_A)
#define IMM_B ((uint32_t)(uintptr_t)HOLE_B)
#define IMM_PC ((uint32_t)(uintptr_t)HOLE_PC)

#define STENCIL(name) \
    void st_##name(Value *sp, Value *locals, Vm *vm, const Value *consts)

#define NEXT(new_sp) __attribute__((musttail)) return HOLE_NEXT((new_sp), locals, vm, consts)
#define GOTO(new_sp) __attribute__((musttail)) return HOLE_TARGET((new_sp), locals, vm, consts)

#define FAIL(code)              \
    do {                        \
        vm->error = (code);     \
        vm->err_pc = IMM_PC;    \
        return;                 \
    } while (0)

#define UNLIKELY(x) __builtin_expect(!!(x), 0)

/* Both operands tagged as ints? */
#define BOTH_INT(a, b) ((((a) & (b)) & 1u) != 0)

/* Bools are exactly VAL_FALSE and VAL_TRUE. */
#define IS_BOOL(v) (((v) & ~VAL_TRUE) == 0)

#define IS_FUNC(v) (((v) & TAG_FUNC_MASK) == TAG_FUNC)

/* ---------------------------------------------------------------- stack */

/* push consts[A] */
STENCIL(push_const) {
    sp[0] = consts[IMM_A];
    NEXT(sp + 1);
}

/* push locals[A] */
STENCIL(load_local) {
    sp[0] = locals[IMM_A];
    NEXT(sp + 1);
}

/* locals[A] = pop */
STENCIL(store_local) {
    locals[IMM_A] = sp[-1];
    NEXT(sp - 1);
}

/* discard top of stack */
STENCIL(pop) {
    NEXT(sp - 1);
}

/* ----------------------------------------------------------- arithmetic */

/* (2a+1) + (2b+1) - 1 == 2(a+b)+1, so the tags cancel without untagging. */
STENCIL(add) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    sp[-2] = a + b - 1;
    NEXT(sp - 1);
}

STENCIL(sub) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    sp[-2] = a - b + 1;
    NEXT(sp - 1);
}

STENCIL(mul) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    int64_t r = ((int64_t)a >> 1) * ((int64_t)b >> 1);
    sp[-2] = ((Value)r << 1) | 1u;
    NEXT(sp - 1);
}

STENCIL(div) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    int64_t rb = (int64_t)b >> 1;
    if (UNLIKELY(rb == 0)) FAIL(ERR_DIV_ZERO);
    /* operands are 63-bit, so INT64_MIN / -1 cannot happen here */
    int64_t r = ((int64_t)a >> 1) / rb;
    sp[-2] = ((Value)r << 1) | 1u;
    NEXT(sp - 1);
}

STENCIL(rem) {
    Value b = sp[-1], a = sp[-2];
    if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);
    int64_t rb = (int64_t)b >> 1;
    if (UNLIKELY(rb == 0)) FAIL(ERR_DIV_ZERO);
    int64_t r = ((int64_t)a >> 1) % rb;
    sp[-2] = ((Value)r << 1) | 1u;
    NEXT(sp - 1);
}

/* 2 - (2a+1) == 2(-a)+1 */
STENCIL(neg) {
    Value a = sp[-1];
    if (UNLIKELY((a & 1u) == 0)) FAIL(ERR_TYPE);
    sp[-1] = 2 - a;
    NEXT(sp);
}

STENCIL(not) {
    Value a = sp[-1];
    if (UNLIKELY(!IS_BOOL(a))) FAIL(ERR_TYPE);
    sp[-1] = a ^ VAL_TRUE;
    NEXT(sp);
}

/* ---------------------------------------------------------- comparisons */

/* Tagging is monotonic on the 63-bit range, so tagged values compare directly. */
#define CMP_STENCIL(name, op)                                  \
    STENCIL(name) {                                            \
        Value b = sp[-1], a = sp[-2];                          \
        if (UNLIKELY(!BOTH_INT(a, b))) FAIL(ERR_TYPE);         \
        sp[-2] = (Value)((int64_t)a op(int64_t) b) << 1;       \
        NEXT(sp - 1);                                          \
    }

CMP_STENCIL(lt, <)
CMP_STENCIL(le, <=)
CMP_STENCIL(gt, >)
CMP_STENCIL(ge, >=)

/* Equality is total: the tag is part of the bit pattern, so an int is never
 * bit-equal to a bool and no type check is needed. */
STENCIL(eq) {
    sp[-2] = (Value)(sp[-2] == sp[-1]) << 1;
    NEXT(sp - 1);
}

STENCIL(ne) {
    sp[-2] = (Value)(sp[-2] != sp[-1]) << 1;
    NEXT(sp - 1);
}

/* ------------------------------------------------------- control flow */

STENCIL(jump) {
    GOTO(sp);
}

STENCIL(jump_if_false) {
    Value a = sp[-1];
    if (UNLIKELY(!IS_BOOL(a))) FAIL(ERR_TYPE);
    if (a == VAL_FALSE) GOTO(sp - 1);
    NEXT(sp - 1);
}

/* call function A with B arguments taken from the top of the stack */
STENCIL(call) {
    uint32_t argc = IMM_B;
    Value *args = sp - argc;
    Value r = vm->rt_call(vm, IMM_A, args, argc);
    if (UNLIKELY(vm->error != 0)) return;
    args[0] = r;
    NEXT(args + 1);
}

/*
 * Indirect call: B arguments on top of the stack, and the callee -- which
 * must be a function reference -- in the slot just below them. Unwrapping the
 * tag here keeps the runtime interface down to the one `rt_call` hook.
 */
STENCIL(call_value) {
    uint32_t argc = IMM_B;
    Value *args = sp - argc;
    Value callee = args[-1];
    if (UNLIKELY(!IS_FUNC(callee))) FAIL(ERR_TYPE);
    Value r = vm->rt_call(vm, (uint32_t)(callee >> TAG_FUNC_SHIFT), args, argc);
    if (UNLIKELY(vm->error != 0)) return;
    args[-1] = r;
    NEXT(args);
}

/* Unwinds the whole tail-call chain back to the Rust caller. */
STENCIL(ret) {
    (void)locals;
    (void)consts;
    vm->ret = sp[-1];
}

STENCIL(print) {
    vm->rt_print(vm, sp[-1]);
    NEXT(sp - 1);
}
