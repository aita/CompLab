(* Instruction selection: closure-converted code into the machine IR.

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

(* Comparing against a literal zero is common enough to be worth using the
   hard-wired zero register for. *)
let compare_operand ctx x = if const_of ctx x = Some 0 then Riscv.zero else reg_of ctx x

let binop_of = function
  | Knormal.Add -> Riscv.Add
  | Knormal.Sub -> Riscv.Sub
  | Knormal.Mul -> Riscv.Mul
  | Knormal.Div -> Riscv.Div
  | Knormal.Rem -> Riscv.Rem

let word = 8

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
      emit ctx.builder (Riscv.Move (target, reg_of ctx x));
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
  | Closure.IfEq (x, y, then_, else_) ->
    generate_branch ctx dest Riscv.Eq (compare_operand ctx x) (compare_operand ctx y) then_ else_
  | Closure.IfLe (x, y, then_, else_) ->
    (* x <= y is y >= x. *)
    generate_branch ctx dest Riscv.Ge (compare_operand ctx y) (compare_operand ctx x) then_ else_
  | Closure.LetTuple (xts, tuple, body) ->
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
      (fun i v -> emit ctx.builder (Riscv.Store (reg_of ctx v, block, (i + 1) * word)))
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
   | Closure.Var x -> emit ctx.builder (Riscv.Move (target, reg_of ctx x))
   | Closure.Neg x -> emit ctx.builder (Riscv.Arith (Riscv.Sub, target, Riscv.zero, reg_of ctx x))
   | Closure.Field (x, i) -> emit ctx.builder (Riscv.Load (target, reg_of ctx x, i * word))
   | Closure.Bin (op, x, y) -> generate_arith ctx target op x y
   | Closure.Tuple xs ->
     let block = allocate_block ctx (List.length xs * word) in
     List.iteri
       (fun i x -> emit ctx.builder (Riscv.Store (reg_of ctx x, block, i * word)))
       xs;
     emit ctx.builder (Riscv.Move (target, block))
   | Closure.Block (tag, xs) ->
     let block = allocate_block ctx ((1 + List.length xs) * word) in
     let tag_reg = Riscv.fresh_reg () in
     emit ctx.builder (Riscv.Li (tag_reg, tag));
     emit ctx.builder (Riscv.Store (tag_reg, block, 0));
     List.iteri
       (fun i x -> emit ctx.builder (Riscv.Store (reg_of ctx x, block, (i + 1) * word)))
       xs;
     emit ctx.builder (Riscv.Move (target, block))
   | Closure.Array (size, init) ->
     emit ctx.builder (Riscv.Move (Riscv.arg_regs.(0), reg_of ctx size));
     emit ctx.builder (Riscv.Move (Riscv.arg_regs.(1), reg_of ctx init));
     emit ctx.builder
       (Riscv.Call (Riscv.Direct "sable_make_array", [ Riscv.arg_regs.(0); Riscv.arg_regs.(1) ]));
     emit ctx.builder (Riscv.Move (target, Riscv.a0))
   | Closure.Get (arr, idx) ->
     let address, offset = element_address ctx arr idx in
     emit ctx.builder (Riscv.Load (target, address, offset))
   | Closure.Put (arr, idx, v) ->
     let address, offset = element_address ctx arr idx in
     emit ctx.builder (Riscv.Store (reg_of ctx v, address, offset));
     emit ctx.builder (Riscv.Li (target, 0))
   | _ -> failwith "Virtual: generate_value on a control-flow expression");
  match dest with
  | Into _ -> ()
  | Return_from_function ->
    emit ctx.builder (Riscv.Move (Riscv.a0, target));
    terminate ctx.builder (Riscv.Return [ Riscv.a0 ])

and generate_arith ctx target op x y =
  let immediate =
    match (op, const_of ctx y) with
    | Knormal.Add, Some n when Riscv.fits_immediate n -> Some (Riscv.Add, reg_of ctx x, n)
    | Knormal.Sub, Some n when Riscv.fits_immediate (-n) -> Some (Riscv.Add, reg_of ctx x, -n)
    | _ -> (
      match (op, const_of ctx x) with
      | Knormal.Add, Some n when Riscv.fits_immediate n -> Some (Riscv.Add, reg_of ctx y, n)
      | _ -> None)
  in
  match immediate with
  | Some (op, src, n) -> emit ctx.builder (Riscv.Arith_imm (op, target, src, n))
  | None ->
    emit ctx.builder (Riscv.Arith (binop_of op, target, reg_of ctx x, reg_of ctx y))

(* The address of an array element, as a base register and a byte offset. *)
and element_address ctx arr idx =
  let base = reg_of ctx arr in
  match const_of ctx idx with
  | Some n when Riscv.fits_immediate (n * word) -> (base, n * word)
  | _ ->
    let scaled = Riscv.fresh_reg () in
    let address = Riscv.fresh_reg () in
    emit ctx.builder (Riscv.Arith_imm (Riscv.Sll, scaled, reg_of ctx idx, 3));
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
