(* ARMv8 assembly, in AAPCS64.

   The frame is the ordinary one.  [x29] points at the saved frame record, the
   slots an escaping variable or a spill lives in are below it, the callee-saved
   registers this function actually used are below those, and outgoing stack
   arguments sit at the bottom, at [sp], where the callee expects them.

   {v
   x29 -> | saved x29, x30 |
          | slot 0         |   x29 - 8      also where a static link points
          | slot 1         |   x29 - 16
          | ...            |
          | saved x19...   |
   sp  -> | outgoing args  |
   v}

   The phis are gone before this point — the allocator left SSA to colour the
   interference graph — so what is left to do all at once is the arguments of a
   call and the parameters at the top of a function: the values are read before
   any is written, which is what [Copies.sequentialize] arranges.  When the copies
   form a cycle it borrows a register the function never used, and when there is
   none it swaps the two ends with three [eor]s, so no register has to be reserved
   for it. *)

open Ir

let unscaled = [ ("ldr", "ldur"); ("str", "stur") ]

(* The one register kept back.  A frame big enough to put a slot out of reach of
   [ldur] is only discovered after allocation has added its spill slots, so the
   address has to be computed somewhere the allocator does not know about. *)
let spare = List.hd Registers.scratch

(* Nothing of ours is live at the top of the prologue except the incoming
   arguments, so a caller-saved register that is not one of them is free there. *)
let prologue_temp = 9

type frame = { slots : int; saved : int list; size : int }

let frame_of f =
  let stack_args =
    List.fold_left
      (fun most b ->
        List.fold_left
          (fun most instr ->
            match instr with
            | Call c -> max most (List.length c.args - List.length Registers.argument_regs)
            | _ -> most)
          most (instrs b))
      0 (walk f)
  in
  let stack_args = max stack_args 0 in
  let raw = word * (f.nslots + List.length f.saved + stack_args) in
  { slots = f.nslots; saved = f.saved; size = (raw + 15) land lnot 15 }

let saved_offset fr index = -word * (fr.slots + index + 1)

(* One character of a literal is one byte; write the ones [.ascii] cannot. *)
let escape text =
  let out = Buffer.create (String.length text) in
  String.iter
    (fun ch ->
      let code = Char.code ch in
      if code = 0x22 then Buffer.add_string out "\\\""
      else if code = 0x5C then Buffer.add_string out "\\\\"
      else if code >= 0x20 && code < 0x7F then Buffer.add_char out ch
      else Buffer.add_string out (Printf.sprintf "\\%03o" code))
    text;
  Buffer.contents out

type emitter = {
  fn : func;
  fr : frame;
  epilogue : string;
  read : IntSet.t;
  taken : IntSet.t;
  (* Forces every cycle of copies to swap, which is otherwise a path only reached
     when a function has used every caller-saved register. *)
  no_borrow : bool;
  mutable out : string list; (* reversed while it is built *)
}

let registers_read f =
  List.fold_left
    (fun acc b ->
      List.fold_left (fun acc instr -> IntSet.union acc (Liveness.of_list (uses instr))) acc
        (instrs b))
    IntSet.empty (walk f)

let make ?(no_borrow = false) f =
  {
    fn = f;
    fr = frame_of f;
    epilogue = ".Lepi_" ^ f.flabel;
    read = registers_read f;
    taken = IntMap.fold (fun _ colour acc -> IntSet.add colour acc) f.colours IntSet.empty;
    no_borrow;
    out = [];
  }

(* -- helpers ---------------------------------------------------------------- *)

let line e text = e.out <- ("\t" ^ text) :: e.out
let label e text = e.out <- (text ^ ":") :: e.out
let raw e text = e.out <- text :: e.out

let colour e r =
  match IntMap.find_opt r e.fn.colours with
  | Some c -> c
  | None -> failwith (Printf.sprintf "%%%d was never coloured" r)

let mov e dst src = if dst <> src then line e (Printf.sprintf "mov x%d, x%d" dst src)

