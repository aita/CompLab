(* Instruction selection: the control-flow graph into the RISC-V one.

   Linear has already decided what the blocks are and what each computes.
   What is left is everything that depends on the target: which instruction
   does the job, what fits in an immediate, and the calling convention.

   Everything here uses fresh virtual registers, so the code it produces is
   correct but unrunnable; Regalloc turns it into something a processor can
   execute.  Two conventions established here are what make that possible:

   - Arguments are moved into a0.. with ordinary `mv` instructions before a
     call, and the result is moved out of a0 afterwards.  The allocator sees
     those moves as coalescing candidates and usually deletes them, but if it
     cannot it still produces correct code.

   - Every callee-saved register is copied into a virtual register on entry and
     copied back before each return.  If the function needs the register for
     something else the allocator spills that virtual, and the spill *is* the
     save/restore -- so a leaf function pays nothing and a deep one pays exactly
     for the registers it uses. *)

exception Error of string

type builder = { mutable pending : Riscv.instr list (* reversed *) }

let emit builder instr = builder.pending <- instr :: builder.pending

type context = {
  builder : builder;
  mutable env : Riscv.reg Ident.Map.t; (* value -> register holding it *)
  mutable consts : int Ident.Map.t; (* values known to hold a constant *)
  once : (Ident.t, unit) Hashtbl.t; (* values with exactly one definition *)
}

let reg_of ctx x =
  match Ident.Map.find_opt x ctx.env with
  | Some r -> r
  | None -> raise (Error (Printf.sprintf "unbound value `%s` reached code generation" x))

(* Give a value a register, or hand back the one it already has.  The two arms
   of an `if` assign the same value, and both have to write the same place --
   the day Linear grows phi nodes, this is what a phi would say instead. *)
let define ctx x =
  match Ident.Map.find_opt x ctx.env with
  | Some r -> r
  | None ->
    let r = Riscv.fresh_reg () in
    ctx.env <- Ident.Map.add x r ctx.env;
    r

(* A value assigned in more than one block is not a constant anywhere, however
   constant each of the assignments looks: `let x = if c then 1 else 2` writes
   x twice, and which one reached a later block is exactly what the graph does
   not say.  Only single-definition values may be remembered. *)
let remember_const ctx x n =
  if Hashtbl.mem ctx.once x then ctx.consts <- Ident.Map.add x n ctx.consts

let const_of ctx x = Ident.Map.find_opt x ctx.consts

(* Reading a value known to be zero uses the hard-wired zero register.  That
   costs nothing here and usually leaves the `li` that materialized the zero
   with no readers, so dead-code elimination takes it away along with the
   register it was occupying. *)
let operand ctx x = if const_of ctx x = Some 0 then Riscv.zero else reg_of ctx x

let binop_of = function
  | Knormal.Add -> Riscv.Add
  | Knormal.Sub -> Riscv.Sub
  | Knormal.Mul -> Riscv.Mul
  | Knormal.Div -> Riscv.Div
  | Knormal.Rem -> Riscv.Rem

let word = 8

(* [Some k] when n is 2^k. *)
let power_of_two n =
  if n > 0 && n land (n - 1) = 0 then
    let rec bits n k = if n = 1 then k else bits (n lsr 1) (k + 1) in
    Some (bits n 0)
  else None

let check_arity where n =
  if n > Riscv.max_args then
    raise
      (Error
         (Printf.sprintf "%s takes %d arguments; at most %d are supported (use a tuple)"
            where n Riscv.max_args))

(* Move the arguments into place and hand back the registers the call reads. *)
let pass_arguments ctx args =
  check_arity "this call" (List.length args);
  List.mapi
    (fun i x ->
      let target = Riscv.arg_regs.(i) in
      emit ctx.builder (Riscv.Move (target, operand ctx x));
      target)
    args

let allocate_block ctx bytes =
  emit ctx.builder (Riscv.Li (Riscv.arg_regs.(0), bytes));
  emit ctx.builder (Riscv.Call (Riscv.Direct "sable_alloc", [ Riscv.arg_regs.(0) ]));
  let r = Riscv.fresh_reg () in
  emit ctx.builder (Riscv.Move (r, Riscv.a0));
  r

(* target <- (x = y) as 0 or 1, or its negation.  The difference of two values
   is zero exactly when they are equal, and `sltu` against zero turns that into
   a boolean without a branch. *)
let generate_equality ctx target x y ~negated =
  let rx = operand ctx x and ry = operand ctx y in
  let difference =
    if rx = Riscv.zero then ry
    else if ry = Riscv.zero then rx
    else begin
      let t = Riscv.fresh_reg () in
      emit ctx.builder (Riscv.Arith (Riscv.Xor, t, rx, ry));
      t
    end
  in
  if negated then emit ctx.builder (Riscv.Arith (Riscv.Sltu, target, Riscv.zero, difference))
  else emit ctx.builder (Riscv.Arith_imm (Riscv.Sltu, target, difference, 1))

let generate_less_than ctx target a b =
  match const_of ctx b with
  | Some n when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Slt, target, operand ctx a, n))
  | _ -> emit ctx.builder (Riscv.Arith (Riscv.Slt, target, operand ctx a, operand ctx b))

