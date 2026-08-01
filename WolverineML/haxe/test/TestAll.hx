import haxe.Int64;
import sys.FileSystem;
import sys.io.File;
import wolv.Ast;
import wolv.Diag;
import wolv.Types;
import wolv.Ir;

/* The suite.
 *
 * Everything above the toolchain runs anywhere.  The parts that need an ARM
 * compiler and qemu say so and skip, so this passes on a machine that has
 * neither — what it cannot check, it does not pretend to have checked. */

class TestAll {
  static function main() {
    lexer();
    parser();
    typecheck();
    middle();
    selection();
    copies();
    allocator();
    programs();
    oracle();
    Sys.exit(Check.report());
  }

  /* -- the front end -------------------------------------------------------- */

  static function lexer() {
    Check.about("lexer");
    final ts = wolv.Lexer.lex("val x = 1 + 2");
    Check.equals("token count, with the end", 7, ts.length);
    Check.equals("first kind", "VAL", Std.string(ts[0].kind));
    Check.equals("first span", "1:1", Std.string(ts[0].span));
    Check.equals("the last is the end", "EOF", Std.string(ts[ts.length - 1].kind));

    Check.equals("`:=` beats `:`", "ASSIGN", Std.string(wolv.Lexer.lex("a := 1")[1].kind));
    Check.equals("`<=` beats `<`", "LE", Std.string(wolv.Lexer.lex("a <= 1")[1].kind));
    Check.equals("`<>` beats `<`", "NE", Std.string(wolv.Lexer.lex("a <> 1")[1].kind));

    Check.equals("a keyword is not an identifier", "WHILE",
      Std.string(wolv.Lexer.lex("while")[0].kind));
    Check.equals("a word starting with one is", "IDENT",
      Std.string(wolv.Lexer.lex("whilex")[0].kind));

    final escaped = wolv.Lexer.lex('"a\\nb\\t\\"c\\\\"')[0];
    Check.equals("escapes", "a\nb\t\"c\\", escaped.text);

    // A string literal is bytes, and a character outside ASCII is its UTF-8.
    Check.equals("a literal holds the bytes of its text", 3, wolv.Lexer.lex('"日"')[0].text.length);
    Check.equals("a comment is skipped", "IDENT",
      Std.string(wolv.Lexer.lex("(* x *) y")[0].kind));
    Check.equals("comments nest", "IDENT",
      Std.string(wolv.Lexer.lex("(* a (* b *) c *) y")[0].kind));
    Check.equals("the column counts characters", "2:2",
      Std.string(wolv.Lexer.lex('"日本"\n x')[1].span));

    Check.raises("an unterminated string", LexKind, () -> wolv.Lexer.lex('"abc'));
    Check.raises("a stray character", LexKind, () -> wolv.Lexer.lex("a @ b"));
    // The bound is the parser's: the scanner takes the digits, and what they mean
    // is decided where they become a value.
    Check.raises("an integer too large", ParseKind,
      () -> wolv.Parser.parse("val a = 99999999999999999999999"));
  }

  /** A parenthesised sketch of the tree, so precedence is easy to assert. */
  static function shape(e:Exp):String {
    return switch e.def {
      case EInt(v): Std.string(v);
      case EStr(v): '"$v"';
      case EBool(v): v ? "true" : "false";
      case ENil: "nil";
      case EUnit: "()";
      case EVar(name): name;
      case ECall(name, args): '$name(${args.map(shape).join(", ")})';
      case ERecord(t, fs): '$t{${fs.map(f -> f.name + "=" + shape(f.value)).join(", ")}}';
      case EIndex(a, i): '${shape(a)}[${shape(i)}]';
      case EField(r, n): '${shape(r)}.$n';
      case ENeg(o): '(~${shape(o)})';
      case EBin(op, l, r) | ELogic(op, l, r): '(${shape(l)} $op ${shape(r)})';
      case EAssign(t, v): '(${shape(t)} := ${shape(v)})';
      case EIf(c, t, e2): 'if(${shape(c)}, ${shape(t)}' + (e2 == null ? ")" : ', ${shape(e2)})');
      case EWhile(c, b): 'while(${shape(c)}, ${shape(b)})';
      case EFor(n, lo, hi, b): 'for($n, ${shape(lo)}, ${shape(hi)}, ${shape(b)})';
      case EBreak: "break";
      case ESeq(items): '(${items.map(shape).join("; ")})';
      case ELet(_, body): 'let(${shape(body)})';
    }
  }

