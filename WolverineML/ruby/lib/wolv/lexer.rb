# frozen_string_literal: true

require "strscan"
require_relative "diag"

module Wolv
  # Tokens, and the scanner that produces them.
  #
  # The scanning is `StringScanner`'s: every rule below is a regular expression
  # anchored at the cursor, and the cursor only ever moves by matching one.  What
  # the class does not keep is the line and the column, which are what every
  # error message and the `tokens` dump are made of, so `eat` counts them out of
  # the text each match consumed.
  module Lexer
    # A token kind is a symbol, so the name a dump prints is the kind itself
    # written down.  The table is the other direction — what an error message
    # calls a kind — and it is the only place either is written.
    KIND_TEXT = {
      INT: "an integer", STRING: "a string", IDENT: "an identifier",
      EOF: "end of input",

      AND: "and", ANDALSO: "andalso", BREAK: "break", DO: "do", ELSE: "else",
      END: "end", FALSE: "false", FOR: "for", FUN: "fun", IF: "if", IN: "in",
      LET: "let", MOD: "mod", NIL: "nil", ORELSE: "orelse", THEN: "then",
      TO: "to", TRUE: "true", TYPE: "type", VAL: "val", VAR: "var",
      WHILE: "while",

      LPAREN: "(", RPAREN: ")", LBRACK: "[", RBRACK: "]", LBRACE: "{",
      RBRACE: "}", COMMA: ",", COLON: ":", SEMI: ";", DOT: ".", ASSIGN: ":=",
      EQ: "=", NE: "<>", LE: "<=", LT: "<", GE: ">=", GT: ">", PLUS: "+",
      MINUS: "-", STAR: "*", SLASH: "/", CARET: "^", TILDE: "~"
    }.freeze

    NAMED = %i[INT STRING IDENT EOF].freeze

    KEYWORDS = KIND_TEXT.reject { |kind, text| NAMED.include?(kind) || !text.match?(/\A[[:alpha:]]+\z/) }
                        .to_h { |kind, text| [text, kind] }
                        .freeze

    # Longest first, so that `:=` beats `:` and `<=` beats `<`.  `Regexp.union`
    # keeps that order, and an alternation tries its branches in order, so the
    # table is the precedence.
    PUNCTUATION = KIND_TEXT.reject { |kind, text| NAMED.include?(kind) || text.match?(/\A[[:alpha:]]/) }
                           .map { |kind, text| [text, kind] }
                           .sort_by { |text, _| -text.length }
                           .freeze

    PUNCTUATION_KIND = PUNCTUATION.to_h.freeze
    PUNCTUATION_RE = Regexp.union(PUNCTUATION.map(&:first)).freeze

    SPACE = /[ \t\r\n]+/.freeze
    NUMBER = /[[:digit:]]+/.freeze
    WORD = /[[:alpha:]_][[:alnum:]_']*/.freeze
    PLAIN = /[^"\n\\]+/.freeze # the run of a string literal that needs no work
    OPEN = /\(\*/.freeze
    CLOSE = /\*\)/.freeze

    ESCAPES = { "n" => "\n", "t" => "\t", "r" => "\r", '"' => '"', "\\" => "\\" }.freeze

    Token = Data.define(:kind, :text, :span) do
      def to_s
        case kind
        when :EOF then "end of input"
        when :STRING then "\"#{text}\""
        else "`#{text}`"
        end
      end
    end

    # Source text into tokens, in one pass.
    class Scanner
      def initialize(source)
        @ss = StringScanner.new(source)
        @line = 1
        @col = 1
      end

      def tokens
        out = []
        out << self.next until out.last&.kind == :EOF
        out
      end

      def next
        skip_trivia
        at = here
        return Token.new(:EOF, "", at) if @ss.eos?

        text = eat(NUMBER) and return number(text, at)
        text = eat(WORD) and return Token.new(KEYWORDS.fetch(text, :IDENT), text, at)
        return string(at) if eat(/"/)

        text = eat(PUNCTUATION_RE)
        raise LexError.new(at, "stray character `#{@ss.check(/./m)}`") unless text

        Token.new(PUNCTUATION_KIND.fetch(text), text, at)
      end

      private

      def here = Span.new(@line, @col)

      # Match at the cursor, and keep the line and column in step with whatever
      # that consumed.
      def eat(pattern)
        text = @ss.scan(pattern)
        return nil unless text

        text.each_char do |c|
          if c == "\n"
            @line += 1
            @col = 1
          else
            @col += 1
          end
        end
        text
      end

      def number(text, at)
        trailing = @ss.check(/[[:alpha:]_]/)
        raise LexError.new(at, "`#{text}#{trailing}` is not a number") if trailing

        Token.new(:INT, text, at)
      end

      # A string literal is a sequence of bytes.  `size`, `ord` and `substring`
      # count bytes at run time, so a literal is read as bytes here too: source
      # text contributes its UTF-8 encoding, and `\ddd` names one byte.  The text
      # comes out in ASCII-8BIT, where one character is one byte, which is what
      # `Emit.escape` writes back out.
      def string(at)
        parts = +"".b
        loop do
          raise LexError.new(at, "unterminated string") if @ss.eos?
          raise LexError.new(here, "a string may not span lines") if @ss.check(/\n/)
          return Token.new(:STRING, parts, at) if eat(/"/)

          if eat(/\\/)
            parts << escape
          else
            parts << eat(PLAIN).b
          end
        end
      end

      def escape
        raise LexError.new(here, "unterminated escape") if @ss.eos?

        digits = @ss.check(/[[:digit:]]{3}/)
        if digits && digits.to_i < 256
          eat(/[[:digit:]]{3}/)
          return digits.to_i.chr
        end
        raise LexError.new(here, 'a numeric escape is three digits, `\065`') if @ss.check(/[[:digit:]]/)

        named = eat(Regexp.union(ESCAPES.keys))
        raise LexError.new(here, "unknown escape `\\#{@ss.check(/./m)}`") unless named

        ESCAPES[named].b
      end

      def skip_trivia
        loop do
          next if eat(SPACE)
          break unless @ss.check(OPEN)

          comment
        end
      end

      # Comments nest, which is why this counts rather than looks for the end.
      def comment
        at = here
        depth = 0
        until @ss.eos?
          if eat(OPEN)
            depth += 1
          elsif eat(CLOSE)
            depth -= 1
            return if depth.zero?
          else
            eat(/./m)
          end
        end
        raise LexError.new(at, "unterminated comment")
      end
    end

    def self.lex(source) = Scanner.new(source).tokens

    # A string literal's text is bytes, and this dump writes each one as the
    # character at that code point — which is what the other ports print,
    # because in them a literal is already a string of those characters.
    def self.dump(tokens)
      tokens.map do |t|
        text = t.kind == :STRING ? t.text.each_byte.map { |b| [b].pack("U") }.join : t.text
        "#{t.span}\t#{t.kind}\t#{text}"
      end.join("\n")
    end
  end
end
