package wolv;

import haxe.Int64;
import wolv.Ir;

/* Optimisation on SSA.
 *
 * Five small passes run to a fixed point.  Each is cheap because SSA makes it
 * cheap: a register has one definition, so constant folding and copy propagation
 * are a lookup rather than a dataflow problem, and a phi whose arguments all
 * agree is a copy that was never needed.
 *
 *     fold constants   ->  arithmetic on known values
 *     propagate copies ->  Move, and phis that turned into one
 *     simplify phis    ->  a phi with one distinct argument is that argument
 *     fold branches    ->  a branch on a known value, and the blocks it strands
 *     dead code        ->  anything computed and not used */

function optimise(m:Module):Void {
  for (f in m.funcs) optimiseFunc(f);
}

function optimiseFunc(f:Func):Void {
  while (true) {
    // Every pass runs every round: they are cheap, and one enables another.
    var changed = false;
    for (run in [foldConstants, propagateCopies, simplifyPhis, foldBranches, deadCode]) {
      if (run(f)) changed = true;
    }
    if (!changed) return;
  }
}

/* -- rewriting -------------------------------------------------------------- */

/** Replace registers everywhere they are read, phi arguments included. */
function rewrite(f:Func, mapping:Map<Reg, Reg>):Void {
  if (!mapping.iterator().hasNext()) return;

  function resolve(r:Reg):Reg {
    final seen = new Map<Reg, Bool>();
    var at = r;
    while (mapping.exists(at) && !seen.exists(at)) {
      seen.set(at, true);
      at = mapping.get(at);
    }
    return at;
  }

  for (b in f.walk()) {
    for (phi in b.phis) for (a in phi.args) a.arg = resolve(a.arg);
    for (at in 0...b.instrs.length) b.instrs[at] = Ir.mapUses(b.instrs[at], resolve);
  }
}

function constants(f:Func):Map<Reg, Int64> {
  final known = new Map<Reg, Int64>();
  for (b in f.walk()) {
    for (i in b.instrs) switch i {
      case Const(dst, value): known.set(dst, value);
      case _:
    }
  }
  return known;
}

/**
 * The language's arithmetic, in the 64 bits it is done in.
 *
 * `haxe.Int64` already wraps, and its division and remainder already truncate
 * towards zero the way `sdiv` does, `min_int / -1` included.  The shifts are the
 * only ones that need saying: Haxe masks the count to six bits, and the language
 * does not.
 */
function arith(op:String, a:Int64, b:Int64):Null<Int64> {
  final zero = Int64.ofInt(0);
  return switch op {
    case "+": Int64.add(a, b);
    case "-": Int64.sub(a, b);
    case "*": Int64.mul(a, b);
    case "/": Int64.eq(b, zero) ? null : Int64.div(a, b);
    case "mod": Int64.eq(b, zero) ? null : Int64.mod(a, b);
    case "and": Int64.and(a, b);
    case "or": Int64.or(a, b);
    case "xor": Int64.xor(a, b);
    case "shl":
      if (Int64.compare(b, zero) < 0) null;
      else if (Int64.compare(b, Int64.ofInt(64)) >= 0) zero;
      else Int64.shl(a, Int64.toInt(b));
    case "shr":
      if (Int64.compare(b, zero) < 0) null;
      else if (Int64.compare(b, Int64.ofInt(64)) >= 0)
        (Int64.compare(a, zero) < 0 ? Int64.ofInt(-1) : zero);
      else Int64.shr(a, Int64.toInt(b));
    case _: null;
  }
}

function order(op:String, a:Int64, b:Int64):Bool {
  return switch op {
    case "=": Int64.eq(a, b);
    case "<>": !Int64.eq(a, b);
    case "<": Int64.compare(a, b) < 0;
    case "<=": Int64.compare(a, b) <= 0;
    case ">": Int64.compare(a, b) > 0;
    case ">=": Int64.compare(a, b) >= 0;
    case "u<": Int64.ucompare(a, b) < 0;
    case "u>=": Int64.ucompare(a, b) >= 0;
    case _: throw 'unknown comparison $op';
  }
}