let immediate e dst value =
  if value = 0L then line e (Printf.sprintf "mov x%d, #0" dst)
  else begin
    let first = ref true in
    for i = 0 to 3 do
      let chunk =
        Int64.logand (Int64.shift_right_logical value (i * 16)) 0xFFFFL
      in
      if chunk <> 0L then begin
        let shift = if i <> 0 then Printf.sprintf ", lsl #%d" (i * 16) else "" in
        line e
          (Printf.sprintf "%s x%d, #%Ld%s" (if !first then "movz" else "movk") dst chunk shift);
        first := false
      end
    done
  end

(* [ldr]/[str], in whichever addressing mode reaches this far. *)
let access e op reg base offset =
  let where = if base = 31 then "sp" else Printf.sprintf "x%d" base in
  if offset >= 0L && offset <= 32760L && Int64.rem offset (Int64.of_int word) = 0L then
    line e (Printf.sprintf "%s x%d, [%s, #%Ld]" op reg where offset)
  else if offset >= -256L && offset <= 255L then
    line e (Printf.sprintf "%s x%d, [%s, #%Ld]" (List.assoc op unscaled) reg where offset)
  else begin
    immediate e spare offset;
    line e (Printf.sprintf "%s x%d, [%s, x%d]" op reg where spare)
  end

(* A register free to clobber here, if the function left one over, and [-1] when
   it did not.

   A caller-saved register this function never gave to a value holds nothing of
   ours anywhere, and one that this copy neither reads nor writes holds nothing of
   the copy's either.  With no such register the copies swap instead, which needs
   no scratch at all. *)
let borrowed e moves =
  if e.no_borrow then -1
  else
    let touched =
      List.fold_left (fun acc (dst, src) -> IntSet.add src (IntSet.add dst acc)) IntSet.empty moves
    in
    match
      List.find_opt
        (fun reg -> (not (IntSet.mem reg e.taken)) && not (IntSet.mem reg touched))
        Registers.caller_saved
    with
    | Some reg -> reg
    | None -> -1

let copies e moves =
  List.iter
    (fun step ->
      match step with
      | Copies.Mov (dst, src) -> mov e dst src
      | Copies.Swap (a, b) ->
          line e (Printf.sprintf "eor x%d, x%d, x%d" a a b);
          line e (Printf.sprintf "eor x%d, x%d, x%d" b a b);
          line e (Printf.sprintf "eor x%d, x%d, x%d" a a b))
    (Copies.sequentialize moves (borrowed e moves))

(* -- one instruction --------------------------------------------------------- *)

