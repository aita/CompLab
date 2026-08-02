# Ermine

A Forth.  The kernel is 60 primitives and 23 constants in C; the other 210
words of the system — the compiler, every control structure, the defining
words, `CATCH`, the number formatter, the decompiler, and the outer
interpreter you type at — are Forth, in [`lib/core.erm`](lib/core.erm).

```forth
: square dup * ;
: my-constant create , does> @ ;
: unless postpone 0= postpone if ; immediate compile-only

299792458 my-constant c
: classify dup 0< unless ." not " then ." negative" cr ;
```

```
$ make
$ ./ermine
Ermine Forth
  16713456 bytes free, dispatch threaded
6 7 * . cr
42
 ok
: square dup * ;
 ok
see square
: square dup * ;
 ok
' square 2 cells + @ .xt cr
*
 ok
```

```sh
make                          # ermine, and ermine-switch for the comparison
make test                     # 186 assertions, five golden outputs, an image
make bench
./ermine examples/tour.erm    # what is peculiar to Forth, in seven parts
./ermine examples/mandel.erm
echo '6 7 * . cr' | ./ermine
./ermine -e '." hi" cr bye'
```

## What is in the kernel and what is not

The dividing line is not "what is hard to write in Forth" but "what cannot be
written in Forth yet".  The kernel holds the inner interpreter, the primitives
it dispatches, and an outer interpreter that exists only to read `core.erm`
once.  Everything a Forth programmer thinks of as the language is above the
line:

| in `src/ermine.c` | in `lib/core.erm` |
|---|---|
| the inner interpreter and 60 primitives | `IF` `THEN` `ELSE` `BEGIN` `WHILE` `REPEAT` `DO` `LOOP` `+LOOP` `LEAVE` `CASE` |
| the header format, once, for its own words | `HEADER,` — the same format, for every other word |
| `:` and `;`, to compile the first 200 lines | `:` and `;`, which compile the rest |
| `REFILL`, `SOURCE`, `>IN` | `PARSE-NAME` `FIND-NAME` `INTERPRET` `QUIT` `EVALUATE` `INCLUDED` |
| `UM/MOD` `S/REM` | `/MOD` `MOD` `*/` `FM/MOD` `SM/REM` |
| `SP@` `SP!` `RP@` `RP!` | `CATCH` and `THROW` |
| `EMIT` `TYPE` | `.` `U.` `.R` `<# # #S #>` |
| `(SAVE-IMAGE)` | `SEE` `WORDS` `.S` `DUMP` |

`:` appears twice on purpose.  The kernel's pair is what compiles the first two
hundred lines of `core.erm`, up to the point where those lines have built
`HEADER,` out of `PARSE-NAME`, `,`, `C,`, `MOVE` and `ALIGN`.  From there the
Forth pair shadows it and compiles everything else, including everything you
type afterwards.

## The system is one array

The dictionary, the data space, both stacks and the input buffers are all
offsets into a single `calloc`ed block.  Nothing a Forth program can name lives
outside it, which is why `@` and `!` can be checked with one comparison, and
why saving the whole system is one `fwrite`:

```
$ ./ermine
: hi ." hello from an image" cr ;
s" my.img" save-image
bye
$ ./ermine --image my.img
hi
hello from an image
```

A saved image records the hash of the primitive table that built it and is
refused by a kernel with a different one.

## Two inner interpreters

`ermine` gets from one word to the next with a computed goto pasted in at the
end of every primitive; `ermine-switch` is the same kernel, the same primitives
and the same `core.erm` with `-DERMINE_SWITCH`, which makes it a `switch` in a
loop.  `make bench` runs both:

```
dispatch: computed goto          dispatch: switch
3M iterations of DO   156011     3M iterations of DO   266410
fib 28, recursively    19445     fib 28, recursively    30563
2M stack shuffles     116343     2M stack shuffles     248691
```

The difference is not the indirect jump — a `switch` compiles to one of those
too — but that the threaded build has sixty of them, one per primitive, so the
branch predictor can learn which word tends to follow which.

## The language

Cells are 64 bits and signed.  Names are case sensitive and at most 31
characters.  `/MOD`, `/` and `MOD` floor; `S/REM` truncates towards zero.
Numbers may be prefixed `$` for hex, `#` for decimal, `%` for binary, or
written `'c'` for a character.  `?NUMBER` reads one cell, not two, so there is
no `>NUMBER` and no double-cell literals — `UM*`, `UM/MOD`, `M*` and `*/` are
there because the number formatter and `*/` need a double intermediate, not
because `2VARIABLE` exists.

Control structures are marked compile-only and say so rather than quietly
compiling a branch into nothing:

```
5 0 do i . loop
compile only: do
```

Documentation is in [`doc/`](doc/index.md), a chapter per concern, in Japanese.

## Files

```
src/ermine.c      the kernel: image, stacks, inner interpreter, primitives,
                  and the outer interpreter that reads core.erm once
lib/core.erm      the system
examples/         sieve, mandelbrot, life, a tour, a benchmark
tests/            186 assertions in Forth, golden outputs, an image round trip
doc/              the book
```
