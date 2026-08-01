# frozen_string_literal: true

require_relative "ir"

module Wolv
  # The machine IR: what instruction selection replaces the arithmetic with.
  #
  # One instruction, because on this machine an instruction is a form, a
  # register it writes and some it reads.  The form names an entry in the table
  # below, and the table is the whole instruction set the compiler can choose
  # from.
  #
  # The machine IR is this plus the part of `ir.rb` that was already
  # machine-level: a call, a move, a frame slot, a phi and the three
  # terminators.  What it may no longer contain is the arithmetic — `Const`,
  # `StrConst`, `Bin`, `Cmp`, `Load`, `Store` — and `verify` is what says so,
  # because a compiler that quietly kept an abstract instruction until the
  # emitter would only find out there.
  #
  # Four forms are not one instruction each, and the emitter expands them:
  #
  #     const   a constant, which is a `mov` or up to four `movz`/`movk`
  #     adr     the address of a string, which is `adrp` and an `add`
  #     ldr     a load, whose addressing mode depends on how far the offset reaches
  #     str     a store, likewise
  module Mach
    # How each form is written down, once the registers have their colours.
    # `d` is the register written and `s0`, `s1`, `s2` the ones read.
    FORMS = {
      "add" => 'add {d}, {s0}, {s1}',
      "addi" => 'add {d}, {s0}, #{imm}',
      "adds" => 'add {d}, {s0}, {s1}, lsl #{imm}',
      "sub" => 'sub {d}, {s0}, {s1}',
      "subi" => 'sub {d}, {s0}, #{imm}',
      "subs" => 'sub {d}, {s0}, {s1}, lsl #{imm}',
      "mul" => 'mul {d}, {s0}, {s1}',
      "madd" => 'madd {d}, {s0}, {s1}, {s2}',
      "msub" => 'msub {d}, {s0}, {s1}, {s2}',
      "sdiv" => 'sdiv {d}, {s0}, {s1}',
      "and" => 'and {d}, {s0}, {s1}',
      "orr" => 'orr {d}, {s0}, {s1}',
      "eor" => 'eor {d}, {s0}, {s1}',
      "eori" => 'eor {d}, {s0}, #{imm}',
      "lsl" => 'lsl {d}, {s0}, {s1}',
      "lsli" => 'lsl {d}, {s0}, #{imm}',
      "asr" => 'asr {d}, {s0}, {s1}',
      "asri" => 'asr {d}, {s0}, #{imm}',
      "cmp" => 'cmp {s0}, {s1}',
      "cmpi" => 'cmp {s0}, #{imm}',
      "cset" => 'cset {d}, {sym}'
    }.freeze

    # Which condition code each comparison sets, and which one says the opposite
    # — the emitter needs the opposite when the branch it is writing falls
    # through to the block the comparison was true for.
    CONDITION = {
      "=" => "eq", "<>" => "ne", "<" => "lt", "<=" => "le",
      ">" => "gt", ">=" => "ge", "u<" => "lo", "u>=" => "hs"
    }.freeze

    OPPOSITE = {
      "eq" => "ne", "ne" => "eq", "lt" => "ge", "ge" => "lt",
      "gt" => "le", "le" => "gt", "lo" => "hs", "hs" => "lo"
    }.freeze

    # The ones the emitter writes itself, because they are not one instruction.
    EXPANDED = %w[const adr ldr str].freeze

    # The machine instruction: a form, a register it writes and some it reads.
    Instr = Data.define(:form, :dst, :srcs, :imm, :symbol, :effect) do
      include IR::Instr
      def defs = dst
      def uses = srcs
      def map_uses(&f) = with(srcs: srcs.map(&f))
      def with_def(reg) = with(dst: reg)
      def effect? = effect

      def show(name)
        operands = srcs.map { |s| name.(s) }
        if symbol.empty?
          operands << "##{imm}" if imm != 0 || form == "const"
        else
          operands << symbol
        end
        written = "#{form} #{operands.join(', ')}".rstrip
        dst ? "#{name.(dst)} = #{written}" : written
      end
    end

    def self.make(form, dst, srcs, imm: 0, symbol: "", effect: false)
      Instr.new(form, dst, srcs, imm, symbol, effect)
    end

    ABSTRACT = [IR::Const, IR::StrConst, IR::Bin, IR::Cmp, IR::Load, IR::Store].freeze

    # Insist that selection left nothing of the three-address IR behind.
    def self.verify(func)
      func.walk.each do |b|
        b.instrs.each do |i|
          if ABSTRACT.any? { |k| i.is_a?(k) }
            raise "#{i.class} survived selection in #{func.name}:#{b.label}"
          end
          if i.is_a?(Instr) && !FORMS.key?(i.form) && !EXPANDED.include?(i.form)
            raise "no such instruction as `#{i.form}`"
          end
        end
      end
    end

    def self.verify_module(mod) = mod.funcs.each { |f| verify(f) }
  end
end
