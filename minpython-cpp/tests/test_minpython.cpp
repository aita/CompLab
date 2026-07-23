// A tiny assertion harness -- no framework, just run programs and diff output.
import std;

import minpython;

using namespace minpython;

static int passes = 0, fails = 0;

static std::string run(const std::string& src) {
  std::string err;
  auto prog = compile_module(src, err);
  if (!prog) return "ERROR: " + err;
  VM vm;
  vm.run_code(prog->module);
  return vm.output();
}

static void check(const std::string& label, const std::string& got,
                  const std::string& want) {
  if (got == want) {
    passes++;
  } else {
    fails++;
    std::cerr << "FAIL " << label << "\n  got: " << got << "\n  want: " << want
              << "\n";
  }
}

#define CHECK(src, want) check(src, run(src), want)

int main() {
  // expressions
  CHECK("print(2 + 3 * 4)", "14");
  CHECK("print((2 + 3) * 4)", "20");
  CHECK("print(17 // 5)", "3");
  CHECK("print(17 % 5)", "2");
  CHECK("print(2 ** 10)", "1024");
  CHECK("print(-7)", "-7");
  CHECK("print(~0)", "-1");
  CHECK("print(13 & 6)", "4");
  CHECK("print(1 << 8)", "256");
  CHECK("print(1 < 2 < 3)", "True");
  CHECK("print(1 < 2 > 3)", "False");
  CHECK("print(0 or 7)", "7");
  CHECK("print(3 and 4)", "4");
  CHECK("print(10 if 1 else 20)", "10");
  CHECK("print(True == 1)", "True");
  CHECK("print(-9 // 2)", "-5");   // Python floor division
  CHECK("print(-9 % 2)", "1");

  // control flow / functions
  check("augassign", run("x = 5\nx += 3\nx *= 2\nprint(x)"), "16");
  check("while", run("i = 0\ntotal = 0\nwhile True:\n    i = i + 1\n"
                     "    if i > 10:\n        break\n"
                     "    if i % 2 == 0:\n        continue\n"
                     "    total = total + i\nprint(total)"),
        "25");
  check("recursion",
        run("def fact(n):\n    if n <= 1:\n        return 1\n"
            "    return n * fact(n - 1)\nprint(fact(6))"),
        "720");
  check("global",
        run("counter = 0\ndef bump():\n    global counter\n"
            "    counter = counter + 1\nbump()\nbump()\nprint(counter)"),
        "2");
  check("locals",
        run("x = 100\ndef f():\n    x = 1\n    return x\nprint(f())\nprint(x)"),
        "1\n100");

  // str / list
  check("str concat len", run("s = 'ab' + 'cd'\nprint(s)\nprint(len(s))"),
        "abcd\n4");
  check("str index", run("s = 'hello'\nprint(s[1])\nprint(s == 'hello')"),
        "e\nTrue");
  check("list", run("xs = [10, 20, 30]\nprint(xs[1])\nprint(len(xs))"),
        "20\n3");
  check("list concat",
        run("xs = [1, 2] + [3, 4]\nprint(len(xs))\nprint(xs[3])"), "4\n4");
  check("plus across types",
        run("print(1 + 2)\nprint('a' + 'b')\nprint(len([1] + [2, 3]))"),
        "3\nab\n3");
  check("list sum loop",
        run("xs = [10, 20, 30, 40]\ni = 0\nt = 0\n"
            "while i < len(xs):\n    t = t + xs[i]\n    i = i + 1\nprint(t)"),
        "100");
  check("nested list repr", run("print([1, 'a', True])"), "[1, 'a', True]");

  // the example programs
  check("fib",
        run("def fib_iter(n):\n    a = 0\n    b = 1\n    i = 0\n"
            "    while i < n:\n        t = a + b\n        a = b\n"
            "        b = t\n        i = i + 1\n    return a\n"
            "print(fib_iter(30))"),
        "832040");
  check("collatz",
        run("def collatz(n):\n    total = 0\n    x = 1\n"
            "    while x <= n:\n        y = x\n        while y != 1:\n"
            "            if y & 1:\n                y = 3 * y + 1\n"
            "            else:\n                y = y >> 1\n"
            "            total = total + 1\n        x = x + 1\n    return total\n"
            "print(collatz(1000))"),
        "59542");

  // -- JIT: differential + native type guard -------------------------------
  struct JitRun {
    std::string out;
    int compiled, runs, aborted, type_deopt;
  };
  auto run_jit = [](const std::string& src, int threshold) -> JitRun {
    std::string err;
    auto prog = compile_module(src, err);
    VM vm;
    TracingJIT jit(vm, threshold);
    if (prog) vm.run_code(prog->module);
    return {vm.output(), jit.n_compiled, jit.n_trace_runs, jit.n_aborted,
            jit.n_type_deopt};
  };

  // A hot int loop compiles and matches the interpreter exactly.
  {
    std::string src =
        "def s(n):\n    i = 0\n    t = 0\n"
        "    while i < n:\n        t = t + i\n        i = i + 1\n"
        "    return t\nprint(s(1000))";
    JitRun j = run_jit(src, 4);
    check("jit sum matches", j.out, run(src));
    check("jit sum compiled", j.compiled >= 1 ? "y" : "n", "y");
  }
  // collatz: nested loop with a data-dependent branch, still exact under JIT.
  {
    std::string src =
        "def collatz(n):\n    total = 0\n    x = 1\n"
        "    while x <= n:\n        y = x\n        while y != 1:\n"
        "            if y & 1:\n                y = 3 * y + 1\n"
        "            else:\n                y = y >> 1\n"
        "            total = total + 1\n        x = x + 1\n    return total\n"
        "print(collatz(500))";
    JitRun j = run_jit(src, 8);
    check("jit collatz matches", j.out, run(src));
  }
  // Native entry type guard: `x = x + x` doubles an int but concatenates a str,
  // so the same loop is valid for both. It traces for int; calling with a str
  // fails the machine-code type guard and deopts -- still exact.
  {
    std::string src =
        "def double(x, n):\n    i = 0\n"
        "    while i < n:\n        x = x + x\n        i = i + 1\n"
        "    return x\n"
        "print(double(1, 20))\n"    // int -> traced
        "print(double('ab', 3))";   // str -> entry type guard deopts
    JitRun j = run_jit(src, 4);
    check("jit typeguard matches", j.out, run(src));
    check("jit typeguard compiled", j.compiled >= 1 ? "y" : "n", "y");
    check("jit typeguard deopted", j.type_deopt >= 1 ? "y" : "n", "y");
  }

  // -- method JIT: recursive int functions ---------------------------------
  struct MethodRun {
    std::string out;
    int compiled, native, aborted;
  };
  auto run_method = [](const std::string& src, int threshold) -> MethodRun {
    std::string err;
    auto prog = compile_module(src, err);
    VM vm;
    MethodJIT mj(vm, threshold);
    if (prog) vm.run_code(prog->module);
    return {vm.output(), mj.n_compiled, mj.n_calls_native, mj.n_aborted};
  };
  {
    std::string src =
        "def fact(n):\n    if n <= 1:\n        return 1\n"
        "    return n * fact(n - 1)\nprint(fact(12))";
    MethodRun m = run_method(src, 2);
    check("method fact matches", m.out, run(src));
    check("method fact compiled", m.compiled >= 1 ? "y" : "n", "y");
    check("method fact native", m.native >= 1 ? "y" : "n", "y");
  }
  {
    std::string src =
        "def fib(n):\n    if n < 2:\n        return n\n"
        "    return fib(n - 1) + fib(n - 2)\nprint(fib(25))";
    MethodRun m = run_method(src, 2);
    check("method fib matches", m.out, run(src));
  }
  {  // spills: many live locals + shifts / bitops force stack slots
    std::string src =
        "def f(n, a, b, c, d, e):\n"
        "    if n == 0:\n        return a + b * 2 + c - d + (e & 7) + (n << 1)\n"
        "    return f(n - 1, a + 1, b + 1, c + 1, d + 1, e + 1)\n"
        "print(f(50, 1, 2, 3, 4, 5))";
    MethodRun m = run_method(src, 2);
    check("method spill matches", m.out, run(src));
    check("method spill compiled", m.compiled >= 1 ? "y" : "n", "y");
  }
  {  // object-capable method JIT: recursion + list subscript
    std::string src =
        "def sumlist(xs, i):\n    if i < 0:\n        return 0\n"
        "    return xs[i] + sumlist(xs, i - 1)\n"
        "print(sumlist([1, 2, 3, 4, 5, 6, 7, 8], 7))";
    MethodRun m = run_method(src, 2);
    check("mixed-method recursion", m.out, run(src));
  }
  {  // calls go through the VM, so *mutual* recursion works here too
    std::string src =
        "def ev(xs, n):\n    if n == 0:\n        return 0\n"
        "    return xs[0] + od(xs, n - 1)\n"
        "def od(xs, n):\n    if n == 0:\n        return 1\n"
        "    return xs[1] + ev(xs, n - 1)\n"
        "print(ev([10, 20], 6))";
    MethodRun m = run_method(src, 2);
    check("mixed-method mutual", m.out, run(src));
  }
  {  // str concat fails the inline int guard -> bails to the interpreter mid
     // function and finishes there; must still be exact
    std::string src =
        "def cat(s, n):\n    if n == 0:\n        return s\n"
        "    return cat(s + 'x', n - 1)\nprint(cat('a', 12))";
    MethodRun m = run_method(src, 2);
    check("mixed-method bail", m.out, run(src));
  }
  {  // len() inside a method-JIT'd function
    std::string src =
        "def pick(xs, i):\n    if i < len(xs):\n        return xs[i]\n"
        "    return 0\nprint(pick([9, 8, 7], 1))\nprint(pick([9, 8, 7], 5))";
    MethodRun m = run_method(src, 2);
    check("mixed-method len", m.out, run(src));
  }
  {  // mutual recursion is NOT self-recursion -> not method-JIT'd, still exact
    std::string src =
        "def ev(n):\n    if n == 0:\n        return 1\n    return od(n - 1)\n"
        "def od(n):\n    if n == 0:\n        return 0\n    return ev(n - 1)\n"
        "print(ev(100))\nprint(od(100))";
    MethodRun m = run_method(src, 2);
    check("method mutual matches", m.out, run(src));
    check("method mutual aborted", m.aborted >= 1 ? "y" : "n", "y");
  }

  // -- str/list in traces: helper calls + per-op native type guards ---------
  {  // list subscript + len now compile instead of aborting
    std::string src =
        "def s(xs, reps):\n    t = 0\n    n = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < len(xs):\n            t = t + xs[i]\n"
        "            i = i + 1\n        n = n + 1\n    return t\n"
        "print(s([1, 2, 3, 4, 5, 6, 7, 8], 500))";
    JitRun j = run_jit(src, 4);
    check("jit list-sum matches", j.out, run(src));
    check("jit list-sum compiled", j.compiled >= 1 ? "y" : "n", "y");
  }
  {  // len() on a str inside a traced loop
    std::string src =
        "def cnt(s, reps):\n    t = 0\n    n = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < len(s):\n            t = t + 1\n"
        "            i = i + 1\n        n = n + 1\n    return t\n"
        "print(cnt('hello', 500))";
    JitRun j = run_jit(src, 4);
    check("jit str-len matches", j.out, run(src));
    check("jit str-len compiled", j.compiled >= 1 ? "y" : "n", "y");
  }
  {  // regression: a type guard that fires *after* a local was written this
     // iteration must resume after the guarded op, not restart the loop header
     // (restarting double-applied `i = i + 1` and lost elements).
    std::string src =
        "def s(xs, reps):\n    t = 0\n    n = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < 8:\n            i = i + 1\n"
        "            t = t + xs[i - 1]\n        n = n + 1\n    return t\n"
        "print(s([1, 2, True, 4, 5, 6, 7, 8], 300))";
    JitRun j = run_jit(src, 4);
    check("jit typeguard resume", j.out, run(src));
    check("jit typeguard fired", j.type_deopt >= 1 ? "y" : "n", "y");
  }
  {  // the inline list fast path must fall back correctly: a negative index
     // and a str subscript both leave it for the helper
    std::string src =
        "def s(xs, t, reps):\n    n = 0\n    r = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < len(xs):\n            r = r + xs[i - 1]\n"
        "            i = i + 1\n"
        "        r = r + len(t)\n        n = n + 1\n    return r\n"
        "print(s([1, 2, 3, 4], 'abc', 400))";
    JitRun j = run_jit(src, 4);
    check("jit list fastpath fallback", j.out, run(src));
  }
  {  // heterogeneous list: the per-op type guard must deopt, still exact
    std::string src =
        "def s(xs, reps):\n    t = 0\n    n = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < len(xs):\n            t = t + xs[i]\n"
        "            i = i + 1\n        n = n + 1\n    return t\n"
        "print(s([1, True, 3], 500))";
    JitRun j = run_jit(src, 4);
    check("jit het-list matches", j.out, run(src));
    check("jit het-list deopted", j.type_deopt >= 1 ? "y" : "n", "y");
  }

  // -- tiered (background) method JIT: exact under async compilation --------
  {
    std::string src =
        "def fib(n):\n    if n < 2:\n        return n\n"
        "    return fib(n - 1) + fib(n - 2)\nprint(fib(25))";
    std::string err;
    auto prog = compile_module(src, err);
    VM vm;
    TieredJIT tj(vm, 2);
    if (prog) vm.run_code(prog->module);
    check("tiered fib matches", vm.output(), run(src));
    // 240k calls: the background compile finishes and native code runs.
    check("tiered fib native", tj.n_calls_native > 0 ? "y" : "n", "y");
  }

  // -- GC firing *inside* a JIT-compiled str/list trace ---------------------
  // The subscr helper allocates a 1-char string every iteration, so a collection
  // happens while native code is on the stack. Everything the trace touches lives
  // in the register array (a GC root), so nothing may be lost.
  {
    std::string src =
        "def scan(s, reps):\n    n = 0\n    t = 0\n"
        "    while n < reps:\n        i = 0\n"
        "        while i < len(s):\n            c = s[i]\n"
        "            t = t + 1\n            i = i + 1\n"
        "        n = n + 1\n    return t\n"
        "print(scan('hello world', 3000))";
    std::string err;
    auto prog = compile_module(src, err);
    VM vm;
    vm.gc_threshold = 500;  // force collections during the trace
    TracingJIT jit(vm, 4);
    if (prog) vm.run_code(prog->module);
    check("gc-in-trace output", vm.output(), run(src));
    check("gc-in-trace collected", vm.n_gc > 0 ? "y" : "n", "y");
    check("gc-in-trace compiled", jit.n_compiled >= 1 ? "y" : "n", "y");
  }

  // -- GC: allocation-heavy loop stays bounded and exact --------------------
  {
    std::string src =
        "i = 0\nt = 0\n"
        "while i < 100000:\n"
        "    xs = [i, i + 1, i + 2]\n"
        "    t = t + xs[1]\n"
        "    i = i + 1\n"
        "print(t)";
    std::string err;
    auto prog = compile_module(src, err);
    VM vm;
    vm.gc_threshold = 1000;  // force frequent collection
    if (prog) vm.run_code(prog->module);
    check("gc output", vm.output(), "5000050000");
    check("gc ran", vm.n_gc > 0 ? "y" : "n", "y");
    // 100k lists were allocated; GC must have reclaimed the garbage.
    check("gc bounded", vm.live_objects() < 3000 ? "y" : "n", "y");
  }

  std::cout << passes << " passed, " << fails << " failed\n";
  return fails ? 1 : 0;
}
