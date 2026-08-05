/** <module> The pipeline, and the toolchain around it.
 *
 *      source -lex-> tokens -parse-> tree -check-> typed tree -lower-> CFG
 *             -ssa-> SSA -opt-> SSA -select-> machine IR -regalloc-> coloured
 *             -emit-> ARMv8
 *
 *  The pipeline is one relation, stopped where the caller wants to look: a
 *  dump is the pipeline halted, not a second description of it that has to be
 *  kept in step with the first.  `stop_at/3` is what halts it, and it is an
 *  ordinary goal that fails to be the identity when the stage has arrived.
 *
 *  Assembling and linking is left to a cross `gcc`, and running to
 *  `qemu-aarch64` when the machine underneath is not itself an ARM.
 */

:- module(driver,
          [ stages/1,             % -Stages
            options/4,            % ?Checks, ?Optimise, ?MaxRegs, ?Options
            default_options/1,
            to_ir/3,              % +Source, +Options, -Module
            compile_module/4,     % +Source, +Options, +Upto, -Module
            compile_to_asm/3,     % +Source, +Options, -Text
            stage/4,              % +Source, +Stage, +Options, -Text
            cross_cc/1, emulator/1, toolchain_ready/0,
            build/3,              % +Source, +Out, +Options
            run/4                 % +Source, +Options, +Stdin, -Outcome
          ]).

:- use_module(library(lists)).
:- use_module(library(process)).
:- use_module(allocator, []).
:- use_module(astshow, []).
:- use_module(dag, []).
:- use_module(emit, []).
:- use_module(ir, []).
:- use_module(lexer, []).
:- use_module(lower, []).
:- use_module(mach, []).
:- use_module(opt, []).
:- use_module(outofssa, []).
:- use_module(parser, []).
:- use_module(registers, []).
:- use_module(select, []).
:- use_module(ssa, []).
:- use_module(typecheck, []).

stages([tokens, ast, ir, ssa, opt, dag, mach, flat, ra, asm]).

options(Checks, Optimise, MaxRegs, options(Checks, Optimise, MaxRegs)).
default_options(options(true, true, none)).

machine_of(options(_, _, none), M) :- !, registers:whole_machine(M).
machine_of(options(_, _, N), M) :- registers:limited(N, M).

to_ir(Source, options(Checks, _, _), Module) :-
    parser:parse(Source, Decls),
    typecheck:check(Decls, Escapes),
    lower:lower(Decls, Escapes, Checks, Module).

%!  compile_module(+Source, +Options, +Upto, -Module) is det.

compile_module(Source, Options, Upto, Module) :-
    to_ir(Source, Options, M0),
    onward(ir, Upto, Options, M0, Module).

%   Each stage says what comes after it, and the first clause is where the
%   caller asked to stop.  There is one description of the order the passes
%   run in and not two.
onward(Here, Upto, _, M, M) :- Here == Upto, !.
onward(ir, Upto, Options, M0, Module) :- !,
    ssa:construct_module(M0, M1),
    onward(ssa, Upto, Options, M1, Module).
onward(ssa, Upto, Options, M0, Module) :- !,
    Options = options(_, Optimise, _),
    ( Optimise == true -> opt:optimise(M0, M1) ; M1 = M0 ),
    onward(opt, Upto, Options, M1, Module).
onward(opt, Upto, Options, module(Funcs0, Strings), Module) :- !,
    maplist(ssa:split_critical_edges, Funcs0, Funcs),
    %   The DAGs are a view of this, taken without changing it.
    onward(dag, Upto, Options, module(Funcs, Strings), Module).
onward(dag, Upto, Options, M0, Module) :- !,
    select:select_module(M0, M1),
    mach:verify_module(M1),
    onward(mach, Upto, Options, M1, Module).
onward(mach, Upto, Options, M0, Module) :- !,
    outofssa:destruct_module(M0, M1),
    onward(flat, Upto, Options, M1, Module).
onward(flat, _, Options, M0, Module) :-
    machine_of(Options, Machine),
    allocator:allocate_module(M0, Machine, Module).

compile_to_asm(Source, Options, Text) :-
    compile_module(Source, Options, asm, Module),
    emit:emit_module(Module, Text).

%!  stage(+Source, +Stage, +Options, -Text) is det.
%
%   Run the pipeline as far as Stage, and show what it has by then.

stage(Source, tokens, _, Text) :- !,
    lexer:lex(Source, Tokens),
    findall(Line,
            ( member(token(Kind, Written, span(L, C)), Tokens),
              lexer:kind_name(Kind, Name),
              format(atom(Line), '~d:~d\t~w\t~w', [L, C, Name, Written]) ),
            Lines),
    atomic_list_concat(Lines, '\n', Atom),
    atom_string(Atom, Text).