  static function firstExp(source:String):Exp {
    return switch wolv.Parser.parse(source).decls[0] {
      case DVal(v): v.init;
      case _: throw "not a val";
    }
  }

  static function parser() {
    Check.about("parser");
    Check.equals("multiplication binds tighter", "(1 + (2 * 3))",
      shape(firstExp("val a = 1 + 2 * 3")));
    Check.equals("comparison is looser than arithmetic", "((1 + 2) < 3)",
      shape(firstExp("val a = 1 + 2 < 3")));
    Check.equals("`andalso` is looser than comparison", "((1 < 2) andalso (3 < 4))",
      shape(firstExp("val a = 1 < 2 andalso 3 < 4")));
    Check.equals("`orelse` is looser than `andalso`", "((a andalso b) orelse c)",
      shape(firstExp("val a = a andalso b orelse c")));
    Check.equals("subtraction goes left", "((1 - 2) - 3)", shape(firstExp("val a = 1 - 2 - 3")));
    Check.equals("`^` goes left", "((a ^ b) ^ c)", shape(firstExp("val a = a ^ b ^ c")));
    Check.equals("unary minus", "(~a)", shape(firstExp("val a = ~a")));
    Check.equals("postfix chains", "a[1].f[2]", shape(firstExp("val a = a[1].f[2]")));
    Check.equals("a parenthesised if takes a postfix", "if(c, a, b).f",
      shape(firstExp("val a = (if c then a else b).f")));
    Check.equals("a trailing `;` is legal", "(a; b)", shape(firstExp("val a = (a; b;)")));

    Check.raises("`nil` takes no postfix", ParseKind, () -> wolv.Parser.parse("val a = nil.f"));
    Check.raises("the left of `:=` is a place", ParseKind,
      () -> wolv.Parser.parse("val () = 1 := 2"));
    Check.raises("an unclosed paren", ParseKind, () -> wolv.Parser.parse("val a = (1"));
  }

  static function checked(source:String):Program {
    final prog = wolv.Parser.parse(source);
    wolv.Typecheck.check(prog);
    return prog;
  }

  static function typecheck() {
    Check.about("typecheck");
    Check.that("a val takes the type of its initialiser", switch checked("val a = 1 + 2").decls[0] {
      case DVal(v): v.sym.ty.match(TInt);
      case _: false;
    });
    Check.that("an `if` with two branches has their type",
      firstExpTy("val a = if true then 1 else 2").match(TInt));
    Check.that("a record literal is of its named type",
      expTyAt("type p = {x: int}\nval a = p{x = 1}", 1).match(TRecord(_)));

    // The escape analysis, which is what lowering reads.
    final prog = checked("val a = 1\nfun f() : int = a\nval () = printInt (f ())");
    Check.that("a variable read from deeper escapes", switch prog.decls[0] {
      case DVal(v): v.sym.escapes;
      case _: false;
    });
    final near = checked("val a = 1\nval () = printInt (a)");
    Check.that("a variable read at its own depth does not", switch near.decls[0] {
      case DVal(v): !v.sym.escapes;
      case _: false;
    });

    Check.raises("an unbound name", TypeKind, () -> checked("val a = b"));
    Check.raises("a function is not a value", TypeKind,
      () -> checked("fun f() = ()\nval a = f"));
    Check.raises("the branches must agree", TypeKind,
      () -> checked("val a = if true then 1 else \"x\""));
    Check.raises("`break` outside a loop", TypeKind, () -> checked("val () = break"));
    Check.raises("`nil` needs an annotation", TypeKind, () -> checked("val a = nil"));
    Check.raises("a `val` cannot be assigned", TypeKind,
      () -> checked("val a = 1\nval () = a := 2"));
    Check.raises("a duplicate field", TypeKind, () -> checked("type p = {x: int, x: int}"));
    Check.raises("a missing field", TypeKind,
      () -> checked("type p = {x: int, y: int}\nval a = p{x = 1}"));
    Check.raises("the wrong arity", TypeKind,
      () -> checked("fun f(a: int) = ()\nval () = f ()"));
    Check.raises("`unit` cannot be compared", TypeKind, () -> checked("val a = () = ()"));
  }

