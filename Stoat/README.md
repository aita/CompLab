# Stoat

A small dynamically typed language with ML-flavoured syntax and Python-flavoured
objects: `fun` declarations, first-class closures, classes with multiple
inheritance, and a C3 method resolution order behind `super`.

The interpreter is a tree-walker written in OCaml (ocamllex + menhir for the
front end).

```stoat
class Animal {
  fun init(name) { self.name = name }
  fun speak() { self.name + " makes a sound" }
}

class Dog : Animal {
  fun speak() { super.speak() + ", specifically a woof" }
}

print(Dog("Rex").speak())
```

## Build and run

```sh
cd interpreter
dune build                       # builds _build/default/src/stoat.exe
dune exec src/stoat.exe examples/tour.stoat
dune test                        # golden tests (dune test --auto-promote to update)

echo 'print("hi")' | dune exec src/stoat.exe   # no file argument reads stdin
```

## The language

### Programs, blocks and `;`

A program is a block, and a block is a sequence of items:

- **declarations** — `fun` and `class` — stand on their own, with no separator;
- **expressions** — everything else — are separated from each other by `;`.

The value of a block is the value of its last expression, so functions rarely
need `return`:

```stoat
fun max3(a, b, c) {
  let m = if a > b { a } else { b };
  if m > c { m } else { c }
}
```

Everything except `fun`/`class` declarations is an expression, including `let`,
`if`, `while`, `for`, `return`, `break` and `continue`. A `while`, a `for`, an
`if` without `else` and an empty block all evaluate to `nil`.

Comments are `// to end of line` and `/* nestable */`.

### Values

| type | literals | notes |
| --- | --- | --- |
| `nil` | `nil` | |
| `bool` | `true`, `false` | |
| `int` | `42`, `-7` | OCaml native ints |
| `float` | `3.14`, `1e3` | |
| `string` | `"hi\n"` | escapes: `\n \t \r \0 \\ \"` |
| `list` | `[1, "two", [3]]` | growable, heterogeneous |
| function | `fun f() {}`, `fn (x) { x }` | closures; methods are bound closures |
| class | `class C {}` | callable: calling it constructs an object |
| object | `C()` | fields live on the instance |

`nil` and `false` are the only falsy values — `0` and `""` are truthy.

### Operators

```
=                          assignment (to a variable, a field or an index)
||  &&  !                  logical; || and && return one of their operands
==  !=  <  <=  >  >=       comparison (== is structural for lists, identity for objects)
+  -  *  /  %              arithmetic; + also concatenates strings and lists
-x                         negation
f(a, b)   xs[i]   o.field  call, index, field
```

`int op int` stays an int (`7 / 2` is `3`); mixing in a float promotes to float
(`7.0 / 2` is `3.5`). Indices may be negative: `xs[-1]` is the last element.

### Functions and closures

```stoat
fun adder(n) {
  fn (x) { x + n }        // captures n by reference
}

let add3 = adder(3);
print(add3(4));           // 7
```

Functions capture the environment they were created in, so closures can keep
mutating a variable after the defining call has returned (see
`examples/closures.stoat`). Each iteration of a loop gets a fresh binding of
the loop variable, so closures made in a loop do not share it.

`let x = ...` declares a binding in the current scope; a bare `x = ...` assigns
to an existing one and is an error if there is none.

### Classes

```stoat
class Point {
  fun init(x, y) { self.x = x; self.y = y }      // constructor
  fun norm2() { self.x * self.x + self.y * self.y }
  fun to_string() { "(" + str(self.x) + ", " + str(self.y) + ")" }
}

let p = Point(3, 4);
print(p, p.norm2());       // (3, 4) 25
```

- `self` is bound implicitly inside methods; fields are always written
  `self.name` and can be created at any time.
- `init` is the constructor. A class without one takes no arguments.
- `to_string`, if present, is what `print` and `str` use.
- Methods are ordinary values: `let f = p.norm2;` gives a bound method.

### Inheritance and the MRO

Bases are listed after `:`, and may be several:

```stoat
class Bottom : Left, Right { ... }
```

Every class gets a **C3 linearization** — the same algorithm Python uses — and
method lookup walks it in order. `super.m()` does *not* mean "my base class";
it means "the class after mine in the MRO of the object this method is running
on", which is what makes diamonds call each class exactly once:

```stoat
class Base   { fun ping() { ["Base"] } }
class Left  : Base { fun ping() { ["Left"] + super.ping() } }
class Right : Base { fun ping() { ["Right"] + super.ping() } }
class Bottom : Left, Right { fun ping() { ["Bottom"] + super.ping() } }

print(Bottom().ping());   // ["Bottom", "Left", "Right", "Base"] — Base runs once
print(mro(Bottom));       // ["Bottom", "Left", "Right", "Base"]
```

A hierarchy whose bases cannot be linearized consistently is rejected when the
class is created.

### Builtins

Global functions:

```
print(...)  str(v)  repr(v)  len(v)  type(v)  bool(v)  int(v)  float(v)
range(stop) / range(start, stop) / range(start, stop, step)
abs  min  max  sqrt  floor  ceil  assert(cond[, message])
class_of(obj)  mro(class_or_obj)  is_instance(v, class)
```

Methods on strings:

```
len  upper  lower  trim  chars  split(sep)  contains(s)
starts_with(s)  ends_with(s)  replace(old, new)  substr(start, len)
```

Methods on lists:

```
len  push(v)  pop()  insert(i, v)  remove_at(i)  contains(v)  index_of(v)
join(sep)  reverse()  copy()  map(f)  filter(f)  each(f)  fold(init, f)
```

### Grammar

```
program     ::= block_items EOF
block_items ::= (decl | expr ';')* expr?
block       ::= '{' block_items '}'
decl        ::= fundecl
              | 'class' IDENT (':' IDENT (',' IDENT)*)? '{' fundecl* '}'
fundecl     ::= 'fun' IDENT '(' params ')' block
expr        ::= 'let' IDENT '=' expr
              | 'return' expr? | 'break' | 'continue'
              | lvalue '=' expr
              | expr binop expr | ('-' | '!') expr
              | expr '(' args ')' | expr '.' IDENT | expr '[' expr ']'
              | primary
primary     ::= INT | FLOAT | STRING | 'true' | 'false' | 'nil' | IDENT
              | 'super' '.' IDENT
              | '(' expr ')' | '[' args ']'
              | 'fn' '(' params ')' block
              | 'if' expr block ('else' (block | if))?
              | 'while' expr block
              | 'for' IDENT 'in' expr block
```

## Implementation

`interpreter/src/`:

| file | |
| --- | --- |
| `lexer.mll` | ocamllex scanner (nested comments, string escapes, line tracking) |
| `parser.mly` | menhir grammar, conflict-free, produces `Ast.block` |
| `ast.ml` | syntax tree; statements carry a line number for error messages |
| `value.ml` | runtime values, environments, classes/objects, printing |
| `mro.ml` | C3 linearization |
| `builtins.ml` | global functions and the methods of strings and lists |
| `interp.ml` | the evaluator |
| `stoat.ml` | command line driver and error reporting |

Notes:

- Environments are hash tables of `value ref` chained by a parent pointer;
  closures hold on to the environment they were defined in.
- A method closure remembers its defining class, which is what `super` needs to
  find its starting point in the receiver's MRO.
- `return`, `break` and `continue` are OCaml exceptions; escaping ones are
  reported as errors ("`break` outside of a loop").
- Runtime errors print as `file:line: runtime error: ...` and exit with 1;
  deep recursion is caught and reported instead of crashing.

## Layout

```
interpreter/src        the interpreter
interpreter/examples   tour.stoat, classes.stoat, mro.stoat, closures.stoat, calc.stoat
interpreter/tests      golden tests (features.stoat, errors/, *.expected)
```

`examples/calc.stoat` is a calculator — lexer, recursive descent parser and
evaluator — written in Stoat itself.
