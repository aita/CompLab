(* IR -> a wasm module.

   The module imports [env.log], so a flow can report intermediate values,
   [env.random], and [env.watch], which is what a breakpoint compiles to; it
   exports [main] taking the start node's inputs as f64 and returning an f64.
   Locals are laid out as parameters, then variables, then whatever scratch
   the expressions need.

   Instruction selection follows the types the lowering worked out: a whole
   number is an i64, everything else an f64.  Both sides of an operator always
   agree by then, so reading the type off the left one is enough. *)

open Ir

(* An operand that costs nothing to read twice, so it never needs a scratch
   local to be kept in. *)
let is_atom = function Num _ | Int _ | Local _ -> true | _ -> false

(* The scratch an expression needs, in the order it will be taken: [%] on
   floats parks both operands, a random parks its low end, an absolute value
   parks its argument, and a breakpoint on a whole number parks it while the
   host is handed a float copy. *)
let rec scratch_of_expr ty = function
  | Int _ | Num _ | Local _ -> []
  | Bin (Mod, l, r) ->
      (if ty l = VFloat then [ VFloat; VFloat ] else [])
      @ scratch_of_expr ty l @ scratch_of_expr ty r
  | Rand (lo, hi) ->
      (if is_atom lo then [] else [ VFloat ])
      @ scratch_of_expr ty lo @ scratch_of_expr ty hi
  | Un (Abs, e) when ty e = VInt -> VInt :: scratch_of_expr ty e
  | Watch (_, VInt, e) -> VInt :: scratch_of_expr ty e
  | Watch (_, _, e) -> scratch_of_expr ty e
  | Bin (_, l, r) | Cmp (_, l, r) | And (l, r) | Or (l, r) ->
      scratch_of_expr ty l @ scratch_of_expr ty r
  | Select (c, a, b) ->
      scratch_of_expr ty c @ scratch_of_expr ty a @ scratch_of_expr ty b
  | Un (_, e) | Not e | Widen e -> scratch_of_expr ty e

let rec scratch_of_block ty b = List.concat_map (scratch_of_stmt ty) b

and scratch_of_stmt ty = function
  | Assign (_, e) | Log e | Ret e | Drop e -> scratch_of_expr ty e
  | If (c, t, e) ->
      scratch_of_expr ty c @ scratch_of_block ty t @ scratch_of_block ty e
  | While (pre, c, body) ->
      scratch_of_block ty pre @ scratch_of_expr ty c @ scratch_of_block ty body

(* The imports come first, in the order they are declared. *)
let log_index = 0
let random_index = 1
let watch_index = 2
let main_index = 3

type env = {
  ty : expr -> vtype;
  mutable scratch_next : int;  (* the scratch locals are taken in order *)
}

let take_scratch env n =
  let i = env.scratch_next in
  env.scratch_next <- i + n;
  i

let binop_code t = function
  | Add -> if t = VInt then Wasm.i64_add else Wasm.f64_add
  | Sub -> if t = VInt then Wasm.i64_sub else Wasm.f64_sub
  | Mul -> if t = VInt then Wasm.i64_mul else Wasm.f64_mul
  | Div -> Wasm.f64_div
  | Min -> Wasm.f64_min
  | Max -> Wasm.f64_max
  | Mod -> Wasm.i64_rem_s (* the float case is expanded before this *)

let unop_code = function
  | Neg -> Wasm.f64_neg
  | Abs -> Wasm.f64_abs
  | Sqrt -> Wasm.f64_sqrt
  | Floor -> Wasm.f64_floor
  | Ceil -> Wasm.f64_ceil
  | Round -> Wasm.f64_nearest