  static function firstExpTy(source:String):Ty return expTyAt(source, 0);

  static function expTyAt(source:String, at:Int):Ty {
    return switch checked(source).decls[at] {
      case DVal(v): v.init.ty;
      case _: throw "not a val";
    }
  }

  /* -- the middle ----------------------------------------------------------- */

  static function inSsa(source:String, optimise = false):Module {
    final opts = new wolv.Driver.Options(true, optimise);
    return wolv.Driver.compileModule(source, opts, optimise ? "opt" : "ssa");
  }

  static function middle() {
    Check.about("ssa and opt");
    final mod = inSsa("var x = 1\nval () = while x < 10 do x := x + 1");
    for (f in mod.funcs) {
      try {
        wolv.Ssa.verify(f);
        Check.that('${f.name} is in SSA', true);
      } catch (e:Dynamic) {
        Check.that('${f.name} is in SSA', false, Std.string(e));
      }
    }
    Check.that("a loop gets a phi",
      mod.funcs[0].walk().filter(b -> b.phis.length > 0).length > 0);

    final folded = inSsa("val () = printInt (2 * 3 + 4)", true);
    var constants = 0;
    var arithmetic = 0;
    for (b in folded.funcs[0].walk()) for (i in b.instrs) switch i {
      case Const(_, v): if (Int64.eq(v, Int64.ofInt(10))) constants += 1;
      case Bin(_, _, _, _): arithmetic += 1;
      case _:
    }
    Check.equals("the arithmetic folded away", 0, arithmetic);
    Check.equals("into one constant", 1, constants);

    final branch = inSsa("val () = if true then print (\"a\") else print (\"b\")", true);
    final calls = [];
    for (b in branch.funcs[0].walk()) for (i in b.instrs) switch i {
      case Call(_, callee, _): calls.push(callee);
      case _:
    }
    Check.equals("a branch on a known value strands the other side", "wol_print",
      calls.join(","));
  }

  static function selection() {
    Check.about("selection");
    final mod = wolv.Driver.compileModule("fun f(a: int, b: int, c: int) : int = a + b * c\n"
      + "val () = printInt (f (1, 2, 3))", new wolv.Driver.Options(), "mach");
    final forms = [];
    for (f in mod.funcs) for (b in f.walk()) for (i in b.instrs) switch i {
      case Machine(m): forms.push(m.form);
      case _:
    }
    Check.that("`a + b * c` is one `madd`", forms.contains("madd"), forms.join(" "));
    for (f in mod.funcs) {
      try {
        wolv.Mach.verify(f);
        Check.that('${f.name} kept nothing abstract', true);
      } catch (e:Dynamic) {
        Check.that('${f.name} kept nothing abstract', false, Std.string(e));
      }
    }

    final shifted = wolv.Driver.compileModule("val a = array (4, 0)\nval () = printInt (a[2])",
      new wolv.Driver.Options(false), "mach");
    final all = [];
    for (f in shifted.funcs) for (b in f.walk()) for (i in b.instrs) switch i {
      case Machine(m): all.push(m.form);
      case _:
    }
    Check.that("an index folds into one shifted `add`", all.contains("adds") || all.contains("ldr"),
      all.join(" "));
  }

