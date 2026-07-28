(* The intermediate form the graph is lowered to: a single function with
   f64 parameters, f64 locals and structured control flow.  Everything that
   follows this module works on trees, never on the graph. *)

type binop = Add | Sub | Mul | Div | Mod | Min | Max
type unop = Neg | Abs | Sqrt | Floor | Ceil | Round
type cmpop = Lt | Le | Gt | Ge | Eq | Ne

(* [Num] and everything built from it has type f64; comparisons and the
   logical operators have type i32, used as a boolean. *)
type expr =
  | Num of float
  | Local of int
  | Bin of binop * expr * expr
  | Un of unop * expr
  | Cmp of cmpop * expr * expr
  | And of expr * expr
  | Or of expr * expr
  | Not of expr

type stmt =
  | Assign of int * expr
  | If of expr * block * block
  | While of expr * block
  | Log of expr
  | Ret of expr

and block = stmt list

type func = {
  params : string list;  (* locals 0 .. n-1 *)
  vars : string list;  (* locals n .. n+m-1, zero initialised *)
  body : block;
}

let local_name f i =
  let np = List.length f.params in
  if i < np then List.nth f.params i else List.nth f.vars (i - np)

let string_of_binop = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "%"
  | Min -> "min"
  | Max -> "max"

let string_of_unop = function
  | Neg -> "neg"
  | Abs -> "abs"
  | Sqrt -> "sqrt"
  | Floor -> "floor"
  | Ceil -> "ceil"
  | Round -> "round"

let string_of_cmpop = function
  | Lt -> "<"
  | Le -> "<="
  | Gt -> ">"
  | Ge -> ">="
  | Eq -> "=="
  | Ne -> "!="

(* A readable dump, so the editor can show what the graph actually meant
   before it turns into bytes. *)
let to_string f =
  let b = Buffer.create 256 in
  let pr fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  let rec expr = function
    | Num x -> Printf.sprintf "%g" x
    | Local i -> local_name f i
    | Bin ((Min | Max) as op, l, r) ->
        Printf.sprintf "%s(%s, %s)" (string_of_binop op) (expr l) (expr r)
    | Bin (op, l, r) ->
        Printf.sprintf "(%s %s %s)" (expr l) (string_of_binop op) (expr r)
    | Un (op, e) -> Printf.sprintf "%s(%s)" (string_of_unop op) (expr e)
    | Cmp (op, l, r) ->
        Printf.sprintf "(%s %s %s)" (expr l) (string_of_cmpop op) (expr r)
    | And (l, r) -> Printf.sprintf "(%s and %s)" (expr l) (expr r)
    | Or (l, r) -> Printf.sprintf "(%s or %s)" (expr l) (expr r)
    | Not e -> Printf.sprintf "not %s" (expr e)
  in
  let rec block ind stmts = List.iter (stmt ind) stmts
  and stmt ind s =
    let pad = String.make (ind * 2) ' ' in
    match s with
    | Assign (i, e) -> pr "%s%s = %s\n" pad (local_name f i) (expr e)
    | Log e -> pr "%slog %s\n" pad (expr e)
    | Ret e -> pr "%sreturn %s\n" pad (expr e)
    | While (c, body) ->
        pr "%swhile %s {\n" pad (expr c);
        block (ind + 1) body;
        pr "%s}\n" pad
    | If (c, t, []) ->
        pr "%sif %s {\n" pad (expr c);
        block (ind + 1) t;
        pr "%s}\n" pad
    | If (c, t, e) ->
        pr "%sif %s {\n" pad (expr c);
        block (ind + 1) t;
        pr "%s} else {\n" pad;
        block (ind + 1) e;
        pr "%s}\n" pad
  in
  pr "fun main(%s) -> f64 {\n" (String.concat ", " f.params);
  List.iter (fun v -> pr "  var %s = 0\n" v) f.vars;
  block 1 f.body;
  pr "}\n";
  Buffer.contents b
