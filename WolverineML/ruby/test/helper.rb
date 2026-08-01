# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "wolv/driver"

module Helper
  HERE = __dir__
  EXAMPLES = File.expand_path("../examples", __dir__)

  module_function

  def programs = Dir[File.join(HERE, "programs", "*.wol")].sort
  def examples = Dir[File.join(EXAMPLES, "*.wol")].sort

  # The pipeline up to a given stage, for the passes that want to look inside.
  def build(source, checks: false)
    prog = Wolv::Parser.parse(source)
    Wolv::Checker.check(prog)
    Wolv::Lower.lower(prog, Wolv::Lower::Options.new(checks: checks))
  end

  def in_ssa(source, checks: false)
    mod = build(source, checks: checks)
    Wolv::SSA.construct_module(mod)
    mod
  end

  def selected(source, checks: false)
    mod = in_ssa(source, checks: checks)
    Wolv::Opt.optimise(mod)
    mod.funcs.each { |f| Wolv::SSA.split_critical_edges(f) }
    Wolv::Select.select_module(mod)
    mod
  end

  def func_named(mod, name) = mod.funcs.find { |f| f.name == name }

  def instructions(func) = func.walk.flat_map(&:instrs)
end
