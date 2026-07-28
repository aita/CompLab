(* The same instruction stream as Emit, written out as text.  It is what the
   editor shows in its Code tab: one line per instruction, in the order the
   bytes are written, so the text and the binary can be read against each
   other. *)

open Ir

type env = {
  names : string array;  (* local index -> $name *)
  mutable scratch_next : int;
  b : Buffer.t;
  mutable indent : int;
}

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

let kind = function VNum -> "f64" | VBool -> "i32"

let binop_name = function
  | Add -> "f64.add"
  | Sub -> "f64.sub"
  | Mul -> "f64.mul"
  | Div -> "f64.div"
  | Min -> "f64.min"
  | Max -> "f64.max"
  | Mod -> assert false

let unop_name = function
  | Neg -> "f64.neg"
  | Abs -> "f64.abs"
  | Sqrt -> "f64.sqrt"
  | Floor -> "f64.floor"
  | Ceil -> "f64.ceil"
  | Round -> "f64.nearest"

let cmp_name = function
  | Lt -> "f64.lt"
  | Le -> "f64.le"
  | Gt -> "f64.gt"
  | Ge -> "f64.ge"
  | Eq -> "f64.eq"
  | Ne -> "f64.ne"

let rec expr env = function
  | Num x -> line env "f64.const %s" (num_literal x)
  | Local i -> line env "local.get %s" (local env i)
  | Bin (Mod, l, r) ->
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
  | Bin (op, l, r) ->
      expr env l;
      expr env r;
      line env "%s" (binop_name op)
  | Un (op, e) ->
      expr env e;
      line env "%s" (unop_name op)
  | Cmp (op, l, r) ->
      expr env l;
      expr env r;
      line env "%s" (cmp_name op)
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
      nested env (fun () -> block env t);
      if e <> [] then (
        line env "else";
        nested env (fun () -> block env e));
      line env "end"
  | While (pre, c, body) ->
      line env "block";
      nested env (fun () ->
          line env "loop";
          nested env (fun () ->
              block env pre;
              expr env c;
              line env "i32.eqz";
              line env "br_if 1";
              block env body;
              line env "br 0");
          line env "end");
      line env "end"

let of_func (f : func) : string =
  let scratch =
    List.init (Emit.scratch_of_block f.body) (fun i -> Printf.sprintf "$t%d" i)
  in
  let names =
    Array.of_list
      (List.map (fun n -> "$" ^ n) (f.params @ List.map fst f.vars) @ scratch)
  in
  let env =
    {
      names;
      scratch_next = List.length f.params + List.length f.vars;
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
      let params =
        String.concat " "
          (List.map (fun p -> Printf.sprintf "(param $%s f64)" p) f.params)
      in
      line env "(func $main (export \"main\") %s(result f64)"
        (if params = "" then "" else params ^ " ");
      nested env (fun () ->
          List.iter (fun (v, t) -> line env "(local $%s %s)" v (kind t)) f.vars;
          List.iter (fun n -> line env "(local %s f64)" n) scratch;
          block env f.body;
          line env "f64.const 0.0");
      line env ")");
  line env ")";
  Buffer.contents env.b
