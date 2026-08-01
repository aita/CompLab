# frozen_string_literal: true

module Wolv
  # Semantic types, and the symbols that carry them.
  #
  # Types are monomorphic.  Records are nominal — two record types with the same
  # fields are different types — and everything else is structural, which for
  # this language means arrays compare by their element type.
  #
  # The five ground types are symbols, because that is all they are: a name with
  # nothing inside.  The two that carry something are objects, and a record is
  # compared by identity, which `equal?` gives directly.
  module Types
    GROUND = %i[int string bool unit nil].freeze

    # Built empty first, because a record may name itself:
    # `type list = {head: int, tail: list}` needs `list` to exist before its
    # fields can be typed.
    class Record
      attr_reader :name
      attr_accessor :fields

      def initialize(name, fields = [])
        @name = name
        @fields = fields
      end

      def index(name) = fields.index { |fname, _| fname == name } || -1

      def field_type(name)
        found = fields.assoc(name)
        found && found[1]
      end

      def to_s = name
    end

    class ArrayOf
      attr_reader :elem

      def initialize(elem) = @elem = elem

      def to_s = "#{Types.show(elem)} array"
    end

    # Every type answers to `to_s`, ground ones because a symbol does.
    def self.show(ty) = ty.to_s

    # Type equality: nominal for records, structural for arrays.
    def self.same?(a, b)
      if a.is_a?(Record) || b.is_a?(Record)
        a.equal?(b)
      elsif a.is_a?(ArrayOf) && b.is_a?(ArrayOf)
        same?(a.elem, b.elem)
      elsif a.is_a?(ArrayOf) || b.is_a?(ArrayOf)
        false
      else
        a == b
      end
    end

    # Equality, but `nil` stands in for any record.
    def self.compatible?(a, b)
      return true if a == :nil && (b.is_a?(Record) || b == :nil)
      return true if b == :nil && (a.is_a?(Record) || a == :nil)

      same?(a, b)
    end

    # -- symbols ------------------------------------------------------------

    # Where a variable lives, once lowering has decided.  Two classes and not a
    # slot number beside a register number beside a flag: a frame slot may be
    # negative — that is an argument the caller left on the stack — so no number
    # is free to mean "not decided yet".
    InRegister = Data.define(:reg)
    InFrame = Data.define(:slot)

    # One binding occurrence of a variable.  `depth` is the static nesting depth
    # of the function that binds it: a variable read from a deeper function
    # escapes, and then it lives in a frame slot instead of a register.
    class VarSym
      attr_reader :name, :ty, :mutable, :depth
      attr_accessor :escapes, :home

      def initialize(name, ty, mutable, depth)
        @name = name
        @ty = ty
        @mutable = mutable
        @depth = depth
        @escapes = false
        @home = nil
      end

      def reg = home.reg
      def slot = home.slot
      def to_s = name
    end

    # A function.  Functions are not values, so there is no function type.
    FunSym = Data.define(:name, :label, :params, :result, :depth, :builtin) do
      def to_s = name
    end
  end
end