(* target <- (x <= y) as 0 or 1, or its negation, which is (y < x). *)
let generate_ordering ctx target x y ~negated =
  if negated then generate_less_than ctx target y x
  else begin
    let t = Riscv.fresh_reg () in
    generate_less_than ctx t y x;
    emit ctx.builder (Riscv.Arith_imm (Riscv.Xor, target, t, 1))
  end

let generate_arith ctx target op x y =
  let shift src k =
    if k = 0 then emit ctx.builder (Riscv.Move (target, src))
    else emit ctx.builder (Riscv.Arith_imm (Riscv.Sll, target, src, k))
  in
  match (op, const_of ctx x, const_of ctx y) with
  (* Addition and multiplication may take their constant on either side. *)
  | Knormal.Add, _, Some n when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx x, n))
  | Knormal.Add, Some n, _ when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx y, n))
  (* Subtracting a constant is adding its negation. *)
  | Knormal.Sub, _, Some n when Riscv.fits_immediate (-n) ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx x, -n))
  (* Multiplying by a power of two is a shift.  Division is deliberately left
     alone: `div` truncates towards zero and an arithmetic shift rounds towards
     minus infinity, so the two disagree on negative numbers and the correction
     costs more than it saves here. *)
  | Knormal.Mul, _, Some n when power_of_two n <> None ->
    shift (operand ctx x) (Option.get (power_of_two n))
  | Knormal.Mul, Some n, _ when power_of_two n <> None ->
    shift (operand ctx y) (Option.get (power_of_two n))
  | _ -> emit ctx.builder (Riscv.Arith (binop_of op, target, operand ctx x, operand ctx y))

(* The address of an array element, as a base register and a byte offset. *)
let element_address ctx arr idx =
  let base = reg_of ctx arr in
  match const_of ctx idx with
  | Some n when Riscv.fits_immediate (n * word) -> (base, n * word)
  | _ ->
    let scaled = Riscv.fresh_reg () in
    let address = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Arith_imm (Riscv.Sll, scaled, operand ctx idx, 3));
    emit ctx.builder (Riscv.Arith (Riscv.Add, address, base, scaled));
    (address, 0)

(* The register the call reads as its callee, and the closure to hand over in
   t6 if there is one.  A closure's first word is its code pointer. *)
let resolve_callee ctx = function
  | Linear.Direct label -> (Riscv.Direct label, None)
  | Linear.Closure f ->
    let closure = reg_of ctx f in
    let code = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Load (code, closure, 0));
    (Riscv.Indirect code, Some closure)

let generate_op ctx target = function
  | Linear.Int n -> emit ctx.builder (Riscv.Li (target, n))
  | Linear.Static label -> emit ctx.builder (Riscv.La (target, label))
  | Linear.Move x -> emit ctx.builder (Riscv.Move (target, operand ctx x))
  | Linear.Neg x -> emit ctx.builder (Riscv.Arith (Riscv.Sub, target, Riscv.zero, operand ctx x))
  | Linear.Field (x, i) -> emit ctx.builder (Riscv.Load (target, reg_of ctx x, i * word))
  | Linear.Byte (s, i) ->
    (* The bytes start one word into the block, so the length word is the
       offset and the index is added to the base. *)
    let address = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Arith (Riscv.Add, address, reg_of ctx s, operand ctx i));
    emit ctx.builder (Riscv.Load_byte (target, address, word))
  | Linear.Bin (op, x, y) -> generate_arith ctx target op x y
  | Linear.Cmp (Linear.Eq, x, y, negated) -> generate_equality ctx target x y ~negated
  | Linear.Cmp (Linear.Le, x, y, negated) -> generate_ordering ctx target x y ~negated
  | Linear.Tuple xs ->
    let block = allocate_block ctx (List.length xs * word) in
    List.iteri (fun i x -> emit ctx.builder (Riscv.Store (operand ctx x, block, i * word))) xs;
    emit ctx.builder (Riscv.Move (target, block))
  | Linear.Block (tag, xs) ->
    let block = allocate_block ctx ((1 + List.length xs) * word) in
    let tag_reg = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Li (tag_reg, tag));
    emit ctx.builder (Riscv.Store (tag_reg, block, 0));
    List.iteri
      (fun i x -> emit ctx.builder (Riscv.Store (operand ctx x, block, (i + 1) * word)))
      xs;
    emit ctx.builder (Riscv.Move (target, block))
  | Linear.Array (size, init) ->
    emit ctx.builder (Riscv.Move (Riscv.arg_regs.(0), operand ctx size));
    emit ctx.builder (Riscv.Move (Riscv.arg_regs.(1), operand ctx init));
    emit ctx.builder
      (Riscv.Call (Riscv.Direct "sable_make_array", [ Riscv.arg_regs.(0); Riscv.arg_regs.(1) ]));
    emit ctx.builder (Riscv.Move (target, Riscv.a0))
  | Linear.Get (arr, idx) ->
    let address, offset = element_address ctx arr idx in
    emit ctx.builder (Riscv.Load (target, address, offset))
  | Linear.Put (arr, idx, v) ->
    let address, offset = element_address ctx arr idx in
    emit ctx.builder (Riscv.Store (operand ctx v, address, offset));
    emit ctx.builder (Riscv.Li (target, 0))
  | Linear.Call (callee, args) ->
    let callee, closure = resolve_callee ctx callee in
    let arg_regs = pass_arguments ctx args in
    (match closure with
     | Some c -> emit ctx.builder (Riscv.Move (Riscv.closure_reg, c))
     | None -> ());
    emit ctx.builder (Riscv.Call (callee, arg_regs));
    emit ctx.builder (Riscv.Move (target, Riscv.a0))

