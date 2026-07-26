// Functions are values: a bare function name evaluates to a reference that
// can be stored, passed, returned and compared.

fn add(a, b) { return a + b; }
fn mul(a, b) { return a * b; }
fn max(a, b) { if a > b { return a; } return b; }

// `op` is an ordinary parameter that happens to hold a function.
fn fold(op, from, to, acc) {
    let i = from;
    while i <= to {
        acc = op(acc, i);
        i = i + 1;
    }
    return acc;
}

// Returning a function.
fn operator(name) {
    if name == 0 { return add; }
    if name == 1 { return mul; }
    return max;
}

print fold(add, 1, 10, 0);          // 55
print fold(mul, 1, 6, 1);           // 720
print fold(max, 1, 10, 0);          // 10

// The returned value can be called straight away.
print operator(1)(6, 7);            // 42

// References compare by identity, and never equal an int or a bool.
print operator(0) == add;           // true
print operator(0) == mul;           // false
print add == 1;                     // false

print add;                          // <fn add/2>

// Self-application gives recursion without naming yourself.
fn fact(self, n) {
    if n < 2 { return 1; }
    return n * self(self, n - 1);
}
print fact(fact, 10);               // 3628800

return fold(operator(0), 1, 100, 0);
