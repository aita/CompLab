# frozen_string_literal: true

require_relative "ast"
require_relative "types"

module Wolv
  # An indented dump of the typed syntax tree, for `wolv emit -s ast`.
  module AstShow
    module_function

    # A string literal, written the way the Python tree writes it, so that a
    # dump taken from either is the same dump.  Every character of one is a
    # byte, and a byte that stands for nothing printable is shown as `\xNN`.
    #
    # Python asks a Unicode database which bytes those are.  Over the range a
    # literal can hold — U+0000 to U+00FF — the answer is four fixed ranges: the
    # C0 and C1 controls, no-break space, and the soft hyphen.
    def quoted(text)
      mark = text.include?("'") && !text.include?('"') ? '"' : "'"
      out = +""
      out << mark
      text.each_char do |ch|
        n = ch.ord
        out <<
          if ch == mark || ch == "\\" then "\\#{ch}"
          elsif n == 10 then "\\n"
          elsif n == 13 then "\\r"
          elsif n == 9 then "\\t"
          elsif n <= 0x1F || (0x7F..0xA0).cover?(n) || n == 0xAD then format("\\x%02x", n)
          # A byte that stands for a printable character stands for the one at
          # that code point, which is U+0080 and up written back out as UTF-8.
          else [n].pack("U")
          end
      end
      out << mark
      out
    end

    def show_program(prog)
      lines = []
      prog.each { |d| show_decl(d, 0, lines) }
      "#{lines.join("\n")}\n"
    end

    def put(lines, depth, text) = lines << ("  " * depth) + text

    def escapes(sym) = sym&.escapes ? " (escapes)" : ""

    def of_type(e) = e.ty.nil? ? "" : " : #{Types.show(e.ty)}"

    def show_decl(decl, depth, lines)
      case decl
      in Ast::TypeDecl(binds:)
        binds.each { |b| put(lines, depth, "type #{b.name}") }
      in Ast::ValDecl(name:, init:, mutable:, sym:)
        put(lines, depth, "#{mutable ? 'var' : 'val'} #{name || '()'}#{escapes(sym)}")
        show_exp(init, depth + 1, lines)
      in Ast::FunDecl(binds:)
        binds.each do |f|
          params = f.params.map { |p| "#{p.name}#{escapes(p.sym)}" }.join(", ")
          result = f.sym ? Types.show(f.sym.result) : "?"
          put(lines, depth, "fun #{f.name}(#{params}) : #{result}")
          show_exp(f.body, depth + 1, lines)
        end
      end
    end

    def show_exp(e, depth, lines)
      kids = ->(*es) { es.each { |k| show_exp(k, depth + 1, lines) } }
      case e
      in Ast::IntLit(value:) then put(lines, depth, "int #{value}")
      in Ast::StrLit(value:) then put(lines, depth, "string #{quoted(value)}")
      in Ast::BoolLit(value:) then put(lines, depth, "bool #{value ? 'true' : 'false'}")
      in Ast::NilLit then put(lines, depth, "nil")
      in Ast::UnitLit then put(lines, depth, "()")
      in Ast::Var(name:) then put(lines, depth, "var #{name}#{of_type(e)}")
      in Ast::Call(name:, args:)
        put(lines, depth, "call #{name}#{of_type(e)}")
        args.each { |a| show_exp(a, depth + 1, lines) }
      in Ast::RecordLit(tyname:, fields:)
        put(lines, depth, "record #{tyname}#{of_type(e)}")
        fields.each do |f|
          put(lines, depth + 1, "#{f.name} =")
          show_exp(f.value, depth + 2, lines)
        end
      in Ast::Index(array:, index:)
        put(lines, depth, "index#{of_type(e)}")
        kids.(array, index)
      in Ast::Field(record:, name:)
        put(lines, depth, "field .#{name}#{of_type(e)}")
        kids.(record)
      in Ast::Neg(operand:)
        put(lines, depth, "neg")
        kids.(operand)
      in Ast::Bin | Ast::Logic
        put(lines, depth, "#{e.op}#{of_type(e)}")
        kids.(e.lhs, e.rhs)
      in Ast::Assign(target:, value:)
        put(lines, depth, ":=")
        kids.(target, value)
      in Ast::If(cond:, els:)
        put(lines, depth, "if#{of_type(e)}")
        kids.(cond, e.then)
        show_exp(els, depth + 1, lines) if els
      in Ast::While(cond:, body:)
        put(lines, depth, "while")
        kids.(cond, body)
      in Ast::For(name:, lo:, hi:, body:, sym:)
        put(lines, depth, "for #{name}#{escapes(sym)}")
        kids.(lo, hi, body)
      in Ast::Break then put(lines, depth, "break")
      in Ast::Seq(items:)
        put(lines, depth, "seq#{of_type(e)}")
        items.each { |item| show_exp(item, depth + 1, lines) }
      in Ast::Let(decls:, body:)
        put(lines, depth, "let#{of_type(e)}")
        decls.each { |d| show_decl(d, depth + 1, lines) }
        put(lines, depth, "in")
        show_exp(body, depth + 1, lines)
      end
    end
  end
end
