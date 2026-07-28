(* IR -> a wasm module.

   The module has one import, [env.log], so a flow can report intermediate
   values, and exports [main] taking the start node's inputs as f64 and
   returning an f64.  Locals are laid out as parameters, then variables,
   then a pair of scratch slots for every [%] in the program. *)

open Ir

let rec count_mods_expr = function
  | Num _ | Local _ -> 0
  | Bin (Mod, l, r) -> 1 + count_mods_expr l + count_mods_expr r
  | Bin (_, l, r) | Cmp (_, l, r) | And (l, r) | Or (l, r) ->
      count_mods_expr l + count_mods_expr r
  | Un (_, e) | Not e -> count_mods_expr e

let rec count_mods_block b = List.fold_left (fun n s -> n + count_mods_stmt s) 0 b

and count_mods_stmt = function
  | Assign (_, e) | Log e | Ret e -> count_mods_expr e
  | If (c, t, e) -> count_mods_expr c + count_mods_block t + count_mods_block e
  | While (c, body) -> count_mods_expr c + count_mods_block body

let log_index = 0 (* the only import, so it takes function index 0 *)

type env = { mutable scratch_next : int }

let take_scratch env =
  let i = env.scratch_next in
  env.scratch_next <- i + 2;
  i

let binop_code = function
  | Add -> Wasm.f64_add
  | Sub -> Wasm.f64_sub
  | Mul -> Wasm.f64_mul
  | Div -> Wasm.f64_div
  | Min -> Wasm.f64_min
  | Max -> Wasm.f64_max
  | Mod -> assert false

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
      (* x % y as x - trunc(x / y) * y; the operands land in scratch locals
         so neither is evaluated twice. *)
      let s = take_scratch env in
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
  | While (c, body) ->
      (* block { loop { br_if 1 (!cond); body; br 0 } } *)
      Wasm.block b (fun () ->
          Wasm.loop b (fun () ->
              expr env b c;
              Wasm.op b Wasm.i32_eqz;
              Wasm.br_if b 1;
              block env b body;
              Wasm.br b 0))

let module_of_func (f : func) : string =
  let nparams = List.length f.params in
  let nvars = List.length f.vars in
  let nmods = count_mods_block f.body in
  let env = { scratch_next = nparams + nvars } in
  let code = Wasm.create () in
  block env code f.body;
  (* A flow that never reaches an end node still has to leave a result. *)
  Wasm.f64_const code 0.;
  let locals =
    List.filter
      (fun (n, _) -> n > 0)
      [ (nvars, Wasm.F64); (2 * nmods, Wasm.F64) ]
  in
  let main_type =
    { Wasm.args = List.map (fun _ -> Wasm.F64) f.params; result = Some Wasm.F64 }
  in
  let log_type = { Wasm.args = [ Wasm.F64 ]; result = None } in
  Wasm.encode ~types:[ log_type; main_type ]
    ~imports:
      [ { Wasm.imp_module = "env"; imp_field = "log"; imp_type = 0 } ]
    ~funcs:[ 1 ]
    ~exports:[ ("main", 1) ]
    ~bodies:[ { Wasm.body_locals = locals; body_code = code } ]
