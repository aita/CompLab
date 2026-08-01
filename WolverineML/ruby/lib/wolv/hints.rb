# frozen_string_literal: true

require_relative "ir"
require_relative "registers"

module Wolv
  # Which colour a value would like, which is the calling convention asking.
  #
  # The allocator does not have to satisfy these — a preference is dropped the
  # moment it clashes with something the colouring actually requires — but
  # taking one when it is free is what stops the emitter having to move a value
  # into `x2` on the way into a call, or out of `x0` on the way back from one.
  module Hints
    module_function

    # The register each value is about to be wanted in, where there is one.
    def preferences(func)
      wanted = {}
      func.params.each_with_index do |param, i|
        wanted[param] = Registers::ARGUMENT_REGS[i] if i < Registers::ARGUMENT_REGS.length
      end
      func.walk.each do |b|
        b.instrs.each do |instr|
          case instr
          when IR::Call
            instr.args.take(Registers::ARGUMENT_REGS.length).each_with_index do |arg, i|
              wanted[arg] = Registers::ARGUMENT_REGS[i]
            end
            wanted[instr.dst] = Registers::ARGUMENT_REGS[0] if instr.dst
          when IR::Ret
            wanted[instr.value] = Registers::ARGUMENT_REGS[0] if instr.value
          end
        end
      end
      wanted
    end
  end
end