let cmp_code t = function
  | Lt -> if t = VInt then Wasm.i64_lt_s else Wasm.f64_lt
  | Le -> if t = VInt then Wasm.i64_le_s else Wasm.f64_le
  | Gt -> if t = VInt then Wasm.i64_gt_s else Wasm.f64_gt
  | Ge -> if t = VInt then Wasm.i64_ge_s else Wasm.f64_ge
  | Eq -> if t = VInt then Wasm.i64_eq else Wasm.f64_eq
  | Ne -> if t = VInt then Wasm.i64_ne else Wasm.f64_ne

let rec expr env b e =
  match e with
  | Int n -> Wasm.i64_const b n
  | Num x -> Wasm.f64_const b x
  | Local i -> Wasm.local_get b i
  | Widen e ->
      expr env b e;
      Wasm.op b Wasm.f64_convert_i64_s
  | Bin (Mod, l, r) when env.ty l = VFloat ->
      (* x % y as x - trunc(x / y) * y; the operands land in scratch locals so
         neither is evaluated twice.  Whole numbers have an instruction. *)
      let s = take_scratch env 2 in
      expr env b l;
      Wasm.local_set b s;
      expr env b r;
      Wasm.local_set b (s + 1);
      Wasm.local_get b s;
      Wasm.local_get b s;
      Wasm.local_get b (s + 1);
      Wasm.op b Wasm.f64_div;
      Wasm.op b Wasm.f64_trunc;
      Wasm.local_get b (s + 1);
      Wasm.op b Wasm.f64_mul;
      Wasm.op b Wasm.f64_sub
  | Un (Neg, e) when env.ty e = VInt ->
      (* wasm has no i64 negate; subtracting from zero is one instruction. *)
      Wasm.i64_const b 0;
      expr env b e;
      Wasm.op b Wasm.i64_sub
  | Un (Abs, e) when env.ty e = VInt ->
      (* nor an i64 absolute value: pick between x and -x. *)
      let s = take_scratch env 1 in
      expr env b e;
      Wasm.local_set b s;
      Wasm.i64_const b 0;
      Wasm.local_get b s;
      Wasm.op b Wasm.i64_sub;
      Wasm.local_get b s;
      Wasm.local_get b s;
      Wasm.i64_const b 0;
      Wasm.op b Wasm.i64_lt_s;
      Wasm.op b Wasm.op_select
  | Bin (op, l, r) ->
      let t = env.ty l in
      expr env b l;
      expr env b r;
      Wasm.op b (binop_code t op)
  | Un (op, e) ->
      expr env b e;
      Wasm.op b (unop_code op)
  | Cmp (op, l, r) ->
      let t = env.ty l in
      expr env b l;
      expr env b r;
      Wasm.op b (cmp_code t op)
  | And (l, r) ->
      expr env b l;
      expr env b r;
      Wasm.op b Wasm.i32_and
  | Or (l, r) ->
      expr env b l;
      expr env b r;
      Wasm.op b Wasm.i32_or
  | Not e ->
      expr env b e;
      Wasm.op b Wasm.i32_eqz
  | Select (c, a, b') ->
      expr env b a;
      expr env b b';
      expr env b c;
      Wasm.op b Wasm.op_select
  | Rand (lo, hi) ->
      (* lo + random() * (hi - lo).  Only lo is read twice, so only lo has to
         be parked, and not even that when it is already a local or a
         literal.  The slot is taken before the operands are emitted, so it
         cannot collide with one they take themselves. *)
      let parked = if is_atom lo then None else Some (take_scratch env 1) in
      let low () =
        match parked with
        | None -> expr env b lo
        | Some s -> Wasm.local_get b s
      in
      (match parked with
      | None -> expr env b lo
      | Some s ->
          expr env b lo;
          Wasm.local_set b s;
          Wasm.local_get b s);
      expr env b hi;
      low ();
      Wasm.op b Wasm.f64_sub;
      Wasm.call b random_index;
      Wasm.op b Wasm.f64_mul;
      Wasm.op b Wasm.f64_add
  | Watch (i, VInt, e) ->
      (* The host takes and returns an f64.  A whole number does not go out
         and back through one -- past 2^53 it would not survive the trip --
         so it waits in a local while a copy is reported. *)
      let s = take_scratch env 1 in
      expr env b e;
      Wasm.local_set b s;
      Wasm.i32_const b i;
      Wasm.local_get b s;
      Wasm.op b Wasm.f64_convert_i64_s;
      Wasm.call b watch_index;
      Wasm.op b Wasm.op_drop;
      Wasm.local_get b s
  | Watch (i, ty, e) ->
      (* A condition goes out and comes back through an f64; 0 and 1 survive
         the trip exactly. *)
      Wasm.i32_const b i;
      expr env b e;
      if ty = VBool then Wasm.op b Wasm.f64_convert_i32_u;
      Wasm.call b watch_index;
      if ty = VBool then Wasm.op b Wasm.i32_trunc_f64_u

let rec block env b stmts = List.iter (stmt env b) stmts

and stmt env b = function
  | Assign (i, e) ->
      expr env b e;
      Wasm.local_set b i
  | Drop e ->
      expr env b e;
      Wasm.op b Wasm.op_drop
  | Log e ->
      expr env b e;
      Wasm.call b log_index
  | Ret e ->
      expr env b e;
      Wasm.op b Wasm.op_return
  | If (c, t, e) ->
      expr env b c;
      Wasm.if_else b
        ~then_:(fun () -> block env b t)
        ~else_:(if e = [] then None else Some (fun () -> block env b e))
  | While (pre, c, body) ->
      (* block { loop { pre; br_if 1 (!cond); body; br 0 } } *)
      Wasm.block b (fun () ->
          Wasm.loop b (fun () ->
              block env b pre;
              expr env b c;
              Wasm.op b Wasm.i32_eqz;
              Wasm.br_if b 1;
              block env b body;
              Wasm.br b 0))

let wasm_type = function
  | VInt -> Wasm.I64
  | VFloat -> Wasm.F64
  | VBool -> Wasm.I32

(* The format wants runs of like-typed locals, in index order. *)
let runs types =
  List.rev
    (List.fold_left
       (fun acc t ->
         let v = wasm_type t in
         match acc with
         | (n, u) :: tl when u = v -> (n + 1, u) :: tl
         | _ -> (1, v) :: acc)
       [] types)

(* Parameters are f64 whatever the graph does with them: they come from the
   host, which has only one kind of number. *)
let local_types (f : func) i =
  let nparams = List.length f.params in
  if i < nparams then VFloat else snd (List.nth f.vars (i - nparams))

let module_of_func (f : func) : string =
  let ty = Ir.type_of (local_types f) in
  let scratch = scratch_of_block ty f.body in
  let env =
    { ty; scratch_next = List.length f.params + List.length f.vars }
  in
  let code = Wasm.create () in
  block env code f.body;
  (* A flow that never reaches an end node still has to leave a result. *)
  Wasm.f64_const code 0.;
  let locals = runs (List.map snd f.vars @ scratch) in
  let main_type =
    { Wasm.args = List.map (fun _ -> Wasm.F64) f.params; result = Some Wasm.F64 }
  in
  let log_type = { Wasm.args = [ Wasm.F64 ]; result = None } in
  let random_type = { Wasm.args = []; result = Some Wasm.F64 } in
  let watch_type =
    { Wasm.args = [ Wasm.I32; Wasm.F64 ]; result = Some Wasm.F64 }
  in
  Wasm.encode
    ~types:[ log_type; random_type; watch_type; main_type ]
    ~imports:
      [
        { Wasm.imp_module = "env"; imp_field = "log"; imp_type = 0 };
        { Wasm.imp_module = "env"; imp_field = "random"; imp_type = 1 };
        { Wasm.imp_module = "env"; imp_field = "watch"; imp_type = 2 };
      ]
    ~funcs:[ 3 ]
    ~exports:[ ("main", main_index) ]
    ~bodies:[ { Wasm.body_locals = locals; body_code = code } ]
