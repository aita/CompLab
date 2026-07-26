//! Differential tests: the interpreter and the JIT must be indistinguishable.
//!
//! Every program here runs three times -- interpreted only, JIT'd from the
//! first call, and JIT'd from the second call so both tiers execute the same
//! function within one run -- and all three must produce the same printed
//! output, the same result, and the same error text.

use copypatch::value;
use copypatch::vm::Vm;

/// Result of a run: either the entry point's value or the error message.
type Outcome = (Result<String, String>, Vec<String>);

fn run_with(src: &str, jit_threshold: Option<u32>) -> Outcome {
    let funcs = copypatch::build(src).unwrap_or_else(|e| panic!("failed to build:\n{e}"));
    let mut vm = Vm::new(funcs);
    vm.jit_threshold = jit_threshold;
    vm.echo = false;
    // Unoptimised test binaries have fat native frames, and test threads get a
    // small stack, so keep the recursion limit well clear of it.
    vm.max_depth = 200;

    // `Vm::show` rather than `value::show`, so function values are named the
    // same way `print` and the CLI name them.
    let result = match vm.run("main") {
        Ok(v) => Ok(vm.show(v)),
        Err(e) => Err(e.to_string()),
    };
    assert!(
        vm.jit_warning.is_none(),
        "the JIT refused to compile: {:?}",
        vm.jit_warning
    );
    (result, vm.printed)
}

/// Runs a program in every tier configuration and returns the agreed outcome.
#[track_caller]
fn agree(src: &str) -> Outcome {
    let interpreted = run_with(src, None);
    assert_eq!(
        interpreted,
        run_with(src, Some(1)),
        "interpreter and always-JIT disagree"
    );
    assert_eq!(
        interpreted,
        run_with(src, Some(2)),
        "interpreter and warm-up-then-JIT disagree"
    );
    interpreted
}

#[track_caller]
fn returns(src: &str, expected: &str) {
    let (result, _) = agree(src);
    assert_eq!(result.as_deref(), Ok(expected));
}

#[track_caller]
fn prints(src: &str, expected: &[&str]) {
    let (result, printed) = agree(src);
    assert!(result.is_ok(), "expected success, got {result:?}");
    assert_eq!(printed, expected);
}

#[track_caller]
fn fails_with(src: &str, needle: &str) {
    let (result, _) = agree(src);
    let Err(message) = result else {
        panic!("expected a runtime error, got {result:?}");
    };
    assert!(
        message.contains(needle),
        "error {message:?} does not mention {needle:?}"
    );
}

// ------------------------------------------------------------- arithmetic

#[test]
fn integer_arithmetic() {
    returns("fn main() { return 2 + 3 * 4 - 6 / 2; }", "11");
    returns("fn main() { return (2 + 3) * 4; }", "20");
    returns("fn main() { return -7 % 3; }", "-1");
    returns("fn main() { return 7 % -3; }", "1");
    returns("fn main() { return -7 / 2; }", "-3");
    returns("fn main() { return - -5; }", "5");
}

#[test]
fn arithmetic_wraps_at_63_bits() {
    // 2^62 - 1 is the largest value; adding one wraps to the smallest.
    returns(
        "fn main() { return 4611686018427387903 + 1; }",
        "-4611686018427387904",
    );
    returns(
        "fn main() { return -4611686018427387904 - 1; }",
        "4611686018427387903",
    );
    returns(
        "fn main() { return -4611686018427387904 / -1; }",
        "-4611686018427387904",
    );
}

#[test]
fn comparisons_and_equality() {
    prints(
        "fn main() {
            print 1 < 2; print 2 < 1; print 2 <= 2; print 3 > 4; print 4 >= 4;
            print 1 == 1; print 1 != 1;
            print true == true; print true != false;
            return 0;
        }",
        &[
            "true", "false", "true", "false", "true", "true", "false", "true", "true",
        ],
    );
}

#[test]
fn mixed_type_equality_is_false_not_an_error() {
    prints(
        "fn main() { print 1 == true; print 0 == false; print 2 != true; return 0; }",
        &["false", "false", "true"],
    );
}

#[test]
fn booleans() {
    prints(
        "fn main() { print !true; print !!false; print !(1 < 2); return 0; }",
        &["false", "false", "false"],
    );
}

// ----------------------------------------------------------- control flow

#[test]
fn if_else_chains() {
    let src = "
        fn sign(n) {
            if n < 0 { return -1; } else if n > 0 { return 1; } else { return 0; }
        }
        fn main() { print sign(-9); print sign(0); print sign(9); return 0; }
    ";
    prints(src, &["-1", "0", "1"]);
}

#[test]
fn if_without_else_falls_through() {
    returns(
        "fn main() { let x = 1; if false { x = 2; } return x; }",
        "1",
    );
}