let machine e (m : mach) =
  let srcs = List.map (colour e) m.srcs in
  match m.form with
  | "const" -> immediate e (colour e m.m_dst) m.imm
  | "adr" ->
      let d = colour e m.m_dst in
      line e (Printf.sprintf "adrp x%d, %s" d m.symbol);
      line e (Printf.sprintf "add x%d, x%d, :lo12:%s" d d m.symbol)
  | "ldr" -> access e "ldr" (colour e m.m_dst) (List.nth srcs 0) m.imm
  | "str" -> access e "str" (List.nth srcs 1) (List.nth srcs 0) m.imm
  | form ->
      let written = ref (Mach.form_of form) in
      let replace sub by = written := CCString.replace ~which:`All ~sub ~by !written in
      List.iteri (fun at c -> replace (Printf.sprintf "{s%d}" at) (Printf.sprintf "x%d" c)) srcs;
      if m.m_dst <> no_reg then replace "{d}" (Printf.sprintf "x%d" (colour e m.m_dst));
      replace "{imm}" (Int64.to_string m.imm);
      replace "{sym}" m.symbol;
      line e !written

let emit_call e dst callee args =
  let in_registers =
    CCList.take (List.length Registers.argument_regs) args
    |> List.mapi (fun at a -> (List.nth Registers.argument_regs at, colour e a))
  in
  List.iteri
    (fun at a -> access e "str" (colour e a) 31 (Int64.of_int (word * at)))
    (CCList.drop (List.length Registers.argument_regs) args);
  copies e in_registers;
  line e ("bl " ^ callee);
  if dst <> no_reg then mov e (colour e dst) (List.hd Registers.argument_regs)

let instruction e instr =
  match instr with
  | Machine m -> machine e m
  | Move m -> mov e (colour e m.dst) (colour e m.src)
  | Load_slot l -> access e "ldr" (colour e l.dst) 29 (Int64.of_int (slot_offset l.slot))
  | Store_slot s -> access e "str" (colour e s.src) 29 (Int64.of_int (slot_offset s.slot))
  | Frame_addr fa -> mov e (colour e fa.dst) 29
  | Call c -> emit_call e c.dst c.callee c.args
  | _ -> failwith "cannot emit this instruction"

(* -- whole functions --------------------------------------------------------- *)

let terminator e b next =
  let l = e.fn.flabel in
  match terminator b with
  | Jmp j -> if Some j.target <> next then line e (Printf.sprintf "b .L%s_%s" l j.target)
  | Cbr c ->
      let then_label = Printf.sprintf ".L%s_%s" l c.then_ in
      let else_label = Printf.sprintf ".L%s_%s" l c.else_ in
      if c.code <> "" then
        if Some c.then_ = next then line e ("b." ^ Mach.opposite_of c.code ^ " " ^ else_label)
        else begin
          line e ("b." ^ c.code ^ " " ^ then_label);
          if Some c.else_ <> next then line e ("b " ^ else_label)
        end
      else if Some c.then_ = next then
        line e (Printf.sprintf "cbz x%d, %s" (colour e c.cond) else_label)
      else begin
        line e (Printf.sprintf "cbnz x%d, %s" (colour e c.cond) then_label);
        if Some c.else_ <> next then line e ("b " ^ else_label)
      end
  | Ret r ->
      if r.value <> no_reg then mov e (List.hd Registers.argument_regs) (colour e r.value);
      (* The epilogue follows the last block. *)
      if next <> None then line e ("b " ^ e.epilogue)
  | _ -> ()

let prologue e =
  line e "stp x29, x30, [sp, #-16]!";
  line e "mov x29, sp";
  if e.fr.size <> 0 then
    if e.fr.size <= 4095 then line e (Printf.sprintf "sub sp, sp, #%d" e.fr.size)
    else begin
      immediate e prologue_temp (Int64.of_int e.fr.size);
      line e (Printf.sprintf "sub sp, sp, x%d" prologue_temp)
    end;
  List.iteri (fun at reg -> access e "str" reg 29 (Int64.of_int (saved_offset e.fr at))) e.fr.saved;
  let moves = ref [] in
  Dynarray.iteri
    (fun at p ->
      if IntSet.mem p e.read then
        moves := !moves @ [ (colour e p, List.nth Registers.argument_regs at) ])
    e.fn.params;
  copies e !moves

let emit e =
  raw e ("\t.globl " ^ e.fn.flabel);
  raw e ("\t.type " ^ e.fn.flabel ^ ", %function");
  label e e.fn.flabel;
  prologue e;
  let order = Array.of_list (order_list e.fn) in
  Array.iteri
    (fun at name ->
      label e (Printf.sprintf ".L%s_%s" e.fn.flabel name);
      let next = if at + 1 < Array.length order then Some order.(at + 1) else None in
      let b = block e.fn name in
      for at = 0 to count b - 2 do
        instruction e (nth b at)
      done;
      terminator e b next)
    order;
  label e e.epilogue;
  List.iteri (fun at reg -> access e "ldr" reg 29 (Int64.of_int (saved_offset e.fr at))) e.fr.saved;
  line e "mov sp, x29";
  line e "ldp x29, x30, [sp], #16";
  line e "ret";
  raw e (Printf.sprintf "\t.size %s, .-%s" e.fn.flabel e.fn.flabel);
  List.rev e.out

let emit_module ?(no_borrow = false) m =
  (* Prepended and reversed once at the end, rather than appended to. *)
  let out = ref [] in
  let put line = out := line :: !out in
  put "\t.text";
  List.iter
    (fun f ->
      List.iter put (emit (make ~no_borrow f));
      put "")
    m.funcs;
  if m.strings <> [] then begin
    put "\t.section .rodata";
    List.iter
      (fun (s : string_lit) ->
        put "\t.p2align 3";
        put (s.lit_symbol ^ ":");
        put (Printf.sprintf "\t.quad %d" (String.length s.text));
        put ("\t.ascii \"" ^ escape s.text ^ "\"");
        put "\t.byte 0")
      m.strings
  end;
  put "\t.section .note.GNU-stack,\"\",%progbits";
  String.concat "\n" (List.rev !out) ^ "\n"
