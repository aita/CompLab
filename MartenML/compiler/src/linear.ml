(* The linear intermediate representation: a control-flow graph whose blocks
   hold a flat sequence of instructions.

   Closure-converted code is still a tree: an `if` carries its two arms inside
   it, and the value of a function is whatever its body evaluates to.  Machine
   code is a graph: blocks that end in a terminator naming their successors.
   Somebody has to turn one into the other, and this is that pass.

   Selection could do it on the way past, but then the control-flow graph does
   not exist until the code is already RISC-V.  Keeping it separate draws the
   line this compiler wants:

     Linear  blocks, values, calls.  Knows nothing about registers, the calling
             convention, or which instructions the target has.
     Riscv   instructions, physical registers, `a0`, callee-saved, `t6`.

   Everything above the line is where an SSA form belongs; everything below is
   where the ABI belongs.  See doc/selection.md.

   "Linear" is the shape of a block's contents: instructions in a row, each
   naming its operands, rather than the tree Closure hands over.  The blocks
   themselves are a graph -- Cooper and Torczon would call the combination a
   hybrid, and it is the arrangement nearly every compiler settles on.

   Values are `Ident.t`, and after Alpha every one of them is bound once in the
   source program -- so a name still identifies its definition, which is most
   of what SSA asks for.  What is missing is the merge: both arms of an `if`
   assign the same name, and the block after the join reads it.  Introducing a
   phi node is exactly what would let [check] below demand that a definition
   dominate its uses; today it can only demand that one exist. *)

type cmp = Eq | Le (* x = y, x <= y.  The other four are these with the arms
                      or the operands swapped -- see Knormal. *)

type callee =
  | Direct of Ident.label
  | Closure of Ident.t (* the closure block; its first word is the code *)

(* Operations that compute a value.  These are Closure's, minus the control
   flow, which is now in the terminator. *)