#[test]
fn while_loops() {
    returns(
        "fn main() { let i = 0; let s = 0; while i < 100 { s = s + i; i = i + 1; } return s; }",
        "4950",
    );
}

#[test]
fn nested_loops() {
    returns(
        "fn main() {
            let total = 0;
            let i = 0;
            while i < 20 {
                let j = 0;
                while j < 20 {
                    if (i + j) % 3 == 0 { total = total + 1; }
                    j = j + 1;
                }
                i = i + 1;
            }
            return total;
        }",
        "133",
    );
}

#[test]
fn a_loop_that_never_runs() {
    returns("fn main() { while false { return 1; } return 2; }", "2");
}

#[test]
fn short_circuit_skips_the_right_operand() {
    // Without short-circuiting these would divide by zero.
    returns(
        "fn main() { if false && 1 / 0 == 0 { return 1; } return 2; }",
        "2",
    );
    returns(
        "fn main() { if true || 1 / 0 == 0 { return 1; } return 2; }",
        "1",
    );
    // And the operand that does run still decides the answer.
    returns(
        "fn main() { if true && 2 > 1 { return 1; } return 2; }",
        "1",
    );
    returns(
        "fn main() { if false || 2 > 1 { return 1; } return 2; }",
        "1",
    );
}

// ------------------------------------------------------------------ calls

#[test]
fn recursion() {
    let src = "
        fn fib(n) { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }
        fn main() { return fib(20); }
    ";
    returns(src, "6765");
}

#[test]
fn mutual_recursion_and_forward_references() {
    let src = "
        fn is_even(n) { if n == 0 { return true; } return is_odd(n - 1); }
        fn is_odd(n) { if n == 0 { return false; } return is_even(n - 1); }
        fn main() { print is_even(10); print is_odd(10); return 0; }
    ";
    prints(src, &["true", "false"]);
}

#[test]
fn calls_with_many_arguments_and_none() {
    let src = "
        fn zero() { return 100; }
        fn six(a, b, c, d, e, f) { return a + b + c + d + e + f; }
        fn main() { return zero() + six(1, 2, 3, 4, 5, 6); }
    ";
    returns(src, "121");
}

#[test]
fn arguments_are_evaluated_left_to_right() {
    let src = "
        fn note(n) { print n; return n; }
        fn add3(a, b, c) { return a + b + c; }
        fn main() { return add3(note(1), note(2), note(3)); }
    ";
    prints(src, &["1", "2", "3"]);
}

#[test]
fn a_function_without_a_return_yields_zero() {
    returns("fn nothing() { } fn main() { return nothing(); }", "0");
    returns("fn bare() { return; } fn main() { return bare(); }", "0");
}

#[test]
fn parameters_are_local_copies() {
    let src = "
        fn bump(n) { n = n + 1; return n; }
        fn main() { let x = 1; print bump(x); print x; return 0; }
    ";
    prints(src, &["2", "1"]);
}

// -------------------------------------------------------- functions as values

#[test]
fn a_function_name_is_a_value() {
    let src = "
        fn add(a, b) { return a + b; }
        let f = add;
        print f;
        return f(3, 4);
    ";
    let (result, printed) = agree(src);
    assert_eq!(result.as_deref(), Ok("7"));
    assert_eq!(printed, ["<fn add/2>"]);
}

#[test]
fn functions_can_be_passed_and_returned() {
    let src = "
        fn add(a, b) { return a + b; }
        fn mul(a, b) { return a * b; }
        fn apply(op, a, b) { return op(a, b); }
        fn pick(sum) { if sum { return add; } return mul; }

        print apply(add, 3, 4);
        print apply(mul, 3, 4);
        print apply(pick(true), 5, 6);
        print pick(false)(5, 6);
        return 0;
    ";
    prints(src, &["7", "12", "11", "30"]);
}

#[test]
fn a_call_can_be_chained_onto_a_returned_function() {
    let src = "
        fn one() { return 1; }
        fn give() { return one; }
        return give()();
    ";
    returns(src, "1");
}

#[test]
fn higher_order_folding() {
    let src = "
        fn add(a, b) { return a + b; }
        fn mul(a, b) { return a * b; }
        fn fold(op, from, to, acc) {
            let i = from;
            while i <= to { acc = op(acc, i); i = i + 1; }
            return acc;
        }
        print fold(add, 1, 10, 0);
        print fold(mul, 1, 5, 1);
        return fold(add, 1, 100, 0);
    ";
    let (result, printed) = agree(src);
    assert_eq!(result.as_deref(), Ok("5050"));
    assert_eq!(printed, ["55", "120"]);
}

