# frozen_string_literal: true

require_relative "helper"
require_relative "oracle"

# Random programs, compiled and checked against what the oracle says they mean.
class RandomTest < Minitest::Test
  CONFIGURATIONS = {
    "default" => Wolv::Driver::Options.new,
    "no-opt" => Wolv::Driver::Options.new(optimise: false),
    "spilling" => Wolv::Driver::Options.new(max_regs: 10)
  }.freeze

  def toolchain
    skip "no ARM toolchain" unless Wolv::Driver.toolchain?
  end

  # The first line that differs is the useful part of the answer.
  def agrees(source, expected, opts, what)
    done = Wolv::Driver.run(source, opts)
    assert_equal 0, done.code, done.stderr
    got = done.stdout.lines.map(&:chomp)
    want = expected.lines.map(&:chomp)
    got.zip(want).each_with_index do |(g, w), i|
      assert_equal w, g, "#{what}, line #{i}"
    end
    assert_equal want.length, got.length, what
  end

  def test_arithmetic
    toolchain
    [1, 2].product(CONFIGURATIONS.to_a).each do |seed, (name, opts)|
      source, expected = Oracle.arithmetic(seed, 25)
      agrees(source, expected, opts, "arithmetic #{seed} [#{name}]")
    end
  end

  def test_arrays_loops_and_branches
    toolchain
    [1, 2].product(CONFIGURATIONS.to_a).each do |seed, (name, opts)|
      source, expected = Oracle.imperative(seed, 8)
      agrees(source, expected, opts, "imperative #{seed} [#{name}]")
    end
  end

  # Force the swap: the borrowed register is what usually hides this path.  The
  # recursive call swaps its two arguments, so the copies into `x0` and `x1` are
  # a cycle that has to be untangled somehow.
  def test_a_cycle_of_copies_can_be_done_without_a_scratch_register
    toolchain
    source = <<~'SOURCE'
      fun swap (a : int, b : int) : int =
        if a > b then swap (b, a) else b * 10 + a
      val () = (printInt (swap (1, 2)); print (" "); printInt (swap (7, 3)))
    SOURCE
    assert_equal "21 73", Wolv::Driver.run(source, Wolv::Driver::Options.new).stdout
    begin
      Wolv::Emit.borrow = false
      assert_includes Wolv::Driver.compile_to_asm(source, Wolv::Driver::Options.new), "eor x"
      assert_equal "21 73", Wolv::Driver.run(source, Wolv::Driver::Options.new).stdout
    ensure
      Wolv::Emit.borrow = true
    end
  end
end
