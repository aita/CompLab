(* Instruction selection: closure-converted code into the RISC-V control-flow
   graph.

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

type builder = {
  mutable done_blocks : Riscv.block list; (* finished, in reverse order *)
  mutable label : Ident.label;
  mutable pending : Riscv.instr list; (* current block's body, reversed *)
  mutable open_block : bool;
}

let emit builder instr =
  if builder.open_block then builder.pending <- instr :: builder.pending

let terminate builder terminator =
  if builder.open_block then begin
    builder.done_blocks <-
      { Riscv.label = builder.label; body = List.rev builder.pending; terminator }
      :: builder.done_blocks;
    builder.open_block <- false
  end

let start_block builder label =
  builder.label <- label;
  builder.pending <- [];
  builder.open_block <- true

(* Where the value of an expression has to end up. *)
type destination =
  | Into of Riscv.reg
  | Return_from_function (* the expression is in tail position *)

type context = {
  builder : builder;
  mutable env : Riscv.reg Ident.Map.t; (* variable -> register holding it *)
  mutable consts : int Ident.Map.t; (* variables known to hold a constant *)
}

let reg_of ctx x =
  match Ident.Map.find_opt x ctx.env with
  | Some r -> r
  | None -> raise (Error (Printf.sprintf "unbound variable `%s` reached code generation" x))

let const_of ctx x = Ident.Map.find_opt x ctx.consts
let bind ctx x r = ctx.env <- Ident.Map.add x r ctx.env

(* Reading a value known to be zero uses the hard-wired zero register.  That
   costs nothing here and usually leaves the `li` that materialized the zero
   with no readers, so dead-code elimination takes it away along with the
   register it was occupying. *)
let operand ctx x = if const_of ctx x = Some 0 then Riscv.zero else reg_of ctx x

(* The arms of a comparison that was turned into a value by A-normalization. *)
let is_boolean_pair a b = (a = 1 && b = 0) || (a = 0 && b = 1)

let binop_of = function
  | Anf.Add -> Riscv.Add
  | Anf.Sub -> Riscv.Sub
  | Anf.Mul -> Riscv.Mul
  | Anf.Div -> Riscv.Div
  | Anf.Rem -> Riscv.Rem

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

let rec generate ctx dest exp =
  match exp with
  | Closure.Let ((x, _), Closure.Int n, body) ->
    (* Remember the value as well as the register: the uses that can take an
       immediate will not read the register, and it disappears. *)
    let r = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Li (r, n));
    bind ctx x r;
    ctx.consts <- Ident.Map.add x n ctx.consts;
    generate ctx dest body
  | Closure.Let ((x, _), value, body) ->
    let r = Riscv.fresh_reg () in
    generate ctx (Into r) value;
    bind ctx x r;
    generate ctx dest body
  (* A comparison whose two arms are 1 and 0 is a comparison used as a value.
     Branching over it costs two blocks and a jump for what `slt` does in one
     instruction, so it goes to generate_value instead. *)
  | Closure.If_eq (_, _, Closure.Int a, Closure.Int b)
  | Closure.If_le (_, _, Closure.Int a, Closure.Int b)
    when is_boolean_pair a b ->
    generate_value ctx dest exp
  | Closure.If_eq (x, y, then_, else_) ->
    generate_branch ctx dest Riscv.Eq (operand ctx x) (operand ctx y) then_ else_
  | Closure.If_le (x, y, then_, else_) ->
    (* x <= y is y >= x. *)
    generate_branch ctx dest Riscv.Ge (operand ctx y) (operand ctx x) then_ else_
  | Closure.Let_tuple (xts, tuple, body) ->
    let base = reg_of ctx tuple in
    List.iteri
      (fun i (x, _) ->
        let r = Riscv.fresh_reg () in
        emit ctx.builder (Riscv.Load (r, base, i * word));
        bind ctx x r)
      xts;
    generate ctx dest body
  | Closure.Make_closure ((x, _), { entry; captured }, body) ->
    let block = allocate_block ctx ((1 + List.length captured) * word) in
    let code = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.La (code, entry));
    emit ctx.builder (Riscv.Store (code, block, 0));
    (* Bind the name before storing the captures so that a closure capturing
       itself stores a pointer to itself. *)
    bind ctx x block;
    List.iteri
      (fun i v -> emit ctx.builder (Riscv.Store (operand ctx v, block, (i + 1) * word)))
      captured;
    generate ctx dest body
  | Closure.Call_direct (label, args) -> generate_call ctx dest (Riscv.Direct label) args None
  | Closure.Call_closure (f, args) ->
    let closure = reg_of ctx f in
    let code = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Load (code, closure, 0));
    generate_call ctx dest (Riscv.Indirect code) args (Some closure)
  | _ -> generate_value ctx dest exp

