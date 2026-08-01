# frozen_string_literal: true

module Wolv
  # Sixty-four bit arithmetic.
  #
  # Ruby's integers are exact and unbounded, which is the right default and the
  # wrong width: the language this compiles has a 64-bit `int` that wraps.  So
  # every operation that can leave the range comes back through `wrap`, the two
  # that round say which way they round, and the shifts say what they do past 63
  # rather than leaving it to the host.
  module I64
    WIDTH = 64
    SPAN = 1 << WIDTH
    MIN = -(1 << (WIDTH - 1))
    MAX = (1 << (WIDTH - 1)) - 1

    module_function

    # The value `n` has when it is kept in 64 bits.
    def wrap(n)
      m = n % SPAN
      m > MAX ? m - SPAN : m
    end

    # The same bits read as unsigned, which is what `u<` and `u>=` compare.
    def unsigned(n) = n % SPAN

    def add(a, b) = wrap(a + b)
    def sub(a, b) = wrap(a - b)
    def mul(a, b) = wrap(a * b)

    # `sdiv` truncates towards zero, and `min_int / -1` wraps to `min_int`.
    # Ruby's `/` floors, so this is not it.
    def quotient(a, b)
      magnitude = a.abs / b.abs
      wrap((a.negative? == b.negative?) ? magnitude : -magnitude)
    end

    def remainder(a, b) = wrap(a - (quotient(a, b) * b))

    def and_(a, b) = wrap(unsigned(a) & unsigned(b))
    def or_(a, b) = wrap(unsigned(a) | unsigned(b))
    def xor(a, b) = wrap(unsigned(a) ^ unsigned(b))

    # A shift of 64 or more is not the host's business to decide, and here it
    # would build a very large exact integer on the way to deciding it.
    def shl(a, b)
      return nil if b.negative?

      b >= WIDTH ? 0 : wrap(a << b)
    end

    def shr(a, b)
      return nil if b.negative?

      b >= WIDTH ? (a.negative? ? -1 : 0) : a >> b
    end
  end
end
