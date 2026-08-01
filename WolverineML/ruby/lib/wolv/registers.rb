# frozen_string_literal: true

module Wolv
  # What the allocator and the emitter both have to agree about: the registers.
  #
  # x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
  # linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
  # call in a caller-saved register, so x16 is allocatable like any other; x17
  # is the one register kept back, for an address the emitter has to compute
  # after allocation is over.  x18 is the platform register, x29 the frame
  # pointer, x30 the link register.
  module Registers
    CALLER_SAVED = [9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8].freeze
    CALLEE_SAVED = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28].freeze
    ARGUMENT_REGS = [0, 1, 2, 3, 4, 5, 6, 7].freeze
    SCRATCH = [17].freeze

    # The machine an allocator is colouring for.
    Machine = Data.define(:caller, :callee) do
      def anywhere = caller + callee
      def count = caller.length + callee.length
    end

    def self.whole = Machine.new(CALLER_SAVED, CALLEE_SAVED)

    # A smaller machine, so that the spiller can be tested on small programs.
    def self.limited(max_regs)
      callee = CALLEE_SAVED[0, [2, max_regs / 2].max]
      caller = CALLER_SAVED[0, [1, max_regs - callee.length].max]
      Machine.new(caller, callee)
    end
  end
end
