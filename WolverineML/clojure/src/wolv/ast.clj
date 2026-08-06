(ns wolv.ast
  "The syntax tree, as plain maps.

  Every node is a map with a `:node`, a `:decl` or a `:ty-node` saying which
  form it is, and that key is what the three passes over the tree dispatch on.
  Nothing is declared: a node is whatever keys it has, and the checker adds
  `:ty`, `:sym` and `:offset` to the ones that want them with `assoc` — so a
  node needs no room made for them in advance and there is no wrapper record
  standing between the passes and the form.

  The forms, and the keys each carries beside `:at`:

      :int :value      :str :value       :bool :value    :nil    :unit
      :var :name       :call :callee :args
      :record :tyname :inits             :index :array :index
      :field :record :select             :neg :operand
      :bin :oper :lhs :rhs               :logic :oper :lhs :rhs
      :assign :target :value             :if :test :then :else
      :while :test :body                 :for :binder :lo :hi :body
      :break                             :seq :items     :let :decls :body

  and the three declarations:

      :type :binds     :val :name :written :init :var?     :fun :binds")

(defn exp [at node m] (into {:node node :at at} m))

(defn e-int [at value] {:node :int :at at :value value})
(defn e-str [at value] {:node :str :at at :value value})
(defn e-bool [at value] {:node :bool :at at :value value})
(defn e-nil [at] {:node :nil :at at})
(defn e-unit [at] {:node :unit :at at})
(defn e-var [at name] {:node :var :at at :name name})
(defn e-call [at callee args] {:node :call :at at :callee callee :args args})
(defn e-record [at tyname inits] {:node :record :at at :tyname tyname :inits inits})
(defn e-index [at array index] {:node :index :at at :array array :index index})
(defn e-field [at record select] {:node :field :at at :record record :select select})
(defn e-neg [at operand] {:node :neg :at at :operand operand})
(defn e-bin [at oper lhs rhs] {:node :bin :at at :oper oper :lhs lhs :rhs rhs})
(defn e-logic [at oper lhs rhs] {:node :logic :at at :oper oper :lhs lhs :rhs rhs})
(defn e-assign [at target value] {:node :assign :at at :target target :value value})
(defn e-if [at test then els] {:node :if :at at :test test :then then :else els})
(defn e-while [at test body] {:node :while :at at :test test :body body})
(defn e-for [at binder lo hi body]
  {:node :for :at at :binder binder :lo lo :hi hi :body body})
(defn e-break [at] {:node :break :at at})
(defn e-seq [at items] {:node :seq :at at :items items})
(defn e-let [at decls body] {:node :let :at at :decls decls :body body})

(defn field-init [name value at] {:name name :value value :at at})

(defn t-name [at name] {:ty-node :name :at at :name name})
(defn t-array [at elem] {:ty-node :array :at at :elem elem})
(defn t-record [at fields] {:ty-node :record :at at :fields fields})
(defn ty-field [name ty at] {:name name :ty ty :at at})

(defn d-type [at binds] {:decl :type :at at :binds binds})
(defn d-val [at name written init var?]
  {:decl :val :at at :name name :written written :init init :var? var?})
(defn d-fun [at binds] {:decl :fun :at at :binds binds})

(defn type-bind [name bound at] {:name name :bound bound :at at})
(defn param [name ty at] {:name name :ty ty :at at})
(defn fun-bind [label params result body at]
  {:label label :params params :result result :body body :at at})

(defn place?
  "Whether `e` is one of the three things the left of `:=` may be."
  [e]
  (contains? #{:var :index :field} (:node e)))
