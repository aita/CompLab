// A small benchmark suite exercising different parts of the VM. Build in
// Release and run: ./build/st_bench
#include <chrono>
#include <print>
#include <string>
#include <vector>

import st;

namespace {

using Clock = std::chrono::steady_clock;

double time_ms(st::System& sys, const std::string& src) {
    auto t0 = Clock::now();
    st::Value v = sys.eval(src);
    auto t1 = Clock::now();
    if (sys.vm().errored()) {
        std::println("  ERROR in [{}]: {}", src.substr(0, 40), sys.vm().error());
        sys.vm().clear_error();
    }
    (void)v;
    return std::chrono::duration<double, std::milli>(t1 - t0).count();
}

void run(st::System& sys, const char* name, const std::string& src) {
    time_ms(sys, src);  // warm (fills inline caches, etc.)
    double best = 1e18;
    for (int i = 0; i < 3; ++i) best = std::min(best, time_ms(sys, src));
    std::println("  {:<34} {:8.1f} ms", name, best);
}

}  // namespace

int main() {
    using namespace st;
    System sys;

    sys.define_class("Bench", "Object", {});
    sys.define_method("Bench",
                      "fib: n\n  n < 2 ifTrue: [^n].\n"
                      "  ^(self fib: n - 1) + (self fib: n - 2)");
    sys.define_method("Bench", "ack: m with: n\n"
                               "  m = 0 ifTrue: [^n + 1].\n"
                               "  n = 0 ifTrue: [^self ack: m - 1 with: 1].\n"
                               "  ^self ack: m - 1 with: (self ack: m with: n - 1)");

    sys.define_class("Counter", "Object", {"count"});
    sys.define_method("Counter", "reset count := 0");
    sys.define_method("Counter", "increment count := count + 1");
    sys.define_method("Counter", "count ^count");

    // polymorphic dispatch: a mix of A and B at one call site
    sys.define_class("A", "Object", {});
    sys.define_method("A", "val ^1");
    sys.define_class("B", "A", {});
    sys.define_method("B", "val ^2");

    std::println("small Smalltalk (C++) — benchmarks (best of 3, -O3):");
    run(sys, "fib: 30  (recursion, dispatch)", "Bench new fib: 30");
    run(sys, "ackermann 3,7  (deep recursion)", "Bench new ack: 3 with: 7");
    run(sys, "to:do: sum 1..3,000,000", "| s | s := 0. 1 to: 3000000 do: [:i | s := s + i]. s");
    run(sys, "timesRepeat: 3,000,000", "| n | n := 0. 3000000 timesRepeat: [n := n + 1]. n");
    run(sys, "OrderedCollection add: 500,000",
        "| c | c := OrderedCollection new. 1 to: 500000 do: [:i | c add: i]. c size");
    run(sys, "OrderedCollection do: sum 500,000",
        "| c s | c := OrderedCollection new. 1 to: 500000 do: [:i | c add: i]. "
        "s := 0. c do: [:x | s := s + x]. s");
    run(sys, "collect: 300,000",
        "| c | c := OrderedCollection new. 1 to: 300000 do: [:i | c add: i]. "
        "(c collect: [:x | x * 2]) size");
    run(sys, "inject:into: sum 300,000",
        "| c | c := OrderedCollection new. 1 to: 300000 do: [:i | c add: i]. "
        "c inject: 0 into: [:a :b | a + b]");
    run(sys, "String , concat 30,000",
        "| s | s := ''. 1 to: 30000 do: [:i | s := s , 'ab']. s size");
    run(sys, "Dictionary at:put: + at: 200,000",
        "| d s | d := Dictionary new. 1 to: 200000 do: [:i | d at: i put: i]. "
        "s := 0. 1 to: 200000 do: [:i | s := s + (d at: i)]. s");
    run(sys, "polymorphic val 400,000",
        "| c s | c := OrderedCollection new. "
        "1 to: 400000 do: [:i | c add: (i even ifTrue: [A new] ifFalse: [B new])]. "
        "s := 0. c do: [:o | s := s + o val]. s");
    run(sys, "object new + ivars 300,000",
        "| n | n := 0. 1 to: 300000 do: [:i | | c | c := Counter new. c reset. "
        "c increment; increment. n := n + c count]. n");
    return 0;
}
