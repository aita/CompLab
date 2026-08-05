:- begin_tests(programs).

%   End to end: compile to ARMv8, assemble, link, and run it.
%
%   These are the only tests that need a toolchain.  Without a cross `gcc` and
%   `qemu-aarch64` they say so and carry on, so the rest of the suite still
%   runs on a machine that has neither.

:- use_module('../src/driver', []).

lines(Parts, Source) :- atomic_list_concat(Parts, '\n', A), atom_string(A, Source).

configuration("default", Options) :- driver:options(true, true, none, Options).
configuration("no-opt", Options) :- driver:options(true, false, none, Options).
configuration("no-checks", Options) :- driver:options(false, true, none, Options).
configuration("spilling", Options) :- driver:options(true, true, 12, Options).
configuration("spilling-no-opt", Options) :- driver:options(true, false, 12, Options).

wol_files(Directory, Files) :-
    atom_concat(Directory, '*.wol', Pattern),
    expand_file_name(Pattern, Unsorted),
    msort(Unsorted, Files).

ran(Source, Options, Out) :-
    driver:run(Source, Options, "", outcome(Status, Out, Err)),
    ( Status =:= 0 -> true ; throw(program_failed(Status, Err)) ).

expected_output(Path, Want) :-
    file_name_extension(Base, _, Path),
    file_name_extension(Base, out, OutPath),
    read_file_to_string(OutPath, Want, []).

test('every option gives the same answer; only the code differs') :-
    (   \+ driver:toolchain_ready
    ->  format(user_error, '~N  (skipped: no ARM toolchain)~n', [])
    ;   wol_files('test/programs/', Files),
        forall(( member(Path, Files), configuration(_, Options) ),
               ( read_file_to_string(Path, Source, []),
                 expected_output(Path, Want),
                 ran(Source, Options, Want) ))
    ).

test('the examples agree with themselves') :-
    %   No expected output on file: what matters is that the stages agree.
    (   \+ driver:toolchain_ready
    ->  true
    ;   wol_files('examples/', Files),
        forall(member(Path, Files),
               ( read_file_to_string(Path, Source, []),
                 driver:default_options(Default),
                 ran(Source, Default, Baseline),
                 string_length(Baseline, N), N > 0,
                 forall(( configuration(Name, Options), Name \== "default",
                          Name \== "no-checks" ),
                        ran(Source, Options, Baseline)) ))
    ).

test('the checks catch what they are for') :-
    (   \+ driver:toolchain_ready
    ->  true
    ;   forall(member(Source-Message, ["val a = array (3, 0)\nval () = printInt (a[5])"
                                       -"outside an array",
                                       "type t = { x : int }\nval n : t = nil\nval () = printInt (n.x)"
                                       -"field of nil",
                                       "var z = 0\nval () = printInt (7 / z)"
                                       -"division by zero"]),
               ( driver:default_options(Options),
                 driver:run(Source, Options, "", outcome(1, _, Err)),
                 sub_string(Err, _, _, _, Message) ))
    ).

test('a check can be turned off') :-
    (   \+ driver:toolchain_ready
    ->  true
    ;   lines(['val a = array (3, 0)', 'val () = printInt (a[1])'], Source),
        driver:options(false, true, none, Options),
        ran(Source, Options, "0")
    ).

test('standard input') :-
    (   \+ driver:toolchain_ready
    ->  true
    ;   lines(['var line = ""',
               'var c = getChar ()',
               'val () = while c <> "" andalso c <> "\\n" do (line := line ^ c; c := getChar ())',
               'val () = print ("read: " ^ line ^ " (" ^ intToString (size (line)) ^ ")\\n")'],
              Source),
        driver:default_options(Options),
        driver:run(Source, Options, "hello\n", outcome(0, Out, _)),
        Out == "read: hello (5)\n"
    ).

test('the exit code is the program\'s') :-
    (   \+ driver:toolchain_ready
    ->  true
    ;   driver:default_options(Options),
        driver:run("val () = (print (\"bye\\n\"); exit (3))", Options, "",
                   outcome(3, "bye\n", _))
    ).

:- end_tests(programs).
