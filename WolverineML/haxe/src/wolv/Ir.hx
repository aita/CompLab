package wolv;

import haxe.Int64;

/* The three-address IR, and the control flow graph both IRs are written in.
 *
 * There are two instruction sets in this compiler.  This file has the first:
 * three-address code over virtual registers, which is what lowering produces,
 * what Ssa.hx puts into SSA and what Opt.hx rewrites.  The second is `Machine`,
 * whose forms and meaning are Mach.hx's; it is a constructor here because a Haxe
 * enum, like an OCaml variant, is closed where it is declared.
 *
 * What the two sets share is everything else — the registers, the blocks, the
 * graph, the frame — so the passes that only care about the shape of a function
 * (liveness, dominance, the register allocator, the verifiers) work on either.
 * That is what `defs`, `uses`, `mapUses`, `withDef` and `hasEffect` are for: an
 * instruction says which register it writes and which it reads, and nothing
 * outside this file switches on what it is.
 *
 * An instruction is an enum and so it cannot be changed in place.  Rewriting one
 * returns a new one, and the caller puts it back where the old one was:
 *
 *     block.instrs[at] = mapUses(block.instrs[at], rename);
 *
 * That is the one place this port reads differently from the other five, all of
 * which mutate the instruction and throw the result away.  Nothing downstream
 * notices, because no pass here holds an instruction anywhere but in the array it
 * came out of.
 *
 * Nothing here is ARM-specific except that a register holds exactly one 64-bit
 * word, and the frame layout at the top, which the emitter and the nested
 * functions have to agree about. */

/** A virtual register.  `null` is how "writes nothing" is said. */
typedef Reg = Int;

/** How a register is written in a dump. */
typedef Name = Reg->String;

/** How a register is renamed. */
typedef Rewrite = Reg->Reg;

final WORD = 8;

/**
 * How many arguments AAPCS64 passes in registers.  The rest go on the stack, and
 * the frame layout below knows where.
 */
final ARGUMENT_REGISTERS = 8;

/**
 * Where a frame slot sits, relative to the frame pointer.
 *
 * Slot 0 of every nested function holds its static link, so a frame chain can be
 * walked without knowing whose frame it is.  Negative slots are the arguments the
 * caller had to pass on the stack: they are already in the frame, above the saved
 * frame record, so nothing has to be copied for them and they never take a
 * register at entry.
 */
function slotOffset(slot:Int):Int {
  return slot < 0 ? 16 + WORD * (-slot - 1) : -WORD * (slot + 1);
}

/* -- the instructions ------------------------------------------------------- */

enum Instr {
  Const(dst:Reg, value:Int64);
  StrConst(dst:Reg, symbol:String);
  Move(dst:Reg, src:Reg);
  Bin(dst:Reg, op:String, lhs:Reg, rhs:Reg);
  Cmp(dst:Reg, op:String, lhs:Reg, rhs:Reg);
  Load(dst:Reg, base:Reg, offset:Int);
  Store(base:Reg, offset:Int, src:Reg);

  /** Read a frame slot of this function — an escaping variable, or a spill. */
  LoadSlot(dst:Reg, slot:Int);

  StoreSlot(slot:Int, src:Reg);

  /** The frame pointer itself, which is what a static link points at. */
  FrameAddr(dst:Reg);

  Call(dst:Null<Reg>, callee:String, args:Array<Reg>);
  Jmp(target:String);

  /**
   * `code` empty means the branch tests `cond`.  After selection it may instead
   * read the flags a comparison just set, and then it reads no register at all.
   */
  CBr(cond:Reg, then_:String, else_:String, code:String);

  Ret(value:Null<Reg>);

  Machine(m:Mach);
}

/**
 * The machine instruction: a form, a register it writes and some it reads.
 * Mach.hx is where the forms are listed and checked.
 */
class Mach {
  public final form:String;
  public final dst:Null<Reg>;
  public final srcs:Array<Reg>;
  public final imm:Int64;
  public final symbol:String;
  public final effectful:Bool;

  public function new(form:String, dst:Null<Reg>, srcs:Array<Reg>, ?imm:Int64, symbol = "",
      effectful = false) {
    this.form = form;
    this.dst = dst;
    this.srcs = srcs;
    this.imm = imm == null ? Int64.ofInt(0) : imm;
    this.symbol = symbol;
    this.effectful = effectful;
  }

