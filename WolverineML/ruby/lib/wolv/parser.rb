# frozen_string_literal: true

require_relative "ast"
require_relative "diag"
require_relative "lexer"

module Wolv
  # A Pratt parser.
  #
  # Every expression form is either a prefix form (in `atom`) or an infix one
  # (in `exp`), and the table below is the whole of the precedence.  The prefix
  # forms that end in an expression — `if`, `while`, `for`, `:=` — take their
  # tail at binding power 0, so `if c then x := 1 else x := 2` reads the way it
  # looks.
  class Parser
    # The left binding power and the power the right side is read at.  Left <
    # right is left-associative; left > right is right-associative, which only
    # `:=` is.
    BP = {
      ASSIGN: [2, 1],
      ORELSE: [4, 5],
      ANDALSO: [6, 7],
      EQ: [8, 9], NE: [8, 9], LT: [8, 9], LE: [8, 9], GT: [8, 9], GE: [8, 9],
      CARET: [10, 11],
      PLUS: [12, 13], MINUS: [12, 13],
      STAR: [14, 15], SLASH: [14, 15], MOD: [14, 15]
    }.freeze

    UNARY_BP = 16

    BINOPS = {
      PLUS: "+", MINUS: "-", STAR: "*", SLASH: "/", MOD: "mod", CARET: "^",
      EQ: "=", NE: "<>", LT: "<", LE: "<=", GT: ">", GE: ">="
    }.freeze

    DECL_STARTERS = %i[VAL VAR FUN TYPE].freeze

    def initialize(tokens)
      @toks = tokens
      @pos = 0
    end

    def self.parse(source) = new(Lexer.lex(source)).program

    # Parse a single expression — the tests use it, the compiler does not.
    def self.parse_exp(source)
      p = new(Lexer.lex(source))
      e = p.exp(0)
      raise ParseError.new(p.cur.span, "unexpected #{p.cur} after the expression") unless p.at?(:EOF)

      e
    end

    # -- token plumbing ----------------------------------------------------

    def cur = @toks[@pos]

    def at?(kind) = cur.kind == kind

    def take(kind)
      return nil unless cur.kind == kind

      tok = cur
      @pos += 1
      tok
    end

    def expect(kind)
      take(kind) or raise ParseError.new(cur.span, "expected `#{Lexer::KIND_TEXT[kind]}`, found #{cur}")
    end

    def expect_ident
      take(:IDENT) or raise ParseError.new(cur.span, "expected a name, found #{cur}")
    end

    # Every list in this grammar is one or more of something with a separator
    # between, so it is one method and the block says what the something is.
    def separated_by(kind)
      items = [yield]
      items << yield while take(kind)
      items
    end

    # ... and every bracketed list may also be empty, which is one token of
    # lookahead away.
    def bracketed(opener, closer, separator = :COMMA)
      expect(opener)
      items = at?(closer) ? [] : separated_by(separator) { yield }
      expect(closer)
      items
    end

    # -- programs and declarations ----------------------------------------

    def program
      decls = []
      decls << decl until at?(:EOF)
      decls
    end

    def decl
      case cur.kind
      when :TYPE then type_decl
      when :VAL, :VAR then val_decl
      when :FUN then fun_decl
      else
        raise ParseError.new(cur.span,
                             "expected a declaration (`val`, `var`, `fun`, `type`), found #{cur}")
      end
    end

    def type_decl
      span = expect(:TYPE).span
      Ast::TypeDecl.new(span, separated_by(:AND) { type_bind })
    end

    def type_bind
      name = expect_ident
      expect(:EQ)
      Ast::TypeBind.new(name.text, ty, name.span)
    end

    def val_decl
      mutable = at?(:VAR)
      span = cur.span
      @pos += 1
      name = if take(:LPAREN)
               expect(:RPAREN)
               nil
             else
               expect_ident.text
             end
      written = take(:COLON) ? ty : nil
      expect(:EQ)
      Ast::ValDecl.new(span, name, written, exp(0), mutable)
    end

    def fun_decl
      span = expect(:FUN).span
      Ast::FunDecl.new(span, separated_by(:AND) { fun_bind })
    end

    def fun_bind
      name = expect_ident
      params = bracketed(:LPAREN, :RPAREN) { param }
      result = take(:COLON) ? ty : nil
      expect(:EQ)
      Ast::FunBind.new(name.text, params, result, exp(0), name.span)
    end

    def param
      name = expect_ident
      expect(:COLON)
      Ast::Param.new(name.text, ty, name.span)
    end

    # -- types --------------------------------------------------------------

    def ty
      span = cur.span
      base =
        if at?(:LBRACE)
          Ast::TyRecord.new(span, bracketed(:LBRACE, :RBRACE) { ty_field })
        elsif take(:LPAREN)
          inner = ty
          expect(:RPAREN)
          inner
        else
          Ast::TyName.new(span, expect_ident.text)
        end
      while at?(:IDENT) && cur.text == "array"
        @pos += 1
        base = Ast::TyArray.new(span, base)
      end
      base
    end

    def ty_field
      name = expect_ident
      expect(:COLON)
      Ast::TyField.new(name.text, ty, name.span)
    end

    # -- expressions --------------------------------------------------------

    def exp(min_bp)
      left = atom
      loop do
        bp = BP[cur.kind]
        return left if bp.nil? || bp[0] < min_bp

        tok = cur
        @pos += 1
        left =
          case tok.kind
          when :ASSIGN
            check_lvalue(left)
            Ast::Assign.new(tok.span, left, exp(bp[1]))
          when :ANDALSO, :ORELSE
            Ast::Logic.new(tok.span, tok.text, left, exp(bp[1]))
          else
            Ast::Bin.new(tok.span, BINOPS[tok.kind], left, exp(bp[1]))
          end
      end
    end

    def check_lvalue(e)
      return if e.is_a?(Ast::Var) || e.is_a?(Ast::Index) || e.is_a?(Ast::Field)

      raise ParseError.new(e.span, "the left of `:=` is not assignable")
    end

    def atom
      tok = cur
      span = tok.span
      case tok.kind
      when :INT
        @pos += 1
        postfix(Ast::IntLit.new(span, tok.text.to_i))
      when :STRING
        @pos += 1
        postfix(Ast::StrLit.new(span, tok.text))
      when :TRUE, :FALSE
        @pos += 1
        Ast::BoolLit.new(span, tok.kind == :TRUE)
      when :NIL
        @pos += 1
        Ast::NilLit.new(span)
      when :BREAK
        @pos += 1
        Ast::Break.new(span)
      when :TILDE
        @pos += 1
        Ast::Neg.new(span, exp(UNARY_BP))
      when :MINUS
        raise ParseError.new(span, "negation is written `~`, not `-`")
      when :LPAREN then postfix(parens)
      when :IDENT then postfix(named)
      when :IF then if_exp
      when :WHILE then while_exp
      when :FOR then for_exp
      when :LET then let_exp
      else
        raise ParseError.new(span, "expected an expression, found #{cur}")
      end
    end

    def parens
      span = expect(:LPAREN).span
      return Ast::UnitLit.new(span) if take(:RPAREN)

      items = sequence(:RPAREN)
      expect(:RPAREN)
      items.length == 1 ? items[0] : Ast::Seq.new(span, items)
    end

    def sequence(final)
      items = [exp(0)]
      while take(:SEMI)
        break if at?(final)

        items << exp(0)
      end
      items
    end

    def named
      tok = expect_ident
      case cur.kind
      when :LPAREN
        Ast::Call.new(tok.span, tok.text, bracketed(:LPAREN, :RPAREN) { exp(0) })
      when :LBRACE
        Ast::RecordLit.new(tok.span, tok.text, bracketed(:LBRACE, :RBRACE) { field_init })
      else
        Ast::Var.new(tok.span, tok.text)
      end
    end

    def field_init
      name = expect_ident
      expect(:EQ)
      Ast::FieldInit.new(name.text, exp(0), name.span)
    end

    def postfix(base)
      loop do
        case cur.kind
        when :LBRACK
          span = cur.span
          @pos += 1
          index = exp(0)
          expect(:RBRACK)
          base = Ast::Index.new(span, base, index)
        when :DOT
          span = cur.span
          @pos += 1
          base = Ast::Field.new(span, base, expect_ident.text, nil, -1)
        else
          return base
        end
      end
    end

    def if_exp
      span = expect(:IF).span
      cond = exp(0)
      expect(:THEN)
      then_branch = exp(0)
      Ast::If.new(span, cond, then_branch, take(:ELSE) ? exp(0) : nil)
    end

    def while_exp
      span = expect(:WHILE).span
      cond = exp(0)
      expect(:DO)
      Ast::While.new(span, cond, exp(0))
    end

    def for_exp
      span = expect(:FOR).span
      name = expect_ident
      expect(:EQ)
      lo = exp(0)
      expect(:TO)
      hi = exp(0)
      expect(:DO)
      Ast::For.new(span, name.text, lo, hi, exp(0))
    end

    def let_exp
      span = expect(:LET).span
      decls = []
      decls << decl while DECL_STARTERS.include?(cur.kind)
      expect(:IN)
      body =
        if at?(:END)
          Ast::UnitLit.new(span)
        else
          items = sequence(:END)
          items.length == 1 ? items[0] : Ast::Seq.new(span, items)
        end
      expect(:END)
      Ast::Let.new(span, decls, body)
    end
  end
end
