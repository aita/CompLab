(* The intermediate stages, as text.

   Every stage of the pipeline can be printed, and the book's dumps and the
   golden tests both come from here.  The two trees print in the same shape, so
   that a core dump and a resolved dump of the same program can be read side by
   side and the one difference — names have become slot numbers — is the only
   difference you see. *)

let indent n = String.make (2 * n) ' '

(* ------------------------------------------------------------- tokens *)

let tokens source =
  let buf = Buffer.create 1024 in
  Array.iter
    (fun (t : Lexer.token) ->
      Buffer.add_string buf
        (Printf.sprintf "%4d:%-3d %s\n" t.Lexer.pos.Diag.line t.Lexer.pos.Diag.col
           (Lexer.describe t.Lexer.kind)))
    (Lexer.tokens source);
  Buffer.contents buf

(* --------------------------------------------------------------- core *)

let rec core level (e : Core.expr) =
  let pad = indent level in
  match e with
  | Core.Int n -> Int64.to_string n
  | Core.Bool b -> string_of_bool b
  | Core.Unit -> "()"
  | Core.Var n -> Core.show_name n
  | Core.Tuple es -> "(" ^ String.concat ", " (List.map (core level) es) ^ ")"
  | Core.Proj (i, e) -> Printf.sprintf "#%d %s" i (operand level e)
  | Core.Prim (op, args) ->
      Printf.sprintf "(%s %s)" (Core.prim_name op)
        (String.concat " " (List.map (operand level) args))
  | Core.If (c, t, f) ->
      Printf.sprintf "if %s\n%sthen %s\n%selse %s" (core level c) pad
        (core (level + 1) t) pad (core (level + 1) f)
  | Core.Fn l -> core_lambda level l
  | Core.App (f, args) ->
      Printf.sprintf "%s (%s)" (core level f)
        (String.concat ", " (List.map (core level) args))
  (* A chain of bindings prints as a block, not as a staircase. *)
  | Core.Let _ | Core.Untuple _ | Core.Letrec _ ->
      let buf = Buffer.create 128 in
      let rec block e =
        match e with
        | Core.Let (binder, rhs, body) ->
            let name =
              match binder with Some n -> Core.show_name n | None -> "_"
            in
            Buffer.add_string buf
              (Printf.sprintf "let %s = %s\n%s" name (core (level + 1) rhs) pad);
            block body
        | Core.Untuple (rhs, binders, body) ->
            let names =
              List.map
                (function Some n -> Core.show_name n | None -> "_")
                binders
            in
            Buffer.add_string buf
              (Printf.sprintf "let (%s) = %s\n%s" (String.concat ", " names)
                 (core (level + 1) rhs) pad);
            block body
        | Core.Letrec (group, body) ->
            List.iteri
              (fun i ((n : Core.name), l) ->
                Buffer.add_string buf
                  (Printf.sprintf "%s %s = %s\n%s"
                     (if i = 0 then "letrec" else "and")
                     (Core.show_name n)
                     (core_lambda (level + 1) l)
                     pad))
              group;
            block body
        | body -> Buffer.add_string buf ("in " ^ core level body)
      in
      block e;
      Buffer.contents buf

(* An application is written `f (x)`, which needs brackets of its own when it
   stands as the operand of something else. *)
and operand level (e : Core.expr) =
  match e with Core.App _ -> "(" ^ core level e ^ ")" | _ -> core level e

and core_lambda level (l : Core.lambda) =
  Printf.sprintf "fn (%s) =>\n%s%s"
    (String.concat ", " (List.map Core.show_name l.Core.params))
    (indent (level + 1))
    (core (level + 1) l.Core.body)

let core_program e = core 0 e ^ "\n"

(* ----------------------------------------------------------- resolved *)

(* Slots print as `l0`, captures as `c0` and capture-free functions as `g0`, so
   that a nest of them stays readable as an operand. *)
let source = function
  | Machine.FromLocal i -> Printf.sprintf "l%d" i
  | Machine.FromCapture i -> Printf.sprintf "c%d" i

let sources ss =
  "[" ^ String.concat ", " (Array.to_list (Array.map source ss)) ^ "]"

let rec resolved level (e : Resolve.expr) =
  let pad = indent level in
  match e with
  | Resolve.Int n -> Int64.to_string n
  | Resolve.Bool b -> string_of_bool b
  | Resolve.Unit -> "()"
  | Resolve.Local i -> Printf.sprintf "l%d" i
  | Resolve.Capture i -> Printf.sprintf "c%d" i
  | Resolve.Global id -> Printf.sprintf "g%d" id
  | Resolve.Tuple es -> "(" ^ String.concat ", " (List.map (resolved level) es) ^ ")"
  | Resolve.Proj (i, e) -> Printf.sprintf "#%d %s" i (roperand level e)
  | Resolve.Prim (op, args) ->
      Printf.sprintf "(%s %s)" (Core.prim_name op)
        (String.concat " " (List.map (roperand level) args))
  | Resolve.If (c, t, f) ->
      Printf.sprintf "if %s\n%sthen %s\n%selse %s" (resolved level c) pad
        (resolved (level + 1) t) pad (resolved (level + 1) f)
  | Resolve.Closure (id, ss) -> Printf.sprintf "closure %d %s" id (sources ss)
  | Resolve.App (f, args) ->
      Printf.sprintf "%s (%s)" (resolved level f)
        (String.concat ", " (List.map (resolved level) args))
  | Resolve.AppGlobal (id, args) ->
      Printf.sprintf "g%d (%s)" id
        (String.concat ", " (List.map (resolved level) args))
  | Resolve.Let _ | Resolve.Untuple _ ->
      let buf = Buffer.create 128 in
      let rec block e =
        match e with
        | Resolve.Let (slot, rhs, body) ->
            let name =
              match slot with Some s -> Printf.sprintf "l%d" s | None -> "_"
            in
            Buffer.add_string buf
              (Printf.sprintf "let %s = %s\n%s" name (resolved (level + 1) rhs) pad);
            block body
        | Resolve.Untuple (rhs, slots, body) ->
            let names =
              List.map
                (function Some s -> Printf.sprintf "l%d" s | None -> "_")
                slots
            in
            Buffer.add_string buf
              (Printf.sprintf "let (%s) = %s\n%s" (String.concat ", " names)
                 (resolved (level + 1) rhs) pad);
            block body
        | body -> Buffer.add_string buf ("in " ^ resolved level body)
      in
      block e;
      Buffer.contents buf

and roperand level (e : Resolve.expr) =
  match e with
  | Resolve.App _ | Resolve.AppGlobal _ -> "(" ^ resolved level e ^ ")"
  | _ -> resolved level e

let resolved_program (p : Resolve.program) =
  let buf = Buffer.create 1024 in
  Buffer.add_string buf (Printf.sprintf "entry %d\n" p.Resolve.entry);
  Array.iteri
    (fun id (f : Resolve.func) ->
      Buffer.add_string buf
        (Printf.sprintf "\nfunction %d %s: arity %d, locals %d, captures %d\n  %s\n"
           id
           (match f.Resolve.name with Some n -> n | None -> "anonymous")
           f.Resolve.arity f.Resolve.local_count f.Resolve.capture_count
           (resolved 1 f.Resolve.body)))
    p.Resolve.functions;
  Buffer.contents buf
