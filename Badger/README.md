# Badger

A Prolog, and an interpreter for it in OCaml.

Badger is a resolution engine: unification with a trail, clauses tried in
order, backtracking, and the cut. It reads ISO-ish Prolog with a
runtime-mutable operator table, has definite clause grammars, exceptions,
`assert`/`retract` under the logical update view, and enough built-in
predicates that the list library is written in Prolog rather than in OCaml.

```prolog
houses(Houses) :-
    Houses = [h(_,norwegian,_,_,_), _, h(_,_,_,milk,_), _, _],
    member(h(red,englishman,_,_,_), Houses),
    right_of(h(green,_,_,_,_), h(ivory,_,_,_,_), Houses),
    next_to(h(_,norwegian,_,_,_), h(blue,_,_,_,_), Houses),
    member(h(_,_,zebra,_,_), Houses).
```

There is no search written down there. The clues are partially known houses,
unification fills in what it can, and the engine does the rest — which is the
whole reason to write a Prolog rather than read about one.

- [`doc/`](doc/index.md) — the chapter-per-concern write-up, in Japanese, with
  the real traces and database dumps pasted in:
  [質問が探索になるまで](doc/00-overview.md) ·
  [項と束縛とトレイル](doc/01-term.md) ·
  [読み取り](doc/02-read.md) · [書き出し](doc/03-write.md) ·
  [節をしまう](doc/04-db.md) · [導出](doc/05-solve.md) ·
  [カットとバリア](doc/06-cut.md) · [組み込み述語と例外](doc/07-builtins.md) ·
  [文法](doc/08-dcg.md) · [ライブラリを Prolog で書く](doc/09-library.md) ·
  [WAM まであとどれくらいか](doc/10-wam.md)。
- [`interpreter/examples/`](interpreter/examples) — programs to read, starting
  with `tour.pl`.
- [`interpreter/tests/features.pl`](interpreter/tests/features.pl) — one line
  of output per thing that is supposed to work, which is also the reference for
  what is supported.

## Build and run

```sh
cd interpreter
dune build                                  # builds _build/default/src/badger.exe
dune exec src/badger.exe examples/tour.pl
dune test                                   # golden tests (dune test --auto-promote to update)
```

With a file, Badger consults it and exits, so a program is a file whose last
directive does something:

```prolog
:- initialization(main).

main :- format("hello, badger~n").
```

With no file it reads queries from standard input:

```
$ dune exec src/badger.exe
?- member(X, [a,b,c]).
X = a ;
X = b ;
X = c.
?- length(L, 2).
L = [_G372,_G371].
```

Answers are printed one behind the search, because only the arrival of the next
answer says that the last one was not final.

```
badger [options] [file ...]

  -g, --goal GOAL   run GOAL once after loading (may be repeated)
  -t, --toplevel    read queries even after loading files
  -q, --quiet       do not report singleton variables
  -T, --trace       report the Call/Exit/Redo/Fail of every predicate call
  -d, --dump-db     print the stored form of every clause, and stop
  -h, --help
```

`-T` is the four-port box model, on standard error so it does not mix into what
the program prints; `trace/0` and `notrace/0` switch it from inside a program.
`-d` shows what the loader made of each clause — variables as frame slots, and
the first-argument key the engine filters on.

```
$ badger -d anc.pl                       ancestor(X, Z) :- parent(X, Z).
% ancestor/2                             ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
  [any, 2 vars] ancestor(_L0,_L1) :- parent(_L0,_L1).
  [any, 3 vars] ancestor(_L0,_L1) :- ','(parent(_L0,_L2),ancestor(_L2,_L1)).
```

## The language

### Syntax

Standard Prolog syntax: terms, operators, lists, curly-brace terms, `0'c`
character codes, `0x`/`0o`/`0b` integers, `%` and `/* */` comments, and quoted
atoms with the usual escapes. `"..."` reads as a list of character codes unless
`set_prolog_flag(double_quotes, chars)` or `atom` says otherwise.

`op/3` and `current_op/3` work, and they work *while a file is being read*: a
directive runs as the loader meets it, so

```prolog
:- op(700, xfx, ===).

equivalent(A === B) :- A == B.
```

is read the way it looks. That is also why the reader is a hand-written
precedence climber rather than a menhir grammar — an LR table is built once, and
this one is not.

### Control

`,` `;` `->` `*->` `!` `\+` `call/1..8` `once/1` `ignore/1` `forall/2`
`between/3` `repeat/0` `true/0` `fail/0` `false/0`.

`!` cuts the predicate whose clause contains it. It is transparent through `,`
`;` and the *branches* of if-then-else, and opaque through `call/1`, `\+`, the
*condition* of if-then-else, `findall/3` and friends. `examples/cut.pl` is
about nothing else.