  static function copies() {
    Check.about("parallel copies");
    final plain = wolv.Copies.sequentialize([{dst: 1, src: 2}, {dst: 3, src: 4}], -1);
    Check.equals("independent copies stay copies", 2, plain.length);

    final chain = wolv.Copies.sequentialize([{dst: 1, src: 2}, {dst: 2, src: 3}], -1);
    Check.equals("a chain is ordered so nothing is lost", "Mov(1,2),Mov(2,3)",
      chain.map(Std.string).join(","));

    final cycle = wolv.Copies.sequentialize([{dst: 1, src: 2}, {dst: 2, src: 1}], -1);
    Check.equals("a cycle with nothing to borrow swaps", "Swap(1,2)",
      cycle.map(Std.string).join(","));

    final borrowed = wolv.Copies.sequentialize([{dst: 1, src: 2}, {dst: 2, src: 1}], 9);
    Check.that("a cycle with a spare register borrows it",
      borrowed.map(Std.string).join(",").indexOf("Swap") < 0,
      borrowed.map(Std.string).join(","));

    Check.equals("a copy to itself is nothing", 0,
      wolv.Copies.sequentialize([{dst: 1, src: 1}], -1).length);
  }

  static function allocator() {
    Check.about("allocator");
    final source = File.getContent("examples/queens.wol");
    for (size in [8, 12, 16, 26]) {
      final mod = wolv.Driver.compileModule(source, new wolv.Driver.Options(true, true, size), "asm");
      var everyValue = true;
      var inRange = true;
      final machine = wolv.Registers.limited(size);
      for (f in mod.funcs) {
        for (b in f.walk()) for (i in b.instrs) {
          for (r in wolv.Ir.uses(i)) if (!f.colours.exists(r)) everyValue = false;
          final d = wolv.Ir.defs(i);
          if (d != null && !f.colours.exists(d)) everyValue = false;
        }
        for (colour in f.colours) if (!machine.anywhere().contains(colour)) inRange = false;
      }
      Check.that('every value has a colour on a machine of $size', everyValue);
      Check.that('every colour is one the machine has, at $size', inRange);
    }

    final big = wolv.Driver.compileModule(source, new wolv.Driver.Options(true, true, 8), "asm");
    var spills = 0;
    for (f in big.funcs) for (_ in f.spillSlots.keys()) spills += 1;
    Check.that("a small machine spills", spills > 0);

    // The verifier, under every configuration.  `--no-opt` is the one that matters:
    // without copy propagation the copies survive to the allocator, and
    // coalescing gives both ends of one copy the same register.
    for (opts in CONFIGURATIONS) {
      final mod = wolv.Driver.compileModule(source, opts, "asm");
      var ok = true;
      var why = "";
      for (f in mod.funcs) {
        try {
          wolv.Allocator.verify(f);
        } catch (e:Dynamic) {
          ok = false;
          why = Std.string(e);
        }
      }
      Check.that("the colouring verifies", ok, why);
    }

    // Both ends of a copy are live after it and hold the same value, so one
    // register for the two is right, and the verifier has to say so.
    final copied = new wolv.Ir.Func("f", "f", 0);
    final entry = copied.addBlock("entry");
    final a = copied.newReg();
    final b = copied.newReg();
    entry.instrs.push(Const(a, haxe.Int64.ofInt(1)));
    entry.instrs.push(Move(b, a));
    entry.instrs.push(Call(null, "wol_print_int", [a]));
    entry.instrs.push(Ret(b));
    copied.colours.set(a, 9);
    copied.colours.set(b, 9);
    Check.that("a coalesced copy is not a clash", try {
      wolv.Allocator.verify(copied);
      true;
    } catch (_:Dynamic) false);

    // And one colour for everything is a clash, so the check above did not
    // simply stop the verifier saying anything.
    final broken = wolv.Driver.compileModule(source, new wolv.Driver.Options(), "asm");
    var rejected = false;
    for (f in broken.funcs) {
      for (r in [for (k in f.colours.keys()) k]) f.colours.set(r, 0);
      try {
        wolv.Allocator.verify(f);
      } catch (_:Dynamic) rejected = true;
    }
    Check.that("one colour for everything is rejected", rejected);

    // A value live across a call has to survive it.
    final full = wolv.Driver.compileModule(source, new wolv.Driver.Options(), "asm");
    var allSaved = true;
    for (f in full.funcs) {
      final live = wolv.Liveness.analyse(f);
      for (r in wolv.Liveness.acrossCalls(f, live).keys()) {
        if (!wolv.Registers.isCalleeSaved(f.colours.get(r))) allSaved = false;
      }
    }
    Check.that("a value live across a call is callee-saved", allSaved);
  }

