(ns wolv.types
  "Semantic types, and the symbols that carry them.

  Types are monomorphic.  The four ground ones are keywords, because that is all
  they are: a name with nothing inside.  An array is `{:type :array :elem t}`
  and compares structurally, which `=` gives.  A record is nominal, and carries
  a number rather than its fields — two record types with the same fields are
  different types, and a record type may name itself, so what a record is made
  of lives in a table the checker keeps and `=` on the type is `=` on the
  number.

  A variable's symbol carries a number for the same reason.  Whether it escapes
  is settled long after the node that mentions it was made, and where it ends up
  living later still, so `check` answers with the set of numbers that escaped
  and lowering keeps a table from the number to the register or frame slot."
  (:require [clojure.string :as str]))

(defn record-type [name id] {:type :record :name name :id id})
(defn array-type [elem] {:type :array :elem elem})

(defn record-type? [t] (= (:type t) :record))
(defn array-type? [t] (= (:type t) :array))

(defn- same?
  "Type equality: nominal for records, structural for arrays."
  [a b]
  (= a b))

(defn compatible?
  "Equality, but `nil` stands in for any record."
  [a b]
  (cond
    (and (= a :nil) (or (record-type? b) (= b :nil))) true
    (and (or (record-type? a) (= a :nil)) (= b :nil)) true
    :else (same? a b)))

(defn show-ty [t]
  (cond
    (record-type? t) (:name t)
    (array-type? t) (str (show-ty (:elem t)) " array")
    :else (name t)))

(defn record-index [fields fname]
  (or (first (keep-indexed (fn [i [n _]] (when (= n fname) i)) fields)) -1))

(defn record-field-type [fields fname]
  (second (first (filter (fn [[n _]] (= n fname)) fields))))

;; -- the symbols -------------------------------------------------------------

(defn var-sym [id name ty mutable? depth]
  {:sym :var :id id :name name :ty ty :mutable? mutable? :depth depth})

(defn fun-sym [name label params result depth builtin]
  {:sym :fun :name name :label label :params params
   :result result :depth depth :builtin builtin})

(defn var-sym? [s] (= (:sym s) :var))
(defn fun-sym? [s] (= (:sym s) :fun))

;; -- where a variable lives --------------------------------------------------

;; Once lowering has decided.  Two shapes and not a slot number beside a
;; register number beside a flag: a frame slot may be negative — that is an
;; argument the caller left on the stack — so no number is free to mean "not
;; decided yet".
(defn in-register [reg] {:home :register :reg reg})
(defn in-frame [slot] {:home :frame :slot slot})
