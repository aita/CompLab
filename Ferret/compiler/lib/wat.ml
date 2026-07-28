(* The same instruction stream as Emit, written out as text.  It is what the
   editor shows in its Code tab: one line per instruction, in the order the
   bytes are written, so the text and the binary can be read against each
   other. *)

open Ir

type env = {
  names : string array;  (* local index -> $name *)
  ty : expr -> vtype;
  mutable scratch_next : int;
  mutable labels : label option list;
  b : Buffer.t;
  mutable indent : int;
}

let depth_of env l =
  let rec find n = function
    | [] -> -1
    | Some x :: _ when x = l -> n
    | _ :: rest -> find (n + 1) rest
  in
  find 0 env.labels

let line env fmt =
  Printf.ksprintf
    (fun s ->
      Buffer.add_string env.b (String.make (env.indent * 2) ' ');
      Buffer.add_string env.b s;
      Buffer.add_char env.b '\n')
    fmt

let local env i =
  if i < Array.length env.names then env.names.(i) else Printf.sprintf "$l%d" i

let take_scratch env n =
  let i = env.scratch_next in
  env.scratch_next <- i + n;
  i

let num_literal x =
  if Float.is_integer x && Float.abs x < 1e15 then Printf.sprintf "%.1f" x
  else Printf.sprintf "%.17g" x

let kind = function VInt -> "i64" | VFloat -> "f64" | VBool -> "i32"

let binop_name t = function
  | Add -> kind t ^ ".add"
  | Sub -> kind t ^ ".sub"
  | Mul -> kind t ^ ".mul"
  | Div -> "f64.div"
  | Min -> "f64.min"
  | Max -> "f64.max"
  | Mod -> "i64.rem_s"

let unop_name = function
  | Neg -> "f64.neg"
  | Abs -> "f64.abs"
  | Sqrt -> "f64.sqrt"
  | Floor -> "f64.floor"
  | Ceil -> "f64.ceil"
  | Round -> "f64.nearest"

let cmp_name t op =
  let signed s = if t = VInt then s ^ "_s" else s in
  kind t ^ "."
  ^
  match op with
  | Lt -> signed "lt"
  | Le -> signed "le"
  | Gt -> signed "gt"
  | Ge -> signed "ge"
  | Eq -> "eq"
  | Ne -> "ne"

let rec expr env e =
  match e with
  | Int n -> line env "i64.const %d" n
  | Num x -> line env "f64.const %s" (num_literal x)
  | Local i -> line env "local.get %s" (local env i)
  | Widen e ->
      expr env e;
      line env "f64.convert_i64_s"
  | Bin (Mod, l, r) when env.ty l = VFloat ->
      let s = take_scratch env 2 in
      expr env l;
      line env "local.set %s" (local env s);
      expr env r;
      line env "local.set %s" (local env (s + 1));
      line env "local.get %s" (local env s);
      line env "local.get %s" (local env s);
      line env "local.get %s" (local env (s + 1));
      line env "f64.div";
      line env "f64.trunc";
      line env "local.get %s" (local env (s + 1));
      line env "f64.mul";
      line env "f64.sub"
  | Un (Neg, e) when env.ty e = VInt ->
      line env "i64.const 0";
      expr env e;
      line env "i64.sub"
  | Un (Abs, e) when env.ty e = VInt ->
      let s = take_scratch env 1 in
      expr env e;
      line env "local.set %s" (local env s);
      line env "i64.const 0";
      line env "local.get %s" (local env s);
      line env "i64.sub";
      line env "local.get %s" (local env s);
      line env "local.get %s" (local env s);
      line env "i64.const 0";
      line env "i64.lt_s";
      line env "select"
  | Bin (op, l, r) ->
      let t = env.ty l in
      expr env l;
      expr env r;
      line env "%s" (binop_name t op)
  | Un (op, e) ->
      expr env e;
      line env "%s" (unop_name op)
  | Cmp (op, l, r) ->
      let t = env.ty l in
      expr env l;
      expr env r;
      line env "%s" (cmp_name t op)
  | And (l, r) ->
      expr env l;
      expr env r;
      line env "i32.and"
  | Or (l, r) ->
      expr env l;
      expr env r;
      line env "i32.or"
  | Not e ->
      expr env e;
      line env "i32.eqz"
  | Select (c, a, b) ->
      expr env a;
      expr env b;
      expr env c;
      line env "select"
  | Now -> line env "call $now"
  | Wait -> line env "call $wait"
  | Rand (lo, hi) ->
      let parked =
        if Emit.is_atom lo then None else Some (take_scratch env 1)
      in
      let low () =
        match parked with
        | None -> expr env lo
        | Some s -> line env "local.get %s" (local env s)
      in
      (match parked with
      | None -> expr env lo
      | Some s ->
          expr env lo;
          line env "local.set %s" (local env s);
          line env "local.get %s" (local env s));
      expr env hi;
      low ();
      line env "f64.sub";
      line env "call $random";
      line env "f64.mul";
      line env "f64.add"
  | Watch (i, VInt, e) ->
      let s = take_scratch env 1 in
      expr env e;
      line env "local.set %s" (local env s);
      line env "i32.const %d" i;
      line env "local.get %s" (local env s);
      line env "f64.convert_i64_s";
      line env "call $watch";
      line env "drop";
      line env "local.get %s" (local env s)
  | Watch (i, ty, e) ->
      line env "i32.const %d" i;
      expr env e;
      if ty = VBool then line env "f64.convert_i32_u";
      line env "call $watch";
      if ty = VBool then line env "i32.trunc_f64_u"

