(* IR -> a wasm module.

   The module has one import, [env.log], so a flow can report intermediate
   values, and exports [main] taking the start node's inputs as f64 and
   returning an f64.  Locals are laid out as parameters, then variables, then
   a pair of scratch slots for every [%] in the program. *)

open Ir

(* Every [%] parks both of its operands in scratch locals. *)
let rec scratch_of_expr = function
  | Num _ | Local _ -> 0
  | Bin (Mod, l, r) -> 2 + scratch_of_expr l + scratch_of_expr r
  | Bin (_, l, r) | Cmp (_, l, r) | And (l, r) | Or (l, r) ->
      scratch_of_expr l + scratch_of_expr r
  | Select (c, a, b) ->
      scratch_of_expr c + scratch_of_expr a + scratch_of_expr b
  | Un (_, e) | Not e -> scratch_of_expr e

let rec scratch_of_block b =
  List.fold_left (fun n s -> n + scratch_of_stmt s) 0 b

and scratch_of_stmt = function
  | Assign (_, e) | Log e | Ret e -> scratch_of_expr e
  | If (c, t, e) -> scratch_of_expr c + scratch_of_block t + scratch_of_block e
  | While (pre, c, body) ->
      scratch_of_block pre + scratch_of_expr c + scratch_of_block body

let log_index = 0 (* the only import, so it takes function index 0 *)
let main_index = 1

type env = { mutable scratch_next : int }

let take_scratch env n =
  let i = env.scratch_next in
  env.scratch_next <- i + n;
  i

let binop_code = function
  | Add -> Wasm.f64_add
  | Sub -> Wasm.f64_sub
  | Mul -> Wasm.f64_mul
  | Div -> Wasm.f64_div
  | Min -> Wasm.f64_min
  | Max -> Wasm.f64_max
  | Mod -> assert false (* expanded before it gets here *)

let unop_code = function
  | Neg -> Wasm.f64_neg
  | Abs -> Wasm.f64_abs
  | Sqrt -> Wasm.f64_sqrt
  | Floor -> Wasm.f64_floor
  | Ceil -> Wasm.f64_ceil
  | Round -> Wasm.f64_nearest

let cmp_code = function
  | Lt -> Wasm.f64_lt
  | Le -> Wasm.f64_le
  | Gt -> Wasm.f64_gt
  | Ge -> Wasm.f64_ge
  | Eq -> Wasm.f64_eq
  | Ne -> Wasm.f64_ne

let rec expr env b = function
  | Num x -> Wasm.f64_const b x
  | Local i -> Wasm.local_get b i
  | Bin (Mod, l, r) ->
      (* x % y as x - trunc(x / y) * y; the operands land in scratch locals so
         neither is evaluated twice. *)
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
  | Bin (op, l, r) ->
      expr env b l;
      expr env b r;
      Wasm.op b (binop_code op)
  | Un (op, e) ->
      expr env b e;
      Wasm.op b (unop_code op)
  | Cmp (op, l, r) ->
      expr env b l;
      expr env b r;
      Wasm.op b (cmp_code op)
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

let rec block env b stmts = List.iter (stmt env b) stmts

and stmt env b = function
  | Assign (i, e) ->
      expr env b e;
      Wasm.local_set b i
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

let wasm_type = function VNum -> Wasm.F64 | VBool -> Wasm.I32

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

let module_of_func (f : func) : string =
  let scratch = scratch_of_block f.body in
  let env = { scratch_next = List.length f.params + List.length f.vars } in
  let code = Wasm.create () in
  block env code f.body;
  (* A flow that never reaches an end node still has to leave a result. *)
  Wasm.f64_const code 0.;
  let locals =
    runs (List.map snd f.vars) @ List.filter (fun (n, _) -> n > 0) [ (scratch, Wasm.F64) ]
  in
  let main_type =
    { Wasm.args = List.map (fun _ -> Wasm.F64) f.params; result = Some Wasm.F64 }
  in
  let log_type = { Wasm.args = [ Wasm.F64 ]; result = None } in
  Wasm.encode ~types:[ log_type; main_type ]
    ~imports:[ { Wasm.imp_module = "env"; imp_field = "log"; imp_type = 0 } ]
    ~funcs:[ 1 ]
    ~exports:[ ("main", main_index) ]
    ~bodies:[ { Wasm.body_locals = locals; body_code = code } ]