(* Expressions that simply compute a value into a register. *)
and generate_value ctx dest exp =
  let target = match dest with Into r -> r | Return_from_function -> Riscv.fresh_reg () in
  (match exp with
   | Closure.Int n -> emit ctx.builder (Riscv.Li (target, n))
   | Closure.Static label -> emit ctx.builder (Riscv.La (target, label))
   | Closure.Var x -> emit ctx.builder (Riscv.Move (target, operand ctx x))
   | Closure.Neg x -> emit ctx.builder (Riscv.Arith (Riscv.Sub, target, Riscv.zero, operand ctx x))
   | Closure.Field (x, i) -> emit ctx.builder (Riscv.Load (target, reg_of ctx x, i * word))
   | Closure.Bin (op, x, y) -> generate_arith ctx target op x y
   (* Comparisons in value position; see generate. *)
   | Closure.If_eq (x, y, Closure.Int a, _) -> generate_equality ctx target x y ~negated:(a = 0)
   | Closure.If_le (x, y, Closure.Int a, _) -> generate_ordering ctx target x y ~negated:(a = 0)
   | Closure.Tuple xs ->
     let block = allocate_block ctx (List.length xs * word) in
     List.iteri
       (fun i x -> emit ctx.builder (Riscv.Store (operand ctx x, block, i * word)))
       xs;
     emit ctx.builder (Riscv.Move (target, block))
   | Closure.Block (tag, xs) ->
     let block = allocate_block ctx ((1 + List.length xs) * word) in
     let tag_reg = Riscv.fresh_reg () in
     emit ctx.builder (Riscv.Li (tag_reg, tag));
     emit ctx.builder (Riscv.Store (tag_reg, block, 0));
     List.iteri
       (fun i x -> emit ctx.builder (Riscv.Store (operand ctx x, block, (i + 1) * word)))
       xs;
     emit ctx.builder (Riscv.Move (target, block))
   | Closure.Array (size, init) ->
     emit ctx.builder (Riscv.Move (Riscv.arg_regs.(0), operand ctx size));
     emit ctx.builder (Riscv.Move (Riscv.arg_regs.(1), operand ctx init));
     emit ctx.builder
       (Riscv.Call (Riscv.Direct "sable_make_array", [ Riscv.arg_regs.(0); Riscv.arg_regs.(1) ]));
     emit ctx.builder (Riscv.Move (target, Riscv.a0))
   | Closure.Get (arr, idx) ->
     let address, offset = element_address ctx arr idx in
     emit ctx.builder (Riscv.Load (target, address, offset))
   | Closure.Put (arr, idx, v) ->
     let address, offset = element_address ctx arr idx in
     emit ctx.builder (Riscv.Store (operand ctx v, address, offset));
     emit ctx.builder (Riscv.Li (target, 0))
   | _ -> failwith "Selection: generate_value on a control-flow expression");
  match dest with
  | Into _ -> ()
  | Return_from_function ->
    emit ctx.builder (Riscv.Move (Riscv.a0, target));
    terminate ctx.builder (Riscv.Return [ Riscv.a0 ])

(* target <- (x = y) as 0 or 1, or its negation.  The difference of two values
   is zero exactly when they are equal, and `sltu` against zero turns that into
   a boolean without a branch. *)
and generate_equality ctx target x y ~negated =
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

(* target <- (x <= y) as 0 or 1, or its negation, which is (y < x). *)
and generate_ordering ctx target x y ~negated =
  if negated then generate_less_than ctx target y x
  else begin
    let t = Riscv.fresh_reg () in
    generate_less_than ctx t y x;
    emit ctx.builder (Riscv.Arith_imm (Riscv.Xor, target, t, 1))
  end

and generate_less_than ctx target a b =
  match const_of ctx b with
  | Some n when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Slt, target, operand ctx a, n))
  | _ -> emit ctx.builder (Riscv.Arith (Riscv.Slt, target, operand ctx a, operand ctx b))

and generate_arith ctx target op x y =
  let shift src k =
    if k = 0 then emit ctx.builder (Riscv.Move (target, src))
    else emit ctx.builder (Riscv.Arith_imm (Riscv.Sll, target, src, k))
  in
  match (op, const_of ctx x, const_of ctx y) with
  (* Addition and multiplication may take their constant on either side. *)
  | Anf.Add, _, Some n when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx x, n))
  | Anf.Add, Some n, _ when Riscv.fits_immediate n ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx y, n))
  (* Subtracting a constant is adding its negation. *)
  | Anf.Sub, _, Some n when Riscv.fits_immediate (-n) ->
    emit ctx.builder (Riscv.Arith_imm (Riscv.Add, target, operand ctx x, -n))
  (* Multiplying by a power of two is a shift.  Division is deliberately left
     alone: `div` truncates towards zero and an arithmetic shift rounds towards
     minus infinity, so the two disagree on negative numbers and the correction
     costs more than it saves here. *)
  | Anf.Mul, _, Some n when power_of_two n <> None ->
    shift (operand ctx x) (Option.get (power_of_two n))
  | Anf.Mul, Some n, _ when power_of_two n <> None ->
    shift (operand ctx y) (Option.get (power_of_two n))
  | _ ->
    emit ctx.builder (Riscv.Arith (binop_of op, target, operand ctx x, operand ctx y))