  public function with(?dst:Null<Reg>, ?srcs:Array<Reg>):Mach {
    return new Mach(form, dst == null ? this.dst : dst, srcs == null ? this.srcs : srcs, imm,
      symbol, effectful);
  }
}

/* -- what every instruction of either set can be asked ---------------------- */

/** The register it writes, or null. */
function defs(i:Instr):Null<Reg> {
  return switch i {
    case Const(dst, _) | StrConst(dst, _) | Move(dst, _) | Bin(dst, _, _, _)
       | Cmp(dst, _, _, _) | Load(dst, _, _) | LoadSlot(dst, _) | FrameAddr(dst): dst;
    case Call(dst, _, _): dst;
    case Machine(m): m.dst;
    case Store(_, _, _) | StoreSlot(_, _) | Jmp(_) | CBr(_, _, _, _) | Ret(_): null;
  }
}

/**
 * The registers it reads.  A phi's arguments are read on the edges, not where the
 * phi stands, so a phi is not an instruction here at all.
 */
function uses(i:Instr):Array<Reg> {
  return switch i {
    case Move(_, src): [src];
    case Bin(_, _, lhs, rhs) | Cmp(_, _, lhs, rhs): [lhs, rhs];
    case Load(_, base, _): [base];
    case Store(base, _, src): [base, src];
    case StoreSlot(_, src): [src];
    case Call(_, _, args): args;
    case Machine(m): m.srcs;
    case CBr(cond, _, _, code): code == "" ? [cond] : [];
    case Ret(value): value == null ? [] : [value];
    case Const(_, _) | StrConst(_, _) | LoadSlot(_, _) | FrameAddr(_) | Jmp(_): [];
  }
}

/** The same instruction with the registers it reads renamed. */
function mapUses(i:Instr, f:Rewrite):Instr {
  return switch i {
    case Move(dst, src): Move(dst, f(src));
    case Bin(dst, op, lhs, rhs): Bin(dst, op, f(lhs), f(rhs));
    case Cmp(dst, op, lhs, rhs): Cmp(dst, op, f(lhs), f(rhs));
    case Load(dst, base, offset): Load(dst, f(base), offset);
    case Store(base, offset, src): Store(f(base), offset, f(src));
    case StoreSlot(slot, src): StoreSlot(slot, f(src));
    case Call(dst, callee, args): Call(dst, callee, args.map(f));
    case Machine(m): Machine(m.with(null, m.srcs.map(f)));
    case CBr(cond, t, e, code): code == "" ? CBr(f(cond), t, e, code) : i;
    case Ret(value): value == null ? i : Ret(f(value));
    case Const(_, _) | StrConst(_, _) | LoadSlot(_, _) | FrameAddr(_) | Jmp(_): i;
  }
}

/** The same instruction, writing `r` instead.  Only asked of one that writes. */
function withDef(i:Instr, r:Reg):Instr {
  return switch i {
    case Const(_, value): Const(r, value);
    case StrConst(_, symbol): StrConst(r, symbol);
    case Move(_, src): Move(r, src);
    case Bin(_, op, lhs, rhs): Bin(r, op, lhs, rhs);
    case Cmp(_, op, lhs, rhs): Cmp(r, op, lhs, rhs);
    case Load(_, base, offset): Load(r, base, offset);
    case LoadSlot(_, slot): LoadSlot(r, slot);
    case FrameAddr(_): FrameAddr(r);
    case Call(_, callee, args): Call(r, callee, args);
    case Machine(m): Machine(m.with(r, null));
    case Store(_, _, _) | StoreSlot(_, _) | Jmp(_) | CBr(_, _, _, _) | Ret(_):
      throw "this instruction defines nothing";
  }
}

/** True when it has to be kept even if its result is dead. */
function hasEffect(i:Instr):Bool {
  return switch i {
    case Store(_, _, _) | StoreSlot(_, _) | Call(_, _, _) | Jmp(_) | CBr(_, _, _, _)
       | Ret(_): true;
    case Machine(m): m.effectful;
    case Const(_, _) | StrConst(_, _) | Move(_, _) | Bin(_, _, _, _) | Cmp(_, _, _, _)
       | Load(_, _, _) | LoadSlot(_, _) | FrameAddr(_): false;
  }
}

/** The same terminator, with one of its targets renamed. */
function renameTarget(i:Instr, old:String, fresh:String):Instr {
  return switch i {
    case Jmp(target): target == old ? Jmp(fresh) : i;
    case CBr(cond, t, e, code):
      CBr(cond, t == old ? fresh : t, e == old ? fresh : e, code);
    case _: i;
  }
}

