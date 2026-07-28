(* The intermediate form the graph is lowered to: a single function with
   f64 parameters, f64 locals and structured control flow.  Everything that
   follows this module works on trees, never on the graph. *)

(* A number is an i64 where the graph can show it never needs to be anything
   else, and an f64 otherwise; a condition is an i32 used as a boolean.  Every
   local and every expression carries which of the three it is. *)
type vtype = VInt | VFloat | VBool

let is_num = function VBool -> false | _ -> true

(* The numeric types meet at f64: an integer widens, a float never narrows. *)
let join a b = if a = b then a else VFloat

let type_name = function
  | VInt -> "whole number"
  | VFloat -> "number"
  | VBool -> "true or false"


type binop = Add | Sub | Mul | Div | Mod | Min | Max
type unop = Neg | Abs | Sqrt | Floor | Ceil | Round
type cmpop = Lt | Le | Gt | Ge | Eq | Ne

type expr =
  | Int of int  (* an i64 literal *)
  | Num of float  (* an f64 literal *)
  | Local of int
  | Widen of expr  (* i64 -> f64 *)
  | Bin of binop * expr * expr
  | Un of unop * expr
  | Cmp of cmpop * expr * expr
  | And of expr * expr
  | Or of expr * expr
  | Not of expr
  (* Both arms are evaluated.  Nothing in an expression can trap, so the only
     thing that makes visible is [Rand], which draws once per arm. *)
  | Select of expr * expr * expr
  (* A number in [min, max), from the host. *)
  | Rand of expr * expr
  (* When the run started, from the host.  Asked for once, at the entry. *)
  | Now
  (* Hand the value to the host and carry on with it: a breakpoint.  The index
     is into the function's list of watch points. *)
  | Watch of int * vtype * expr

(* A place a branch can land.  Blocks and loops carry one so that the emitter
   can work out how many levels a [Br] has to climb, which is the one number
   that is easy to get wrong by hand -- an [if] is a level too. *)
type label = int

type stmt =
  | Assign of int * expr
  (* Evaluate and throw away, which only a watch is ever worth doing it to. *)
  | Drop of expr
  | If of expr * block * block
  | Block of label * block  (* branching to it leaves the block *)
  | Loop of label * block  (* branching to it goes round again *)
  | Br of label
  | Log of expr
  | Ret of expr

and block = stmt list

type func = {
  (* A graph takes nothing: the only thing the host hands it is the time, and
     it asks for that itself. *)
  vars : (string * vtype) list;  (* the locals, zero initialised *)
  body : block;
}

(* Both sides of an operator always agree by the time the lowering is done, so
   a type can be read straight back off the tree. *)
let rec type_of locals = function
  | Int _ -> VInt
  | Num _ | Widen _ | Rand _ | Now -> VFloat
  | Local i -> locals i
  | Bin ((Div | Min | Max), _, _) -> VFloat
  | Bin (_, a, _) -> type_of locals a
  | Un ((Sqrt | Floor | Ceil | Round), _) -> VFloat
  | Un (_, e) -> type_of locals e
  | Cmp _ | And _ | Or _ | Not _ -> VBool
  | Select (_, a, _) -> type_of locals a
  | Watch (_, t, _) -> t

let local_name f i = fst (List.nth f.vars i)

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
    | Int n -> string_of_int n
    | Num x -> Printf.sprintf "%g" x
    | Widen e -> Printf.sprintf "float(%s)" (expr e)
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
    | Select (c, a, b) ->
        Printf.sprintf "(if %s then %s else %s)" (expr c) (expr a) (expr b)
    | Rand (lo, hi) -> Printf.sprintf "random(%s, %s)" (expr lo) (expr hi)
    | Now -> "now()"
    | Watch (i, _, e) -> Printf.sprintf "watch#%d(%s)" i (expr e)
  in
  let rec block ind stmts = List.iter (stmt ind) stmts
  and stmt ind s =
    let pad = String.make (ind * 2) ' ' in
    match s with
    | Assign (i, e) -> pr "%s%s = %s\n" pad (local_name f i) (expr e)
    | Drop e -> pr "%s%s\n" pad (expr e)
    | Log e -> pr "%slog %s\n" pad (expr e)
    | Ret e -> pr "%sreturn %s\n" pad (expr e)
    | Block (l, body) ->
        pr "%sblock $%d {\n" pad l;
        block (ind + 1) body;
        pr "%s}\n" pad
    | Loop (l, body) ->
        pr "%sloop $%d {\n" pad l;
        block (ind + 1) body;
        pr "%s}\n" pad
    | Br l -> pr "%sbr $%d\n" pad l
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
  pr "fun main() -> f64 {\n";
  List.iter
    (fun (v, t) ->
      pr "  var %s : %s = %s\n" v
        (match t with VInt -> "int" | VFloat -> "float" | VBool -> "bool")
        (match t with VBool -> "false" | _ -> "0"))
    f.vars;
  block 1 f.body;
  pr "}\n";
  Buffer.contents b