(* The address of an array element, as a base register and a byte offset. *)
and element_address ctx arr idx =
  let base = reg_of ctx arr in
  match const_of ctx idx with
  | Some n when Riscv.fits_immediate (n * word) -> (base, n * word)
  | _ ->
    let scaled = Riscv.fresh_reg () in
    let address = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Arith_imm (Riscv.Sll, scaled, operand ctx idx, 3));
    emit ctx.builder (Riscv.Arith (Riscv.Add, address, base, scaled));
    (address, 0)

and generate_branch ctx dest cond left right then_ else_ =
  let then_label = Ident.fresh_label "then" in
  let else_label = Ident.fresh_label "else" in
  terminate ctx.builder (Riscv.Branch (cond, left, right, then_label, else_label));
  match dest with
  | Return_from_function ->
    (* Each arm returns on its own; there is nothing to join. *)
    let saved = ctx.env and saved_consts = ctx.consts in
    start_block ctx.builder then_label;
    generate ctx dest then_;
    ctx.env <- saved;
    ctx.consts <- saved_consts;
    start_block ctx.builder else_label;
    generate ctx dest else_
  | Into r ->
    let join_label = Ident.fresh_label "join" in
    let saved = ctx.env and saved_consts = ctx.consts in
    start_block ctx.builder then_label;
    generate ctx (Into r) then_;
    terminate ctx.builder (Riscv.Jump join_label);
    ctx.env <- saved;
    ctx.consts <- saved_consts;
    start_block ctx.builder else_label;
    generate ctx (Into r) else_;
    terminate ctx.builder (Riscv.Jump join_label);
    (* Nothing an arm bound is in scope after the join, so the environment
       goes back to what it was. *)
    ctx.env <- saved;
    ctx.consts <- saved_consts;
    start_block ctx.builder join_label

and generate_call ctx dest callee args closure =
  let arg_regs = pass_arguments ctx args in
  (match closure with
   | Some c -> emit ctx.builder (Riscv.Move (Riscv.closure_reg, c))
   | None -> ());
  match dest with
  | Return_from_function -> terminate ctx.builder (Riscv.Tail_call (callee, arg_regs))
  | Into r ->
    emit ctx.builder (Riscv.Call (callee, arg_regs));
    emit ctx.builder (Riscv.Move (r, Riscv.a0))

(* --------------------------------------------------------------- functions *)

let build_function label args captures body =
  check_arity ("the function `" ^ label ^ "`") (List.length args);
  Riscv.reset_virtuals ();
  let builder =
    { done_blocks = []; label; pending = []; open_block = true }
  in
  let ctx = { builder; env = Ident.Map.empty; consts = Ident.Map.empty } in
  (* Copy the callee-saved registers somewhere the allocator can move them. *)
  let saved =
    Array.to_list !Riscv.callee_saved
    |> List.map (fun phys ->
           let v = Riscv.fresh_reg () in
           emit builder (Riscv.Move (v, phys));
           (phys, v))
  in
  List.iteri
    (fun i (x, _) ->
      let r = Riscv.fresh_reg () in
      emit builder (Riscv.Move (r, Riscv.arg_regs.(i)));
      bind ctx x r)
    args;
  List.iteri
    (fun i (x, _) ->
      let r = Riscv.fresh_reg () in
      emit builder (Riscv.Load (r, Riscv.closure_reg, (i + 1) * word));
      bind ctx x r)
    captures;
  generate ctx Return_from_function body;
  (* Put the callee-saved registers back on every way out. *)
  let blocks = List.rev builder.done_blocks in
  List.iter
    (fun (block : Riscv.block) ->
      match block.terminator with
      | Riscv.Return _ | Riscv.Tail_call _ ->
        block.body <- block.body @ List.map (fun (phys, v) -> Riscv.Move (phys, v)) saved
      | _ -> ())
    blocks;
  {
    Riscv.name = label;
    blocks;
    num_regs = Riscv.virtual_bound ();
    num_spill_slots = 0;
  }

let translate (program : Closure.program) =
  let functions =
    List.map
      (fun (fd : Closure.fundef) ->
        build_function fd.label fd.args fd.captures fd.body)
      program.functions
  in
  functions @ [ build_function "sable_main" [] [] program.main ]
