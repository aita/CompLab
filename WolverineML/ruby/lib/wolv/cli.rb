# frozen_string_literal: true

require "optparse"
require_relative "diag"
require_relative "driver"
require_relative "spill"

module Wolv
  # The command line.
  module CLI
    COMMANDS = %w[build run emit check].freeze

    module_function

    def main(argv)
      out = nil
      which = "asm"
      settings = { checks: true, optimise: true, max_regs: nil }
      rest = parser(settings) { |o, w| out = o || out; which = w || which }.parse(argv)

      return complain("wants a command and a file") unless rest.length == 2

      command, file = rest
      return complain("no such command as `#{command}`: #{COMMANDS.join(', ')}") unless
        COMMANDS.include?(command)

      opts = Driver::Options.new(**settings)
      source = File.read(file)
      run_command(command, file, source, which, out, opts)
    rescue OptionParser::ParseError, Errno::ENOENT, Errno::EACCES => e
      complain(e.message)
    end

    def run_command(command, file, source, which, out, opts)
      case command
      when "check" then Driver.to_ir(source, opts)
      when "emit" then $stdout.write(Driver.stage(source, which, opts))
      when "build" then Driver.build(source, out || file.sub(/\.wol\z/, ""), opts)
      when "run"
        done = Driver.run(source, opts, stdin: $stdin.tty? ? "" : $stdin.read)
        $stdout.write(done.stdout)
        $stderr.write(done.stderr)
        return done.code
      end
      0
    rescue Error => e
      warn "#{file}:#{e.message}"
      1
    rescue Driver::ToolchainError, Spill::OutOfRegisters => e
      warn "wolv: #{e.message}"
      1
    end

    def parser(settings)
      OptionParser.new do |o|
        o.banner = "usage: wolv <command> <file> [options]\n\n" \
                   "  build   compile and link an executable\n" \
                   "  run     build it and run it\n" \
                   "  emit    write one stage of the pipeline to standard output\n" \
                   "  check   types only\n\n"
        o.on("-o", "--out PATH", "where `build` should write the executable") { |v| yield(v, nil) }
        o.on("-s", "--stage NAME", Driver::STAGES,
             "which stage `emit` should show: #{Driver::STAGES.join(', ')}") { |v| yield(nil, v) }
        o.on("--no-checks", "leave out the nil, bounds and divide-by-zero checks") do
          settings[:checks] = false
        end
        o.on("--no-opt", "do not optimise the SSA") { settings[:optimise] = false }
        o.on("--max-regs N", Integer,
             "pretend the machine has N registers, to make it spill") do |v|
          settings[:max_regs] = v
        end
      end
    end

    def complain(message)
      warn "wolv: #{message}"
      1
    end
  end
end
