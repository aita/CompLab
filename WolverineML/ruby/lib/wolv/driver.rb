# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "allocator"
require_relative "astshow"
require_relative "dag"
require_relative "emit"
require_relative "ir"
require_relative "lexer"
require_relative "lower"
require_relative "mach"
require_relative "opt"
require_relative "outofssa"
require_relative "parser"
require_relative "registers"
require_relative "select"
require_relative "ssa"
require_relative "typecheck"

module Wolv
  # The pipeline, and the toolchain around it.
  #
  #     source ─lex─▶ tokens ─parse─▶ tree ─check─▶ typed tree ─lower─▶ CFG
  #            ─ssa─▶ SSA ─opt─▶ SSA ─select─▶ machine IR ─regalloc─▶ coloured
  #            ─emit─▶ ARMv8
  #
  # Assembling and linking is left to a cross `gcc`, and running to
  # `qemu-aarch64` when the machine underneath is not itself an ARM.
  module Driver
    STAGES = %w[tokens ast ir ssa opt dag mach flat ra asm].freeze

    RUNTIME = File.expand_path("../../runtime/runtime.c", __dir__)

    class ToolchainError < StandardError; end

    Options = Struct.new(:checks, :optimise, :max_regs, keyword_init: true) do
      def initialize(checks: true, optimise: true, max_regs: nil) = super

      def machine = max_regs ? Registers.limited(max_regs) : Registers.whole
    end

    Outcome = Struct.new(:code, :stdout, :stderr)

    module_function

    def to_ir(source, opts)
      prog = Parser.parse(source)
      Checker.check(prog)
      Lower.lower(prog, Lower::Options.new(checks: opts.checks))
    end

    # The pipeline, stopped as soon as `upto` has something to show.  There is
    # one of these and not two: a dump is the pipeline halted, not a second
    # description of it that has to be kept in step.
    def compile_module(source, opts, upto: "asm")
      mod = to_ir(source, opts)
      return mod if upto == "ir"

      SSA.construct_module(mod)
      return mod if upto == "ssa"

      Opt.optimise(mod) if opts.optimise
      return mod if upto == "opt"

      mod.funcs.each { |f| SSA.split_critical_edges(f) }
      return mod if upto == "dag" # the DAGs are a view of this, taken as it is

      Select.select_module(mod)
      Mach.verify_module(mod)
      return mod if upto == "mach"

      OutOfSSA.destruct_module(mod)
      return mod if upto == "flat"

      Allocator.allocate_module(mod, opts.machine)
      mod
    end

    def compile_to_asm(source, opts) = Emit.emit_module(compile_module(source, opts))

    # Run the pipeline as far as `name`, and show what it has by then.
    def stage(source, name, opts)
      case name
      when "tokens" then Lexer.dump(Lexer.lex(source))
      when "ast"
        prog = Parser.parse(source)
        Checker.check(prog)
        AstShow.show_program(prog)
      else
        mod = compile_module(source, opts, upto: name)
        case name
        when "dag" then show_dags(mod)
        when "asm" then Emit.emit_module(mod)
        else IR.show_module(mod)
        end
      end
    end

    def show_dags(mod)
      "#{mod.funcs.map do |func|
        "fun #{func.label}\n" +
          Select.graphs(func).map { |label, graph| "#{label}:\n#{Dag.show(graph)}" }.join("\n")
      end.join("\n\n")}\n"
    end

    # -- the toolchain ------------------------------------------------------

    def arm? = %w[aarch64 arm64].include?(RbConfig::CONFIG["host_cpu"])

    def which(name)
      ENV["PATH"].split(File::PATH_SEPARATOR).each do |dir|
        path = File.join(dir, name)
        return path if File.executable?(path) && !File.directory?(path)
      end
      nil
    end

    def cross_cc
      found = ENV["WOLV_CC"] ||
              %w[aarch64-linux-gnu-gcc aarch64-linux-gnu-cc aarch64-none-linux-gnu-gcc]
              .filter_map { |name| which(name) }.first ||
              (arm? ? (which("cc") || which("gcc")) : nil)
      return found if found

      raise ToolchainError, "no ARM compiler found; install aarch64-linux-gnu-gcc or set WOLV_CC"
    end

    def emulator
      return [] if arm?

      found = which("qemu-aarch64") || which("qemu-aarch64-static")
      raise ToolchainError, "no qemu-aarch64 found, and this machine is not an ARM" unless found

      [found]
    end

    # Whether an end-to-end test can run at all, so that one can say it is
    # skipping.
    def toolchain?
      cross_cc
      emulator
      true
    rescue ToolchainError
      false
    end

    def build(source, out, opts)
      asm = compile_to_asm(source, opts)
      Dir.mktmpdir("wolv") do |tmp|
        path = File.join(tmp, "program.s")
        File.write(path, asm)
        _, errors, status = Open3.capture3(cross_cc, "-static", "-O2", "-o", out.to_s,
                                           path, RUNTIME)
        raise ToolchainError, "the assembler refused it:\n#{errors}" unless status.success?
      end
    end

    def run(source, opts, stdin: "")
      Dir.mktmpdir("wolv") do |tmp|
        binary = File.join(tmp, "program")
        build(source, binary, opts)
        out, errors, status = Open3.capture3(*emulator, binary, stdin_data: stdin)
        Outcome.new(status.exitstatus, out, errors)
      end
    end
  end
end
