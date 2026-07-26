//! Tagged value representation, shared bit-for-bit with `csrc/stencils.c`.
//!
//! ```text
//! int n   ->  (n << 1) | 1     63-bit, wrapping
//! false   ->  0b000
//! true    ->  0b010
//! fn #i   ->  (i << 3) | 0b100
//! ```
//!
//! The layout is picked so the JIT's arithmetic stencils stay a couple of
//! instructions long: `v & 1` is the "is int" test, tagged ints add and
//! compare without untagging, and equality is a plain bitwise comparison that
//! is already correct across all three types.
//!
//! Note that "is bool" is *not* `!is_int`: function values also have bit 0
//! clear. Bools are exactly `0` and `2`, so the test is `v & !2 == 0`.

/// A dynamically typed value: a 63-bit int, a bool, or a function reference.
pub type Value = u64;

pub const FALSE: Value = 0;
pub const TRUE: Value = 2;

/// Low bits identifying a function reference, and the mask that exposes them.
pub const FUNC_TAG: Value = 0b100;
pub const FUNC_TAG_MASK: Value = 0b111;
/// How far a function index is shifted up past its tag.
pub const FUNC_SHIFT: u32 = 3;

/// Smallest representable integer.
pub const INT_MIN: i64 = -(1 << 62);
/// Largest representable integer.
pub const INT_MAX: i64 = (1 << 62) - 1;

/// Tags `n`, wrapping into the 63-bit range.
#[inline]
pub fn int(n: i64) -> Value {
    ((n as u64) << 1) | 1
}

#[inline]
pub fn boolean(b: bool) -> Value {
    (b as u64) << 1
}

/// A reference to the function at `index` in the program's function table.
#[inline]
pub fn func(index: u32) -> Value {
    ((index as u64) << FUNC_SHIFT) | FUNC_TAG
}

#[inline]
pub fn is_int(v: Value) -> bool {
    v & 1 == 1
}

/// Bools are exactly `FALSE` and `TRUE`; every other bit pattern is not one.
#[inline]
pub fn is_bool(v: Value) -> bool {
    v & !TRUE == 0
}

#[inline]
pub fn is_func(v: Value) -> bool {
    v & FUNC_TAG_MASK == FUNC_TAG
}

#[inline]
pub fn as_int(v: Value) -> i64 {
    (v as i64) >> 1
}

#[inline]
pub fn as_bool(v: Value) -> bool {
    v != FALSE
}

#[inline]
pub fn as_func(v: Value) -> u32 {
    (v >> FUNC_SHIFT) as u32
}

/// Does `n` survive a round trip through [`int`]?
pub fn fits(n: i64) -> bool {
    (INT_MIN..=INT_MAX).contains(&n)
}

pub fn type_name(v: Value) -> &'static str {
    if is_int(v) {
        "int"
    } else if is_func(v) {
        "fn"
    } else {
        "bool"
    }
}

/// Renders a value without a function table to consult, so function
/// references show up by index. [`crate::vm::Vm::show`] names them.
pub fn show(v: Value) -> String {
    show_with(v, |_| None)
}

/// Renders a value, asking `name` for the display name of function `i`.
pub fn show_with(v: Value, name: impl Fn(u32) -> Option<String>) -> String {
    if is_int(v) {
        as_int(v).to_string()
    } else if is_func(v) {
        let i = as_func(v);
        match name(i) {
            Some(n) => format!("<fn {n}>"),
            None => format!("<fn #{i}>"),
        }
    } else if as_bool(v) {
        "true".to_string()
    } else {
        "false".to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tagging_round_trips() {
        for n in [0i64, 1, -1, 42, -42, INT_MIN, INT_MAX] {
            assert_eq!(as_int(int(n)), n, "round trip of {n}");
            assert!(is_int(int(n)));
            assert!(!is_bool(int(n)));
            assert!(!is_func(int(n)));
        }
        for i in [0u32, 1, 2, 7, 1234, u32::MAX] {
            assert_eq!(as_func(func(i)), i, "round trip of fn #{i}");
            assert!(is_func(func(i)));
            assert!(!is_int(func(i)));
            assert!(!is_bool(func(i)), "fn #{i} must not read as a bool");
        }
    }

    #[test]
    fn the_three_types_never_collide() {
        assert!(is_bool(TRUE) && is_bool(FALSE));
        assert!(as_bool(TRUE) && !as_bool(FALSE));
        // Every type has a disjoint set of bit patterns, so `==` needs no type
        // check and mixed comparisons are simply false.
        let ints = [0i64, 1, -1, INT_MIN, INT_MAX].map(int);
        let funcs = [0u32, 1, 9].map(func);
        for v in ints {
            assert_ne!(v, TRUE);
            assert_ne!(v, FALSE);
            assert!(funcs.iter().all(|f| *f != v));
        }
        for f in funcs {
            assert_ne!(f, TRUE);
            assert_ne!(f, FALSE);
        }
    }

    #[test]
    fn tagged_arithmetic_matches_untagged() {
        // The identities the stencils rely on.
        for (a, b) in [(3i64, 4i64), (-7, 9), (INT_MAX, 1), (INT_MIN, -1)] {
            let (ta, tb) = (int(a), int(b));
            assert_eq!(ta.wrapping_add(tb).wrapping_sub(1), int(a.wrapping_add(b)));
            assert_eq!(ta.wrapping_sub(tb).wrapping_add(1), int(a.wrapping_sub(b)));
            assert_eq!(2u64.wrapping_sub(ta), int(a.wrapping_neg()));
            assert_eq!((ta as i64) < (tb as i64), a < b, "ordering of {a} < {b}");
        }
    }

    #[test]
    fn rendering() {
        assert_eq!(show(int(-3)), "-3");
        assert_eq!(show(TRUE), "true");
        assert_eq!(show(FALSE), "false");
        assert_eq!(show(func(5)), "<fn #5>");
        assert_eq!(
            show_with(func(5), |i| Some(format!("gcd/{i}"))),
            "<fn gcd/5>"
        );
    }
}
