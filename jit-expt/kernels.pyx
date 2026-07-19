# cython: language_level=3, boundscheck=False, wraparound=False
#
# Cython comparison kernels, kept on the same footing as the hand-written JIT:
# `noexcept` so Cython emits a bare C function with no exception-propagation
# checks (the `cmp rax, -1` the JIT doesn't have either), and plain machine
# integer types -- native code vs native code, apples to apples.

# collatz: scalar loop + branch axis (no calls, not vectorizable). Sum of the
# 3n+1 step counts for x = 1..n. `long` because intermediate values exceed 2^32
# but stay well under 2^63, so every implementation agrees exactly (no wrap).
cpdef long collatz_cy(long n) noexcept:
    cdef long total = 0
    cdef long x, y
    for x in range(1, n + 1):
        y = x
        while y != 1:
            if y & 1:
                y = 3 * y + 1
            else:
                y >>= 1
            total += 1
    return total