#[test]
fn recursion_through_a_function_value() {
    let src = "
        fn fact(self, n) { if n < 2 { return 1; } return n * self(self, n - 1); }
        return fact(fact, 10);
    ";
    returns(src, "3628800");
}

#[test]
fn function_values_compare_by_identity() {
    let src = "
        fn a() { return 0; }
        fn b() { return 0; }
        print a == a;
        print a == b;
        print a != b;
        // Cross-type comparisons stay false rather than erroring.
        print a == 1;
        print a == true;
        return 0;
    ";
    prints(src, &["true", "false", "true", "false", "false"]);
}

#[test]
fn a_local_shadows_a_function_of_the_same_name() {
    let src = "
        fn f() { return 1; }
        fn shadowed() { let f = 2; return f; }
        print shadowed();
        print f();
        return 0;
    ";
    prints(src, &["2", "1"]);
}

#[test]
fn calling_a_non_function_is_a_type_error() {
    fails_with(
        "let x = 1; return x(2);",
        "the called value is not a function",
    );
    fails_with(
        "let x = true; return x();",
        "the called value is not a function",
    );
}

#[test]
fn indirect_calls_still_check_arity() {
    let src = "
        fn two(a, b) { return a + b; }
        let f = two;
        return f(1);
    ";
    fails_with(src, "takes 2 argument(s) but got 1");
}

#[test]
fn function_values_are_not_ints_or_bools() {
    let src = "fn f() { return 0; }";
    fails_with(&format!("{src} return f + 1;"), "`+` needs int operands");
    fails_with(&format!("{src} return -f;"), "`unary -` needs int operands");
    fails_with(&format!("{src} return !f;"), "`!` needs a bool");
    fails_with(&format!("{src} return f < 1;"), "`<` needs int operands");
    // A function reference has bit 0 clear like a bool does, so the bool test
    // has to be more than "not an int".
    fails_with(
        &format!("{src} if f {{ return 1; }} return 0;"),
        "must be a bool",
    );
    fails_with(&format!("{src} while f {{ }} return 0;"), "must be a bool");
    fails_with(
        &format!("{src} if f && true {{ }} return 0;"),
        "must be a bool",
    );
}

#[test]
fn a_function_value_survives_a_round_trip_through_a_call() {
    let src = "
        fn id(x) { return x; }
        fn target() { return 42; }
        return id(target)();
    ";
    returns(src, "42");
}

// ------------------------------------------------------ top-level statements

#[test]
fn a_program_can_be_bare_statements() {
    prints("print 1; print 2;", &["1", "2"]);
    returns("let x = 6; let y = 7; return x * y;", "42");
}

#[test]
fn top_level_statements_may_call_functions_defined_later() {
    let src = "
        print double(21);
        fn double(n) { return n * 2; }
        return double(50);
    ";
    let (result, printed) = agree(src);
    assert_eq!(result.as_deref(), Ok("100"));
    assert_eq!(printed, ["42"]);
}

#[test]
fn top_level_statements_keep_source_order_across_definitions() {
    let src = "
        print 1;
        fn a() { return 0; }
        print 2;
        fn b() { return 0; }
        print 3;
    ";
    prints(src, &["1", "2", "3"]);
}

#[test]
fn top_level_control_flow_and_recursion() {
    let src = "
        fn fact(n) { if n < 2 { return 1; } return n * fact(n - 1); }
        let i = 1;
        while i <= 5 {
            print fact(i);
            i = i + 1;
        }
        return i;
    ";
    let (result, printed) = agree(src);
    assert_eq!(result.as_deref(), Ok("6"));
    assert_eq!(printed, ["1", "2", "6", "24", "120"]);
}

#[test]
fn a_program_with_no_return_at_the_top_level_yields_zero() {
    returns("print 1;", "0");
}

#[test]
fn top_level_errors_are_reported_against_main() {
    fails_with("let x = 1 + true; return x;", "in `main`");
}

// ------------------------------------------------------------- variables

#[test]
fn inner_scopes_shadow() {
    prints(
        "fn main() { let x = 1; if true { let x = 2; print x; } print x; return 0; }",
        &["2", "1"],
    );
}

#[test]
fn sibling_scopes_do_not_leak_into_each_other() {
    prints(
        "fn main() {
            let n = 0;
            while n < 2 { let doubled = n * 2; print doubled; n = n + 1; }
            return 0;
        }",
        &["0", "2"],
    );
}

#[test]
fn a_let_initialiser_sees_the_outer_binding() {
    returns(
        "fn main() { let x = 1; if true { let x = x + 10; print x; } return x; }",
        "1",
    );
}

// ------------------------------------------------------------ diagnostics

