#include <iostream>
#include <print>
#include <string>

import st;

int main() {
    using namespace st;
    System sys;
    std::println("small Smalltalk (C++20 modules) — v{}", version);

    // A few demo evaluations.
    const char* demos[] = {
        "3 + 4 factorial",
        "| s | s := 0. 1 to: 10 do: [:i | s := s + i]. s",
        "(3 > 2) and: [5 < 9]",
        "[:a :b | a * b] value: 6 value: 7",
    };
    for (const char* src : demos) {
        Value v = sys.eval(src);
        if (sys.vm().errored()) {
            std::println("{}  =>  Error: {}", src, sys.vm().error());
        } else {
            std::println("{}  =>  {}", src, sys.print_value(v));
        }
    }

    // A little class.
    sys.define_class("Counter", "Object", {"count"});
    sys.define_method("Counter", "init count := 0");
    sys.define_method("Counter", "increment count := count + 1");
    sys.define_method("Counter", "count ^count");
    Value r = sys.eval(
        "| c | c := Counter new. c init. c increment; increment; increment. c count");
    std::println("Counter after 3 increments => {}", sys.print_value(r));

    // Interactive REPL (reads until EOF).
    std::println("\nType an expression (Ctrl-D to quit):");
    std::string line;
    while (true) {
        std::print("st> ");
        if (!std::getline(std::cin, line)) break;
        if (line.empty()) continue;
        Value v = sys.eval(line);
        if (sys.vm().errored()) {
            std::println("Error: {}", sys.vm().error());
        } else {
            std::println("{}", sys.print_value(v));
        }
    }
    return 0;
}
