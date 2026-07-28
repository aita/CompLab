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

(* What an error message calls a type, for the person reading it. *)
let type_name = function
  | VInt -> "whole number"
  | VFloat -> "number"
  | VBool -> "true or false"

(* What the dump calls it, where one word has to do. *)
let type_tag = function VInt -> "int" | VFloat -> "float" | VBool -> "bool"

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
  (* The next event, from the host.  Waits for one: this is the only thing in
     the language that takes time rather than just arithmetic. *)
  | Wait
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
  | Num _ | Widen _ | Rand _ | Now | Wait -> VFloat
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
   before it turns into bytes.

   S-expressions, because the IR is a tree and the graph it came from is one
   too: an expression's shape is the nesting rather than a precedence table
   the reader has to know.  It is not wat -- that is [wat.ml], and it is a
   stack machine.  Here a call still has its arguments inside it. *)
let to_string f =
  let b = Buffer.create 256 in
  let pr fmt = Printf.ksprintf (Buffer.add_string b) fmt in
  let call head parts = "(" ^ String.concat " " (head :: parts) ^ ")" in
  let rec expr = function
    | Int n -> string_of_int n
    | Num x -> Printf.sprintf "%g" x
    | Local i -> local_name f i
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
    | Wait -> "(wait)"
    | Watch (i, _, e) -> call "watch" [ string_of_int i; expr e ]
  in
  (* Every form closes on the line its last child ends on, the way a Lisp is
     written: the shape is the indentation, not a column of brackets. *)
  let rec block ind stmts = List.iter (stmt ind) stmts
  and nested ind head parts =
    let pad = String.make (ind * 2) ' ' in
    pr "%s(%s\n" pad head;
    List.iter (fun part -> part (ind + 1)) parts;
    (* undo the newline the last child wrote, so the bracket lands on its line *)
    let n = Buffer.length b in
    if n > 0 && Buffer.nth b (n - 1) = '\n' then Buffer.truncate b (n - 1);
    pr ")\n"
  and stmt ind s =
    let pad = String.make (ind * 2) ' ' in
    match s with
    | Assign (i, e) -> pr "%s(set %s %s)\n" pad (local_name f i) (expr e)
    | Drop e -> pr "%s(drop %s)\n" pad (expr e)
    | Log e -> pr "%s(log %s)\n" pad (expr e)
    | Ret e -> pr "%s(return %s)\n" pad (expr e)
    | Br l -> pr "%s(br $%d)\n" pad l
    | Block (l, body) ->
        nested ind (Printf.sprintf "block $%d" l) [ (fun i -> block i body) ]
    | Loop (l, body) ->
        nested ind (Printf.sprintf "loop $%d" l) [ (fun i -> block i body) ]
    | If (c, t, []) ->
        nested ind (Printf.sprintf "if %s" (expr c)) [ (fun i -> block i t) ]
    | If (c, t, e) ->
        nested ind
          (Printf.sprintf "if %s" (expr c))
          [
            (fun i -> nested i "then" [ (fun j -> block j t) ]);
            (fun i -> nested i "else" [ (fun j -> block j e) ]);
          ]
  in
  nested 0 "func main (result f64)"
    [
      (fun ind ->
        List.iter
          (fun (v, t) ->
            pr "%s(local %s %s)\n"
              (String.make (ind * 2) ' ')
              v (type_tag t))
          f.vars);
      (fun ind -> block ind f.body);
    ];
  Buffer.contents b