### Exceptions

`throw/1`, `catch/3`, and the ISO error terms: `instantiation_error`,
`type_error/2`, `domain_error/2`, `existence_error/2`, `permission_error/3`,
`evaluation_error/1`, `representation_error/1`, each wrapped in `error/2`.

### Unification, terms, order

`=` `\=` `unify_with_occurs_check/2`, `==` `\==` `@<` `@>` `@=<` `@>=`
`compare/3` `=@=` `\=@=`, `functor/3` `arg/3` `=../2` `copy_term/2`
`term_variables/2` `numbervars/3`, and the type tests `var` `nonvar` `atom`
`number` `integer` `float` `atomic` `compound` `callable` `is_list` `ground`.

### Arithmetic

`is/2` and `=:=` `=\=` `<` `>` `=<` `>=`, over integers and floats:

`+ - * / // div mod rem min max ** ^ >> << /\ \/ xor \ abs sign gcd sqrt sin
cos tan asin acos atan atan2 sinh cosh tanh exp log log2 msb succ float integer
float_integer_part float_fractional_part truncate round ceiling floor
copysign`, and the constants `pi e inf nan epsilon max_integer min_integer
random cputime`.

`/` on two integers is an integer when it divides exactly and a float
otherwise. `//` truncates toward zero and `div` toward negative infinity;
`rem` takes the sign of the dividend and `mod` the sign of the divisor. `**`
is always float, `^` on two integers stays integer.

### Atoms and text

`atom_length/2` `atom_chars/2` `atom_codes/2` `char_code/2` `atom_number/2`
`number_codes/2` `number_chars/2` `atom_concat/3` `sub_atom/5`
`atomic_list_concat/2,3` `upcase_atom/2` `downcase_atom/2` `term_to_atom/2`
`atom_to_term/3` `char_type/2` `code_type/2`.

`atom_concat/3` and `sub_atom/5` run backwards, enumerating every split and
every substring.

### Lists, sorting, all solutions

Built in: `length/2` `msort/2` `sort/2` `keysort/2` `findall/3,4`.

In the prelude, written in Prolog: `append/3` `member/2` `memberchk/2`
`reverse/2` `last/2` `nth0/3` `nth1/3` `select/3,4` `selectchk/3`
`permutation/2` `subtract/3` `intersection/3` `union/3` `delete/3`
`exclude/3` `include/3` `partition/4` `maplist/2..5` `foldl/4,5`
`sum_list/2` `max_list/2` `min_list/2` `max_member/2` `min_member/2`
`numlist/3` `list_to_set/2` `flatten/2` `pairs_keys_values/3` `predsort/3`
`bagof/3` `setof/3` `aggregate_all/3` `not/1` `writeln/1` `phrase/2,3`.

`bagof/3` and `setof/3` do group by their free variables, which is the whole
difference between them and `findall/3`:

```
?- bagof(V, pair(K, V), Bag).
K = a, Bag = [1,3] ;
K = b, Bag = [2].
```

### Grammars

`H --> B` is translated as the clause is read: every nonterminal gains the list
before it and the list after, terminals consume, and `{}/1` and `!` consume
nothing. `phrase/2` and `phrase/3` run a body, which need not be a bare
nonterminal. `examples/dcg.pl` is a calculator and an AST builder over the same
grammar, and shows the same nonterminal generating the strings it accepts.

### The database

`assert/1` `asserta/1` `assertz/1` `retract/1` `retractall/1` `abolish/1`
`clause/2` `dynamic/1` `current_predicate/1` `predicate_property/2`
`consult/1` `ensure_loaded/1`, and `:- [file].`

A call reads a predicate's clause list once, so a goal that asserts to or
retracts from the predicate it is iterating over sees the predicate as it was
when the call began.

### Output

`write/1` `print/1` `writeq/1` `write_canonical/1` `write_term/2` `nl/0`
`tab/1` `put_char/1` `portray_clause/1` `listing/1` `read/1` `read_term/2`
`format/1,2,3`, `halt/0,1`, `statistics/2`, `op/3`, `current_op/3`,
`set_prolog_flag/2`, `current_prolog_flag/2`, `trace/0`, `notrace/0`.

`format/2` supports `~w ~p ~q ~a ~d ~D ~e ~f ~g ~s ~n ~c ~r ~i ~t ~| ~+ ~~`
and `~*`. `format/3` writes to `atom(A)`, `codes(C)` or `chars(C)` instead of
to the output.

### What is not here

