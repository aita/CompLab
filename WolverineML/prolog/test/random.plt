:- begin_tests(random).

%   Random programs, compiled and checked against what the oracle says they mean.

:- use_module('oracle', []).
:- use_module('../src/driver', []).

configuration("default", Options) :- driver:options(true, true, none, Options).
configuration("no-opt", Options) :- driver:options(true, false, none, Options).
configuration("spilling", Options) :- driver:options(true, true, 10, Options).

%   The first line that differs is the useful part of the answer.
agrees(Source, Expected, Options, What) :-
    driver:run(Source, Options, "", outcome(Status, Out, Err)),
    ( Status =:= 0 -> true ; throw(program_failed(What, Status, Err)) ),
    split_string(Out, "\n", "", Got),
    split_string(Expected, "\n", "", Want),
    ( Got == Want -> true ; throw(disagreed(What, Got, Want)) ).

test(arithmetic) :-
    (   \+ driver:toolchain_ready
    ->  format(user_error, '~N  (skipped: no ARM toolchain)~n', [])
    ;   forall(( member(Seed, [1, 2]), configuration(Name, Options) ),
               ( oracle:arithmetic(Seed, 25, Source, Expected),
                 format(atom(What), 'arithmetic ~d [~w]', [Seed, Name]),
                 agrees(Source, Expected, Options, What) ))
    ).

test('arrays, loops and branches') :-
    (   \+ driver:toolchain_ready
    ->  true
    ;   forall(( member(Seed, [1, 2]), configuration(Name, Options) ),
               ( oracle:imperative(Seed, 8, Source, Expected),
                 format(atom(What), 'imperative ~d [~w]', [Seed, Name]),
                 agrees(Source, Expected, Options, What) ))
    ).

test('a cycle of copies can be done without a scratch register') :-
    %   The recursive call swaps its two arguments, so the copies into `x0` and
    %   `x1` are a cycle that has to be untangled somehow.  The borrowed
    %   register is what usually hides the other path.
    (   \+ driver:toolchain_ready
    ->  true
    ;   Source = "fun swap (a : int, b : int) : int =\n  if a > b then swap (b, a) else b * 10 + a\nval () = (printInt (swap (1, 2)); print (\" \"); printInt (swap (7, 3)))\n",
        driver:default_options(Options),
        driver:run(Source, Options, "", outcome(0, "21 73", _)),
        setup_call_cleanup(
            ( retractall(emit:borrow_nothing(_)), assertz(emit:borrow_nothing(true)) ),
            ( driver:compile_to_asm(Source, Options, Text),
              sub_string(Text, _, _, _, "eor x"),
              driver:run(Source, Options, "", outcome(0, "21 73", _)) ),
            ( retractall(emit:borrow_nothing(_)), assertz(emit:borrow_nothing(false)) ))
    ).

:- end_tests(random).
