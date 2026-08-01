# frozen_string_literal: true

require_relative "helper"

# The allocator, the parallel copies, and what the emitter does with them.
class AllocatorTest < Minitest::Test
  include Helper

  SOURCE = <<~SOURCE
    type point = { x : int, y : int }

    fun busy (n : int) : int =
      let
        var a = n + 1
        var b = n + 2
        var c = n + 3
        var d = n + 4
        var total = 0
      in
        while a < n * 10 do (
          total := total + a * b + c * d;
          a := a + 1;
          b := b + 2;
          c := c + 3;
          d := d + 4
        );
        total
      end

    fun caller (n : int) : int = busy (n) + busy (n + 1) + busy (n + 2)

    val p = point { x = 1, y = 2 }
    val () = printInt (caller (3) + p.x)
  SOURCE

  # The pipeline up to the point where the allocator takes over.
  def prepared(source = SOURCE)
    mod = in_ssa(source, checks: true)
    Wolv::Opt.optimise(mod)
    mod.funcs.each { |f| Wolv::SSA.split_critical_edges(f) }
    Wolv::Select.select_module(mod)
    Wolv::OutOfSSA.destruct_module(mod)
    mod
  end

  def allocated(machine = Wolv::Registers.whole, source = SOURCE)
    mod = prepared(source)
    Wolv::Allocator.allocate_module(mod, machine)
    mod
  end

  # -- what the colouring promises ------------------------------------------

  def test_every_value_gets_a_colour
    allocated.funcs.each do |func|
      instructions(func).each do |i|
        i.uses.each { |r| assert func.colours.key?(r) }
        assert func.colours.key?(i.defs) unless i.defs.nil?
      end
    end
  end

  def test_values_live_together_differ
    allocated.funcs.each { |func| Wolv::Allocator.verify(func) }
  end

  # One colour for everything is wrong, and has to be said so.  Without this,
  # weakening the verifier enough to accept a coalesced copy would go unnoticed
  # if it also stopped saying anything at all.
  def test_the_verifier_rejects_a_real_clash
    allocated.funcs.each do |func|
      next if func.colours.values.uniq.length < 2

      func.colours = func.colours.transform_values { 0 }
      error = assert_raises(RuntimeError) { Wolv::Allocator.verify(func) }
      assert_includes error.message, "at once"
    end
  end

  # Both ends of a copy are live after it, and hold the same value.  Coalescing
  # gives them one register, so a verifier that read a whole live set and
  # complained would reject every program it had worked on.
  def test_the_verifier_accepts_a_coalesced_copy
    func = Wolv::IR::Func.new("f", "f", 0)
    entry = func.add_block("entry")
    a = func.new_reg
    b = func.new_reg
    entry.instrs << Wolv::IR::Const.new(a, 1)
    entry.instrs << Wolv::IR::Move.new(b, a)
    entry.instrs << Wolv::IR::Call.new(nil, "wol_print_int", [a])
    entry.instrs << Wolv::IR::Ret.new(b)
    Wolv::IR.recompute_preds(func)
    func.colours = { a => 9, b => 9 }
    Wolv::Allocator.verify(func)
  end

  def test_a_value_live_across_a_call_is_callee_saved
    allocated.funcs.each do |func|
      live = Wolv::Liveness.analyse(func)
      Wolv::Liveness.across_calls(func, live).each do |reg|
        assert_includes Wolv::Registers::CALLEE_SAVED, func.colours[reg]
      end
    end
  end

  def test_only_the_callee_saved_it_used_are_saved
    allocated.funcs.each do |func|
      assert_equal (func.colours.values.uniq & Wolv::Registers::CALLEE_SAVED).sort,
                   func.saved.sort
    end
  end

  def test_a_smaller_machine_still_works
    [5, 6, 8, 12, 16, 26].each do |size|
      machine = Wolv::Registers.limited(size)
      allocated(machine).funcs.each do |func|
        Wolv::Allocator.verify(func)
        func.colours.each_value { |colour| assert_includes machine.anywhere, colour }
      end
    end
  end

  def test_a_small_machine_spills
    mod = allocated(Wolv::Registers.limited(6))
    assert mod.funcs.any? { |f| f.spill_slots.any? }, "nothing spilled"
    mod.funcs.each do |func|
      func.spill_slots.each_value { |slot| assert_operator slot, :<, func.nslots }
    end
  end

  def test_pressure_falls_to_what_the_machine_has
    machine = Wolv::Registers.limited(5)
    allocated(machine).funcs.each do |func|
      assert_operator Wolv::Liveness.pressure(func, Wolv::Liveness.analyse(func)),
                      :<=, machine.count
    end
  end

  def test_an_impossible_demand_is_reported
    mod = prepared(<<~SOURCE)
      fun ten (a : int, b : int, c : int, d : int, e : int,
               f : int, g : int, h : int, i : int, j : int) : int = a + j
      val () = printInt (ten (1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
    SOURCE
    error = assert_raises(Wolv::Spill::OutOfRegisters) do
      Wolv::Allocator.allocate_module(mod, Wolv::Registers.limited(8))
    end
    assert_includes error.message, "more registers"
  end

  # -- what coalescing is for -----------------------------------------------

  def test_leaving_ssa_removes_every_phi
    prepared.funcs.each { |func| func.walk.each { |b| assert_empty b.phis } }
  end

  def test_leaving_ssa_makes_copies_and_coalescing_eats_them
    mod = prepared
    before = mod.funcs.sum { |f| instructions(f).count { |i| i.is_a?(Wolv::IR::Move) } }
    assert_operator before, :>, 0, "leaving SSA should have made copies"
    Wolv::Allocator.allocate_module(mod)
    left = mod.funcs.sum do |f|
      instructions(f).count do |i|
        i.is_a?(Wolv::IR::Move) && f.colours[i.dst] != f.colours[i.src]
      end
    end
    assert_operator left, :<=, before / 10, "#{left} of #{before} copies survived"
  end

  # -- parallel copies ------------------------------------------------------

  # Run a parallel copy on a register file and insist the permutation came out
  # right.  This is what caught a swap the ordering was doing twice.
  def worked(moves, borrowed)
    before = (0...32).to_h { |r| [r, "v#{r}"] }
    steps = Wolv::Copies.sequentialize(moves, borrowed)
    after = before.dup
    steps.each do |step|
      case step
      when Wolv::Copies::Mov then after[step.dst] = after[step.src]
      when Wolv::Copies::Swap then after[step.a], after[step.b] = after[step.b], after[step.a]
      end
    end
    moves.each { |dst, src| assert_equal before[src], after[dst], "x#{dst} should hold v#{src}" }
    steps
  end

  def test_a_copy_with_no_cycle_is_just_moves
    steps = worked([[1, 2], [3, 4], [5, 5]], 9)
    assert steps.all? { |s| s.is_a?(Wolv::Copies::Mov) }
    assert_equal 2, steps.length
  end

  def test_a_chain_is_ordered_so_nothing_is_lost
    worked([[1, 2], [2, 3], [3, 4]], 9)
  end

  def test_a_cycle_borrows_a_register_when_there_is_one
    steps = worked([[1, 2], [2, 1]], 9)
    assert steps.all? { |s| s.is_a?(Wolv::Copies::Mov) }
    assert steps.any? { |s| s.dst == 9 }
  end

  def test_a_cycle_swaps_when_there_is_nothing_to_borrow
    steps = worked([[1, 2], [2, 1]], nil)
    assert_equal [true], steps.map { |s| s.is_a?(Wolv::Copies::Swap) }
  end

  def test_a_longer_cycle_swaps_its_way_round
    steps = worked([[1, 2], [2, 3], [3, 1]], nil)
    assert steps.all? { |s| s.is_a?(Wolv::Copies::Swap) }
    assert_equal 2, steps.length
  end

  def test_two_cycles_at_once
    worked([[1, 2], [2, 1], [3, 4], [4, 3]], nil)
    worked([[1, 2], [2, 1], [3, 4], [4, 3]], 9)
  end

  # -- what the scratch registers used to be for ----------------------------

  def asm(source) = Wolv::Driver.compile_to_asm(source, Wolv::Driver::Options.new)

  def test_the_remainder_is_a_divide_and_an_msub
    text = asm("fun f (a : int, b : int) : int = a mod b\nval () = printInt (f (7, 2))")
    assert_equal 1, text.scan("sdiv").length
    assert_equal 1, text.scan("msub").length
    refute_includes text, "mul"
  end

  # x17 is only for an address the emitter cannot reach any other way.
  def test_ordinary_code_keeps_no_register_back
    refute_includes asm(File.read(File.join(Helper::EXAMPLES, "tour.wol"))), "x17"
  end

  # It used to be held back for the emitter; a busy function should take it.
  def test_x16_is_allocatable
    assert_includes asm(File.read(File.join(Helper::HERE, "programs", "pressure.wol"))), "x16"
  end
end