#[test]
fn type_errors_report_the_same_place_in_both_tiers() {
    fails_with("fn main() { return 1 + true; }", "`+` needs int operands");
    fails_with("fn main() { return true * 2; }", "`*` needs int operands");
    fails_with("fn main() { return 1 < false; }", "`<` needs int operands");
    fails_with(
        "fn main() { return -true; }",
        "`unary -` needs int operands",
    );
    fails_with("fn main() { return !1; }", "`!` needs a bool");
    fails_with(
        "fn main() { if 1 { return 1; } return 0; }",
        "condition must be a bool",
    );
    fails_with(
        "fn main() { while 0 { } return 0; }",
        "condition must be a bool",
    );
}

#[test]
fn division_by_zero() {
    fails_with("fn main() { return 1 / 0; }", "division by zero");
    fails_with("fn main() { return 1 % 0; }", "division by zero");
    fails_with("fn main() { let z = 0; return 5 / z; }", "division by zero");
}

#[test]
fn errors_name_the_function_they_happened_in() {
    let src = "
        fn inner(a) { return a + true; }
        fn outer() { return inner(1); }
        fn main() { return outer(); }
    ";
    fails_with(src, "in `inner`");
}

#[test]
fn errors_propagate_out_through_nested_calls() {
    let src = "
        fn boom() { return 1 / 0; }
        fn a() { return boom(); }
        fn b() { return a(); }
        fn main() { print 1; return b() + 1; }
    ";
    let (result, printed) = agree(src);
    assert!(result.is_err(), "expected the error to reach the top");
    assert_eq!(printed, ["1"], "output before the error should survive");
}

#[test]
fn runaway_recursion_is_caught() {
    fails_with(
        "fn f() { return f(); } fn main() { return f(); }",
        "call depth limit",
    );
}

// --------------------------------------------------------------- printing

#[test]
fn print_order_survives_the_jit_boundary() {
    let src = "
        fn shout(n) { print n; return n; }
        fn main() {
            let i = 0;
            while i < 5 { shout(i); i = i + 1; }
            return 0;
        }
    ";
    prints(src, &["0", "1", "2", "3", "4"]);
}

// ------------------------------------------------------- the JIT itself

#[test]
fn hot_functions_actually_get_compiled() {
    let funcs = copypatch::build(
        "fn work(n) { return n * 2; }
         fn main() { let i = 0; while i < 10 { work(i); i = i + 1; } return 0; }",
    )
    .expect("builds");
    let mut vm = Vm::new(funcs);
    vm.echo = false;
    vm.jit_threshold = Some(3);
    vm.run("main").expect("runs");

    // `main` is compiled eagerly as the entry point; `work` on its 3rd call.
    assert_eq!(vm.stats.jit_functions, 2);
    assert!(vm.stats.jit_bytes > 0);
    assert_eq!(vm.stats.interpreted_calls, 2, "`work`'s two warm-up calls");
    assert_eq!(vm.stats.jit_calls, 9, "`main` plus `work`'s last eight");
}

#[test]
fn the_entry_point_is_compiled_even_though_it_runs_once() {
    // A script's work lives in the implicit `main`, which a call counter can
    // never see as hot.
    let funcs =
        copypatch::build("let i = 0; while i < 100 { i = i + 1; } return i;").expect("builds");
    let mut vm = Vm::new(funcs);
    vm.echo = false;
    vm.jit_threshold = Some(1000);
    let result = vm.run("main").map(value::show).map_err(|e| e.to_string());
    assert_eq!(result.as_deref(), Ok("100"));
    assert_eq!(vm.stats.jit_functions, 1);
    assert_eq!(
        vm.stats.interpreted_ops, 0,
        "main should not be interpreted"
    );
}

#[test]
fn no_jit_really_means_no_jit() {
    let funcs = copypatch::build("return 1;").expect("builds");
    let mut vm = Vm::new(funcs);
    vm.echo = false;
    vm.jit_threshold = None;
    vm.run("main").expect("runs");
    assert_eq!(vm.stats.jit_functions, 0);
    assert_eq!(vm.stats.jit_calls, 0);
}

#[test]
fn every_example_program_agrees_across_tiers() {
    // `collatz.cp` is left out on purpose: it runs a couple of hundred million
    // interpreted ops, which is a benchmark rather than a test.
    for name in ["tour", "fib", "higher_order"] {
        let path = format!("{}/examples/{name}.cp", env!("CARGO_MANIFEST_DIR"));
        let src = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
        let interpreted = run_with(&src, None);
        assert_eq!(interpreted, run_with(&src, Some(1)), "{name} disagrees");
        assert_eq!(interpreted, run_with(&src, Some(2)), "{name} disagrees");
        assert!(interpreted.0.is_ok(), "{name} failed: {:?}", interpreted.0);
    }
}