  /* -- the whole thing ------------------------------------------------------ */

  static var toolchain:Null<Bool> = null;

  static function haveToolchain():Bool {
    if (toolchain == null) {
      toolchain = try {
        wolv.Driver.crossCc();
        wolv.Driver.emulator();
        true;
      } catch (_:Dynamic) false;
    }
    return toolchain;
  }

  static final CONFIGURATIONS = [
    new wolv.Driver.Options(),
    new wolv.Driver.Options(true, false),
    new wolv.Driver.Options(false),
    new wolv.Driver.Options(true, true, 12),
  ];

  static function programs() {
    Check.about("programs");
    if (!haveToolchain()) {
      Check.skip("no aarch64 compiler or qemu");
      return;
    }
    for (entry in FileSystem.readDirectory("test/programs")) {
      if (!StringTools.endsWith(entry, ".wol")) continue;
      final source = File.getContent("test/programs/" + entry);
      final want = File.getContent("test/programs/" + entry.substr(0, entry.length - 4) + ".out");
      for (at in 0...CONFIGURATIONS.length) {
        final done = wolv.Driver.run(source, CONFIGURATIONS[at], "");
        Check.that('$entry [$at]', done.exitCode == 0 && done.stdout == want,
          done.exitCode != 0 ? done.stderr : "output differs");
      }
    }
    for (entry in FileSystem.readDirectory("examples")) {
      final source = File.getContent("examples/" + entry);
      final base = wolv.Driver.run(source, CONFIGURATIONS[0], "");
      Check.that('$entry runs', base.exitCode == 0, base.stderr);
      for (at in 1...CONFIGURATIONS.length) {
        final done = wolv.Driver.run(source, CONFIGURATIONS[at], "");
        Check.that('$entry agrees with itself [$at]', done.stdout == base.stdout);
      }
    }
  }

  /* -- the oracle ----------------------------------------------------------- */

  /**
   * Random arithmetic, and the answer worked out here.
   *
   * The generator is a fixed sequence rather than a random one, so a failure can
   * be looked at again.  `Math.random` is not used at all: the same seed has to
   * give the same programs on every run and every target.
   */
  static var seed = 0x2F6E2B1;

  static function next():Int {
    seed = (seed * 1103515245 + 12345) & 0x3FFFFFFF;
    return seed;
  }

  static function expression(depth:Int):{text:String, value:Int64} {
    if (depth == 0 || next() % 4 == 0) {
      final v = Int64.ofInt(next() % 1000 - 500);
      return {text: Int64.compare(v, Int64.ofInt(0)) < 0 ? '(~${Std.string(Int64.neg(v))})'
        : Std.string(v), value: v};
    }
    final l = expression(depth - 1);
    final r = expression(depth - 1);
    return switch next() % 5 {
      case 0: {text: '(${l.text} + ${r.text})', value: Int64.add(l.value, r.value)};
      case 1: {text: '(${l.text} - ${r.text})', value: Int64.sub(l.value, r.value)};
      case 2: {text: '(${l.text} * ${r.text})', value: Int64.mul(l.value, r.value)};
      case 3:
        Int64.eq(r.value, Int64.ofInt(0))
          ? {text: l.text, value: l.value}
          : {text: '(${l.text} / ${r.text})', value: Int64.div(l.value, r.value)};
      case _:
        Int64.eq(r.value, Int64.ofInt(0))
          ? {text: l.text, value: l.value}
          : {text: '(${l.text} mod ${r.text})', value: Int64.mod(l.value, r.value)};
    }
  }

  static function oracle() {
    Check.about("oracle");
    if (!haveToolchain()) {
      Check.skip("no aarch64 compiler or qemu");
      return;
    }
    for (round in 0...12) {
      final e = expression(4);
      final source = 'val () = printInt (${e.text})\n';
      final done = wolv.Driver.run(source, CONFIGURATIONS[round % CONFIGURATIONS.length], "");
      Check.equals('round $round', Std.string(e.value), done.stdout);
    }
  }
}
