package wolv;

import wolv.Ir;

/* The machine IR: what instruction selection replaces the arithmetic with.
 *
 * One class, because on this machine an instruction is a form, a register it
 * writes and some it reads.  The form names an entry in the table below, and the
 * table is the whole instruction set the compiler can choose from.
 *
 * The class itself is `Ir.Mach`, carried by the `Machine` constructor, because a
 * Haxe enum — like an OCaml variant — is closed where it is declared.  Everything
 * about what it means is here: which forms exist, which the emitter expands
 * rather than writing in one line, and the verifier that says the three-address
 * instructions may no longer appear.
 *
 * Four forms are not one instruction each, and the emitter expands them:
 *
 *     const   a constant, which is a `mov` or up to four `movz`/`movk`
 *     adr     the address of a string, which is `adrp` and an `add`
 *     ldr     a load, whose addressing mode depends on how far the offset reaches
 *     str     a store, likewise */

/**
 * How each form is written down, once the registers have their colours.  `d` is
 * the register written and `s0`, `s1`, `s2` the ones read.
 */
final FORMS:Map<String, String> = [
  "add" => "add {d}, {s0}, {s1}",
  "addi" => "add {d}, {s0}, #{imm}",
  "adds" => "add {d}, {s0}, {s1}, lsl #{imm}",
  "sub" => "sub {d}, {s0}, {s1}",
  "subi" => "sub {d}, {s0}, #{imm}",
  "subs" => "sub {d}, {s0}, {s1}, lsl #{imm}",
  "mul" => "mul {d}, {s0}, {s1}",
  "madd" => "madd {d}, {s0}, {s1}, {s2}",
  "msub" => "msub {d}, {s0}, {s1}, {s2}",
  "sdiv" => "sdiv {d}, {s0}, {s1}",
  "and" => "and {d}, {s0}, {s1}",
  "orr" => "orr {d}, {s0}, {s1}",
  "eor" => "eor {d}, {s0}, {s1}",
  "eori" => "eor {d}, {s0}, #{imm}",
  "lsl" => "lsl {d}, {s0}, {s1}",
  "lsli" => "lsl {d}, {s0}, #{imm}",
  "asr" => "asr {d}, {s0}, {s1}",
  "asri" => "asr {d}, {s0}, #{imm}",
  "cmp" => "cmp {s0}, {s1}",
  "cmpi" => "cmp {s0}, #{imm}",
  "cset" => "cset {d}, {sym}",
];

/**
 * Which code each comparison sets, and which says the opposite — the emitter
 * needs the opposite when the branch it is writing falls through to the block the
 * comparison was true for.
 */
final CONDITION:Map<String, String> = [
  "=" => "eq", "<>" => "ne", "<" => "lt", "<=" => "le",
  ">" => "gt", ">=" => "ge", "u<" => "lo", "u>=" => "hs",
];

final OPPOSITE:Map<String, String> = [
  "eq" => "ne", "ne" => "eq", "lt" => "ge", "ge" => "lt",
  "gt" => "le", "le" => "gt", "lo" => "hs", "hs" => "lo",
];

/** The ones the emitter writes itself, because they are not one instruction. */
final EXPANDED = ["const", "adr", "ldr", "str"];

function codeOf(op:String):String return CONDITION.get(op);

function oppositeOf(code:String):String return OPPOSITE.get(code);

function formOf(name:String):String return FORMS.get(name);

/** The three-address instructions selection is required to have replaced. */
function isAbstract(i:Instr):Bool {
  return switch i {
    case Const(_, _) | StrConst(_, _) | Bin(_, _, _, _) | Cmp(_, _, _, _)
       | Load(_, _, _) | Store(_, _, _): true;
    case _: false;
  }
}

/** Insist that selection left nothing of the three-address IR behind. */
function verify(f:Func):Void {
  for (b in f.walk()) {
    for (i in b.instrs) {
      if (isAbstract(i)) {
        throw 'an abstract instruction survived selection in ${f.name}:${b.label}';
      }
      switch i {
        case Machine(m):
          if (!FORMS.exists(m.form) && !EXPANDED.contains(m.form)) {
            throw 'no such instruction as `${m.form}`';
          }
        case _:
      }
    }
  }
}

function verifyModule(m:Module):Void {
  for (f in m.funcs) verify(f);
}
