(* IR -> a wasm module.

   The module imports [env.log], so a graph can report intermediate values,
   [env.random], [env.now], [env.say], and [env.watch], which is what a
   breakpoint compiles to; it exports [main], which takes nothing and returns
   an f64: one cook of the graph.  Locals are laid out as the ones the IR
   named, then whatever scratch the expressions need.

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
  | Int _ | Num _ | Local _ | Global _ | Now -> []
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
  | Assign (_, e) | Store (_, e) | Log e | Ret e | Drop e -> scratch_of_expr ty e
  | Say _ -> []

(* The imports come first, in the order they are declared. *)
let log_index = 0
let random_index = 1
let watch_index = 2
let now_index = 3
let say_index = 4

(* The only function the module defines, so it comes after the imports. *)
let main_index = 5

type env = {
  ty : expr -> vtype;
  (* where each literal sits in the module's memory: offset and length *)
  strings : (int * int) array;
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
  | Global i -> Wasm.global_get b i
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
  | Now -> Wasm.call b now_index
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
  | Store (i, e) ->
      expr env b e;
      Wasm.global_set b i
  | Drop e ->
      expr env b e;
      Wasm.op b Wasm.op_drop
  | Log e ->
      expr env b e;
      Wasm.call b log_index
  | Say i ->
      let off, len = env.strings.(i) in
      Wasm.i32_const b off;
      Wasm.i32_const b len;
      Wasm.call b say_index
  | Ret e ->
      expr env b e;
      Wasm.op b Wasm.op_return

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

let local_types (f : func) i = snd (List.nth f.vars i)

(* One function, called once per cook.  What a feedback holds has to outlive
   the call, so a graph's state is in globals rather than in a function's
   locals -- which is also what lets the host read all of it. *)
let module_of (m : modul) : string =
  let globals i = let _, t, _ = List.nth m.globals i in t in
  (* The literals go end to end from offset 0 and are never written to. *)
  let data = String.concat "" m.strings in
  let layout =
    let at = ref 0 in
    Array.of_list
      (List.map
         (fun s ->
           let here = (!at, String.length s) in
           at := !at + String.length s;
           here)
         m.strings)
  in
  let log_type = { Wasm.args = [ Wasm.F64 ]; result = None } in
  let random_type = { Wasm.args = []; result = Some Wasm.F64 } in
  (* [now] has the same shape as [random], and is asked the same way: the host
     is the only thing that knows. *)
  let watch_type =
    { Wasm.args = [ Wasm.I32; Wasm.F64 ]; result = Some Wasm.F64 }
  in
  (* [say] is handed a slice of the module's memory, which is exported so the
     host can read the bytes back out of it. *)
  let say_type = { Wasm.args = [ Wasm.I32; Wasm.I32 ]; result = None } in
  let cook_type = { Wasm.args = []; result = Some Wasm.F64 } in
  let imports =
    [
      { Wasm.imp_module = "env"; imp_field = "log"; imp_type = 0 };
      { Wasm.imp_module = "env"; imp_field = "random"; imp_type = 1 };
      { Wasm.imp_module = "env"; imp_field = "watch"; imp_type = 2 };
      { Wasm.imp_module = "env"; imp_field = "now"; imp_type = 1 };
      { Wasm.imp_module = "env"; imp_field = "say"; imp_type = 4 };
    ]
  in
  let first = List.length imports in
  let body_of (f : func) =
    let locals i = snd (List.nth f.vars i) in
    let ty = Ir.type_of ~locals ~globals in
    let scratch = scratch_of_block ty f.body in
    let env =
      {
        ty;
        strings = layout;
        scratch_next = List.length f.vars;
      }
    in
    let code = Wasm.create () in
    block env code f.body;
    (* A flow that never reaches an end node still has to leave a result. *)
    Wasm.f64_const code 0.;
    {
      Wasm.body_locals = runs (List.map snd f.vars @ scratch);
      body_code = code;
    }
  in
  Wasm.encode
    ~types:[ log_type; random_type; watch_type; cook_type; say_type ]
    ~imports
    ~funcs:(List.map (fun _ -> 3) m.funcs)
    ~globals:(List.map (fun (_, t, init) -> (wasm_type t, init)) m.globals)
    ~data
    ~exports:
      (List.mapi (fun i (f : func) -> (f.name, Wasm.Func (first + i))) m.funcs
      @ List.mapi
          (fun i (v, _, _) -> (Ir.global_export v, Wasm.Global i))
          m.globals
      (* The host reads the text out of the memory it was handed a slice of. *)
      @ (if m.strings = [] then [] else [ ("memory", Wasm.Memory) ]))
    ~bodies:(List.map body_of m.funcs)
