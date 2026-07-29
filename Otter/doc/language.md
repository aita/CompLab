# The Otter language

Otter is statically typed and does no type inference: every variable,
parameter and result says what it is. There are no implicit conversions of any
kind, so a number changes type only where the program says `as`.

The grammar in [`../interpreter/grammar/Otter.g4`](../interpreter/grammar/Otter.g4)
is the last word on the syntax. This document says what the syntax means.

## A program

A file is a module, and its first line says so. Everything else is a
declaration.

```
module main;

import io;

fun main() -> int {
    io.println("hello");
    return 0;
}
```

The module a program is started from must declare `fun main() -> int`, taking
no arguments. What it returns is the exit status. `-> void` is accepted too,
and exits with 0.

## Modules

A module is named after its file: `module geometry;` lives in `geometry.otter`.
Modules are found beside the file the program was started from.

`import` makes another module reachable. There is no wildcard import and
nothing is brought into scope implicitly, so every use of another module's
names is spelled out.

```
import geometry;

var here: geometry.Point = geometry.origin();
```

A declaration is visible only inside its own module unless it says `export`.

```
export struct Point { x: float64; y: float64; }
export fun origin() -> Point { return new Point { x: 0.0, y: 0.0 }; }
```

Modules may not import one another in a cycle. Within a module, order does not
matter: functions may call functions declared later, and a struct may mention a
struct declared later.

