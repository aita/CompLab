# CompLab

- [`MartenML/`](MartenML) — an ML-like language compiled to RISC-V, in OCaml, with
  graph-colouring register allocation.
- [`rvemu/`](rvemu) — an RV64GC user-mode emulator in C++, with a built-in
  assembler and a gdb stub. It runs what `MartenML` compiles.
- [`Otter/`](Otter) — a small statically typed language with modules, closures
  and an explicit C ABI, and a tree-walking interpreter for it in C++23, parsed
  with ANTLR.
- [`Ferret/`](Ferret) — a node-based visual editor in React Flow, and an OCaml
  compiler that turns the graph into WebAssembly bytes. The compiler runs in
  the browser through js_of_ocaml, so the page compiles and runs what you draw.
- [`MinkML/`](MinkML) — one small ML with six interchangeable type systems:
  Hindley-Milner, higher-rank polymorphism, row polymorphism, refinement types
  with a solver, linear and session types, and dependent types. The syntax and
  the machine are shared, so what differs between them is only the type theory.
- [`Badger/`](Badger) — a Prolog, in OCaml: unification with a trail,
  backtracking on the host stack, the cut as an exception that names the frame
  it cuts back to, and definite clause grammars. The book is in
  [`Badger/doc/`](Badger/doc/index.md), a chapter per concern, in Japanese.
- [`SkunkML/`](SkunkML) — a Standard ML with modules and functors, in OCaml:
  Hindley-Milner with levels, semantic signatures and generative functors, and
  four intermediate languages — typed A-normal form, pattern matching compiled
  to decision trees, explicit join points, explicit closures. Two back ends
  share them: a CESK machine, and a compiler that turns those join points into
  the phi-functions of value SSA without ever computing a dominance frontier.
  The book is in [`SkunkML/doc/`](SkunkML/doc/index.md), a chapter per pass, in
  Japanese.
- [`WolverineML/`](WolverineML) — Tiger's language in SML's syntax, compiled to
  ARMv8: records, arrays and nested functions with static links, SSA built the
  textbook way with dominance frontiers, instructions chosen by covering a DAG
  of each block, and then the same function allocated two ways — by colouring
  the SSA in dominance order, because an SSA interference graph is chordal and
  there is no graph to build, and by leaving SSA and colouring the graph with
  iterated coalescing, so that the two can be measured against each other. The
  compiler is written six times, in Python, Kotlin, Go, OCaml, TypeScript and
  Haxe, each in its own language's idiom rather than as a transliteration, and
  every stage of every example dumps the same bytes out of any of them; the
  comparison between the two allocators is in the Python one. The book is in
  [`WolverineML/doc/`](WolverineML/doc/index.md), a chapter per pass, in
  Japanese.
- [`PolecatML/`](PolecatML) — a small strict ML compiled to a stack machine, in
  OCaml: Hindley-Milner inference, and then a machine whose state is an operand
  stack, a frame stack and a program counter — CEK's continuation with the
  statically known part compiled away. The tail call is its own instruction, so
  it is stated by the compiler rather than recognised by the machine; captures
  are copies, so a recursive group rebuilds its members out of the one capture
  vector they share, and no cell or back-patch appears anywhere; and a verifier
  walks the operand stack's height over every path before anything runs. There
  is a tree-walking evaluator beside the machine, and every test demands the two
  print the same characters.
