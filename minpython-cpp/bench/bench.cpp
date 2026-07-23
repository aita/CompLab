// Benchmark: a hot integer loop on the interpreter vs the tracing JIT.
import std;

import minpython;

using namespace minpython;

static const char* kCollatz =
    "def collatz(n):\n    total = 0\n    x = 1\n"
    "    while x <= n:\n        y = x\n        while y != 1:\n"
    "            if y & 1:\n                y = 3 * y + 1\n"
    "            else:\n                y = y >> 1\n"
    "            total = total + 1\n        x = x + 1\n    return total\n"
    "print(collatz(300000))\n";

template <class F>
static double time_ms(F&& f) {
  auto t0 = std::chrono::steady_clock::now();
  f();
  auto t1 = std::chrono::steady_clock::now();
  return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

int main() {
  std::string err;
  auto prog = compile_module(kCollatz, err);
  if (!prog) {
    std::cout << "compile error: " << err << "\n";
    return 1;
  }

  double interp = time_ms([&] {
    VM vm;
    vm.run_code(prog->module);
  });

  double jit = time_ms([&] {
    VM vm;
    TracingJIT tj(vm, /*threshold=*/50);
    vm.run_code(prog->module);
  });

  std::cout << "collatz(300000):\n"
            << "  interpreter " << interp << " ms\n"
            << "  tracing JIT " << jit << " ms  ("
            << (interp / jit) << "x)\n";
  return 0;
}
