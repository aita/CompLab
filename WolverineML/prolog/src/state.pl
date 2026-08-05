/** <module> A pass with state, as a grammar.
 *
 *  Several passes here carry something along: the checker its scopes, the
 *  lowering its half-built function, the allocator twenty worklists.  Prolog's
 *  way to thread a value through a sequence of goals without naming it twice
 *  at every step is the same notation it uses for parsing -- a DCG whose
 *  "list" is one item long and is the state.
 *
 *      emit(Instr) --> get_via(lw_cur, Label), { ... }, set_via(set_func_of_lw, F).
 *
 *  is `S1 = S0.emit(I)` written so that S0 and S1 do not have to be named.
 *  Nothing is mutated: each step answers with the next state, and the DCG is
 *  what hands it on.
 *
 *  The state itself is a term declared with library(record), so `get_via` and
 *  `set_via` take the accessor the declaration generated.  Naming it at the
 *  call site is what says which record is being read, which a dict would leave
 *  to the reader to remember.
 */

:- module(state,
          [ get_state//1,         % -State
            put_state//1,         % +State
            get_via//2,           % :Accessor, -Value
            set_via//2,           % :Setter, +Value
            fold//2,              % :Goal, +List
            fold//3               % :Goal, +List, -Results
          ]).

:- meta_predicate
       get_via(2, -, ?, ?),
       set_via(3, +, ?, ?),
       fold(3, +, ?, ?),
       fold(4, +, -, ?, ?).

get_state(S), [S] --> [S].
put_state(S), [S] --> [_].

get_via(Accessor, Value) --> get_state(S), { call(Accessor, S, Value) }.

set_via(Setter, Value) -->
    get_state(S0), { call(Setter, Value, S0, S) }, put_state(S).

%!  fold(:Goal, +List)// is det.
%
%   Run Goal over each item, threading the state.  `maplist//2` would do, but
%   this one says in its name that the state is what is being folded.

fold(_, []) --> [].
fold(Goal, [X|Xs]) --> call(Goal, X), fold(Goal, Xs).

fold(_, [], []) --> [].
fold(Goal, [X|Xs], [Y|Ys]) --> call(Goal, X, Y), fold(Goal, Xs, Ys).
