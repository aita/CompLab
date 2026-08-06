(ns wolv.i64
  "Sixty-four bit arithmetic.

  A Clojure `long` is the machine's word already, which is most of what this
  file would otherwise have to say.  What is left is the three places the host
  and the machine disagree: `+`, `-` and `*` throw on overflow rather than
  wrapping, so the `unchecked-` forms are the ones meant; a shift past 63 is
  taken modulo 64 by the JVM and is a defined answer on ARM; and a literal is
  read as a bignum on the way in, because the largest one the language admits is
  written `~9223372036854775808`.")

(def i64-min Long/MIN_VALUE)
(def i64-max Long/MAX_VALUE)

(defn wrap
  "The value `n` has when it is kept in 64 bits."
  [n]
  (.longValue (biginteger n)))

(defn unsigned
  "The same bits read as unsigned, which is what `u<` and `u>=` compare."
  [n]
  (if (neg? n) (+' (bigint n) 18446744073709551616N) (bigint n)))

(defn i64+ [a b] (unchecked-add a b))
(defn i64- [a b] (unchecked-subtract a b))
(defn i64* [a b] (unchecked-multiply a b))

;; `sdiv` truncates towards zero, and `min_int / -1` wraps to `min_int` — which
;; is what the JVM's `/` on longs does too, so `quot` and `rem` are the ones.
(defn i64-quot [a b] (if (and (= a i64-min) (= b -1)) i64-min (quot a b)))
(defn i64-rem [a b] (if (and (= a i64-min) (= b -1)) 0 (rem a b)))

(defn i64-and [a b] (bit-and a b))
(defn i64-or [a b] (bit-or a b))
(defn i64-xor [a b] (bit-xor a b))

;; A shift of 64 or more is not the host's business to decide: the JVM takes the
;; count modulo 64, so `1 << 64` would be 1.
(defn i64-shl [a b]
  (cond (neg? b) nil
        (>= b 64) 0
        :else (bit-shift-left a b)))

(defn i64-shr [a b]
  (cond (neg? b) nil
        (>= b 64) (if (neg? a) -1 0)
        :else (bit-shift-right a b)))
