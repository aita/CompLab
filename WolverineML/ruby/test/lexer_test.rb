# frozen_string_literal: true

require_relative "helper"

class LexerTest < Minitest::Test
  def kinds(source) = Wolv::Lexer.lex(source).map(&:kind)

  def refuses(message, source)
    error = assert_raises(Wolv::LexError) { Wolv::Lexer.lex(source) }
    assert_includes error.message, message
  end

  def test_keywords_are_not_identifiers
    assert_equal %i[LET VAL EOF], kinds("let val")
    assert_equal %i[IDENT EOF], kinds("letter")
  end

  def test_the_longest_punctuation_wins
    assert_equal %i[ASSIGN COLON LE LT NE GE EOF], kinds(":= : <= < <> >=")
  end

  def test_comments_nest
    assert_equal %i[INT EOF], kinds("(* a (* b *) c *) 1")
  end

  def test_an_unterminated_comment_is_an_error
    refuses "unterminated comment", "(* forever"
  end

  def test_string_escapes
    source = <<~'SOURCE'.chomp
      "a\nb\t\"\\\065"
    SOURCE
    assert_equal "a\nb\t\"\\A", Wolv::Lexer.lex(source).first.text
  end

  # Source text contributes its UTF-8; `\ddd` names one byte of it.
  def test_a_string_is_bytes
    assert_equal Wolv::Lexer.lex('"日"').first.text, Wolv::Lexer.lex('"\230\151\165"').first.text
    assert_equal 9, Wolv::Lexer.lex('"日本語"').first.text.length
  end

  def test_a_numeric_escape_is_three_digits
    refuses "three digits", '"\65"'
  end

  def test_a_string_may_not_span_lines
    refuses "may not span lines", "\"one\ntwo\""
  end

  def test_spans_count_from_one
    tokens = Wolv::Lexer.lex("val\n  x")
    assert_equal [1, 1], [tokens[0].span.line, tokens[0].span.col]
    assert_equal [2, 3], [tokens[1].span.line, tokens[1].span.col]
  end

  def test_a_number_may_not_run_into_a_name
    refuses "is not a number", "12ab"
  end

  def test_a_stray_character_is_an_error
    refuses "stray character", "a ? b"
  end
end
