(* The machine: RV64 instructions over an unbounded set of registers, arranged
   as a control-flow graph, together with the register file and the calling
   convention they obey.

   This is the only module that knows what the target is -- register names, the
   ABI, which operations take a 12-bit immediate -- which is why it is not
   called `Ir`.  The passes built on top of it (Liveness, Regalloc) use only the
   instruction-independent part of the interface: uses, definitions,
   successors, and register substitution.

   Registers are plain integers.  0..31 are the physical RV64 registers and
   everything from 32 up is a virtual register, which is what makes the
   interference graph an ordinary graph over integers with the physical
   registers pre-coloured -- see Regalloc.

   Calling convention (the standard RISC-V one, with one addition):
     a0-a7   arguments and the return value
     ra      return address, saved by any function that calls
     t6      the closure being entered, at a call through a closure
     t5      reserved for the emitter, which needs a register to materialize
             offsets that do not fit in an instruction *)

type reg = int

let num_physical = 32

let zero = 0
let ra = 1
let sp = 2
let t0 = 5
let s0 = 8
let s1 = 9
let a0 = 10
let t5 = 30
let t6 = 31

let register_names =
  [|
    "zero"; "ra"; "sp"; "gp"; "tp"; "t0"; "t1"; "t2"; "s0"; "s1"; "a0"; "a1"; "a2";
    "a3"; "a4"; "a5"; "a6"; "a7"; "s2"; "s3"; "s4"; "s5"; "s6"; "s7"; "s8"; "s9";
    "s10"; "s11"; "t3"; "t4"; "t5"; "t6";
  |]

let arg_regs = [| 10; 11; 12; 13; 14; 15; 16; 17 |]
let max_args = Array.length arg_regs
let scratch = t5
let closure_reg = t6

(* --------------------------------------------------- allocatable registers *)

(* The argument registers must stay allocatable for the calling convention to
   work at all; everything else is negotiable, which is what `-nregs` shrinks.
   Temporaries come before saved registers so that a small budget spends itself
   on registers that cost nothing at a call boundary. *)
let optional_regs = [ 5; 6; 7; 28; 29; 8; 9; 18; 19; 20; 21; 22; 23; 24; 25; 26; 27 ]

let max_colors = max_args + List.length optional_regs
let min_colors = 10
let allocatable = ref [||]
let caller_saved = ref [||]
let callee_saved = ref [||]
let is_allocatable = Array.make num_physical false
let num_colors () = Array.length !allocatable

let configure budget =
  let budget = max min_colors (min budget max_colors) in
  let rec take n = function [] -> [] | x :: r -> if n = 0 then [] else x :: take (n - 1) r in
  let chosen = Array.to_list arg_regs @ take (budget - max_args) optional_regs in
  Array.fill is_allocatable 0 num_physical false;
  List.iter (fun r -> is_allocatable.(r) <- true) chosen;
  allocatable := Array.of_list chosen;
  (* s0..s11 are the registers a callee must preserve; the rest of what we
     allocate is scratch across a call. *)
  let is_saved r = r = 8 || r = 9 || (r >= 18 && r <= 27) in
  callee_saved := Array.of_list (List.filter is_saved chosen);
  caller_saved := Array.of_list (List.filter (fun r -> not (is_saved r)) chosen)

let () = configure max_colors

(* A register the allocator reasons about: a virtual one, or a physical one we
   are free to hand out.  sp, ra and the two reserved temporaries appear in
   instructions but never take part in colouring. *)
let is_virtual r = r >= num_physical
let is_tracked r = is_virtual r || is_allocatable.(r)

let next_virtual = ref num_physical
let reset_virtuals () = next_virtual := num_physical
let fresh_reg () = let r = !next_virtual in incr next_virtual; r
let virtual_bound () = !next_virtual

let name_of_reg r =
  if is_virtual r then Printf.sprintf "v%d" (r - num_physical) else register_names.(r)

(* ---------------------------------------------------------- instructions *)

type binop = Add | Sub | Mul | Div | Rem | And | Or | Xor | Sll | Sra | Slt
type cond = Eq | Ne | Lt | Ge
type callee = Direct of Ident.label | Indirect of reg

type instr =
  | Li of reg * int
  | La of reg * Ident.label
  | Move of reg * reg
  | Arith of binop * reg * reg * reg
  | Arith_imm of binop * reg * reg * int
  | Load of reg * reg * int (* dst <- [base + offset] *)
  | Store of reg * reg * int (* [base + offset] <- src *)
  | Call of callee * reg list (* the argument registers it reads *)

type terminator =
  | Jump of Ident.label
  | Branch of cond * reg * reg * Ident.label * Ident.label
  | Return of reg list (* the registers holding the result *)
  | Tail_call of callee * reg list

type block = {
  label : Ident.label;
  mutable body : instr list;
  mutable terminator : terminator;
}

