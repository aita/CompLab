# cython: language_level=3, boundscheck=False, wraparound=False
# cython: freethreading_compatible=True
"""A Cython port of `VM.run_frame`: the same register dispatch loop, compiled.

The speedup is structural, not from unboxing: registers stay Python objects (a
MinPython value can be an int, a bool, a Function, or None), so arithmetic is
still Python-level and keeps the interpreter's bignum semantics -- results match
the pure-Python VM exactly. What goes away is the interpreter *overhead*: the pc
and opcode are C ints, the bytecode is fetched from C `int` arrays instead of a
list of NamedTuples, and the opcode dispatch is a C switch.

`vm` is called back into for the operations that stay in Python: CALL (recursion
runs through `vm._dispatch`), PRINT, MAKE_FUNCTION, and the tracing JIT's
on_backedge hook. Everything else is inline here.
"""

import array

from minpython.bytecode import MinPythonError

# Opcodes -- must match minpython.bytecode.Op.
DEF LOAD_CONST = 1
DEF LOAD_GLOBAL = 2
DEF STORE_GLOBAL = 3
DEF MOVE = 4
DEF MAKE_FUNCTION = 5
DEF ADD = 10
DEF SUB = 11
DEF MUL = 12
DEF FLOORDIV = 13
DEF MOD = 14
DEF POW = 15
DEF BIT_AND = 16
DEF BIT_OR = 17
DEF BIT_XOR = 18
DEF LSHIFT = 19
DEF RSHIFT = 20
DEF NEG = 30
DEF POS = 31
DEF INVERT = 32
DEF NOT = 33
DEF EQ = 40
DEF NE = 41
DEF LT = 42
DEF LE = 43
DEF GT = 44
DEF GE = 45
DEF JUMP = 50
DEF JUMP_IF_FALSE = 51
DEF JUMP_IF_TRUE = 52
DEF CALL = 60
DEF RETURN = 61
DEF PRINT = 62
DEF MAKE_LIST = 63
DEF SUBSCR = 64
DEF LEN = 65


cdef _arrays(code):
    """Flat C-int arrays (op, a, b, c) for a CodeObject, built and cached once."""
    cache = code._cy_cache
    if cache is not None:
        return cache
    insns = code.code
    ops = array.array('i', [int(ins.op) for ins in insns])
    aa = array.array('i', [ins.a for ins in insns])
    bb = array.array('i', [ins.b for ins in insns])
    cc = array.array('i', [ins.c for ins in insns])
    cache = (ops, aa, bb, cc)
    code._cy_cache = cache
    return cache


def run_frame(vm, code, list regs, dict glb):
    """Execute one activation of `code`; see VM.run_frame for the contract."""
    cdef int[::1] ops
    cdef int[::1] aa
    cdef int[::1] bb
    cdef int[::1] cc
    arrays = _arrays(code)
    ops, aa, bb, cc = arrays[0], arrays[1], arrays[2], arrays[3]

    consts = code.consts
    names = code.names

    cdef bint profile = vm.profile
    loop_counts = vm.loop_counts
    on_backedge = vm.on_backedge
    cdef long code_id = id(code)

    cdef int pc = 0
    cdef int op, a, b
    name = None
    resume = None

    while True:
        op = ops[pc]
        a = aa[pc]
        b = bb[pc]

        if op == LOAD_CONST:
            regs[a] = consts[b]
        elif op == MOVE:
            regs[a] = regs[b]
        elif op == LOAD_GLOBAL:
            name = names[b]
            if name in glb:
                regs[a] = glb[name]
            else:
                raise MinPythonError(f"name '{name}' is not defined")
        elif op == STORE_GLOBAL:
            glb[names[a]] = regs[b]

        elif op == ADD:
            regs[a] = regs[b] + regs[cc[pc]]
        elif op == SUB:
            regs[a] = regs[b] - regs[cc[pc]]
        elif op == MUL:
            regs[a] = regs[b] * regs[cc[pc]]
        elif op == FLOORDIV:
            regs[a] = regs[b] // regs[cc[pc]]
        elif op == MOD:
            regs[a] = regs[b] % regs[cc[pc]]
        elif op == POW:
            regs[a] = regs[b] ** regs[cc[pc]]
        elif op == BIT_AND:
            regs[a] = regs[b] & regs[cc[pc]]
        elif op == BIT_OR:
            regs[a] = regs[b] | regs[cc[pc]]
        elif op == BIT_XOR:
            regs[a] = regs[b] ^ regs[cc[pc]]
        elif op == LSHIFT:
            regs[a] = regs[b] << regs[cc[pc]]
        elif op == RSHIFT:
            regs[a] = regs[b] >> regs[cc[pc]]

        elif op == NEG:
            regs[a] = -regs[b]
        elif op == POS:
            regs[a] = +regs[b]
        elif op == INVERT:
            regs[a] = ~regs[b]
        elif op == NOT:
            regs[a] = not regs[b]

        elif op == EQ:
            regs[a] = regs[b] == regs[cc[pc]]
        elif op == NE:
            regs[a] = regs[b] != regs[cc[pc]]
        elif op == LT:
            regs[a] = regs[b] < regs[cc[pc]]
        elif op == LE:
            regs[a] = regs[b] <= regs[cc[pc]]
        elif op == GT:
            regs[a] = regs[b] > regs[cc[pc]]
        elif op == GE:
            regs[a] = regs[b] >= regs[cc[pc]]

        elif op == JUMP:
            if a <= pc:
                if profile:
                    loop_counts[(code_id, a)] = \
                        loop_counts.get((code_id, a), 0) + 1
                if on_backedge is not None:
                    resume = on_backedge(code, a, regs, glb)
                    if resume is not None:
                        pc = resume
                        continue
            pc = a
            continue
        elif op == JUMP_IF_FALSE:
            if not regs[a]:
                pc = b
                continue
        elif op == JUMP_IF_TRUE:
            if regs[a]:
                pc = b
                continue

        elif op == CALL:
            regs[a] = vm._call(regs[b], regs, b + 1, cc[pc])
        elif op == PRINT:
            vm._print(regs, a, b)
        elif op == RETURN:
            return regs[a]
        elif op == MAKE_FUNCTION:
            regs[a] = vm._make_function(consts[b], glb)
        elif op == MAKE_LIST:
            regs[a] = regs[b:b + cc[pc]]
        elif op == SUBSCR:
            regs[a] = regs[b][regs[cc[pc]]]
        elif op == LEN:
            regs[a] = len(regs[b])
        else:
            raise MinPythonError(f"unknown opcode: {op!r}")

        pc += 1
