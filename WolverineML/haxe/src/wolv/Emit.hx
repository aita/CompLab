package wolv;

import haxe.Int64;
import wolv.Ir;

/* ARMv8 assembly, in AAPCS64.
 *
 * The frame is the ordinary one.  `x29` points at the saved frame record, the
 * slots an escaping variable or a spill lives in are below it, the callee-saved
 * registers this function actually used are below those, and outgoing stack
 * arguments sit at the bottom, at `sp`, where the callee expects them.
 *
 *     x29 -> | saved x29, x30 |
 *            | slot 0         |   x29 - 8      also where a static link points
 *            | slot 1         |   x29 - 16
 *            | ...            |
 *            | saved x19...   |
 *     sp  -> | outgoing args  |
 *
 * The phis are gone before this point — the allocator left SSA to colour the
 * interference graph — so what is left to do all at once is the arguments of a
 * call and the parameters at the top of a function: the values are read before
 * any is written, which is what `Copies.sequentialize` arranges.  When the copies
 * form a cycle it borrows a register the function never used, and when there is
 * none it swaps the two ends with three `eor`s, so no register has to be reserved
 * for it. */

private final UNSCALED = ["ldr" => "ldur", "str" => "stur"];

/**
 * The one register kept back.  A frame big enough to put a slot out of reach of
 * `ldur` is only discovered after allocation has added its spill slots, so the
 * address has to be computed somewhere the allocator does not know about.
 */
private final SPARE = Registers.SCRATCH[0];

/**
 * Nothing of ours is live at the top of the prologue except the incoming
 * arguments, so a caller-saved register that is not one of them is free there.
 */
private final PROLOGUE_TEMP = 9;

function emitModule(m:Module, noBorrow = false):String {
  final out = ["\t.text"];
  for (f in m.funcs) {
    for (line in new Emitter(f, noBorrow).emit()) out.push(line);
    out.push("");
  }
  if (m.strings.length > 0) {
    out.push("\t.section .rodata");
    for (s in m.strings) {
      out.push("\t.p2align 3");
      out.push(s.symbol + ":");
      out.push("\t.quad " + s.text.length);
      out.push("\t.ascii \"" + escape(s.text) + "\"");
      out.push("\t.byte 0");
    }
  }
  out.push("\t.section .note.GNU-stack,\"\",%progbits");
  return out.join("\n") + "\n";
}

/** One character of a literal is one byte; write the ones `.ascii` cannot. */
function escape(text:String):String {
  final out = new StringBuf();
  for (at in 0...text.length) {
    final code = text.charCodeAt(at);
    if (code == 0x22) out.add("\\\"");
    else if (code == 0x5C) out.add("\\\\");
    else if (code >= 0x20 && code < 0x7F) out.addChar(code);
    else out.add("\\" + StringTools.lpad(octal(code), "0", 3));
  }
  return out.toString();
}

private function octal(n:Int):String {
  var v = n;
  var s = "";
  do {
    s = Std.string(v & 7) + s;
    v = v >> 3;
  } while (v != 0);
  return s;
}

private class Frame {
  public final slots:Int;
  public final saved:Array<Int>;
  public final size:Int;

  public function new(slots:Int, saved:Array<Int>, size:Int) {
    this.slots = slots;
    this.saved = saved;
    this.size = size;
  }

  public function savedOffset(index:Int):Int return -Ir.WORD * (slots + index + 1);
}

private function frameOf(f:Func):Frame {
  var stackArgs = 0;
  for (b in f.walk()) {
    for (i in b.instrs) switch i {
      case Call(_, _, args):
        final over = args.length - Registers.ARGUMENT_REGS.length;
        if (over > stackArgs) stackArgs = over;
      case _:
    }
  }
  final raw = Ir.WORD * (f.nslots + f.saved.length + stackArgs);
  return new Frame(f.nslots, f.saved, (raw + 15) & ~15);
}

private class Emitter {
  final fn:Func;
  final fr:Frame;
  final epilogue:String;
  final read:IntSet;
  final taken:IntSet;

  /**
   * Forces every cycle of copies to swap, which is otherwise a path only reached
   * when a function has used every caller-saved register.
   */
  final noBorrow:Bool;

  final out:Array<String> = [];

