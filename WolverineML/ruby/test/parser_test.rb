# frozen_string_literal: true

require_relative "helper"

class ParserTest < Minitest::Test
  # A parenthesised sketch of the tree, so precedence is easy to assert.
  def shape(e)
    case e
    in Wolv::Ast::IntLit(value:) then value.to_s
    in Wolv::Ast::StrLit(value:) then "\"#{value}\""
    in Wolv::Ast::BoolLit(value:) then value ? "true" : "false"
    in Wolv::Ast::NilLit then "nil"
    in Wolv::Ast::UnitLit then "()"
    in Wolv::Ast::Var(name:) then name
    in Wolv::Ast::Neg(operand:) then "(~ #{shape(operand)})"
    in Wolv::Ast::Bin | Wolv::Ast::Logic then "(#{e.op} #{shape(e.lhs)} #{shape(e.rhs)})"
    in Wolv::Ast::Assign(target:, value:) then "(:= #{shape(target)} #{shape(value)})"
    in Wolv::Ast::If(cond:, els:)
      "(if #{shape(cond)} #{shape(e.then)}#{els.nil? ? '' : " #{shape(els)}"})"
    in Wolv::Ast::While(cond:, body:) then "(while #{shape(cond)} #{shape(body)})"
    in Wolv::Ast::For(name:, lo:, hi:, body:)
      "(for #{name} #{shape(lo)} #{shape(hi)} #{shape(body)})"
    in Wolv::Ast::Break then "break"
    in Wolv::Ast::Seq(items:) then "(seq #{items.map { |i| shape(i) }.join(' ')})"
    in Wolv::Ast::Call(name:, args:) then "(#{name} #{args.map { |a| shape(a) }.join(' ')})"
    in Wolv::Ast::Index(array:, index:) then "(index #{shape(array)} #{shape(index)})"
    in Wolv::Ast::Field(record:, name:) then "(field #{shape(record)} #{name})"
    in Wolv::Ast::RecordLit(tyname:, fields:)
      inner = fields.map { |f| "#{f.name}=#{shape(f.value)}" }.join(" ")
      "(record #{tyname} #{inner})"
    in Wolv::Ast::Let(decls:, body:) then "(let #{decls.length} #{shape(body)})"
    end
  end

  def sketch(source) = shape(Wolv::Parser.parse_exp(source))

  def refuses(message, source)
    error = assert_raises(Wolv::ParseError) { Wolv::Parser.parse_exp(source) }
    assert_includes error.message, message
  end

  def test_arithmetic_precedence
    assert_equal "(+ 1 (* 2 3))", sketch("1 + 2 * 3")
    assert_equal "(+ (* 1 2) 3)", sketch("1 * 2 + 3")
    assert_equal "(- (- 1 2) 3)", sketch("1 - 2 - 3")
    assert_equal "(= (+ 1 2) 3)", sketch("1 + 2 = 3")
  end

  def test_logic_binds_looser_than_comparison
    assert_equal "(andalso (< a b) (> c d))", sketch("a < b andalso c > d")
    assert_equal "(orelse a (andalso b c))", sketch("a orelse b andalso c")
  end

  def test_assignment_is_right_associative_and_loosest
    assert_equal "(:= x (+ y 1))", sketch("x := y + 1")
  end

  def test_a_branch_swallows_what_follows_it
    assert_equal "(if c (:= x 1) (:= x 2))", sketch("if c then x := 1 else x := 2")
    assert_equal "(if c a (+ b 1))", sketch("if c then a else b + 1")
  end

  def test_postfix_chains
    assert_equal "(index (field (index a i) f) j)", sketch("a[i].f[j]")
    assert_equal "(field (f 1 2) g)", sketch("f(1, 2).g")
  end

  def test_sequences_and_unit
    assert_equal "()", sketch("()")
    assert_equal "(seq a b c)", sketch("(a; b; c)")
    assert_equal "a", sketch("(a)")
  end

  def test_negation_is_a_tilde
    assert_equal "(+ (~ x) 1)", sketch("~x + 1")
    refuses "negation is written", "-x"
  end

  def test_a_record_literal_is_not_a_call
    assert_equal "(record point x=1 y=2)", sketch("point { x = 1, y = 2 }")
    assert_equal "(point 1 2)", sketch("point (1, 2)")
  end

  def test_let_with_declarations
    assert_equal "(let 2 (+ x y))", sketch("let val x = 1 var y = 2 in x + y end")
  end

  def test_a_program_is_declarations
    prog = Wolv::Parser.parse("type t = int\nval x = 1\nfun f (a : int) : int = a\n")
    assert_equal [Wolv::Ast::TypeDecl, Wolv::Ast::ValDecl, Wolv::Ast::FunDecl],
                 prog.map(&:class)
  end

  def test_mutual_recursion_is_one_declaration
    prog = Wolv::Parser.parse("fun f () : int = g ()\nand g () : int = 1\n")
    assert_equal %w[f g], prog.first.binds.map(&:name)
  end

  def test_only_a_place_can_be_assigned
    refuses "not assignable", "1 + 2 := 3"
  end

  def test_errors_name_what_was_expected
    refuses "expected `then`", "if a do b"
  end
end
