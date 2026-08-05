/** <module> The command line.
 *
 *  A compile error is a thrown term, so the whole of the error handling is one
 *  `catch/3` around the command.
 */

:- module(cli, [main/1]).               % +Argv

:- use_module(library(lists)).
:- use_module(diag, []).
:- use_module(driver, []).

usage("wolv -- compile WolverineML to ARMv8

  wolv build  FILE [-o OUT]   build an executable
  wolv run    FILE            build it and run it
  wolv check  FILE            typecheck only
  wolv emit   FILE [-s STAGE] dump one stage

  -s, --stage STAGE   one of: tokens ast ir ssa opt dag mach flat ra asm
  --no-checks         leave out the nil, bounds and divide-by-zero checks
  --no-opt            do not optimise the SSA
  --max-regs N        pretend the machine has this many registers
").

main(Argv) :-
    catch(( parse_arguments(Argv, Args), dispatch(Args) ),
          Error,
          ( report(Error), halt(1) )).

parse_arguments(Argv, args(Command, File, Out, Stage, Checks, Optimise, MaxRegs)) :-
    walk(Argv, [], Positional, none-asm-true-true-none,
         Out-Stage-Checks-Optimise-MaxRegs),
    (   Positional = [Command, File],
        memberchk(Command, [build, run, check, emit])
    ->  true
    ;   usage(Usage), throw(usage(Usage))
    ).

walk([], Acc, Positional, Flags, Flags) :- reverse(Acc, Positional).
walk(['-o'|[Value|Rest]], Acc, P, _-S-C-O-M, Flags) :- !,
    walk(Rest, Acc, P, Value-S-C-O-M, Flags).
walk(['--out'|[Value|Rest]], Acc, P, F, Flags) :- !,
    walk(['-o', Value|Rest], Acc, P, F, Flags).
walk(['-s'|[Value|Rest]], Acc, P, Out-_-C-O-M, Flags) :- !,
    ( driver:stages(Stages), memberchk(Value, Stages) -> true
    ; format(atom(Message), 'no such stage as `~w`', [Value]),
      throw(bad_argument(Message)) ),
    walk(Rest, Acc, P, Out-Value-C-O-M, Flags).
walk(['--stage'|[Value|Rest]], Acc, P, F, Flags) :- !,
    walk(['-s', Value|Rest], Acc, P, F, Flags).
walk(['--no-checks'|Rest], Acc, P, Out-S-_-O-M, Flags) :- !,
    walk(Rest, Acc, P, Out-S-false-O-M, Flags).
walk(['--no-opt'|Rest], Acc, P, Out-S-C-_-M, Flags) :- !,
    walk(Rest, Acc, P, Out-S-C-false-M, Flags).
walk(['--max-regs'|[Value|Rest]], Acc, P, Out-S-C-O-_, Flags) :- !,
    atom_number(Value, N),
    walk(Rest, Acc, P, Out-S-C-O-N, Flags).
walk([Arg|_], _, _, _, _) :-
    atom_concat('-', _, Arg), Arg \== '-', !,
    format(atom(Message), 'unknown option `~w`', [Arg]),
    throw(bad_argument(Message)).
walk([Arg|Rest], Acc, P, F, Flags) :- walk(Rest, [Arg|Acc], P, F, Flags).

dispatch(args(Command, File, Out, Stage, Checks, Optimise, MaxRegs)) :-
    read_file_to_string(File, Source, []),
    driver:options(Checks, Optimise, MaxRegs, Options),
    catch(perform(Command, Source, File, Out, Stage, Options),
          wolv_error(Kind, Span, Message),
          ( diag:error_text(wolv_error(Kind, Span, Message), Text),
            format(user_error, '~w:~w~n', [File, Text]),
            halt(1) )).

perform(check, Source, _, _, _, Options) :- driver:to_ir(Source, Options, _).
perform(emit, Source, _, _, Stage, Options) :-
    driver:stage(Source, Stage, Options, Text),
    write(Text).
perform(build, Source, File, Out0, _, Options) :-
    ( Out0 == none -> default_output(File, Out) ; Out = Out0 ),
    driver:build(Source, Out, Options).
perform(run, Source, _, _, _, Options) :-
    read_stdin(Stdin),
    driver:run(Source, Options, Stdin, outcome(Status, Out, Err)),
    write(Out), write(user_error, Err),
    flush_output, flush_output(user_error),
    halt(Status).

default_output(File, Out) :-
    file_name_extension(Base, _, File), Out = Base.

read_stdin(Text) :-
    (   stream_property(user_input, tty(true))
    ->  Text = ""
    ;   read_string(user_input, _, Text)
    ).

report(usage(Usage)) :- !, write(user_error, Usage).
report(bad_argument(Message)) :- !, format(user_error, 'wolv: ~w~n', [Message]).
report(toolchain_error(Message)) :- !, format(user_error, 'wolv: ~w~n', [Message]).
report(out_of_registers(Message)) :- !, format(user_error, 'wolv: ~w~n', [Message]).
report(error(existence_error(source_sink, File), _)) :- !,
    format(user_error, 'wolv: no such file as ~w~n', [File]).
report(Error) :- print_message(error, Error).