  public function new(fn:Func, noBorrow:Bool) {
    this.fn = fn;
    this.noBorrow = noBorrow;
    fr = frameOf(fn);
    epilogue = ".Lepi_" + fn.label;
    read = new IntSet();
    for (b in fn.walk()) for (i in b.instrs) read.addAll(Ir.uses(i));
    taken = new IntSet();
    for (colour in fn.colours) taken.add(colour);
  }

  /* -- helpers -------------------------------------------------------------- */

  function line(text:String):Void out.push("\t" + text);

  function label(text:String):Void out.push(text + ":");

  function raw(text:String):Void out.push(text);

  function colour(r:Reg):Int {
    final c = fn.colours.get(r);
    if (c == null) throw '%$r was never coloured';
    return c;
  }

  function mov(dst:Int, src:Int):Void {
    if (dst != src) line('mov x$dst, x$src');
  }

  function immediate(dst:Int, value:Int64):Void {
    if (Int64.eq(value, Int64.ofInt(0))) {
      line('mov x$dst, #0');
      return;
    }
    var first = true;
    for (i in 0...4) {
      final chunk = Int64.and(Int64.ushr(value, i * 16), Int64.ofInt(0xFFFF));
      if (Int64.eq(chunk, Int64.ofInt(0))) continue;
      final shift = i != 0 ? ', lsl #${i * 16}' : "";
      line('${first ? "movz" : "movk"} x$dst, #${Std.string(chunk)}$shift');
      first = false;
    }
  }

  /** `ldr`/`str`, in whichever addressing mode reaches this far. */
  function access(op:String, reg:Int, base:Int, offset:Int64):Void {
    final where = base == 31 ? "sp" : 'x$base';
    if (Int64.compare(offset, Int64.ofInt(0)) >= 0
      && Int64.compare(offset, Int64.ofInt(32760)) <= 0
      && Int64.eq(Int64.mod(offset, Int64.ofInt(Ir.WORD)), Int64.ofInt(0))) {
      line('$op x$reg, [$where, #${Std.string(offset)}]');
    } else if (Int64.compare(offset, Int64.ofInt(-256)) >= 0
      && Int64.compare(offset, Int64.ofInt(255)) <= 0) {
      line('${UNSCALED.get(op)} x$reg, [$where, #${Std.string(offset)}]');
    } else {
      immediate(SPARE, offset);
      line('$op x$reg, [$where, x$SPARE]');
    }
  }

  /**
   * A register free to clobber here, if the function left one over, and -1 when
   * it did not.
   *
   * A caller-saved register this function never gave to a value holds nothing of
   * ours anywhere, and one that this copy neither reads nor writes holds nothing
   * of the copy's either.  With no such register the copies swap instead, which
   * needs no scratch at all.
   */
  function borrowed(moves:Array<Copies.Copy>):Int {
    if (noBorrow) return -1;
    final touched = new IntSet();
    for (m in moves) {
      touched.add(m.dst);
      touched.add(m.src);
    }
    for (reg in Registers.CALLER_SAVED) {
      if (!taken.has(reg) && !touched.has(reg)) return reg;
    }
    return -1;
  }

  function copies(moves:Array<Copies.Copy>):Void {
    for (step in Copies.sequentialize(moves, borrowed(moves))) switch step {
      case Mov(dst, src): mov(dst, src);
      case Swap(a, b):
        line('eor x$a, x$a, x$b');
        line('eor x$b, x$a, x$b');
        line('eor x$a, x$a, x$b');
    }
  }

  /* -- one instruction ------------------------------------------------------- */

  function machine(m:Ir.Mach):Void {
    final srcs = m.srcs.map(colour);
    switch m.form {
      case "const":
        immediate(colour(m.dst), m.imm);
      case "adr":
        final d = colour(m.dst);
        line('adrp x$d, ${m.symbol}');
        line('add x$d, x$d, :lo12:${m.symbol}');
      case "ldr":
        access("ldr", colour(m.dst), srcs[0], m.imm);
      case "str":
        access("str", srcs[1], srcs[0], m.imm);
      case form:
        var written = Mach.formOf(form);
        for (at in 0...srcs.length) {
          written = StringTools.replace(written, '{s$at}', 'x${srcs[at]}');
        }
        if (m.dst != null) written = StringTools.replace(written, "{d}", 'x${colour(m.dst)}');
        written = StringTools.replace(written, "{imm}", Std.string(m.imm));
        written = StringTools.replace(written, "{sym}", m.symbol);
        line(written);
    }
  }

