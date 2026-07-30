(* amd64 instructions, still in a control-flow graph and still in SSA.

   Three passes run over it: selection produces it, `outofssa.ml` replaces the
   phis with copies, and `regalloc.ml` colours what is left.

   The phis survive selection because selection is a change of instruction set,
   not a change of control flow, and a phi is a fact about control flow.  They
   are gone before colouring, because the interference graph is much easier to
   reason about when every instruction is an ordinary one -- which is the order
   Chaitin's algorithm was written for.

   Operands are *virtual* registers until then.  A virtual register is exactly
   one SSA value, so "which value is live here" and "which register does this
   need" are the same question.

   The instruction set is small on purpose.  Anything that would need a loop or
   a heap walk -- allocation, structural equality, printing, string and list
   work -- is a call into the runtime in `runtime.c`, so the code here only has
   to know how to move words around, do tagged arithmetic and jump. *)

type reg =
  | V of int (* a virtual register: one SSA value *)
  | R of int (* a real one, indexing [reg_name] *)

(* The allocatable registers first, in the System V argument order so that a
   call's operands often need no moves, then rsp and rbp, which belong to the
   frame and are never handed out.

   There is no scratch register.  Reserving one costs a colour, and the two
   things that would have wanted it do not: a spilled value is rewritten to a
   fresh virtual register with a load and a store around it, and the tail call
   that has to read its target before the frame goes away can use any
   caller-saved register, because nothing is live at a tail call except the
   closure and its argument. *)
let reg_name =
  [|
    "rax"; "rcx"; "rdx"; "rsi"; "rdi"; "r8"; "r9"; "r11"; "r10"; "rbx"; "r12"; "r13"; "r14";
    "r15"; "rsp"; "rbp";
  |]

(* The number the instruction encoding uses for each of them, which is not the
   order they are listed in. *)
let x86 = [| 0; 1; 2; 6; 7; 8; 9; 11; 10; 3; 12; 13; 14; 15; 4; 5 |]

let rax = 0
let rcx = 1
let rdx = 2
let rsi = 3
let rdi = 4
let rsp = 14
let rbp = 15

(* How many colours the register allocator has. *)
let nregs = 14

(* Which registers a call destroys.  The callee-saved ones survive it, which is
   what makes them worth having: a value live across a call wants to be in
   one. *)
let caller_saved = [ 0; 1; 2; 3; 4; 5; 6; 7; 8 ]
let callee_saved = [ 9; 10; 11; 12; 13 ]

type operand =
  | Reg of reg
  | Imm of int
  | (* [base + index * scale + disp], any part optional.  This is the operand
       the DP tiler is trying to build: folding an address computation into it
       is the whole reason to tile rather than macro-expand. *)
    Mem of { base : reg option; index : reg option; scale : int; disp : int; sym : string option }

type instr =
  | Mov of operand * operand (* dst, src *)
  | Lea of reg * operand
  | Alu of string * operand * operand (* add/sub/and/or/xor/imul: dst, src *)
  | Sar of operand * int
  | Shl of operand * int
  | Neg of operand
  | Cmp of operand * operand
  | Setcc of string * reg (* dst gets 0 or 1 *)
  | Idiv of reg (* rax:rdx / reg, quotient in rax, remainder in rdx *)
  | Cqo
  | Call of string (* a known symbol; the result is in rax *)
  | CallReg of reg (* through a register *)
  | Push of operand
  | Pop of operand
  (* Byte-wide moves, for the inside of a string; [Loadb] zero-extends. *)
  | Loadb of reg * operand
  | Storeb of operand * reg
  | RepMovsb (* rcx bytes from rsi to rdi *)
  | Syscall
  | Comment of string

type term =
  | Ret of operand
  | Jmp of int (* block id *)
  | Jcc of string * int * int (* condition, then, else *)
  (* A tail call: the frame is dropped and control leaves without returning.
     The closure is already in rdi and its argument in rsi. *)
  | TailCall
  | Halt of string (* a match failure: report where and exit *)

type block = {
  id : int;
  mutable phis : (reg * (int * operand) list) list; (* dst, (pred, source) *)
  mutable code : instr list;
  mutable term : term;
  mutable preds : int list;
}

