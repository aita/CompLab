// Dependency-free test runner (no framework, no exceptions). The process exit
// code is the number of failed checks.
#include <print>
#include <string>
#include <string_view>

import st;

namespace {

int failures = 0;

void check(bool cond, std::string_view what) {
    if (!cond) {
        ++failures;
        std::println("FAIL: {}", what);
    }
}

// Evaluate and return the printString, or "ERR:<msg>".
std::string ev(st::System& sys, std::string_view src) {
    st::Value v = sys.eval(src);
    if (sys.vm().errored()) return "ERR:" + sys.vm().error();
    return sys.print_value(v);
}

void test_lexer() {
    auto t = st::tokenize("x := arr at: 1 put: 2").tokens;
    check(t[0].kind == st::Tok::Ident && t[0].text == "x", "ident x");
    check(t[1].kind == st::Tok::Assign, "assign");
    check(t[3].kind == st::Tok::Keyword && t[3].text == "at:", "keyword at:");
}

void test_arithmetic() {
    st::System sys;
    check(ev(sys, "3 + 4 factorial") == "27", "unary binds tighter than binary");
    check(ev(sys, "3 + 4 * 2") == "14", "binary left to right");
    check(ev(sys, "1 max: 2") == "ERR:SmallInteger does not understand #max:", "dnu");
    check(ev(sys, "10 / 2") == "5", "exact division -> integer");
    check(ev(sys, "10 / 4") == "2.500000", "inexact division -> float");
}

void test_control_flow() {
    st::System sys;
    check(ev(sys, "3 > 2 ifTrue: ['yes'] ifFalse: ['no']") == "'yes'", "ifTrue:ifFalse:");
    check(ev(sys, "(3 > 2) and: [5 < 9]") == "true", "and:");
    check(ev(sys, "(1 > 2) or: [2 > 1]") == "true", "or:");
    check(ev(sys, "| i s | i := 1. s := 0. [i <= 5] whileTrue: [s := s + i. i := i + 1]. s") == "15",
          "whileTrue:");
    check(ev(sys, "| s | s := 0. 1 to: 10 do: [:i | s := s + i]. s") == "55", "to:do:");
    check(ev(sys, "| n | n := 0. 5 timesRepeat: [n := n + 1]. n") == "5", "timesRepeat:");
}

void test_blocks_and_closures() {
    st::System sys;
    check(ev(sys, "[:a :b | a + b] value: 3 value: 4") == "7", "block value:value:");
    check(ev(sys,
             "| make add | make := [:n | [:x | x + n]]. add := make value: 10. add value: 5") == "15",
          "closure captures outer var");
}

void test_temps_and_workspace() {
    st::System sys;
    check(ev(sys, "| x y | x := 3. y := 4. x * x + (y * y)") == "25", "temps");
    sys.eval("g := 41");
    check(ev(sys, "g + 1") == "42", "workspace global persists");
}

void test_user_class() {
    st::System sys;
    sys.define_class("Counter", "Object", {"count"});
    sys.define_method("Counter", "init count := 0");
    sys.define_method("Counter", "increment count := count + 1");
    sys.define_method("Counter", "count ^count");
    check(ev(sys, "| c | c := Counter new. c init. c increment; increment. c count") == "2",
          "user class with ivars, cascade");
}

void test_super_and_polymorphism() {
    st::System sys;
    sys.define_class("Animal", "Object", {});
    sys.define_method("Animal", "speak ^'...'");
    sys.define_class("Dog", "Animal", {});
    sys.define_method("Dog", "speak ^'woof and ', super speak");
    check(ev(sys, "Dog new speak") == "'woof and ...'", "super send");
}

void test_non_local_return() {
    st::System sys;
    sys.define_class("Finder", "Object", {});
    sys.define_method("Finder", "firstOver: n\n"
                                "  n > 3 ifTrue: [^'big'].\n"
                                "  ^'small'");
    check(ev(sys, "Finder new firstOver: 5") == "'big'", "non-local return taken");
    check(ev(sys, "Finder new firstOver: 1") == "'small'", "non-local return not taken");
}

void test_gc_survives_computation() {
    st::System sys;
    // allocates many short-lived strings; must not corrupt the result
    check(ev(sys, "| s | s := ''. 1 to: 100 do: [:i | s := s , 'x']. s size") == "100",
          "GC-heavy loop keeps the live accumulator");
}

}  // namespace

int main() {
    test_lexer();
    test_arithmetic();
    test_control_flow();
    test_blocks_and_closures();
    test_temps_and_workspace();
    test_user_class();
    test_super_and_polymorphism();
    test_non_local_return();
    test_gc_survives_computation();
    if (failures == 0) std::println("all tests passed");
    return failures;
}