  function emitCall(dst:Null<Reg>, callee:String, args:Array<Reg>):Void {
    final n = Registers.ARGUMENT_REGS.length;
    final inRegisters = [
      for (at in 0...(args.length < n ? args.length : n))
        {dst: Registers.ARGUMENT_REGS[at], src: colour(args[at])}
    ];
    for (at in n...args.length) {
      access("str", colour(args[at]), 31, Int64.ofInt(Ir.WORD * (at - n)));
    }
    copies(inRegisters);
    line("bl " + callee);
    if (dst != null) mov(colour(dst), Registers.ARGUMENT_REGS[0]);
  }

  function instruction(i:Instr):Void {
    switch i {
      case Machine(m): machine(m);
      case Move(dst, src): mov(colour(dst), colour(src));
      case LoadSlot(dst, slot): access("ldr", colour(dst), 29, Int64.ofInt(Ir.slotOffset(slot)));
      case StoreSlot(slot, src): access("str", colour(src), 29, Int64.ofInt(Ir.slotOffset(slot)));
      case FrameAddr(dst): mov(colour(dst), 29);
      case Call(dst, callee, args): emitCall(dst, callee, args);
      case _: throw "cannot emit this instruction";
    }
  }

  /* -- whole functions ------------------------------------------------------- */

  function terminator(b:Block, next:Null<String>):Void {
    final l = fn.label;
    switch b.terminator() {
      case Jmp(target):
        if (target != next) line('b .L${l}_$target');

      case CBr(cond, then_, else_, code):
        final thenLabel = '.L${l}_$then_';
        final elseLabel = '.L${l}_$else_';
        if (code != "") {
          if (then_ == next) {
            line("b." + Mach.oppositeOf(code) + " " + elseLabel);
          } else {
            line("b." + code + " " + thenLabel);
            if (else_ != next) line("b " + elseLabel);
          }
        } else if (then_ == next) {
          line('cbz x${colour(cond)}, $elseLabel');
        } else {
          line('cbnz x${colour(cond)}, $thenLabel');
          if (else_ != next) line("b " + elseLabel);
        }

      case Ret(value):
        if (value != null) mov(Registers.ARGUMENT_REGS[0], colour(value));
        // The epilogue follows the last block.
        if (next != null) line("b " + epilogue);

      case _:
    }
  }

  function prologue():Void {
    line("stp x29, x30, [sp, #-16]!");
    line("mov x29, sp");
    if (fr.size != 0) {
      if (fr.size <= 4095) {
        line('sub sp, sp, #${fr.size}');
      } else {
        immediate(PROLOGUE_TEMP, Int64.ofInt(fr.size));
        line('sub sp, sp, x$PROLOGUE_TEMP');
      }
    }
    for (at in 0...fr.saved.length) {
      access("str", fr.saved[at], 29, Int64.ofInt(fr.savedOffset(at)));
    }
    final moves = [];
    for (at in 0...fn.params.length) {
      final p = fn.params[at];
      if (read.has(p)) moves.push({dst: colour(p), src: Registers.ARGUMENT_REGS[at]});
    }
    copies(moves);
  }

  public function emit():Array<String> {
    raw("\t.globl " + fn.label);
    raw("\t.type " + fn.label + ", %function");
    label(fn.label);
    prologue();
    final order = fn.order;
    for (at in 0...order.length) {
      final name = order[at];
      label('.L${fn.label}_$name');
      final next = at + 1 < order.length ? order[at + 1] : null;
      final b = fn.block(name);
      for (i in 0...(b.instrs.length - 1)) instruction(b.instrs[i]);
      terminator(b, next);
    }
    label(epilogue);
    for (at in 0...fr.saved.length) {
      access("ldr", fr.saved[at], 29, Int64.ofInt(fr.savedOffset(at)));
    }
    line("mov sp, x29");
    line("ldp x29, x30, [sp], #16");
    line("ret");
    raw('\t.size ${fn.label}, .-${fn.label}');
    return out;
  }
}
