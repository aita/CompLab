# frozen_string_literal: true

require_relative "ast"
require_relative "diag"
require "set"
require_relative "types"

module Wolv
  # The type checker, which also decides which variables escape.
  #
  # Types are monomorphic and there is nothing to infer but the type of a `val`.
  # A `fun` without a result type is a procedure and returns `unit`, which is
  # what makes recursion checkable without inference: every function's signature
  # is known before any body is.
  #
  # The pass has a second job.  A variable read from inside a function nested
  # more deeply than the one that binds it cannot live in a register, because
  # the inner function reaches it through a static link at run time.  Every
  # lookup that crosses a function boundary marks the variable as escaping, and
  # the lowering pass gives those a frame slot instead.
  class Checker
    BUILTINS = [
      # name, argument types, result, the symbol the runtime calls it
      ["print", [:string], :unit, "wol_print"],
      ["println", [:string], :unit, "wol_println"],
      ["printInt", [:int], :unit, "wol_print_int"],
      ["flush", [], :unit, "wol_flush"],
      ["getChar", [], :string, "wol_getchar"],
      ["ord", [:string], :int, "wol_ord"],
      ["chr", [:int], :string, "wol_chr"],
      ["size", [:string], :int, "wol_size"],
      ["substring", %i[string int int], :string, "wol_substring"],
      ["concat", %i[string string], :string, "wol_concat"],
      ["intToString", [:int], :string, "wol_int_to_string"],
      ["stringToInt", [:string], :int, "wol_string_to_int"],
      ["exit", [:int], :unit, "wol_exit"]
    ].freeze

    # The three whose types depend on their arguments, so the checker types them.
    SPECIALS = %w[array length not].freeze

    ARITHMETIC = %w[+ - * / mod].freeze
    ORDERING = %w[< <= > >=].freeze
    EQUALITY = %w[= <>].freeze

    # A scope is two tables; the stack of them is innermost first, so a lookup
    # walks outward and stops at the first hit.
    Scope = Struct.new(:tys, :vals)

    def self.check(prog) = new.check(prog)

    def initialize
      @scopes = [prelude]
      @depth = 0
      @loops = 0
      @labels = Hash.new(0)
    end

    def check(prog)
      push
      decls(prog)
      pop
    end

    private

    def prelude
      s = Scope.new({}, {})
      %i[int string bool unit].each { |t| s.tys[t.to_s] = t }
      BUILTINS.each do |name, args, result, label|
        params = args.each_with_index.map { |t, i| Types::VarSym.new("a#{i}", t, false, 0) }
        s.vals[name] = Types::FunSym.new(name, label, params, result, 0, label)
      end
      SPECIALS.each { |name| s.vals[name] = Types::FunSym.new(name, name, [], :unit, 0, name) }
      s
    end

    # -- scopes -------------------------------------------------------------

    def push = @scopes.unshift(Scope.new({}, {}))
    def pop = @scopes.shift

    def bind_val(name, sym) = @scopes.first.vals[name] = sym
    def bind_type(name, ty) = @scopes.first.tys[name] = ty

    def lookup(table, name, at, what)
      @scopes.lazy.filter_map { |scope| scope[table][name] }.first ||
        raise(CheckError.new(at, "`#{name}` is not #{what}"))
    end

    def lookup_val(name, at) = lookup(:vals, name, at, "bound")
    def lookup_type(name, at) = lookup(:tys, name, at, "a type")

    # Two functions of the same name in one program need two labels.
    def unique_label(name)
      n = @labels[name]
      @labels[name] = n + 1
      n.zero? ? "wol_#{name}" : "wol_#{name}.#{n}"
    end

    def unify(want, got, at, where)
      return if Types.compatible?(want, got)

      raise CheckError.new(at, "expected `#{Types.show(want)}`, found `#{Types.show(got)}` #{where}")
    end

    # -- types as they are written -----------------------------------------

    def resolve(t)
      case t
      in Ast::TyName(span:, name:) then lookup_type(name, span)
      in Ast::TyArray(elem:) then Types::ArrayOf.new(resolve(elem))
      in Ast::TyRecord(span:)
        raise CheckError.new(span, "a record type has to be given a name by `type`")
      end
    end

    # -- declarations -------------------------------------------------------

    def decls(list) = list.each { |d| decl(d) }

    def decl(d)
      case d
      in Ast::TypeDecl(binds:) then type_decl(binds)
      in Ast::ValDecl then val_decl(d)
      in Ast::FunDecl(binds:) then fun_decl(binds)
      end
    end

    # Records are bound before any field is resolved, so a group of `type`s may
    # name each other and itself.
    def type_decl(binds)
      records = binds.filter_map do |b|
        next unless b.ty.is_a?(Ast::TyRecord)

        r = Types::Record.new(b.name)
        bind_type(b.name, r)
        [r, b.ty.fields]
      end
      binds.each { |b| bind_type(b.name, resolve(b.ty)) unless b.ty.is_a?(Ast::TyRecord) }
      records.each do |record, fields|
        seen = Set.new
        record.fields = fields.map do |f|
          raise CheckError.new(f.span, "duplicate field `#{f.name}`") unless seen.add?(f.name)

          [f.name, resolve(f.ty)]
        end
      end
    end

    def val_decl(d)
      got = infer(d.init)
      if d.ty
        want = resolve(d.ty)
        unify(want, got, d.init.span, "in this binding")
        got = want
      end
      if d.name.nil?
        unify(:unit, got, d.init.span, "in `val () =`")
      else
        raise CheckError.new(d.span, "`#{d.name}` needs a type annotation to hold `nil`") if got == :nil

        d.sym = Types::VarSym.new(d.name, got, d.mutable, @depth)
        bind_val(d.name, d.sym)
      end
    end

    # Every signature in the group is bound before any body is typed.
    def fun_decl(binds)
      binds.each do |b|
        seen = Set.new
        params = b.params.map do |p|
          raise CheckError.new(p.span, "duplicate parameter `#{p.name}`") unless seen.add?(p.name)

          p.sym = Types::VarSym.new(p.name, resolve(p.ty), false, @depth + 1)
        end
        result = b.result ? resolve(b.result) : :unit
        b.sym = Types::FunSym.new(b.name, unique_label(b.name), params, result, @depth + 1, nil)
        bind_val(b.name, b.sym)
      end
      binds.each do |b|
        @depth += 1
        outer = @loops
        @loops = 0
        push
        b.params.each { |p| bind_val(p.name, p.sym) }
        got = infer(b.body)
        unify(b.sym.result, got, b.body.span, "in the body of `#{b.name}`")
        pop
        @loops = outer
        @depth -= 1
      end
    end

    # -- expressions --------------------------------------------------------

    def infer(e)
      e.ty = infer_node(e)
    end

    def infer_node(e)
      case e
      in Ast::IntLit then :int
      in Ast::StrLit then :string
      in Ast::BoolLit then :bool
      in Ast::NilLit then :nil
      in Ast::UnitLit then :unit
      in Ast::Var then variable(e)
      in Ast::Call then call_exp(e)
      in Ast::RecordLit then record_lit(e)
      in Ast::Index then index_exp(e)
      in Ast::Field then field_exp(e)
      in Ast::Neg(operand:)
        unify(:int, infer(operand), e.span, "in a negation")
        :int
      in Ast::Bin then binop(e)
      in Ast::Logic(op:, lhs:, rhs:)
        unify(:bool, infer(lhs), lhs.span, "on the left of `#{op}`")
        unify(:bool, infer(rhs), rhs.span, "on the right of `#{op}`")
        :bool
      in Ast::Assign then assign(e)
      in Ast::If then if_exp(e)
      in Ast::While(cond:, body:)
        unify(:bool, infer(cond), cond.span, "as a `while` condition")
        @loops += 1
        unify(:unit, infer(body), body.span, "in a `while` body")
        @loops -= 1
        :unit
      in Ast::For then for_exp(e)
      in Ast::Break
        raise CheckError.new(e.span, "`break` is outside any loop") if @loops.zero?

        :unit
      in Ast::Seq(items:)
        items.reduce(:unit) { |_, item| infer(item) }
      in Ast::Let(decls:, body:)
        push
        decls(decls)
        ty = infer(body)
        pop
        ty
      end
    end

    def variable(e)
      sym = lookup_val(e.name, e.span)
      if sym.is_a?(Types::FunSym)
        raise CheckError.new(e.span, "`#{e.name}` is a function, and functions are not values")
      end

      # Read from deeper than it was bound: it cannot live in a register.
      sym.escapes = true if sym.depth < @depth
      e.sym = sym
      sym.ty
    end

    def arity(e, callee, args, want)
      return if args.length == want

      raise CheckError.new(e.span,
                           "`#{callee}` takes #{want} argument#{want == 1 ? '' : 's'}, " \
                           "given #{args.length}")
    end

    def call_exp(e)
      f = lookup_val(e.name, e.span)
      raise CheckError.new(e.span, "`#{e.name}` is a variable, not a function") if f.is_a?(Types::VarSym)

      e.sym = f
      args = e.args
      case f.builtin
      when "array"
        arity(e, e.name, args, 2)
        unify(:int, infer(args[0]), args[0].span, "as an array length")
        elem = infer(args[1])
        raise CheckError.new(args[1].span, "`array` cannot tell which record `nil` stands for") if elem == :nil

        Types::ArrayOf.new(elem)
      when "length"
        arity(e, e.name, args, 1)
        got = infer(args[0])
        unless got.is_a?(Types::ArrayOf)
          raise CheckError.new(args[0].span, "`length` wants an array, found `#{Types.show(got)}`")
        end

        :int
      when "not"
        arity(e, e.name, args, 1)
        unify(:bool, infer(args[0]), e.span, "in a call to `not`")
        :bool
      else
        arity(e, e.name, args, f.params.length)
        args.zip(f.params).each do |a, p|
          unify(p.ty, infer(a), a.span, "in a call to `#{e.name}`")
        end
        f.result
      end
    end

    # The initialisers are put into declaration order, which is what lowering
    # wants.
    def record_lit(e)
      found = lookup_type(e.tyname, e.span)
      raise CheckError.new(e.span, "`#{e.tyname}` is not a record type") unless found.is_a?(Types::Record)

      given = {}
      e.fields.each do |f|
        raise CheckError.new(f.span, "field `#{f.name}` is given twice") if given.key?(f.name)
        raise CheckError.new(f.span, "`#{found.name}` has no field `#{f.name}`") if found.index(f.name).negative?

        given[f.name] = f
      end
      e.fields = found.fields.map do |name, want|
        init = given[name]
        raise CheckError.new(e.span, "field `#{name}` is missing") unless init

        unify(want, infer(init.value), init.span, "in field `#{name}`")
        init
      end
      found
    end

    def index_exp(e)
      got = infer(e.array)
      raise CheckError.new(e.span, "`#{Types.show(got)}` is not an array") unless got.is_a?(Types::ArrayOf)

      unify(:int, infer(e.index), e.index.span, "as an array index")
      got.elem
    end

    def field_exp(e)
      got = infer(e.record)
      raise CheckError.new(e.span, "`#{Types.show(got)}` is not a record") unless got.is_a?(Types::Record)

      ty = got.field_type(e.name)
      raise CheckError.new(e.span, "`#{got.name}` has no field `#{e.name}`") unless ty

      e.offset = got.index(e.name)
      ty
    end

    def binop(e)
      op = e.op
      l = infer(e.lhs)
      r = infer(e.rhs)
      if ARITHMETIC.include?(op)
        unify(:int, l, e.lhs.span, "on the left of `#{op}`")
        unify(:int, r, e.rhs.span, "on the right of `#{op}`")
        :int
      elsif op == "^"
        unify(:string, l, e.lhs.span, "on the left of `^`")
        unify(:string, r, e.rhs.span, "on the right of `^`")
        :string
      elsif ORDERING.include?(op)
        unless %i[int string].include?(l)
          raise CheckError.new(e.span, "`#{op}` compares int or string, not `#{Types.show(l)}`")
        end

        unify(l, r, e.rhs.span, "on the right of `#{op}`")
        :bool
      elsif EQUALITY.include?(op)
        raise CheckError.new(e.span, "`#{op}` cannot compare `unit`") if l == :unit || r == :unit
        unless Types.compatible?(l, r)
          raise CheckError.new(e.span,
                               "`#{op}` compares `#{Types.show(l)}` with `#{Types.show(r)}`")
        end

        :bool
      else
        raise CheckError.new(e.span, "unknown operator `#{op}`")
      end
    end

    def assign(e)
      ty = infer(e.target)
      if e.target.is_a?(Ast::Var) && !e.target.sym.mutable
        raise CheckError.new(e.span, "`#{e.target.sym.name}` is a `val`, so it cannot be assigned")
      end

      unify(ty, infer(e.value), e.value.span, "in an assignment")
      :unit
    end

    def if_exp(e)
      unify(:bool, infer(e.cond), e.cond.span, "as an `if` condition")
      t = infer(e.then)
      return (unify(:unit, t, e.then.span, "in an `if` with no `else`") || :unit) if e.els.nil?

      other = infer(e.els)
      unless Types.compatible?(t, other)
        raise CheckError.new(e.span,
                             "the branches differ: `#{Types.show(t)}` and `#{Types.show(other)}`")
      end

      t == :nil ? other : t
    end

    def for_exp(e)
      unify(:int, infer(e.lo), e.lo.span, "as a `for` bound")
      unify(:int, infer(e.hi), e.hi.span, "as a `for` bound")
      e.sym = Types::VarSym.new(e.name, :int, false, @depth)
      push
      bind_val(e.name, e.sym)
      @loops += 1
      unify(:unit, infer(e.body), e.body.span, "in a `for` body")
      @loops -= 1
      pop
      :unit
    end
  end
end
