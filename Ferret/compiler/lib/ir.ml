(* The intermediate form the graph is lowered to.

   A graph is a dataflow network and a run is one cook of it: work out what
   every sink wants, then let the feedback nodes take up their new values.
   There is no control flow in here at all -- no branches, no loops, no
   labels -- because there is none in the graph either.  What is left is a
   list of assignments in the order the values depend on each other. *)

(* A number is an i64 where the graph can show it never needs to be anything
   else, and an f64 otherwise; a condition is an i32 used as a boolean.  Every
   local and every expression carries which of the three it is. *)
type vtype = VInt | VFloat | VBool

let is_num = function VBool -> false | _ -> true

(* The numeric types meet at f64: an integer widens, a float never narrows. *)
let join a b = if a = b then a else VFloat

(* What an error message calls a type, for the person reading it. *)
let type_name = function
  | VInt -> "whole number"
  | VFloat -> "number"
  | VBool -> "true or false"

(* A global is exported under this name, so the host can read what a graph
   holds and write what it asks for.  One place, because the emitter, the text
   and the lowering all have to agree on it. *)
let global_export name = "state_" ^ name

(* What the dump calls it, where one word has to do. *)
let type_tag = function VInt -> "int" | VFloat -> "float" | VBool -> "bool"

type binop = Add | Sub | Mul | Div | Mod | Min | Max
type unop = Neg | Abs | Sqrt | Floor | Ceil | Round
type cmpop = Lt | Le | Gt | Ge | Eq | Ne

type expr =
  | Int of int  (* an i64 literal *)
  | Num of float  (* an f64 literal *)
  | Local of int  (* one call's own *)
  | Global of int  (* the graph's, and it outlives the call *)
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
  (* What the host says the time is.  Asked for once a cook. *)
  | Now
  (* Hand the value to the host and carry on with it: a breakpoint.  The index
     is into the function's list of watch points. *)
  | Watch of int * vtype * expr

type stmt =
  | Assign of int * expr  (* into a local *)
  | Store of int * expr  (* into a global: a feedback taking its new value *)
  (* Evaluate and throw away, which only a watch is ever worth doing it to. *)
  | Drop of expr
  | Log of expr
  (* Hand a piece of the module's text to the host: the index is into the
     module's list of literals.  Text is only ever a literal here -- there is
     no memory to build one in. *)
  | Say of int
  | Ret of expr

type block = stmt list

(* One cook of the graph, which is the whole of a run. *)
type func = {
  name : string;  (* what it is exported as *)
  vars : (string * vtype) list;  (* the locals, zero initialised *)
  body : block;
}

(* A graph is a module: one function, and the state it keeps between calls.  A
   global outlives a call, which is what lets one cook read what the last one
   left behind. *)
type modul = {
  (* name, type, and what it starts at: an Input carries its default here, so
     a host that sets nothing still gets the number the graph was drawn with *)
  globals : (string * vtype * float) list;
  (* Every piece of text the graph says, in the order the module lays them out
     in its memory. *)
  strings : string list;
  funcs : func list;
}

(* Both sides of an operator always agree by the time the lowering is done, so
   a type can be read straight back off the tree. *)
let type_of ~locals ~globals =
  let rec go = function
    | Int _ -> VInt
    | Num _ | Widen _ | Rand _ | Now -> VFloat
    | Local i -> locals i
    | Global i -> globals i
    | Bin ((Div | Min | Max), _, _) -> VFloat
    | Bin (_, a, _) -> go a
    | Un ((Sqrt | Floor | Ceil | Round), _) -> VFloat
    | Un (_, e) -> go e
    | Cmp _ | And _ | Or _ | Not _ -> VBool
    | Select (_, a, _) -> go a
    | Watch (_, t, _) -> t
  in
  go

let local_name (f : func) i = fst (List.nth f.vars i)

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
   before it turns into bytes.

   S-expressions, because the IR is a tree and the graph it came from is one
   too: an expression's shape is the nesting rather than a precedence table
   the reader has to know.  It is not wat -- that is [wat.ml], and it is a
   stack machine.  Here a call still has its arguments inside it. *)
let to_string (m : modul) =
  let b = Buffer.create 256 in
  let pr fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  let call head parts = "(" ^ String.concat " " (head :: parts) ^ ")" in
  let global_name i = let n, _, _ = List.nth m.globals i in n in
  let expr_of (f : func) =
    let rec expr = function
      | Int n -> string_of_int n
      | Num x -> Printf.sprintf "%g" x
      | Local i -> local_name f i
      | Global i -> global_name i
      | Widen e -> call "float" [ expr e ]
      | Bin (op, l, r) -> call (string_of_binop op) [ expr l; expr r ]
      | Un (op, e) -> call (string_of_unop op) [ expr e ]
      | Cmp (op, l, r) -> call (string_of_cmpop op) [ expr l; expr r ]
      | And (l, r) -> call "and" [ expr l; expr r ]
      | Or (l, r) -> call "or" [ expr l; expr r ]
      | Not e -> call "not" [ expr e ]
      | Select (c, a, b) -> call "select" [ expr c; expr a; expr b ]
      | Rand (lo, hi) -> call "random" [ expr lo; expr hi ]
      | Now -> "(now)"
      | Watch (i, _, e) -> call "watch" [ string_of_int i; expr e ]
    in
    expr
  in
  let func (f : func) =
    let expr = expr_of f in
    let stmt = function
      | Assign (i, e) -> Printf.sprintf "  (set %s %s)" (local_name f i) (expr e)
      | Store (i, e) -> Printf.sprintf "  (set %s %s)" (global_name i) (expr e)
      | Drop e -> Printf.sprintf "  (drop %s)" (expr e)
      | Log e -> Printf.sprintf "  (log %s)" (expr e)
      | Say i -> Printf.sprintf "  (say %S)" (List.nth m.strings i)
      | Ret e -> Printf.sprintf "  (return %s)" (expr e)
    in
    pr "(func %s (result f64)\n" f.name;
    List.iter (fun (v, t) -> pr "  (local %s %s)\n" v (type_tag t)) f.vars;
    let lines = List.map stmt f.body in
    pr "%s)\n" (String.concat "\n" lines)
  in
  List.iter
    (fun (v, t, init) ->
      if init = 0. then pr "(global %s %s)\n" v (type_tag t)
      else pr "(global %s %s %g)\n" v (type_tag t) init)
    m.globals;
  List.iter func m.funcs;
  Buffer.contents b