/* -- phis ------------------------------------------------------------------- */

/**
 * One edge of a phi.  They are an array and not a map because the order they were
 * placed in is the order a dump has to print them in — and because Haxe's `Map`
 * has no order at all.
 */
class PhiArg {
  public final pred:String;
  public var arg:Reg;

  public function new(pred:String, arg:Reg) {
    this.pred = pred;
    this.arg = arg;
  }
}

class Phi {
  public var dst:Reg;
  public var args:Array<PhiArg>;

  public function new(dst:Reg, args:Array<PhiArg>) {
    this.dst = dst;
    this.args = args;
  }

  public function arg(pred:String):Null<PhiArg> {
    for (a in args) if (a.pred == pred) return a;
    return null;
  }

  /** Keeps an argument where it was, and appends a new one at the end. */
  public function setArg(pred:String, r:Reg):Void {
    final a = arg(pred);
    if (a == null) args.push(new PhiArg(pred, r)) else a.arg = r;
  }

  public function removeArg(pred:String):Null<Reg> {
    final a = arg(pred);
    if (a == null) return null;
    args = args.filter(other -> other.pred != pred);
    return a.arg;
  }

  public function preds():Array<String> {
    return args.map(a -> a.pred);
  }
}

/* -- the graph -------------------------------------------------------------- */

class Block {
  public final label:String;
  public var phis:Array<Phi> = [];
  public var instrs:Array<Instr> = [];
  public var preds:Array<String> = [];

  public function new(label:String) {
    this.label = label;
  }

  public function terminator():Instr {
    if (instrs.length == 0) throw 'block $label is unterminated';
    final last = instrs[instrs.length - 1];
    return switch last {
      case Jmp(_) | CBr(_, _, _, _) | Ret(_): last;
      case _: throw 'block $label falls through';
    }
  }

  public function succs():Array<String> {
    return switch terminator() {
      case Jmp(target): [target];
      case CBr(_, t, e, _): t != e ? [t, e] : [t];
      case _: [];
    }
  }
}

/** One function: a frame, a set of parameters, and a graph of blocks. */
class Func {
  public final label:String;
  public final name:String;
  public final params:Array<Reg> = [];
  public final depth:Int;
  public final entry = "entry";
  public final blocks = new Map<String, Block>();

  /** The order the blocks were made in, which `blocks` cannot remember. */
  public var order:Array<String> = [];

  public var nregs = 0;
  public var nslots = 0;
  public var linkSlot = -1;
  public var colours = new Map<Reg, Int>();
  public var spillSlots = new Map<Reg, Int>();
  public var saved:Array<Int> = [];

  public function new(label:String, name:String, depth:Int) {
    this.label = label;
    this.name = name;
    this.depth = depth;
  }

  public function newReg():Reg {
    return nregs++;
  }

  public function newSlot():Int {
    return nslots++;
  }

  public function block(label:String):Block {
    final b = blocks.get(label);
    if (b == null) throw 'no block $label in $name';
    return b;
  }

  public function addBlock(label:String):Block {
    if (blocks.exists(label)) throw 'block $label already exists';
    final b = new Block(label);
    blocks.set(label, b);
    order.push(label);
    return b;
  }

  /** Every block, in the order they were made. */
  public function walk():Array<Block> {
    return order.map(block);
  }
}

/** A literal and the symbol it is emitted under, in the order first seen. */
class StringLit {
  public final symbol:String;
  public final text:String;

  public function new(symbol:String, text:String) {
    this.symbol = symbol;
    this.text = text;
  }
}

class Module {
  public var funcs:Array<Func> = [];
  public var strings:Array<StringLit> = [];

  public function new() {}
}

/* -- rewiring --------------------------------------------------------------- */

function recomputePreds(f:Func):Void {
  for (b in f.blocks) b.preds = [];
  for (b in f.walk()) {
    for (s in b.succs()) f.block(s).preds.push(b.label);
  }
}

function reachable(f:Func):Map<String, Bool> {
  final seen = new Map<String, Bool>();
  function go(label:String) {
    if (seen.exists(label)) return;
    seen.set(label, true);
    for (s in f.block(label).succs()) go(s);
  }
  go(f.entry);
  return seen;
}

