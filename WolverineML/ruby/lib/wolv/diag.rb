# frozen_string_literal: true

module Wolv
  # A position in the source, counted from one.
  Span = Data.define(:line, :col) do
    def to_s = "#{line}:#{col}"
  end

  # A user-facing compile error, carrying where it happened.  The three
  # subclasses exist so that a test can ask for the one it means; nothing in the
  # compiler tells them apart.
  class Error < StandardError
    attr_reader :span, :detail

    def initialize(span, detail)
      @span = span
      @detail = detail
      super("#{span}: #{detail}")
    end
  end

  class LexError < Error; end
  class ParseError < Error; end

  # Not `TypeError`: inside `module Wolv` that name would shadow Ruby's, and
  # Ruby's is what an ordinary bug in this compiler raises.
  class CheckError < Error; end
end
