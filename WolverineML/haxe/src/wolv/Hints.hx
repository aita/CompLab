package wolv;

import wolv.Ir;

/* Which colour a value would like, which is the calling convention asking.
 *
 * The allocator does not have to satisfy these — a preference is dropped the
 * moment it clashes with something the colouring actually requires — but taking
 * one when it is free is what stops the emitter having to move a value into `x2`
 * on the way into a call, or out of `x0` on the way back from one. */

/** The register each value is about to be wanted in, where there is one. */
function preferences(f:Func):Map<Reg, Int> {
  final wanted = new Map<Reg, Int>();
  for (at in 0...f.params.length) {
    if (at < Registers.ARGUMENT_REGS.length) {
      wanted.set(f.params[at], Registers.ARGUMENT_REGS[at]);
    }
  }
  for (b in f.walk()) {
    for (i in b.instrs) switch i {
      case Call(dst, _, args):
        for (at in 0...args.length) {
          if (at < Registers.ARGUMENT_REGS.length) {
            wanted.set(args[at], Registers.ARGUMENT_REGS[at]);
          }
        }
        if (dst != null) wanted.set(dst, Registers.ARGUMENT_REGS[0]);
      case Ret(value):
        if (value != null) wanted.set(value, Registers.ARGUMENT_REGS[0]);
      case _:
    }
  }
  return wanted;
}
