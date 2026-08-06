(ns wolv.registers
  "What the allocator and the emitter both have to agree about: the registers.

  x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
  linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
  call in a caller-saved register, so x16 is allocatable like any other; x17 is
  the one register kept back, for an address the emitter has to compute after
  allocation is over.  x18 is the platform register, x29 the frame pointer, x30
  the link register.")

(def CALLER-SAVED [9 10 11 12 13 14 15 16 0 1 2 3 4 5 6 7 8])
(def CALLEE-SAVED [19 20 21 22 23 24 25 26 27 28])
(def ARGUMENT-REGS [0 1 2 3 4 5 6 7])
(def SCRATCH [17])

(defn whole-machine [] {:caller CALLER-SAVED :callee CALLEE-SAVED})

(defn anywhere [m] (into (vec (:caller m)) (:callee m)))
(defn register-count [m] (+ (count (:caller m)) (count (:callee m))))

(defn limited
  "A smaller machine, so that the spiller can be tested on small programs."
  [max-regs]
  (let [callee (vec (take (min (count CALLEE-SAVED) (max 2 (quot max-regs 2))) CALLEE-SAVED))
        caller (vec (take (min (count CALLER-SAVED) (max 1 (- max-regs (count callee))))
                          CALLER-SAVED))]
    {:caller caller :callee callee}))