stage(Source, ast, _, Text) :- !,
    parser:parse(Source, Decls),
    typecheck:check(Decls, Escapes),
    astshow:show_program(Decls, Escapes, Text).
stage(Source, dag, Options, Text) :- !,
    compile_module(Source, Options, dag, module(Funcs, _)),
    findall(Part, ( member(F, Funcs), function_dags(F, Part) ), Parts),
    atomic_list_concat(Parts, '\n\n', Atom),
    format(string(Text), '~w\n', [Atom]).
stage(Source, asm, Options, Text) :- !,
    compile_to_asm(Source, Options, Text).
stage(Source, Stage, Options, Text) :-
    compile_module(Source, Options, Stage, Module),
    ir:show_module(Module, Text).

function_dags(F, Part) :-
    ir:func_label(F, Label),
    select:graphs(F, Pairs),
    findall(Block,
            ( member(BlockLabel-Dag, Pairs), dag:show(Dag, Shown),
              format(atom(Block), '~w:\n~w', [BlockLabel, Shown]) ),
            Blocks),
    atomic_list_concat(Blocks, '\n', Body),
    format(atom(Part), 'fun ~w\n~w', [Label, Body]).

%   -- the toolchain ----------------------------------------------------------

arm_host :-
    current_prolog_flag(arch, Arch),
    ( sub_atom(Arch, 0, _, _, aarch64) -> true ; sub_atom(Arch, 0, _, _, arm64) ).

cross_cc(Cc) :-
    getenv('WOLV_CC', Override), Override \== '', !, Cc = Override.
cross_cc(Cc) :-
    member(Name, ['aarch64-linux-gnu-gcc', 'aarch64-linux-gnu-cc',
                  'aarch64-none-linux-gnu-gcc']),
    which(Name, Cc), !.
cross_cc(Cc) :-
    arm_host, member(Name, [cc, gcc]), which(Name, Cc), !.
cross_cc(_) :-
    throw(toolchain_error(
              'no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC')).

emulator([]) :- arm_host, !.
emulator([Qemu]) :-
    member(Name, ['qemu-aarch64', 'qemu-aarch64-static']),
    which(Name, Qemu), !.
emulator(_) :-
    throw(toolchain_error('no qemu-aarch64 found, and this machine is not an ARM')).

which(Name, Path) :-
    catch(absolute_file_name(path(Name), Path, [access(execute)]), _, fail).

toolchain_ready :-
    catch(( cross_cc(_), emulator(_) ), _, fail).

runtime_path(Path) :-
    module_property(driver, file(Here)),
    file_directory_name(Here, Src),
    file_directory_name(Src, Root),
    atomic_list_concat([Root, '/runtime/runtime.c'], Path).

build(Source, Out, Options) :-
    compile_to_asm(Source, Options, Asm),
    %   The name has to end in `.s`, or the assembler takes it for an object.
    tmp_file_stream(text, Stem, Handle), close(Handle), delete_file(Stem),
    atom_concat(Stem, '.s', Path),
    setup_call_cleanup(open(Path, write, Stream), write(Stream, Asm), close(Stream)),
    cross_cc(Cc), runtime_path(Runtime),
    process_create(Cc, ['-static', '-O2', '-o', Out, file(Path), file(Runtime)],
                   [stderr(pipe(Err)), process(Pid)]),
    read_string(Err, _, Complaint), close(Err),
    process_wait(Pid, Status),
    delete_file(Path),
    (   Status == exit(0)
    ->  true
    ;   format(atom(M), 'the assembler refused it:\n~w', [Complaint]),
        throw(toolchain_error(M))
    ).

%!  run(+Source, +Options, +Stdin, -Outcome) is det.
%
%   Outcome is `outcome(Status, Out, Err)`.

run(Source, Options, Stdin, outcome(Status, Out, Err)) :-
    tmp_file_stream(binary, Binary, Handle), close(Handle),
    delete_file(Binary),
    setup_call_cleanup(
        build(Source, Binary, Options),
        emulate(Binary, Stdin, Status, Out, Err),
        catch(delete_file(Binary), _, true)).

emulate(Binary, Stdin, Status, Out, Err) :-
    emulator(Prefix),
    ( Prefix = [Qemu] -> Program = Qemu, Args = [file(Binary)]
    ; Program = Binary, Args = [] ),
    process_create(Program, Args,
                   [stdin(pipe(In)), stdout(pipe(OutStream)),
                    stderr(pipe(ErrStream)), process(Pid)]),
    write(In, Stdin), close(In),
    read_string(OutStream, _, Out), close(OutStream),
    read_string(ErrStream, _, Err), close(ErrStream),
    process_wait(Pid, Exit),
    ( Exit = exit(Status) -> true ; Status = 1 ).
