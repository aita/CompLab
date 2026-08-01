package wolv;

/* Doing several copies at once, one at a time.
 *
 * Every argument of a call is read before any of them is written, and so is every
 * parameter at the top of a function.  Once the allocator has given both ends
 * real registers that is a permutation, and putting a permutation into a sequence
 * of instructions is this file.
 *
 * Copies whose destination nobody else has still to read can go first.  When only
 * cycles are left, something has to be got out of the way, and there are two ways
 * to do it: a register the function never used can hold a value for one step, and
 * if there is no such register the two ends of the cycle swap.  A swap is three
 * `eor`s and needs nothing to borrow, which is why no register is reserved for
 * this anywhere in the compiler. */

enum Step {
  Mov(dst:Int, src:Int);
  Swap(a:Int, b:Int);
}

typedef Copy = {dst:Int, src:Int};

/**
 * Order the `(destination, source)` pairs so that nothing is lost on the way.
 * `borrowed` of -1 means there is nothing free to hold a value for a step.
 *
 * `pending` keeps the order it was given in, because which copy is picked when
 * only cycles are left has to be the same every run.
 */
function sequentialize(moves:Array<Copy>, borrowed:Int):Array<Step> {
  var pending = moves.filter(m -> m.dst != m.src);
  final seen = new Map<Int, Bool>();
  for (m in pending) {
    if (seen.exists(m.dst)) throw "a parallel copy writes a register twice";
    seen.set(m.dst, true);
  }

  /** The value that was in `was` is in `now`; whoever wanted it looks there. */
  function moved(was:Int, now:Int):Void {
    final kept = [];
    for (m in pending) {
      if (m.src != was) kept.push(m);
      else if (m.dst == now) {} // the swap already put it where it belongs
      else kept.push({dst: m.dst, src: now});
    }
    pending = kept;
  }

  final done:Array<Step> = [];
  while (pending.length > 0) {
    final sources = pending.map(m -> m.src);
    final ready = pending.filter(m -> !sources.contains(m.dst));
    if (ready.length > 0) {
      for (m in ready) {
        done.push(Mov(m.dst, m.src));
        pending = pending.filter(p -> p.dst != m.dst);
      }
    } else {
      final stuck = pending[0].dst;
      final other = pending[0].src;
      if (borrowed >= 0) {
        done.push(Mov(borrowed, stuck));
        moved(stuck, borrowed);
      } else {
        // Swapping satisfies `stuck` outright and leaves its old value where the
        // other end was, so everything still to read it reads there instead.
        pending = pending.filter(p -> p.dst != stuck);
        done.push(Swap(stuck, other));
        moved(stuck, other);
      }
    }
  }
  return done;
}
