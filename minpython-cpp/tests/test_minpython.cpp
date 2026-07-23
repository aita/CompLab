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

  std::cout << passes << " passed, " << fails << " failed\n";
  return fails ? 1 : 0;
}
