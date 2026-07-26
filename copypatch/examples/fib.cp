// Recursive fibonacci: exercises calls, comparisons and the JIT's `rt_call`
// bridge back into Rust.

fn fib(n) {
    if n < 2 {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

fn main() {
    let i = 0;
    while i <= 10 {
        print fib(i);
        i = i + 1;
    }
    return fib(25);
}
