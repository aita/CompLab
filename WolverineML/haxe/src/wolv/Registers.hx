package wolv;

/* What the allocator and the emitter both have to agree about: the registers.
 *
 * x16 and x17 are the ABI's intra-procedure-call scratch registers, which a
 * linker veneer may clobber at a `bl`.  Nothing of ours is ever live across a
 * call in a caller-saved register, so x16 is allocatable like any other; x17 is
 * the one register kept back, for an address the emitter has to compute after
 * allocation is over.  x18 is the platform register, x29 the frame pointer, x30
 * the link register. */

final CALLER_SAVED = [9, 10, 11, 12, 13, 14, 15, 16, 0, 1, 2, 3, 4, 5, 6, 7, 8];
final CALLEE_SAVED = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28];
final ARGUMENT_REGS = [0, 1, 2, 3, 4, 5, 6, 7];
final SCRATCH = [17];

/** The machine the allocator is colouring for. */
class Machine {
  public final caller:Array<Int>;
  public final callee:Array<Int>;

  public function new(caller:Array<Int>, callee:Array<Int>) {
    this.caller = caller;
    this.callee = callee;
  }

  public function anywhere():Array<Int> return caller.concat(callee);

  public function count():Int return caller.length + callee.length;
}

function all():Machine return new Machine(CALLER_SAVED, CALLEE_SAVED);

/**
 * A smaller machine, so that the spiller can be tested on small programs.  Haxe's
 * `slice` stops at the end of the array the way Python's slice does, so asking
 * for more registers than this machine has is capped rather than fatal.
 */
function limited(maxRegs:Int):Machine {
  final half = Std.int(maxRegs / 2);
  final callee = CALLEE_SAVED.slice(0, half > 2 ? half : 2);
  final want = maxRegs - callee.length;
  final caller = CALLER_SAVED.slice(0, want > 1 ? want : 1);
  return new Machine(caller, callee);
}

function isCalleeSaved(colour:Int):Bool return CALLEE_SAVED.contains(colour);