let generate_instr ctx = function
  | Linear.Let (x, Linear.Int n) ->
    (* Remember the value as well as the register: the uses that can take an
       immediate will not read the register, and it disappears. *)
    let r = define ctx x in
    emit ctx.builder (Riscv.Li (r, n));
    remember_const ctx x n
  | Linear.Let (x, op) ->
    let r = define ctx x in
    generate_op ctx r op
  | Linear.Closures definitions ->
    (* Allocate every block and bind every name first, then fill them in: a
       closure may capture itself or a sibling, and neither pointer exists
       until its block does. *)
    let blocks =
      List.map
        (fun (x, entry, captured) ->
          let block = allocate_block ctx ((1 + List.length captured) * word) in
          ctx.env <- Ident.Map.add x block ctx.env;
          (block, entry, captured))
        definitions
    in
    List.iter
      (fun (block, entry, captured) ->
        let code = Riscv.fresh_reg () in
        emit ctx.builder (Riscv.La (code, entry));
        emit ctx.builder (Riscv.Store (code, block, 0));
        List.iteri
          (fun i v -> emit ctx.builder (Riscv.Store (operand ctx v, block, (i + 1) * word)))
          captured)
      blocks

let generate_terminator ctx = function
  | Linear.Jump l -> Riscv.Jump l
  | Linear.Branch (Linear.Eq, x, y, t, f) -> Riscv.Branch (Riscv.Eq, operand ctx x, operand ctx y, t, f)
  (* x <= y is y >= x. *)
  | Linear.Branch (Linear.Le, x, y, t, f) -> Riscv.Branch (Riscv.Ge, operand ctx y, operand ctx x, t, f)
  | Linear.Return x ->
    emit ctx.builder (Riscv.Move (Riscv.a0, reg_of ctx x));
    Riscv.Return [ Riscv.a0 ]
  | Linear.Tail (callee, args) ->
    let callee, closure = resolve_callee ctx callee in
    let arg_regs = pass_arguments ctx args in
    (match closure with
     | Some c -> emit ctx.builder (Riscv.Move (Riscv.closure_reg, c))
     | None -> ());
    Riscv.Tail_call (callee, arg_regs)

(* --------------------------------------------------------------- functions *)

let single_definitions (f : Linear.func) =
  let counts = Hashtbl.create 64 in
  let seen x = Hashtbl.replace counts x (1 + Option.value ~default:0 (Hashtbl.find_opt counts x)) in
  List.iter (fun (b : Linear.block) -> List.iter (fun i -> List.iter seen (Linear.defines i)) b.body) f.blocks;
  let once = Hashtbl.create 64 in
  Hashtbl.iter (fun x n -> if n = 1 then Hashtbl.replace once x ()) counts;
  once

let translate_function (f : Linear.func) =
  check_arity ("the function `" ^ f.label ^ "`") (List.length f.args);
  Riscv.reset_virtuals ();
  let builder = { pending = [] } in
  let ctx = { builder; env = Ident.Map.empty; consts = Ident.Map.empty; once = single_definitions f } in
  (* Copy the callee-saved registers somewhere the allocator can move them. *)
  let saved =
    Array.to_list !Riscv.callee_saved
    |> List.map (fun phys ->
           let v = Riscv.fresh_reg () in
           emit builder (Riscv.Move (v, phys));
           (phys, v))
  in
  List.iteri (fun i x -> emit builder (Riscv.Move (define ctx x, Riscv.arg_regs.(i)))) f.args;
  List.iteri
    (fun i x -> emit builder (Riscv.Load (define ctx x, Riscv.closure_reg, (i + 1) * word)))
    f.captures;
  (* The prologue belongs to the entry block, which Linear puts first. *)
  let blocks =
    List.map
      (fun (b : Linear.block) ->
        List.iter (generate_instr ctx) b.body;
        let terminator = generate_terminator ctx b.terminator in
        let body = List.rev builder.pending in
        builder.pending <- [];
        { Riscv.label = b.label; body; terminator })
      f.blocks
  in
  (* Put the callee-saved registers back on every way out. *)
  List.iter
    (fun (block : Riscv.block) ->
      match block.terminator with
      | Riscv.Return _ | Riscv.Tail_call _ ->
        block.body <- block.body @ List.map (fun (phys, v) -> Riscv.Move (phys, v)) saved
      | _ -> ())
    blocks;
  { Riscv.name = f.label; blocks; num_regs = Riscv.virtual_bound (); num_spill_slots = 0 }

let translate functions = List.map translate_function functions
