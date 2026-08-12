// Dependency-free test runner (no framework, no exceptions). The process exit
// code is the number of failed checks.
import std;
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

void test_character() {
    st::System sys;
    check(ev(sys, "$a") == "$a", "character literal prints");
    check(ev(sys, "$a asInteger") == "97", "character asInteger");
    check(ev(sys, "($a = $a) & ($a = $b) not") == "true", "character equality");
    check(ev(sys, "'hello' at: 1") == "$h", "String at: returns a Character");
}

void test_collections() {
    st::System sys;
    check(ev(sys, "#(1 2 3 4) collect: [:x | x * x]") == "(1 4 9 16 )", "collect:");
    check(ev(sys, "#(1 2 3 4 5) select: [:x | x odd]") == "OrderedCollection (1 3 5 )", "select:");
    check(ev(sys, "#(1 2 3 4 5) inject: 0 into: [:a :b | a + b]") == "15", "inject:into:");
    check(ev(sys, "#(1 2 3) includes: 2") == "true", "includes:");
    check(ev(sys, "#(3 1 4 1 5) detect: [:x | x > 3]") == "4", "detect: (non-local return through do:)");
    check(ev(sys, "#(1 2 3) detect: [:x | x > 9] ifNone: [42]") == "42", "detect:ifNone:");
    check(ev(sys, "| c | c := OrderedCollection new. c add: 1; add: 2; add: 3. c size") == "3",
          "OrderedCollection add:");
    check(ev(sys, "| c | c := OrderedCollection new. c add: 5; addFirst: 1. c first") == "1",
          "OrderedCollection addFirst:");
    check(ev(sys, "(#(10 20 30) inject: 0 into: [:a :b | a + b])") == "60", "inject sum");
}

void test_dictionary() {
    st::System sys;
    check(ev(sys, "| d | d := Dictionary new. d at: #a put: 1. d at: #b put: 2. d at: #a") == "1",
          "Dictionary at:put: / at:");
    check(ev(sys, "| d | d := Dictionary new. d at: #a put: 1. d includesKey: #b") == "false",
          "includesKey:");
    check(ev(sys, "| d | d := Dictionary new. d at: 1 put: 'one'. d at: 2 ifAbsent: ['none']") == "'none'",
          "at:ifAbsent:");
    check(ev(sys, "| d | d := Dictionary new. d at: #x put: 10. d at: #y put: 20. d size") == "2",
          "size");
    check(ev(sys, "| d sum | d := Dictionary new. d at: #a put: 3. d at: #b put: 4. "
                  "sum := 0. d do: [:v | sum := sum + v]. sum") == "7",
          "Dictionary do: over values");
}

void test_arithmetic_fast_path() {
    st::System sys;
    // fast path must match primitive semantics
    check(ev(sys, "1000000 * 1000000") == "1000000000000", "int * fast path");
    check(ev(sys, "5 - 8") == "-3", "int - fast path");
    check(ev(sys, "3 = 3") == "true", "int = fast path");
    // overriding an arithmetic selector on a numeric class disables the fast path
    sys.define_method("SmallInteger", "* other\n  ^42");
    check(ev(sys, "3 * 4") == "42", "override wins after fast path disabled");
    check(ev(sys, "3 + 4") == "7", "other operators still correct");
}

void test_nan_boxing() {
    check(sizeof(st::Value) == 8, "Value is NaN-boxed to 8 bytes");
    st::System sys;
    // immediates round-trip through the boxed representation
    check(ev(sys, "3.14 + 0.5") == "3.640000", "float round-trips");
    check(ev(sys, "5 negated") == "-5", "negative int round-trips");
    check(ev(sys, "0 - 300000000000") == "-300000000000", "large negative in range");
    check(ev(sys, "$A asInteger") == "65", "character");
    check(ev(sys, "nil isNil") == "true", "nil identity");
    // SmallInteger overflow raises instead of silently wrapping
    check(ev(sys, "100 factorial") == "ERR:SmallInteger overflow", "factorial overflow");
    check(ev(sys, "1000000000 * 1000000000") == "ERR:SmallInteger overflow", "* overflow");
    // in-range large arithmetic still works
    check(ev(sys, "1000000 * 100000000") == "100000000000000", "in-range * (1e14)");
}

void test_inline_cache_invalidation() {
    st::System sys;
    sys.define_class("A", "Object", {});
    sys.define_method("A", "foo ^1");
    // callFoo's compiled code holds an inline cache at the `self foo` send
    sys.define_method("A", "callFoo ^self foo");
    check(ev(sys, "A new callFoo") == "1", "inline cache fills");
    sys.define_method("A", "foo ^2");  // redefinition bumps the method version
    check(ev(sys, "A new callFoo") == "2", "redefinition invalidates the inline cache");
    // polymorphic: same call site, different receiver classes
    sys.define_class("B", "A", {});
    sys.define_method("B", "foo ^3");
    check(ev(sys, "| r | r := OrderedCollection new. r add: A new; add: B new. "
                  "(r collect: [:o | o callFoo]) printString") == "'(2 3 )'",
          "call site sees both A and B correctly");
}

void test_string_iteration() {
    st::System sys;
    check(ev(sys, "| n | n := 0. 'hello' do: [:c | n := n + 1]. n") == "5",
          "String do: iterates characters");
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
    test_character();
    test_collections();
    test_dictionary();
    test_arithmetic_fast_path();
    test_nan_boxing();
    test_inline_cache_invalidation();
    test_string_iteration();
    test_gc_survives_computation();
    if (failures == 0) std::println("all tests passed");
    return failures;
}
