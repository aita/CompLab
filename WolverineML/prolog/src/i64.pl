/** <module> Sixty-four bit arithmetic.
 *
 *  Prolog's integers are the mathematical ones, which is the right default and
 *  the wrong width: the language this compiles has an `int` that is eight
 *  bytes and wraps.  So every operation the optimiser folds comes back through
 *  wrap/2, and the shifts say for themselves what happens past sixty-three
 *  rather than leaving it to the host.
 *
 *  `//` and `rem` already round towards zero, which is what `sdiv` and `msub`
 *  do, so the two operations that usually need care need none.
 *
 *  Every predicate here is a relation that can fail: i64_shl/3 with a negative
 *  amount has no answer, and i64_arith/4 with a divisor of zero has none
 *  either, which is exactly what the optimiser wants to hear.
 */

:- module(i64,
          [ wrap/2,               % +N, -Wrapped
            unsigned/2,           % +N, -Bits
            i64_arith/4,          % +Op, +A, +B, -Value
            i64_order/3           % +Op, +A, +B   (semidet)
          ]).

width(64).
span(S) :- S is 1 << 64.
max(M) :- M is (1 << 63) - 1.

%!  wrap(+N, -Wrapped) is det.
%
%   The value N has once it is kept in sixty-four bits.

wrap(N, Wrapped) :-
    span(Span), max(Max),
    M is N mod Span,
    ( M > Max -> Wrapped is M - Span ; Wrapped = M ).

%!  unsigned(+N, -Bits) is det.
%
%   The same bits read as unsigned, which is what `u<` and `u>=` compare.

unsigned(N, Bits) :- span(Span), Bits is N mod Span.

%!  i64_arith(+Op, +A, +B, -Value) is semidet.
%
%   Fails where the operation has no answer: a division by zero, a shift by a
%   negative amount, or an operator this machine does not have.

i64_arith(+, A, B, V) :- !, X is A + B, wrap(X, V).
i64_arith(-, A, B, V) :- !, X is A - B, wrap(X, V).
i64_arith(*, A, B, V) :- !, X is A * B, wrap(X, V).
i64_arith(/, A, B, V) :- !, B =\= 0, X is A // B, wrap(X, V).
i64_arith(mod, A, B, V) :- !, B =\= 0, X is A rem B, wrap(X, V).
i64_arith(and, A, B, V) :- !, bits(A, X), bits(B, Y), Z is X /\ Y, wrap(Z, V).
i64_arith(or, A, B, V) :- !, bits(A, X), bits(B, Y), Z is X \/ Y, wrap(Z, V).
i64_arith(xor, A, B, V) :- !, bits(A, X), bits(B, Y), Z is X xor Y, wrap(Z, V).
i64_arith(shl, A, B, V) :- !, i64_shl(A, B, V).
i64_arith(shr, A, B, V) :- !, i64_shr(A, B, V).

bits(N, Bits) :- unsigned(N, Bits).

%   A shift of sixty-four or more is not the host's business to decide.
i64_shl(_, B, _) :- B < 0, !, fail.
i64_shl(_, B, 0) :- width(W), B >= W, !.
i64_shl(A, B, V) :- X is A << B, wrap(X, V).

i64_shr(_, B, _) :- B < 0, !, fail.
i64_shr(A, B, V) :- width(W), B >= W, !, ( A < 0 -> V = -1 ; V = 0 ).
i64_shr(A, B, V) :- V is A >> B.

%!  i64_order(+Op, +A, +B) is semidet.

i64_order(=, A, B) :- A =:= B.
i64_order(<>, A, B) :- A =\= B.
i64_order(<, A, B) :- A < B.
i64_order(<=, A, B) :- A =< B.
i64_order(>, A, B) :- A > B.
i64_order(>=, A, B) :- A >= B.
i64_order('u<', A, B) :- unsigned(A, X), unsigned(B, Y), X < Y.
i64_order('u>=', A, B) :- unsigned(A, X), unsigned(B, Y), X >= Y.
