(ns wolv.diag
  "Source positions, and the one error every pass raises.

  A failure is an `ex-info`, which is Clojure's exception with a map attached:
  the map says which pass raised it and where, so a test can ask for the one it
  means without a class hierarchy to declare.")

(defn span
  "A position in the source, counted from one."
  [line col]
  {:line line :col col})

(defn show-span [at] (str (:line at) ":" (:col at)))

(defn wolv-error
  "Raise `kind` — :lex, :parse or :type — at `at`."
  [kind at message]
  (throw (ex-info (str (show-span at) ": " message) {:wolv kind :at at})))

(defn lex-error [at message] (wolv-error :lex at message))
(defn parse-error [at message] (wolv-error :parse at message))
(defn type-error [at message] (wolv-error :type at message))

(defn wolv-error?
  "The kind of compiler error `e` is, or nil if it is not one."
  [e]
  (when (instance? clojure.lang.ExceptionInfo e) (:wolv (ex-data e))))