function dropUnreachable(f:Func):Void {
  final live = reachable(f);
  for (label in f.order) if (!live.exists(label)) f.blocks.remove(label);
  f.order = f.order.filter(live.exists);
  for (b in f.walk()) {
    for (phi in b.phis) phi.args = phi.args.filter(a -> live.exists(a.pred));
  }
  recomputePreds(f);
}

/** Reverse post-order, which is the order every dataflow pass walks in. */
function rpo(f:Func):Array<String> {
  final seen = new Map<String, Bool>();
  final post:Array<String> = [];
  function go(label:String) {
    if (seen.exists(label)) return;
    seen.set(label, true);
    for (s in f.block(label).succs()) go(s);
    post.push(label);
  }
  go(f.entry);
  post.reverse();
  return post;
}

/* -- printing --------------------------------------------------------------- */

function regName(f:Func, r:Reg):String {
  final colour = f.colours.get(r);
  return colour == null ? '%$r' : '%$r:$colour';
}

function naming(f:Func):Name {
  return r -> regName(f, r);
}

function showInstr(name:Name, i:Instr):String {
  inline function joined(rs:Array<Reg>) return rs.map(name).join(", ");
  return switch i {
    case Const(dst, value): '${name(dst)} = ${Std.string(value)}';
    case StrConst(dst, symbol): '${name(dst)} = &$symbol';
    case Move(dst, src): '${name(dst)} = ${name(src)}';
    case Bin(dst, op, lhs, rhs): '${name(dst)} = ${name(lhs)} $op ${name(rhs)}';
    case Cmp(dst, op, lhs, rhs): '${name(dst)} = ${name(lhs)} $op ${name(rhs)}';
    case Load(dst, base, offset): '${name(dst)} = [${name(base)} + $offset]';
    case Store(base, offset, src): '[${name(base)} + $offset] = ${name(src)}';
    case LoadSlot(dst, slot): '${name(dst)} = slot$slot';
    case StoreSlot(slot, src): 'slot$slot = ${name(src)}';
    case FrameAddr(dst): '${name(dst)} = frame';
    case Call(dst, callee, args):
      final call = '$callee(${joined(args)})';
      dst == null ? call : '${name(dst)} = $call';
    case Jmp(target): 'jmp $target';
    case CBr(cond, t, e, code):
      final test = code != "" ? '$code?' : '${name(cond)} ?';
      'br $test $t : $e';
    case Ret(value): value == null ? "ret" : 'ret ${name(value)}';
    case Machine(m):
      final operands = m.srcs.map(name);
      if (m.symbol != "") operands.push(m.symbol);
      else if (Int64.neq(m.imm, Int64.ofInt(0)) || m.form == "const")
        operands.push("#" + Std.string(m.imm));
      final written = StringTools.rtrim(m.form + " " + operands.join(", "));
      m.dst == null ? written : '${name(m.dst)} = $written';
  }
}

function showPhi(name:Name, phi:Phi):String {
  final parts = phi.args.map(a -> '${a.pred}: ${name(a.arg)}');
  return '${name(phi.dst)} = phi [${parts.join(", ")}]';
}

function showFunc(f:Func):String {
  final name = naming(f);
  final out = ['fun ${f.label}(${f.params.map(name).join(", ")})  ; depth ${f.depth}, ${f.nslots} slots'];
  for (b in f.walk()) {
    final preds = b.preds.length == 0 ? "" : "  ; preds: " + b.preds.join(", ");
    out.push('${b.label}:$preds');
    for (phi in b.phis) out.push("    " + showPhi(name, phi));
    for (i in b.instrs) out.push("    " + showInstr(name, i));
  }
  return out.join("\n");
}

/**
 * Widen every byte of a literal to the character of the same number, which is
 * what a dump shows.  A literal is bytes and a dump is text; here is where the
 * two are told apart.  Haxe strings on this target are bytes too, so the widening
 * has to be written out rather than left to the runtime.
 */
function asText(literal:String):String {
  final out = new StringBuf();
  for (at in 0...literal.length) {
    final c = literal.charCodeAt(at);
    if (c < 0x80) out.addChar(c);
    else {
      out.addChar(0xC0 | (c >> 6));
      out.addChar(0x80 | (c & 0x3F));
    }
  }
  return out.toString();
}

function showModule(m:Module):String {
  final parts = m.funcs.map(showFunc);
  if (m.strings.length > 0) {
    parts.push(m.strings.map(s -> '${s.symbol}: "${asText(s.text)}"').join("\n"));
  }
  return parts.join("\n\n") + "\n";
}