Four modules are built in and need no file:
[`io`, `str`, `math` and `gc`](#built-in-modules).

## Types

| type | what it holds |
| --- | --- |
| `void` | nothing; only a function result can be void |
| `bool` | `true` or `false` |
| `int` | a whole number, 64 bits, signed, wrapping on overflow |
| `byte` | a whole number, 8 bits, unsigned, wrapping on overflow |
| `char` | one Unicode scalar value, held in 32 bits |
| `float32` | an IEEE binary32 number |
| `float64` | an IEEE binary64 number |
| `string` | an immutable run of UTF-8 bytes |
| `array<T>` | a run of values of one type, its length fixed when it is made |
| `*T` | the address of a `T`, or `null` |
| `fun(A, B) -> R` | a function value, which may have captured variables |
| a struct name | the fields that struct declares |

Type names are not reserved words. `int` is an ordinary identifier that the
initial environment happens to bind, so a struct may take the name and shadow
it inside its own module.

`array` is the only type that takes an argument, and it takes exactly one.

### Aliases

`type` gives a type another name. Aliases are transparent: the name and what it
stands for are one type, not two that convert, so a `UserId` may be used
wherever an `int` is wanted and the other way round.

```
type UserId = int;
type Callback = fun(int) -> int;
type Names = array<string>;
```

Aliases may be written in any order and may name one another, but not
themselves, even at a remove. Because an alias is only a name, a diagnostic
about one reports the type behind it.

### Copying and sharing

The distinction matters whenever a value is assigned, passed to a function, or
stored into a field or element.

**Copied**: `bool`, the numbers, `char`, and structs. A struct is copied field
by field, all the way down, so changing one copy leaves the other alone.

**Shared**: `array<T>`, `*T`, and function values. Two names for one array are
two names for the same elements.

`string` is immutable, so the difference is not observable: copies share one
buffer.

```
var here: Point = new Point { x: 3, y: 4 };
var copy: Point = here;
copy.x = 99;                    // here.x is still 3

var values: array<int> = [1, 2, 3];
var alias: array<int> = values;
alias[0] = 99;                  // values[0] is now 99
```

## Declarations

### Variables

```
var count: int = 0;
```

Every variable is assignable, and every variable is initialised where it is
declared: there are no uninitialised variables. A `var` at the top level of a
module is a global; globals are initialised in the order they are written, and
each may use the ones before it.

### Structs

```
struct Point {
    x: float64;
    y: float64;
}
```

A struct is built with `new`, which names every field exactly once, in any
order.

```
var here: Point = new Point { y: 4.0, x: 3.0 };
```

A struct may not contain itself by value, because that would have no size. It
may contain itself through a pointer, which is what a linked structure is made
of.

```
struct Node {
    value: int;
    next: *Node;
}
```

### Functions

```
fun add(left: int, right: int) -> int {
    return left + right;
}
```

A result type is always written, `void` included. A function that returns
anything but `void` must return on every path through its body. A top-level
function may leave the body out, which means [the host provides
it](#host-functions). A loop whose
condition is the literal `true` and which contains no `break` counts as
returning, so this needs no unreachable `return` after it:

```
fun first_multiple(of: int, above: int) -> int {
    var candidate: int = above + 1;
    while (true) {
        if (candidate % of == 0) {
            return candidate;
        }
        candidate = candidate + 1;
    }
}
```

A `for` with no condition counts the same way.

### Nested functions

A function may be declared inside another. It reads and writes the variables
around it, and its name is gone once the block it was declared in is.

```
fun tally(values: array<int>) -> int {
    var seen: int = 0;

    fun record(value: int) -> void {
        seen = seen + value;
        return;
    }

    for (var index: int = 0; index < values.length; index = index + 1) {
        record(values[index]);
    }
    return seen;
}
```

Every function declared in a block is in scope throughout it, so a pair of them
may call each other and either may be used above where it is written. A nested
function is a value like any other and may be returned, in which case it keeps
what it captured.

A nested function is neither exported nor supplied by the host, since neither
would mean anything for a name that exists inside one block.

## Statements

```
var name: Type = expression;
fun name(...) -> Type { ... }
return expression;    return;
if (condition) { ... } else if (condition) { ... } else { ... }
while (condition) { ... }
for (initialiser; condition; step) { ... }
break;    continue;
expression;
{ ... }
```

The condition of an `if`, a `while` or a `for` is a `bool`; nothing else is
treated as one. The body of any of them is always a block, so there is no
dangling-else question. A block is a statement in its own right, and names
declared inside one are gone after it.

### for

```
for (var index: int = 0; index < values.length; index = index + 1) {
    ...
}
```

The initialiser is either a variable declaration or an expression, and whatever
it declares belongs to the loop and is gone after it. Any of the three parts
may be left out; an absent condition never ends the loop.

```
for (;;) { ... }              // until a break or a return
for (; index < 10;) { ... }   // the same as a while
```

`continue` runs the step before testing the condition again, so a loop written
this way always makes progress.

## Expressions

From tightest to loosest:

| | operators | |
| --- | --- | --- |
| 1 | `f(x)` `a[i]` `a.b` | call, index, member |
| 2 | `+` `-` `!` `~` `*` `&` | prefix |
| 3 | `as` | conversion |
| 4 | `*` `/` `%` | |
| 5 | `+` `-` | |
| 6 | `<` `<=` `>` `>=` | |
| 7 | `==` `!=` | |
| 8 | `&&` | |
| 9 | `\|\|` | |
| 10 | `=` | assignment, right associative |

`&&` and `||` stop as soon as the answer is known. Assignment is an expression
whose value is the value assigned.

### if as an expression

An `if` may stand for a value. Both arms are then required, and each is a block
that ends in the expression it gives rather than in a statement.

```
var name: string = if (value < 0) {
    "negative"
} else if (value == 0) {
    "zero"
} else {
    "positive"
};
```

An arm may do work before it yields, and what it declares is gone afterwards:

```
var scaled: int = if (id > 5) {
    var doubled: int = id * 2;
    doubled + 1
} else {
    0
};
```

Both arms must give one type, and it may not be `void`. A block that stands for
a value cannot `return` out of the function around it, nor `break` or
`continue` a loop outside it; a loop written *inside* the arm is its own affair
and may be left normally.

An `if` at the start of a statement is read as the statement form, so the value
form appears where an expression is expected — after `=`, inside a call, inside
a literal.

Both operands of an arithmetic or comparison operator must already have the
same type; there are no promotions. A bare number literal takes its type from
the other operand, so `1 + x` and `x + 1` both work when `x` is a `byte`.

`+` joins two strings. `<`, `<=`, `>` and `>=` compare strings by their bytes.

`==` compares structs field by field, strings by their contents, and arrays and
pointers by identity. Function values cannot be compared.

`%` is defined on whole numbers only. Division or remainder by zero is a fault.

### Assignment targets

Only these name storage, and only these may appear to the left of `=` or after
`&`:

```
variable
value.field
array[index]
*pointer
```

A string is immutable, so `text[0] = ...` is rejected.

### Conversions

`as` converts between any two numeric types, and between any two pointer types.
`float64 as int` truncates towards zero; `int as byte` keeps the low eight
bits; `int as float32` rounds. Nothing else converts.

```
var whole: int = 3;
var exact: float64 = whole as float64 / 2.0;
```

### Members

`a.b` means one of four things, decided when the program is checked:

- a field, if `a` is a struct, or a pointer to one — `p.next` reads through the
  pointer without an explicit `*`;
- `length`, if `a` is an array or a string — the number of elements, or the
  number of bytes;
- a member of a module, if `a` is the name of one and nothing nearer has that
  name;
- nothing, which is an error.

## Literals

```
42        0xff        0b1010        1_000_000
1.0       3.14        1.0e-3
true      false       null
'o'       '\n'        '\u{1F9A6}'
"otters"  "a\tb"
[1, 2, 3]           [0; 16]
new Point { x: 1.0, y: 2.0 }
fun(value: int) -> int { return value * 2; }
```

A whole-number literal takes the type it is used as, and is checked against
that type's range when the program is checked, so `var small: byte = 256;` is
rejected. With nothing to go on it is an `int`. A number with a point or an
exponent is a `float64` unless it is used as a `float32`.

`[value; count]` builds `count` copies of `value`; the count is any `int`
expression, so an array's length may be decided while the program runs. An
array's length never changes after that.

An empty `[]` needs its element type from somewhere, as in
`var empty: array<int> = [];`.

Escapes are `\a \b \f \n \r \t \v \0 \\ \' \" \?`, `\xHH`, and `\u{...}` for a
code point.

## Pointers

```
var value: int = 1;
var slot: *int = &value;
*slot = 42;                     // value is 42
```

`&` takes the address of a variable, a field, an array element, or a
dereference. Applied to anything else it makes a fresh cell holding that value,
which is how a linked structure is grown:

```
fun push(list: *Node, value: int) -> *Node {
    return &new Node { value: value, next: list };
}
```

Every pointer type includes `null`, and `null` may be written wherever a
pointer is wanted. Dereferencing a null pointer is a fault rather than
undefined behaviour.

There is no pointer arithmetic. Indexing an array is how a run of values is
walked.

## Functions and closures

A named function is a value of its own function type, and an anonymous function
is written the same way as a named one without the name.

```
var double: fun(int) -> int = fun(value: int) -> int {
    return value * 2;
};
```

An anonymous function may read and write the variables of the function that
made it, and so may a [nested named one](#nested-functions). It captures the
variable itself, not a snapshot, so this counter reports 3:

```
var count: int = 0;
var bump: fun() -> void = fun() -> void {
    count = count + 1;
    return;
};
bump(); bump(); bump();
```

Captured variables live as long as the closure does, and are collected once it
is unreachable.

## Host functions

A top-level function declared without a body is one the host provides. It is
written like any other and used like any other; only the body is missing.

```
fun otter_io_println(text: string) -> void;
```

There is one function type, so a host function is a `fun(string) -> void` like
anything else and may be passed around as a value. What the host cannot do is
capture, but since it never had a body there is nothing for it to capture.

The name is what finds it, and the name has to be one this implementation
knows, which is settled when the program is checked rather than when the call
happens. Those names are the ones the built-in modules are written against:
`otter_io_print`, `otter_io_println`, `otter_io_read_line`,
`otter_str_from_int`, `otter_str_from_float`, `otter_str_from_bool`,
`otter_str_from_char`, `otter_str_to_int`, `otter_str_substring`,
`otter_str_index_of`, `otter_math_sqrt`, `otter_math_pow`, `otter_math_floor`,
`otter_math_ceil`, `otter_gc_collect`, `otter_gc_live` and
`otter_gc_collections`.

A body-less declaration is a top-level one: a nested function always has a
body.

## Built-in modules

These need no file beside the program. Each is ordinary Otter source, kept in
`interpreter/modules` and embedded into the interpreter when it is built, that
declares the host functions it needs and re-exports them; nothing about them is
a special case.

### io

```
fun print(text: string) -> void
fun println(text: string) -> void
fun read_line() -> string
```

`read_line` returns the line without its ending, and the empty string at end of
input.

### str

```
fun from_int(value: int) -> string
fun from_float(value: float64) -> string
fun from_bool(value: bool) -> string
fun from_char(value: char) -> string
fun to_int(text: string) -> int
fun substring(text: string, start: int, length: int) -> string
fun index_of(text: string, needle: string) -> int
```

`substring` counts in bytes. `index_of` returns -1 when the needle is absent.
`to_int` faults if the text is not a whole number.

### math

```
fun sqrt(value: float64) -> float64
fun pow(base: float64, exponent: float64) -> float64
fun floor(value: float64) -> float64
fun ceil(value: float64) -> float64
fun abs(value: int) -> int
fun min(left: int, right: int) -> int
fun max(left: int, right: int) -> int
```

### gc

```
fun collect() -> void
fun live() -> int
fun collections() -> int
```

Nothing has to be freed by hand, so this module is for looking rather than for
managing. `collect` runs a collection now instead of waiting for the heap to
grow enough to do it on its own; `live` is how many objects survived the last
one plus whatever has been allocated since.

## Faults

The language checks for these while the program runs, and reports the position
of the expression that caused them:

- an index outside an array or a string;
- a dereference of a null pointer, including through `.`;
- division or remainder by zero;
- a negative array length;
- more than 2000 nested calls, which stands in for running out of stack.

Everything else is settled before the program starts.

## Memory

Nothing is freed by hand and there is no way to free anything on purpose. A
mark-and-sweep collector runs when the heap has grown enough since the last
one, and reclaims every array, string, struct, closure and scope that no
longer reaches a variable. Because it traces rather than counts, a closure and
the scope that holds it, which point at each other, are reclaimed like anything
else.

The [`gc`](#gc) module can force a collection and report what is live.

## Reserved words

```
module    import    export    struct    fun       var       type
return    if        else      while     for       break     continue
new       as        true      false     null
```

Type names are not among them: `int`, `string` and the rest are ordinary
identifiers.

## What the language does not have

No generics, no inheritance, no interfaces, no operator overloading, no
exceptions, and no variadic or default arguments. Integer overflow wraps rather
than faulting.
