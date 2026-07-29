(* The same instruction stream as Emit, written out as text.  It is what the
   editor shows in its Code tab: one line per instruction, in the order the
   bytes are written, so the text and the binary can be read against each
   other. *)

open Ir

type env = {
  names : string array;  (* local index -> $name *)
  strings : (int * int) array;  (* literal -> where it sits in memory *)
  globals : string array;  (* global index -> $name *)
  ty : expr -> vtype;
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

let global env i =
  if i < Array.length env.globals then env.globals.(i)
  else Printf.sprintf "$g%d" i

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
  | Global i -> line env "global.get %s" (global env i)
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
  | Store (i, e) ->
      expr env e;
      line env "global.set %s" (global env i)
  | Drop e ->
      expr env e;
      line env "drop"
  | Log e ->
      expr env e;
      line env "call $log"
  | Say i ->
      let off, len = env.strings.(i) in
      line env "i32.const %d" off;
      line env "i32.const %d" len;
      line env "call $say"
  | Ret e ->
      expr env e;
      line env "return"
(* wat wants the bytes as an escaped string, and a graph's text can hold
   anything the editor let someone type. *)
let quoted s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      if c = '"' || c = '\\' then Printf.bprintf b "\\%c" c
      else if c >= ' ' && c < '\127' then Buffer.add_char b c
      else Printf.bprintf b "\\%02x" (Char.code c))
    s;
  Buffer.contents b

let of_module (m : modul) : string =
  let globals = Array.of_list (List.map (fun (v, _, _) -> "$" ^ v) m.globals) in
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
  let global_types i = let _, t, _ = List.nth m.globals i in t in
  let b = Buffer.create 512 in
  let top =
    {
      names = [||];
      strings = layout;
      globals;
      ty = (fun _ -> VFloat);
      scratch_next = 0;
      b;
      indent = 0;
    }
  in
  line top "(module";
  nested top (fun () ->
      line top "(import \"env\" \"log\" (func $log (param f64)))";
      line top "(import \"env\" \"random\" (func $random (result f64)))";
      line top
        "(import \"env\" \"watch\" (func $watch (param i32) (param f64) (result f64)))";
      line top "(import \"env\" \"now\" (func $now (result f64)))";
      line top "(import \"env\" \"say\" (func $say (param i32) (param i32)))";
      if m.strings <> [] then (
        line top "(memory (export \"memory\") 1)";
        line top "(data (i32.const 0) \"%s\")"
          (quoted (String.concat "" m.strings)));
      List.iter
        (fun (v, t, init) ->
          line top "(global $%s (export \"%s\") (mut %s) (%s.const %s))" v
            (Ir.global_export v) (kind t) (kind t)
            (if kind t = "f64" then num_literal init
             else string_of_int (int_of_float init)))
        m.globals;
      List.iter
        (fun (f : func) ->
          let locals i = snd (List.nth f.vars i) in
          let ty = Ir.type_of ~locals ~globals:global_types in
          let scratch =
            List.mapi
              (fun i t -> (Printf.sprintf "$t%d" i, t))
              (Emit.scratch_of_block ty f.body)
          in
          let names =
            Array.of_list
              (List.map (fun (n, _) -> "$" ^ n) f.vars
              @ List.map fst scratch)
          in
          let env =
            {
              names;
              strings = layout;
              globals;
              ty;
              scratch_next = List.length f.vars;
                      b;
              indent = top.indent;
            }
          in
          line env "(func $%s (export \"%s\") (result f64)" f.name f.name;
          nested env (fun () ->
              List.iter (fun (v, t) -> line env "(local $%s %s)" v (kind t)) f.vars;
              List.iter (fun (n, t) -> line env "(local %s %s)" n (kind t)) scratch;
              block env f.body;
              line env "f64.const 0.0");
          line env ")")
        m.funcs);
  line top ")";
  Buffer.contents b