let nested env f =
  env.indent <- env.indent + 1;
  f ();
  env.indent <- env.indent - 1

let rec block env stmts = List.iter (stmt env) stmts

and stmt env = function
  | Assign (i, e) ->
      expr env e;
      line env "local.set %s" (local env i)
  | Drop e ->
      expr env e;
      line env "drop"
  | Log e ->
      expr env e;
      line env "call $log"
  | Ret e ->
      expr env e;
      line env "return"
  | If (c, t, e) ->
      expr env c;
      line env "if";
      env.labels <- None :: env.labels;
      nested env (fun () -> block env t);
      if e <> [] then (
        line env "else";
        nested env (fun () -> block env e));
      env.labels <- List.tl env.labels;
      line env "end"
  | Block (l, body) ->
      line env "block  ;; $%d" l;
      env.labels <- Some l :: env.labels;
      nested env (fun () -> block env body);
      env.labels <- List.tl env.labels;
      line env "end"
  | Loop (l, body) ->
      line env "loop  ;; $%d" l;
      env.labels <- Some l :: env.labels;
      nested env (fun () -> block env body);
      env.labels <- List.tl env.labels;
      line env "end"
  | Br l -> line env "br %d  ;; $%d" (depth_of env l) l

let of_func (f : func) : string =
  let ty = Ir.type_of (Emit.local_types f) in
  let scratch =
    List.mapi
      (fun i t -> (Printf.sprintf "$t%d" i, t))
      (Emit.scratch_of_block ty f.body)
  in
  let names =
    Array.of_list
      (List.map (fun n -> "$" ^ n) (List.map fst f.vars)
      @ List.map fst scratch)
  in
  let env =
    {
      names;
      ty;
      scratch_next = List.length f.vars;
      labels = [];
      b = Buffer.create 512;
      indent = 0;
    }
  in
  line env "(module";
  nested env (fun () ->
      line env "(import \"env\" \"log\" (func $log (param f64)))";
      line env "(import \"env\" \"random\" (func $random (result f64)))";
      line env
        "(import \"env\" \"watch\" (func $watch (param i32) (param f64) (result f64)))";
      line env "(import \"env\" \"now\" (func $now (result f64)))";
      line env "(import \"env\" \"wait\" (func $wait (result f64)))";
      line env "(func $main (export \"main\") (result f64)";
      nested env (fun () ->
          List.iter (fun (v, t) -> line env "(local $%s %s)" v (kind t)) f.vars;
          List.iter (fun (n, t) -> line env "(local %s %s)" n (kind t)) scratch;
          block env f.body;
          line env "f64.const 0.0");
      line env ")");
  line env ")";
  Buffer.contents env.b