type op =
  | Int of int
  | Move of Ident.t
  | Neg of Ident.t
  | Bin of Knormal.binop * Ident.t * Ident.t
  (* A comparison used as a value rather than as a test.  `negated` is the
     `<>` / `>` case.  Keeping this separate from the branch below is what
     stops a value-position comparison from becoming a diamond of blocks that
     the target would then have to recognize and collapse again. *)
  | Cmp of cmp * Ident.t * Ident.t * bool
  | Static of Ident.label
  | Tuple of Ident.t list
  | Block of int * Ident.t list (* a tagged block: a constructor's value *)
  | Field of Ident.t * int
  | Byte of Ident.t * Ident.t
  | Array of Ident.t * Ident.t
  | Get of Ident.t * Ident.t
  | Put of Ident.t * Ident.t * Ident.t (* yields 0, so that it has a value *)
  | Call of callee * Ident.t list

type instr =
  | Let of Ident.t * op
  (* A whole group at once, because mutually recursive closures capture one
     another: every name is bound before any capture is stored.  The only
     instruction that defines more than one value. *)
  | Closures of (Ident.t * Ident.label * Ident.t list) list

type terminator =
  | Jump of Ident.label
  | Branch of cmp * Ident.t * Ident.t * Ident.label * Ident.label
  | Return of Ident.t
  | Tail of callee * Ident.t list

type block = {
  label : Ident.label;
  body : instr list;
  terminator : terminator;
}

type func = {
  label : Ident.label;
  args : Ident.t list;
  captures : Ident.t list;
  blocks : block list; (* entry first; its label is the function's *)
}

let successors = function
  | Jump l -> [ l ]
  | Branch (_, _, _, t, f) -> [ t; f ]
  | Return _ | Tail _ -> []

let defines = function
  | Let (x, _) -> [ x ]
  | Closures definitions -> List.map (fun (x, _, _) -> x) definitions

let uses_of_op = function
  | Int _ | Static _ -> []
  | Move x | Neg x | Field (x, _) -> [ x ]
  | Bin (_, x, y) | Cmp (_, x, y, _) | Byte (x, y) | Array (x, y) | Get (x, y) -> [ x; y ]
  | Put (x, y, z) -> [ x; y; z ]
  | Tuple xs | Block (_, xs) -> xs
  | Call (Direct _, xs) -> xs
  | Call (Closure f, xs) -> f :: xs

let uses = function
  | Let (_, op) -> uses_of_op op
  | Closures definitions -> List.concat_map (fun (_, _, captured) -> captured) definitions

let uses_of_terminator = function
  | Jump _ -> []
  | Branch (_, x, y, _, _) -> [ x; y ]
  | Return x -> [ x ]
  | Tail (Direct _, xs) -> xs
  | Tail (Closure f, xs) -> f :: xs

(* ------------------------------------------------------------- the builder *)

type builder = {
  mutable done_blocks : block list; (* finished, in reverse order *)
  mutable label : Ident.label;
  mutable pending : instr list; (* current block's body, reversed *)
  mutable open_block : bool;
}

(* Nothing after a terminator can be reached, so it is dropped rather than
   collected into a block with no way in. *)
let emit b instr = if b.open_block then b.pending <- instr :: b.pending

let terminate b terminator =
  if b.open_block then begin
    b.done_blocks <- { label = b.label; body = List.rev b.pending; terminator } :: b.done_blocks;
    b.open_block <- false
  end

let start_block b label =
  b.label <- label;
  b.pending <- [];
  b.open_block <- true

(* ----------------------------------------------------------- from Closure *)

(* Where the value of an expression has to end up. *)
type destination =
  | Into of Ident.t
  | Return_from_function

type context = {
  builder : builder;
  (* Only for the divisor check below: a constant divisor that is not zero
     needs no test.  The target does its own, wider, constant tracking. *)
  mutable consts : int Ident.Map.t;
}

let const_of ctx x = Ident.Map.find_opt x ctx.consts

(* The arms of a comparison that K-normalization turned into a value. *)
let is_boolean_pair a b = (a = 1 && b = 0) || (a = 0 && b = 1)

let finish ctx dest op =
  match dest with
  | Into x -> emit ctx.builder (Let (x, op))
  | Return_from_function ->
    let v = Ident.fresh "v" in
    emit ctx.builder (Let (v, op));
    terminate ctx.builder (Return v)

(* Division by zero is a language-level error, not a machine one: RISC-V
   answers -1 and carries on, so the check has to be in the program.  It is a
   branch, so it belongs here rather than in the target -- which is the whole
   point of the split, and it is why this pass tracks constants at all. *)
let check_divisor ctx divisor =
  let fine = Ident.fresh_label "nonzero" in
  let bad = Ident.fresh_label "divzero" in
  let zero = Ident.fresh "zero" in
  emit ctx.builder (Let (zero, Int 0));
  terminate ctx.builder (Branch (Eq, divisor, zero, bad, fine));
  start_block ctx.builder bad;
  let ignored = Ident.fresh "trap" in
  emit ctx.builder (Let (ignored, Call (Direct "martenml_division_by_zero", [])));
  terminate ctx.builder (Jump fine);
  start_block ctx.builder fine

let rec generate ctx dest exp =
  match exp with
  | Closure.Let ((x, _), Closure.Int n, body) ->
    emit ctx.builder (Let (x, Int n));
    ctx.consts <- Ident.Map.add x n ctx.consts;
    generate ctx dest body
  | Closure.Let ((x, _), value, body) ->
    generate ctx (Into x) value;
    generate ctx dest body
  (* A comparison whose arms are 1 and 0 is a comparison used as a value.
     Branching over it would cost two blocks and a jump for what one
     instruction does. *)
  | Closure.If_eq (x, y, Closure.Int a, Closure.Int b) when is_boolean_pair a b ->
    finish ctx dest (Cmp (Eq, x, y, a = 0))
  | Closure.If_le (x, y, Closure.Int a, Closure.Int b) when is_boolean_pair a b ->
    finish ctx dest (Cmp (Le, x, y, a = 0))
  | Closure.If_eq (x, y, then_, else_) -> generate_branch ctx dest Eq x y then_ else_
  | Closure.If_le (x, y, then_, else_) -> generate_branch ctx dest Le x y then_ else_
  | Closure.Let_tuple (xts, tuple, body) ->
    List.iteri (fun i (x, _) -> emit ctx.builder (Let (x, Field (tuple, i)))) xts;
    generate ctx dest body
  | Closure.Make_closures (definitions, body) ->
    emit ctx.builder
      (Closures
         (List.map
            (fun ((x, _), (c : Closure.closure)) -> (x, c.entry, c.captured))
            definitions));
    generate ctx dest body
  | Closure.Call_direct (label, args) -> generate_call ctx dest (Direct label) args
  | Closure.Call_closure (f, args) -> generate_call ctx dest (Closure f) args
  | Closure.Int n -> finish ctx dest (Int n)
  | Closure.Var x -> finish ctx dest (Move x)
  | Closure.Neg x -> finish ctx dest (Neg x)
  | Closure.Static label -> finish ctx dest (Static label)
  | Closure.Field (x, i) -> finish ctx dest (Field (x, i))
  | Closure.Byte (s, i) -> finish ctx dest (Byte (s, i))
  | Closure.Tuple xs -> finish ctx dest (Tuple xs)
  | Closure.Block (tag, xs) -> finish ctx dest (Block (tag, xs))
  | Closure.Array (size, init) -> finish ctx dest (Array (size, init))
  | Closure.Get (arr, idx) -> finish ctx dest (Get (arr, idx))
  | Closure.Put (arr, idx, v) -> finish ctx dest (Put (arr, idx, v))
  | Closure.Bin (op, x, y) ->
    (match (op, const_of ctx y) with
     | (Knormal.Div | Knormal.Rem), Some n when n <> 0 -> ()
     | (Knormal.Div | Knormal.Rem), _ -> check_divisor ctx y
     | _ -> ());
    finish ctx dest (Bin (op, x, y))

and generate_branch ctx dest cond x y then_ else_ =
  let then_label = Ident.fresh_label "then" in
  let else_label = Ident.fresh_label "else" in
  terminate ctx.builder (Branch (cond, x, y, then_label, else_label));
  match dest with
  | Return_from_function ->
    (* Each arm returns on its own; there is nothing to join. *)
    let saved = ctx.consts in
    start_block ctx.builder then_label;
    generate ctx dest then_;
    ctx.consts <- saved;
    start_block ctx.builder else_label;
    generate ctx dest else_
  | Into r ->
    let join_label = Ident.fresh_label "join" in
    let saved = ctx.consts in
    start_block ctx.builder then_label;
    generate ctx (Into r) then_;
    terminate ctx.builder (Jump join_label);
    ctx.consts <- saved;
    start_block ctx.builder else_label;
    generate ctx (Into r) else_;
    terminate ctx.builder (Jump join_label);
    (* Nothing an arm bound is in scope after the join.  `r` itself is: it is
       assigned in both arms, which is the merge a phi node would carry. *)
    ctx.consts <- saved;
    start_block ctx.builder join_label

and generate_call ctx dest callee args =
  match dest with
  | Return_from_function -> terminate ctx.builder (Tail (callee, args))
  | Into r -> emit ctx.builder (Let (r, Call (callee, args)))

let build_function label args captures body =
  let builder = { done_blocks = []; label; pending = []; open_block = true } in
  let ctx = { builder; consts = Ident.Map.empty } in
  generate ctx Return_from_function body;
  {
    label;
    args = List.map fst args;
    captures = List.map fst captures;
    blocks = List.rev builder.done_blocks;
  }

let translate (program : Closure.program) =
  List.map
    (fun (fd : Closure.fundef) -> build_function fd.label fd.args fd.captures fd.body)
    program.functions
  @ [ build_function "martenml_main" [] [] program.main ]

(* ------------------------------------------------------------ the invariant *)

exception Broken of string

let broken fmt = Printf.ksprintf (fun s -> raise (Broken s)) fmt

(* What a well-formed graph owes the passes below it.

   The use check is deliberately weak: it asks that a definition exist, not
   that it dominate the use.  It cannot ask for more yet.  `let x = if c then a
   else b` puts one definition of x in each arm, and neither arm dominates the
   block that reads it -- the definition that reaches the join depends on which
   way control went, and nothing in the graph says so.  A phi node in the join
   block is what would, and the day one exists this check becomes a dominance
   check.  That is the honest measure of how far this IR is from SSA. *)
let check (f : func) =
  let where = f.label in
  (match f.blocks with
   | [] -> broken "%s: no blocks" where
   | (entry : block) :: _ when entry.label <> f.label ->
     broken "%s: the entry block is labelled `%s'" where entry.label
   | _ -> ());
  let labels = Hashtbl.create 16 in
  List.iter
    (fun (b : block) ->
      if Hashtbl.mem labels b.label then broken "%s: two blocks labelled `%s'" where b.label;
      Hashtbl.add labels b.label ())
    f.blocks;
  List.iter
    (fun (b : block) ->
      List.iter
        (fun l ->
          if not (Hashtbl.mem labels l) then
            broken "%s: block `%s' names a successor `%s' that does not exist" where b.label l)
        (successors b.terminator))
    f.blocks;
  (* Every block has to be on some path from the entry.  A block with no way
     in is not wrong so much as a sign that the builder emitted one it then
     never jumped to, which is the kind of mistake that stays invisible until
     the allocator reports a value live in a place it cannot be. *)
  let index = Hashtbl.create 16 in
  List.iteri (fun i (b : block) -> Hashtbl.replace index b.label i) f.blocks;
  let blocks = Array.of_list f.blocks in
  let seen = Array.make (Array.length blocks) false in
  let rec visit i =
    if not seen.(i) then begin
      seen.(i) <- true;
      List.iter
        (fun l -> match Hashtbl.find_opt index l with Some s -> visit s | None -> ())
        (successors blocks.(i).terminator)
    end
  in
  if Array.length blocks > 0 then visit 0;
  Array.iteri
    (fun i reached ->
      if not reached then broken "%s: block `%s' cannot be reached" where blocks.(i).label)
    seen;
  (* Defined anywhere in the function, or coming in as a parameter. *)
  let defined = Hashtbl.create 64 in
  List.iter (fun x -> Hashtbl.replace defined x ()) (f.args @ f.captures);
  List.iter
    (fun (b : block) ->
      List.iter (fun i -> List.iter (fun x -> Hashtbl.replace defined x ()) (defines i)) b.body)
    f.blocks;
  List.iter
    (fun (b : block) ->
      let check_use x =
        if not (Hashtbl.mem defined x) then
          broken "%s: block `%s' uses `%s', which nothing defines" where b.label x
      in
      List.iter (fun i -> List.iter check_use (uses i)) b.body;
      List.iter check_use (uses_of_terminator b.terminator))
    f.blocks
