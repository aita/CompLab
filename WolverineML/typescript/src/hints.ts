// Which colour a value would like, which is the calling convention asking.
//
// The allocator does not have to satisfy these — a preference is dropped the
// moment it clashes with something the colouring actually requires — but taking
// one when it is free is what stops the emitter having to move a value into `x2`
// on the way into a call, or out of `x0` on the way back from one.

import * as ir from "./ir.ts";
import { ARGUMENT_REGS } from "./registers.ts";

/** The register each value is about to be wanted in, where there is one. */
export function preferences(f: ir.Func): Map<ir.Reg, number> {
  const wanted = new Map<ir.Reg, number>();
  f.params.forEach((param, at) => {
    if (at < ARGUMENT_REGS.length) wanted.set(param, ARGUMENT_REGS[at]!);
  });
  for (const b of f.walk()) {
    for (const instr of b.instrs) {
      if (instr instanceof ir.Call) {
        instr.args.slice(0, ARGUMENT_REGS.length).forEach((arg, at) => {
          wanted.set(arg, ARGUMENT_REGS[at]!);
        });
        if (instr.dst !== null) wanted.set(instr.dst, ARGUMENT_REGS[0]!);
      } else if (instr instanceof ir.Ret && instr.value !== null) {
        wanted.set(instr.value, ARGUMENT_REGS[0]!);
      }
    }
  }
  return wanted;
}