type func = {
  name : Ident.label;
  mutable blocks : block list; (* entry block first *)
  mutable num_regs : int; (* physical + virtual, sizes the allocator's arrays *)
  mutable num_spill_slots : int;
}

let fits_immediate n = n >= -2048 && n <= 2047

let has_immediate_form = function
  | Add | And | Or | Xor | Sll | Sra | Slt -> true
  | Sub | Mul | Div | Rem -> false

(* ------------------------------------------------- uses and definitions *)

let keep regs = List.filter is_tracked regs

let uses = function
  | Li _ | La _ -> []
  | Move (_, src) -> keep [ src ]
  | Arith (_, _, a, b) -> keep [ a; b ]
  | Arith_imm (_, _, a, _) -> keep [ a ]
  | Load (_, base, _) -> keep [ base ]
  | Store (src, base, _) -> keep [ src; base ]
  | Call (Direct _, args) -> keep args
  | Call (Indirect r, args) -> keep (r :: args)

let defines = function
  | Li (d, _) | La (d, _) | Move (d, _) | Arith (_, d, _, _) | Arith_imm (_, d, _, _)
  | Load (d, _, _) ->
    keep [ d ]
  | Store _ -> []
  (* A call destroys every caller-saved register: a value that has to survive
     it therefore interferes with all of them, which is what pushes long-lived
     values into callee-saved registers or onto the stack. *)
  | Call _ -> Array.to_list !caller_saved

(* Leaving a function -- by returning or by tail-calling -- reads the
   callee-saved registers, because that is when the caller's values have to be
   back in them.  Saying so here is what keeps the restore moves alive and what
   makes a value that outlives a call interfere with the right registers. *)
let terminator_uses = function
  | Jump _ -> []
  | Branch (_, a, b, _, _) -> keep [ a; b ]
  | Return regs -> keep regs @ Array.to_list !callee_saved
  | Tail_call (Direct _, args) -> keep args @ Array.to_list !callee_saved
  | Tail_call (Indirect r, args) -> keep (r :: args) @ Array.to_list !callee_saved

let successors = function
  | Jump l -> [ l ]
  | Branch (_, _, _, t, f) -> [ t; f ]
  | Return _ | Tail_call _ -> []

(* A move between two registers the allocator controls is a coalescing
   candidate; a move involving a reserved register is just an instruction. *)
let move_pair = function
  | Move (dst, src) when is_tracked dst && is_tracked src -> Some (dst, src)
  | _ -> None

let map_regs ~use ~def instr =
  match instr with
  | Li (d, n) -> Li (def d, n)
  | La (d, l) -> La (def d, l)
  | Move (d, s) -> Move (def d, use s)
  | Arith (op, d, a, b) -> Arith (op, def d, use a, use b)
  | Arith_imm (op, d, a, n) -> Arith_imm (op, def d, use a, n)
  | Load (d, b, off) -> Load (def d, use b, off)
  | Store (s, b, off) -> Store (use s, use b, off)
  | Call (Direct l, args) -> Call (Direct l, List.map use args)
  | Call (Indirect r, args) -> Call (Indirect (use r), List.map use args)

let map_terminator_regs ~use term =
  match term with
  | Jump _ -> term
  | Branch (c, a, b, t, f) -> Branch (c, use a, use b, t, f)
  | Return regs -> Return (List.map use regs)
  | Tail_call (Direct l, args) -> Tail_call (Direct l, List.map use args)
  | Tail_call (Indirect r, args) -> Tail_call (Indirect (use r), List.map use args)

let is_leaf func =
  List.for_all
    (fun b -> List.for_all (function Call _ -> false | _ -> true) b.body)
    func.blocks

(* ------------------------------------------------------------- printing *)

let string_of_binop = function
  | Add -> "add"
  | Sub -> "sub"
  | Mul -> "mul"
  | Div -> "div"
  | Rem -> "rem"
  | And -> "and"
  | Or -> "or"
  | Xor -> "xor"
  | Sll -> "sll"
  | Sra -> "sra"
  | Slt -> "slt"

let string_of_cond = function Eq -> "beq" | Ne -> "bne" | Lt -> "blt" | Ge -> "bge"

let string_of_callee = function
  | Direct l -> l
  | Indirect r -> "*" ^ name_of_reg r

let string_of_instr instr =
  let r = name_of_reg in
  match instr with
  | Li (d, n) -> Printf.sprintf "li %s, %d" (r d) n
  | La (d, l) -> Printf.sprintf "la %s, %s" (r d) l
  | Move (d, s) -> Printf.sprintf "mv %s, %s" (r d) (r s)
  | Arith (op, d, a, b) ->
    Printf.sprintf "%s %s, %s, %s" (string_of_binop op) (r d) (r a) (r b)
  | Arith_imm (op, d, a, n) ->
    Printf.sprintf "%si %s, %s, %d" (string_of_binop op) (r d) (r a) n
  | Load (d, b, off) -> Printf.sprintf "ld %s, %d(%s)" (r d) off (r b)
  | Store (s, b, off) -> Printf.sprintf "sd %s, %d(%s)" (r s) off (r b)
  | Call (c, args) ->
    Printf.sprintf "call %s(%s)" (string_of_callee c)
      (String.concat ", " (List.map r args))

let string_of_terminator term =
  let r = name_of_reg in
  match term with
  | Jump l -> "j " ^ l
  | Branch (c, a, b, t, f) ->
    Printf.sprintf "%s %s, %s, %s else %s" (string_of_cond c) (r a) (r b) t f
  | Return regs -> "ret " ^ String.concat ", " (List.map r regs)
  | Tail_call (c, args) ->
    Printf.sprintf "tail %s(%s)" (string_of_callee c)
      (String.concat ", " (List.map r args))

let print_func out func =
  Printf.fprintf out "function %s (%d registers, %d spill slots)\n" func.name
    (func.num_regs - num_physical) func.num_spill_slots;
  List.iter
    (fun b ->
      Printf.fprintf out "  %s:\n" b.label;
      List.iter (fun i -> Printf.fprintf out "    %s\n" (string_of_instr i)) b.body;
      Printf.fprintf out "    %s\n" (string_of_terminator b.terminator))
    func.blocks
