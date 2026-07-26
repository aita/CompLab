// Everything the language has, in one file.

fn classify(n) {
    // `&&` short-circuits: when n is 0 the division is never evaluated.
    if n != 0 && 100 / n < 0 {
        return -1;
    }
    if n == 0 {
        return 0;
    }
    return 1;
}

fn gcd(a, b) {
    while b != 0 {
        let t = b;
        b = a % b;
        a = t;
    }
    return a;
}

// Statements outside any `fn` become the body of an implicit `main`, so a
// program can just be a script. They may call functions defined further down.

print classify(-5);
print classify(0);
print classify(7);

print gcd(1071, 462);

// Values are dynamically typed, but only ints and bools exist.
let flag = true;
print !flag;
print flag == true;
print 1 == true; // different types are never equal
print -(3 * 4) + 100 / 7 % 5;

fn double(n) {
    return n * 2;
}

print double(21);

return gcd(270, 192);
