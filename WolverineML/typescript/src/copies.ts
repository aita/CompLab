// Doing several copies at once, one at a time.
//
// Every argument of a call is read before any of them is written, and so is every
// parameter at the top of a function.  Once the allocator has given both ends real
// registers that is a permutation, and putting a permutation into a sequence of
// instructions is this file.
//
// Copies whose destination nobody else has still to read can go first.  When only
// cycles are left, something has to be got out of the way, and there are two ways
// to do it: a register the function never used can hold a value for one step, and
// if there is no such register the two ends of the cycle swap.  A swap is three
// `eor`s and needs nothing to borrow, which is why no register is reserved for
// this anywhere in the compiler.

export class Mov {
  readonly dst: number;
  readonly src: number;
  constructor(dst: number, src: number) { this.dst = dst; this.src = src; }
}

export class Swap {
  readonly a: number;
  readonly b: number;
  constructor(a: number, b: number) { this.a = a; this.b = b; }
}

export type Step = Mov | Swap;

/** Order `[destination, source]` pairs so that nothing is lost on the way. */
export function sequentialize(moves: [number, number][], borrowed: number | null): Step[] {
  const real = moves.filter(([dst, src]) => dst !== src);
  // A Map, because which copy is picked when only cycles are left has to be the
  // same every run.
  const pending = new Map<number, number>(real);
  if (pending.size !== real.length) throw new Error("a parallel copy writes a register twice");

  /** The value that was in `was` is in `now`; whoever wanted it looks there. */
  const moved = (was: number, now: number): void => {
    for (const [dst, src] of [...pending]) {
      if (src !== was) continue;
      if (dst === now) pending.delete(dst); // the swap already put it where it belongs
      else pending.set(dst, now);
    }
  };

  const done: Step[] = [];
  while (pending.size > 0) {
    const sources = new Set(pending.values());
    const ready = [...pending.keys()].filter((dst) => !sources.has(dst));
    if (ready.length > 0) {
      for (const dst of ready) {
        done.push(new Mov(dst, pending.get(dst)!));
        pending.delete(dst);
      }
      continue;
    }
    const stuck = [...pending.keys()][0]!;
    if (borrowed !== null) {
      done.push(new Mov(borrowed, stuck));
      moved(stuck, borrowed);
      continue;
    }
    // Swapping satisfies `stuck` outright and leaves its old value where the
    // other end was, so everything still to read it reads there instead.
    const other = pending.get(stuck)!;
    pending.delete(stuck);
    done.push(new Swap(stuck, other));
    moved(stuck, other);
  }
  return done;
}