No modules, no tabling, no constraints, no attributed variables, no coroutining
(`freeze/2`), no streams beyond standard input and output, and no string type
distinct from atoms. Integers are OCaml's native `int` — 63 bits, no bignums.
Atoms are byte strings, so `atom_length/2` counts bytes and an escape above 255
becomes UTF-8 bytes. Cyclic terms can be built (there is an `occurs_check`
flag) but not printed or compared. `~t` in `format/2` is accepted and ignored:
column stops pad on the left rather than distributing fill.

## The interpreter

Of some three thousand lines, eleven hundred are built-in predicates and eight
hundred are the reader and the writer. The engine — terms, the trail, the
clause database and resolution — is six hundred, in four files.

### Terms and the trail — `term.ml`

A variable is a mutable cell. Binding one pushes it onto a global trail;
backtracking pops the trail down to a mark and empties those cells again. That
is the entire memory model — there is no cell heap to compact, because a clause
is copied afresh every time it is tried.

Unification leaves the bindings a failed attempt managed to make on the trail,
and every construct that offers alternatives undoes to its own mark before
trying the next one. Keeping it that way means `unify` itself needs no cleanup
path, and it is exactly the discipline a WAM enforces with choice points.

### Clauses — `db.ml`

A stored clause holds no variables. Where the source had one, the stored term
has `Local i`, an index into a frame; trying the clause means allocating a
frame of fresh variables and rebuilding the head and body against it. So each
attempt starts from a private copy.

Before that copy is built, the clause's first argument is compared against the
goal's as a single tag — the cheap half of what a WAM does with first-argument
indexing, and what keeps a predicate with fifty facts from copying fifty heads
to match one. Building the head at all is what a WAM's `get`/`unify`
instructions exist to avoid, and that is the obvious next thing this engine
does not do.

### Resolution — `solve.ml`, `engine.ml`

Solving a goal is a call that invokes a continuation once per solution and
returns when the goal has no more:

```ocaml
solve db goal barrier (fun () -> ...)
```

So backtracking is what happens when the continuation returns, and OCaml's own
stack is the choice point stack. Nothing about a returned-from stack frame is
reversible, which is why the cut needs its own channel out.

A cut has already produced its solutions by the time control comes back to it,
and what it must do then is discard the alternatives its predicate still had.
Those alternatives are OCaml stack frames, so the cut raises an exception naming
the frame that owns it, and every predicate call catches its own number and
returns quietly. That number is the barrier: it is what makes a cut in a clause
cut that clause's predicate and nothing outside it, and what makes `call/1`
opaque to cut, since `call/1` hands its goal a barrier of its own.

The one place this shape bites is `catch/3`. An error raised after `catch/3` has
already succeeded belongs to whatever comes next, not to the `catch` — but in a
continuation-passing engine the continuation runs inside the OCaml `try`. So
`catch/3` keeps a depth counter that records whether control is currently inside
the protected goal or out in its continuation, and only catches in the first
case.

The cost of using the host stack is that there is no last-call optimisation: a
deterministic recursion costs stack in proportion to its depth. The stack is
OCaml 5's growable fiber stack rather than the operating system's, so the
ceiling is high — a million-deep non-tail recursion runs, and the limit is
OCaml's `l` runtime parameter rather than `ulimit -s` — but it is a ceiling,
and the toplevel reports hitting it rather than crashing.

### Reading and writing — `lexer.mll`, `read.ml`, `write.ml`

Two details make the lexer more than a word splitter. `f(` and `f (` are
different — only the first is functor notation — so it remembers where the
previous token ended and reports a `(` starting exactly there as a distinct
token. And a `.` ends a clause when what follows is layout, a comment or the end
of the file, and is an ordinary symbolic atom otherwise, so `1.5`, `X = '.'` and
`a. ` all come out right.

The reader climbs priorities rather than consulting a table. Two numbers do the
work: the highest-priority operator this position may contain, and the priority
each parsed term reports back, which is 0 for anything bracketed or atomic.
Arguments and list elements are read at 999, one below the priority of `,`,
which is exactly why a comma can separate them.

The writer's job is that whatever `writeq/1` prints, the reader reads back as
the same term. Priority accounts for the brackets in `a*(b+c)`; adjacency
accounts for the rest, and it is subtler. `-(1)` printed as `-1` comes back as
an integer, and `-(','(1,2))` printed as `-(1,2)` comes back with the wrong
arity, so the writer prints `- 1` and `- (1,2)`. `features.pl` checks the
round trip on the awkward cases.

### The library — `prelude.ml`

The list predicates are Prolog source, consulted at startup like any other
file. They could have been written in OCaml and are not, because they are
shorter and clearer as clauses — and because a library written in the language
is the best evidence that the language works.

## Tests

`dune test` runs golden tests: `features.pl`, every example, a set of queries
fed through the toplevel, and a directory of programs that are expected to
fail, whose diagnostics go into one file. `dune test --auto-promote` updates
them.