private final ZERO_IDENTITY = ["+", "-", "or", "xor", "shl", "shr"];
private final ONE_IDENTITY = ["*", "/"];

function fold(i:Instr, known:Map<Reg, Int64>):Null<Instr> {
  final zero = Int64.ofInt(0);
  final one = Int64.ofInt(1);
  return switch i {
    case Bin(dst, op, lhs, rhs):
      final a = known.get(lhs);
      final b = known.get(rhs);
      if (a != null && b != null) {
        final v = arith(op, a, b);
        v == null ? null : Const(dst, v);
      } else if (b != null && Int64.eq(b, zero) && ZERO_IDENTITY.contains(op)) {
        Move(dst, lhs);
      } else if (b != null && Int64.eq(b, one) && ONE_IDENTITY.contains(op)) {
        Move(dst, lhs);
      } else if (a != null && Int64.eq(a, zero) && op == "+") {
        Move(dst, rhs);
      } else {
        null;
      }

    case Cmp(dst, op, lhs, rhs):
      final a = known.get(lhs);
      final b = known.get(rhs);
      a != null && b != null ? Const(dst, Int64.ofInt(order(op, a, b) ? 1 : 0)) : null;

    case _: null;
  }
}

/* -- the passes ------------------------------------------------------------- */

function foldConstants(f:Func):Bool {
  final known = constants(f);
  var changed = false;
  for (b in f.walk()) {
    for (at in 0...b.instrs.length) {
      final folded = fold(b.instrs[at], known);
      if (folded == null) continue;
      b.instrs[at] = folded;
      switch folded {
        case Const(dst, value): known.set(dst, value);
        case _:
      }
      changed = true;
    }
  }
  return changed;
}

function propagateCopies(f:Func):Bool {
  final mapping = new Map<Reg, Reg>();
  for (b in f.walk()) {
    for (i in b.instrs) switch i {
      case Move(dst, src): mapping.set(dst, src);
      case _:
    }
  }
  if (!mapping.iterator().hasNext()) return false;
  rewrite(f, mapping);
  for (b in f.walk()) {
    b.instrs = b.instrs.filter(i -> !i.match(Move(_, _)));
  }
  return true;
}

function simplifyPhis(f:Func):Bool {
  final mapping = new Map<Reg, Reg>();
  var changed = false;
  for (b in f.walk()) {
    b.phis = b.phis.filter(phi -> {
      // A phi that names only itself and one other value is that other value.
      final others = new Map<Reg, Bool>();
      for (a in phi.args) if (a.arg != phi.dst) others.set(a.arg, true);
      final only = [for (r in others.keys()) r];
      if (only.length != 1) return true;
      mapping.set(phi.dst, only[0]);
      changed = true;
      return false;
    });
  }
  if (changed) rewrite(f, mapping);
  return changed;
}

function foldBranches(f:Func):Bool {
  final known = constants(f);
  var changed = false;
  for (b in f.walk()) {
    switch b.terminator() {
      case CBr(cond, then_, else_, _):
        final value = known.get(cond);
        if (value == null && then_ != else_) continue;
        final taken = value != null && Int64.eq(value, Int64.ofInt(0)) ? else_ : then_;
        b.instrs[b.instrs.length - 1] = Jmp(taken);
        changed = true;
      case _:
    }
  }
  if (changed) Ir.dropUnreachable(f);
  return changed;
}

function deadCode(f:Func):Bool {
  var changed = false;
  var round = true;
  while (round) {
    round = false;
    final used = new Map<Reg, Bool>();
    for (b in f.walk()) {
      for (phi in b.phis) for (a in phi.args) used.set(a.arg, true);
      for (i in b.instrs) for (r in Ir.uses(i)) used.set(r, true);
    }
    for (b in f.walk()) {
      final phis = b.phis.filter(phi -> used.exists(phi.dst));
      if (phis.length != b.phis.length) {
        b.phis = phis;
        round = true;
      }
      final kept = b.instrs.filter(i -> {
        final d = Ir.defs(i);
        if (d != null && !used.exists(d) && !Ir.hasEffect(i)) {
          round = true;
          return false;
        }
        return true;
      });
      b.instrs = kept;
    }
    if (round) changed = true;
  }
  return changed;
}
