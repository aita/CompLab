# frozen_string_literal: true

require_relative "helper"

# SSA construction, the optimiser, and instruction selection.
class MiddleTest < Minitest::Test
  include Helper

  LOOP = <<~SOURCE
    fun count (n : int) : int =
      let var i = 0
          var total = 0
      in
        while i < n do (total := total + i; i := i + 1);
        total
      end
    val () = printInt (count (10))
  SOURCE

  def function(body)
    "fun f (a : int, b : int, c : int) : int = #{body}\nval () = printInt (f (1, 2, 3))"
  end

  # The instruction forms chosen inside one function, the caller's aside.
  def forms(source, name = "f", checks: false)
    instructions(func_named(selected(source, checks: checks), name))
      .select { |i| i.is_a?(Wolv::Mach::Instr) }.map(&:form)
  end

  # -- SSA ------------------------------------------------------------------

  def test_lowering_writes_a_variable_more_than_once
    func = build(LOOP).funcs[1]
    written = Hash.new(0)
    instructions(func).each { |i| written[i.defs] += 1 unless i.defs.nil? }
    assert written.values.any? { |n| n > 1 }
    assert func.walk.all? { |b| b.phis.empty? }
  end

  def test_construction_gives_one_definition_and_phis
    func = in_ssa(LOOP).funcs[1]
    Wolv::SSA.verify(func)
    assert func.walk.any? { |b| b.phis.any? }, "a loop needs phis"
  end

  def test_every_function_of_the_tour_verifies
    in_ssa(File.read(File.join(Helper::EXAMPLES, "tour.wol")), checks: true)
      .funcs.each { |f| Wolv::SSA.verify(f) }
  end

  def test_the_dominators_of_a_diamond
    func = in_ssa("fun f (c : bool) : int = if c then 1 else 2\n" \
                  "val () = printInt (f (true))").funcs[1]
    dom = Wolv::SSA.dominance(func)
    func.blocks.each_key { |label| assert dom.dominates?(func.entry, label) }
    joins = func.walk.select { |b| b.preds.length > 1 }
    assert joins.any?, "a diamond has a join"
    joins.each { |join| assert_equal func.entry, dom.idom[join.label] }
  end

  def test_a_phi_names_exactly_its_predecessors
    in_ssa(LOOP).funcs.each do |func|
      func.walk.each do |b|
        b.phis.each { |phi| assert_equal b.preds.sort, phi.args.keys.sort }
      end
    end
  end

  # -- the optimiser --------------------------------------------------------

  def test_constants_fold
    mod = in_ssa("val () = printInt (2 * 3 + 4)")
    Wolv::Opt.optimise(mod)
    values = instructions(mod.funcs.first).select { |i| i.is_a?(Wolv::IR::Const) }.map(&:value)
    assert_equal [10], values
  end

  def test_dead_code_goes
    mod = in_ssa("fun f (n : int) : int = let val unused = n * n in n + 1 end\n" \
                 "val () = printInt (f (2))")
    Wolv::Opt.optimise(mod)
    refute instructions(mod.funcs[1]).any? { |i| i.is_a?(Wolv::IR::Bin) && i.op == "*" }
  end

  def test_unreachable_blocks_go
    mod = in_ssa('val () = if true then print ("a") else print ("b")')
    Wolv::Opt.optimise(mod)
    calls = instructions(mod.funcs.first).select { |i| i.is_a?(Wolv::IR::Call) }.map(&:callee)
    assert_equal ["wol_print"], calls
  end

  def test_splitting_leaves_phis_only_after_a_jump
    mod = in_ssa(LOOP, checks: true)
    Wolv::Opt.optimise(mod)
    mod.funcs.each do |func|
      Wolv::SSA.split_critical_edges(func)
      Wolv::SSA.verify(func)
      func.walk.each do |b|
        next unless b.succs.length > 1

        b.succs.each { |succ| assert_empty func.blocks[succ].phis }
      end
    end
  end

  # -- the tiles ------------------------------------------------------------

  def test_multiply_add_is_one_instruction
    chosen = forms(function("a + b * c"))
    assert_includes chosen, "madd"
    refute_includes chosen, "mul"
  end

  def test_multiply_subtract_is_one_instruction
    chosen = forms(function("a - b * c"))
    assert_includes chosen, "msub"
    refute_includes chosen, "mul"
  end

  # `a + b * 8` is one instruction with a shift and two as a multiply-add.
  def test_a_shifted_operand_beats_a_multiply_add
    chosen = forms(function("a + b * 8"))
    assert_equal 1, chosen.count("adds")
    refute_includes chosen, "madd"
    refute_includes chosen, "lsli"
  end

  def test_a_small_constant_is_an_immediate
    assert_equal ["addi"], forms(function("a + 5"))
    assert_equal %w[addi subi], forms(function("(a + 5) - 7"))
  end

  def test_a_large_constant_is_not
    assert_includes forms(function("a + 100000")), "const"
  end

  def test_a_multiply_by_a_power_of_two_is_a_shift
    chosen = forms(function("a * 8"))
    assert_includes chosen, "lsli"
    refute_includes chosen, "mul"
  end

  def test_a_comparison_read_only_by_its_branch_sets_the_flags
    source = "fun f (a : int) : int = if a < 3 then 1 else 2\nval () = printInt (f (1))"
    codes = selected(source).funcs.flat_map do |func|
      func.walk.map(&:terminator).select { |t| t.is_a?(Wolv::IR::CBr) }.map(&:code)
    end
    assert_includes codes, "lt"
    refute_includes forms(source), "cset"
  end

  def test_a_comparison_read_by_something_else_is_a_value
    assert_includes forms("fun f (a : int) : bool = a < 3\nval () = print (\"x\")"), "cset"
  end

  def test_an_array_element_takes_two_instructions
    text = Wolv::Driver.compile_to_asm("val a = array (4, 0)\nval () = printInt (a[2] + a[3])",
                                       Wolv::Driver::Options.new(checks: false))
    assert_equal 2, text.lines.count { |l| l.start_with?("\tldr ") }
  end

  # -- what the plan is for -------------------------------------------------

  # It costs nothing to repeat, so two readers may both take it.
  def test_a_constant_read_twice_is_still_an_immediate
    chosen = forms(function("(a + 1) * (b + 1)"))
    assert_equal 2, chosen.count("addi")
    refute_includes chosen, "const"
  end

  # Folding a whole spine would keep every term live until the end.
  def test_a_chain_of_additions_is_not_deferred_to_its_last_line
    mod = selected(<<~SOURCE)
      fun sum (a : int, b : int, c : int, d : int, e : int, f : int) : int =
        a + b + c + d + e + f
      val () = printInt (sum (1, 2, 3, 4, 5, 6))
    SOURCE
    func = func_named(mod, "sum")
    assert_operator Wolv::Liveness.pressure(func, Wolv::Liveness.analyse(func)), :<=, 8
  end

  def test_a_node_read_twice_is_computed_once
    assert_equal 1, forms(function("let val t = a * b in t + t end")).count("mul")
  end

  def test_the_graph_counts_its_readers
    func = func_named(selected(function("a + b")), "f")
    live = Wolv::Liveness.analyse(func)
    func.walk.each do |b|
      graph = Wolv::Dag.build(b, live.live_out[b.label])
      graph.nodes.each do |node|
        expected = graph.nodes.sum { |other| other.operands.count(node.index) }
        assert_equal expected, node.users
      end
    end
  end

  def test_selection_keeps_it_in_ssa
    selected(function("a + b * c + 8"), checks: true).funcs.each { |f| Wolv::SSA.verify(f) }
  end
end
