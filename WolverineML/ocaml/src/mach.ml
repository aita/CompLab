(* The machine IR: what instruction selection replaces the arithmetic with.

   One record, because on this machine an instruction is a form, a register it
   writes and some it reads.  The form names an entry in the table below, and the
   table is the whole instruction set the compiler can choose from.

   The record itself is declared in [ir.ml], because OCaml cannot add a
   constructor to a variant from another file.  Everything about what it means is
   here: which forms exist, which the emitter expands rather than writing in one
   line, and the verifier that says the three-address instructions may no longer
   appear. *)

open Ir

(* How each form is written down, once the registers have their colours.  [d] is
   the register written and [s0], [s1], [s2] the ones read. *)
let forms =
  [
    ("add", "add {d}, {s0}, {s1}");
    ("addi", "add {d}, {s0}, #{imm}");
    ("adds", "add {d}, {s0}, {s1}, lsl #{imm}");
    ("sub", "sub {d}, {s0}, {s1}");
    ("subi", "sub {d}, {s0}, #{imm}");
    ("subs", "sub {d}, {s0}, {s1}, lsl #{imm}");
    ("mul", "mul {d}, {s0}, {s1}");
    ("madd", "madd {d}, {s0}, {s1}, {s2}");
    ("msub", "msub {d}, {s0}, {s1}, {s2}");
    ("sdiv", "sdiv {d}, {s0}, {s1}");
    ("and", "and {d}, {s0}, {s1}");
    ("orr", "orr {d}, {s0}, {s1}");
    ("eor", "eor {d}, {s0}, {s1}");
    ("eori", "eor {d}, {s0}, #{imm}");
    ("lsl", "lsl {d}, {s0}, {s1}");
    ("lsli", "lsl {d}, {s0}, #{imm}");
    ("asr", "asr {d}, {s0}, {s1}");
    ("asri", "asr {d}, {s0}, #{imm}");
    ("cmp", "cmp {s0}, {s1}");
    ("cmpi", "cmp {s0}, #{imm}");
    ("cset", "cset {d}, {sym}");
  ]

(* Which code each comparison sets, and which says the opposite — the emitter
   needs the opposite when the branch it is writing falls through to the block
   the comparison was true for. *)
let condition =
  [ ("=", "eq"); ("<>", "ne"); ("<", "lt"); ("<=", "le");
    (">", "gt"); (">=", "ge"); ("u<", "lo"); ("u>=", "hs") ]

let opposite =
  [ ("eq", "ne"); ("ne", "eq"); ("lt", "ge"); ("ge", "lt");
    ("gt", "le"); ("le", "gt"); ("lo", "hs"); ("hs", "lo") ]

let code_of op = List.assoc op condition
let opposite_of code = List.assoc code opposite
let form_of name = List.assoc name forms

(* The ones the emitter writes itself, because they are not one instruction. *)
let expanded = [ "const"; "adr"; "ldr"; "str" ]

let is_abstract = function
  | Const _ | Str_const _ | Bin _ | Cmp _ | Load _ | Store _ -> true
  | _ -> false

(* Insist that selection left nothing of the three-address IR behind. *)
let verify f =
  List.iter
    (fun b ->
      List.iter
        (fun instr ->
          if is_abstract instr then
            failwith
              (Printf.sprintf "an abstract instruction survived selection in %s:%s" f.fname
                 b.label);
          match instr with
          | Machine m ->
              if (not (List.mem_assoc m.form forms)) && not (List.mem m.form expanded) then
                failwith (Printf.sprintf "no such instruction as `%s`" m.form)
          | _ -> ())
        (instrs b))
    (walk f)

let verify_module m = List.iter verify m.funcs
