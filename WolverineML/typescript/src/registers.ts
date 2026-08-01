// What the allocator and the emitter both have to agree about: the registers.
//
// x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
// linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
// call in a caller-saved register, so x16 is allocatable like any other; x17 is
// the one register kept back, for an address the emitter has to compute after
// allocation is over.  x18 is the platform register, x29 the frame pointer, x30
// the link register.

export const CALLER_SAVED = [9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8];
export const CALLEE_SAVED = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28];
export const ARGUMENT_REGS = [0, 1, 2, 3, 4, 5, 6, 7];
export const SCRATCH = [17];

/** The machine the allocator is colouring for. */
export class Registers {
  readonly caller: number[];
  readonly callee: number[];

  constructor(caller: number[] = CALLER_SAVED, callee: number[] = CALLEE_SAVED) {
    this.caller = caller;
    this.callee = callee;
  }

  get anywhere(): number[] { return [...this.caller, ...this.callee]; }

  count(): number { return this.caller.length + this.callee.length; }
}

/**
 * A smaller machine, so that the spiller can be tested on small programs.
 * `slice` stops at the end of the array, the way Python's slice does.
 */
export function limited(maxRegs: number): Registers {
  const callee = CALLEE_SAVED.slice(0, Math.max(2, Math.floor(maxRegs / 2)));
  const caller = CALLER_SAVED.slice(0, Math.max(1, maxRegs - callee.length));
  return new Registers(caller, callee);
}

export const isCalleeSaved = (colour: number): boolean => CALLEE_SAVED.includes(colour);
