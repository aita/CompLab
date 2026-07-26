// Longest Collatz chain below a bound: a loop-heavy program, which is where
// the tail-call chain the JIT builds pays off most.

fn steps(n) {
    let count = 0;
    while n != 1 {
        if n % 2 == 0 {
            n = n / 2;
        } else {
            n = 3 * n + 1;
        }
        count = count + 1;
    }
    return count;
}

fn main() {
    let best = 0;
    let best_n = 0;
    let n = 1;
    while n < 100000 {
        let s = steps(n);
        if s > best {
            best = s;
            best_n = n;
        }
        n = n + 1;
    }
    print best_n;
    return best;
}