type func = {
  name : string;
  entry : int;
  mutable blocks : block list;
  mutable nvreg : int;
  (* Filled in by register allocation. *)
  mutable nspill : int;
  mutable used_callee : int list;
}

type item = {
  (* The global this fills in, the label of the code that computes it, and what
     to print afterwards. *)
  it_global : string option;
  it_code : string option;
  it_label : string option;
  it_show : bool;
}

type prog = { funcs : func list; globals : string list; items : item list }

let reg_str = function
  | R i -> "%" ^ reg_name.(i)
  | V i -> Printf.sprintf "%%v%d" i

let operand_str = function
  | Reg r -> reg_str r
  | Imm n -> Printf.sprintf "$%d" n
  | Mem m ->
      let d =
        match m.sym with
        | Some s -> if m.disp = 0 then s else Printf.sprintf "%s%+d" s m.disp
        | None -> if m.disp = 0 then "" else string_of_int m.disp
      in
      let inner =
        match (m.base, m.index) with
        | None, None -> ""
        | Some b, None -> Printf.sprintf "(%s)" (reg_str b)
        | None, Some i -> Printf.sprintf "(,%s,%d)" (reg_str i) m.scale
        | Some b, Some i -> Printf.sprintf "(%s,%s,%d)" (reg_str b) (reg_str i) m.scale
      in
      (* A symbol with no base is rip-relative. *)
      if m.base = None && m.index = None && m.sym <> None then d ^ "(%rip)" else d ^ inner

let instr_str = function
  | Mov (d, s) -> Printf.sprintf "mov %s, %s" (operand_str s) (operand_str d)
  | Lea (d, s) -> Printf.sprintf "lea %s, %s" (operand_str s) (reg_str d)
  | Alu (op, d, s) -> Printf.sprintf "%s %s, %s" op (operand_str s) (operand_str d)
  | Sar (d, n) -> Printf.sprintf "sar $%d, %s" n (operand_str d)
  | Shl (d, n) -> Printf.sprintf "shl $%d, %s" n (operand_str d)
  | Neg d -> Printf.sprintf "neg %s" (operand_str d)
  | Cmp (a, b) -> Printf.sprintf "cmp %s, %s" (operand_str b) (operand_str a)
  | Setcc (c, r) -> Printf.sprintf "set%s %s" c (reg_str r)
  | Idiv r -> Printf.sprintf "idiv %s" (reg_str r)
  | Cqo -> "cqo"
  | Call s -> Printf.sprintf "call %s" s
  | CallReg r -> Printf.sprintf "call *%s" (reg_str r)
  | Loadb (d, s) -> Printf.sprintf "movzbq %s, %s" (operand_str s) (reg_str d)
  | Storeb (d, s) -> Printf.sprintf "movb %s, %s" (reg_str s) (operand_str d)
  | RepMovsb -> "rep movsb"
  | Push o -> Printf.sprintf "push %s" (operand_str o)
  | Pop o -> Printf.sprintf "pop %s" (operand_str o)
  | Syscall -> "syscall"
  | Comment c -> Printf.sprintf "; %s" c

let term_str = function
  | Ret o -> Printf.sprintf "ret %s" (operand_str o)
  | Jmp b -> Printf.sprintf "jmp b%d" b
  | Jcc (c, t, e) -> Printf.sprintf "j%s b%d else b%d" c t e
  | TailCall -> "tailcall"
  | Halt m -> Printf.sprintf "halt %S" m

let to_string (p : prog) =
  let buf = Buffer.create 1024 in
  let add = Buffer.add_string buf in
  List.iter
    (fun f ->
      add (Printf.sprintf "func %s:\n" f.name);
      List.iter
        (fun b ->
          add (Printf.sprintf "  b%d:\n" b.id);
          List.iter
            (fun (d, srcs) ->
              add
                (Printf.sprintf "    %s = phi [%s]\n" (reg_str d)
                   (String.concat ", "
                      (List.map
                         (fun (p, o) -> Printf.sprintf "b%d: %s" p (operand_str o))
                         srcs))))
            b.phis;
          List.iter (fun i -> add (Printf.sprintf "    %s\n" (instr_str i))) (List.rev b.code);
          add (Printf.sprintf "    %s\n" (term_str b.term)))
        f.blocks;
      add "\n")
    p.funcs;
  Buffer.contents buf
