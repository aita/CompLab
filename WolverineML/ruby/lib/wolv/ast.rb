# frozen_string_literal: true

module Wolv
  # The syntax tree.
  #
  # These are `Struct`s and not `Data`s, which is the one place in the compiler
  # where that matters: the parser builds a tree with three holes in every node —
  # the type, what a name resolved to, and which word of a record a field access
  # reads — and the checker fills them in.  Everything after the checker reads
  # them.  `Struct` also deconstructs in `case/in`, which is how every pass walks
  # the tree.
  module Ast
    # -- types as they are written ----------------------------------------

    TyName = Struct.new(:span, :name)
    TyArray = Struct.new(:span, :elem)
    TyRecord = Struct.new(:span, :fields)
    TyField = Struct.new(:name, :ty, :span)

    # -- expressions -------------------------------------------------------

    IntLit = Struct.new(:span, :value, :ty)
    StrLit = Struct.new(:span, :value, :ty)
    BoolLit = Struct.new(:span, :value, :ty)
    NilLit = Struct.new(:span, :ty)
    UnitLit = Struct.new(:span, :ty)
    Var = Struct.new(:span, :name, :ty, :sym)
    Call = Struct.new(:span, :name, :args, :ty, :sym)

    FieldInit = Struct.new(:name, :value, :span)

    # `fields` is put into declaration order by the checker, so it is the one
    # node field a later pass writes that the parser also filled.
    RecordLit = Struct.new(:span, :tyname, :fields, :ty)

    Index = Struct.new(:span, :array, :index, :ty)
    Field = Struct.new(:span, :record, :name, :ty, :offset)
    Neg = Struct.new(:span, :operand, :ty)
    Bin = Struct.new(:span, :op, :lhs, :rhs, :ty)

    # `andalso` and `orelse`, which are control flow and not operators.
    Logic = Struct.new(:span, :op, :lhs, :rhs, :ty)

    Assign = Struct.new(:span, :target, :value, :ty)
    If = Struct.new(:span, :cond, :then, :els, :ty)
    While = Struct.new(:span, :cond, :body, :ty)
    For = Struct.new(:span, :name, :lo, :hi, :body, :ty, :sym)
    Break = Struct.new(:span, :ty)
    Seq = Struct.new(:span, :items, :ty)
    Let = Struct.new(:span, :decls, :body, :ty)

    # -- declarations ------------------------------------------------------

    TypeBind = Struct.new(:name, :ty, :span)
    TypeDecl = Struct.new(:span, :binds)
    ValDecl = Struct.new(:span, :name, :ty, :init, :mutable, :sym)
    Param = Struct.new(:name, :ty, :span, :sym)
    FunBind = Struct.new(:name, :params, :result, :body, :span, :sym)
    FunDecl = Struct.new(:span, :binds)
  end
end
