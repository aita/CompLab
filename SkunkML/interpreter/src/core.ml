(* Typed Core: A-normal form with the patterns still in it.

   Three invariants hold everywhere in this tree:

     1. Every operand is an *atom* -- a variable or a literal.  Nothing has to
        be evaluated to find the argument of a call, so one step of the machine
        never recurses into a subterm.
     2. A block is a straight run of bindings ending in a tail form.  A `let`
        never binds another block, so tail position is syntactic.
     3. Application is unary.  Currying happens during elaboration.

   Two things are *not* gone yet, and each is a pass of its own:

     * [Case] still carries source patterns, nested and possibly overlapping.
       Compiling them needs to know, for a column of constructor patterns,
       which constructors the datatype has -- and that is a question about
       types.  Which is why this IR keeps its types: `patmat.ml` reads them.
     * [Lam] is still a lambda with free variables.  `closure.ml` makes the
       capture explicit.

   Between the two, [Join] appears.  A join point is a label with parameters
   that is only ever jumped to, never stored, never returned: no closure, no
   frame.  Nothing in the elaborator makes one -- they arrive with pattern
   matching, because a decision tree reaches the same arm down several paths
   and the body has to be shared rather than copied. *)

type label = string

type atom = AVar of string | AInt of int | AStr of string | AUnit

(* Patterns, after elaboration has resolved which names are constructors and
   filled a record pattern out to every field of its type. *)
type pat =
  | PAny of string option (* `_`, or a variable *)
  | PInt of int
  | PStr of string
  | PCon of Types.constr * pat option
  (* Every field of the record type, sorted.  A tuple pattern is one of these
     with the labels 1, 2, ... n. *)
  | PRec of (label * pat) list
  | PAs of string * pat

(* What a decision tree tests. *)
type key = Ktag of Types.constr | Kint of int | Kstr of string

type rhs =
  | Atom of atom
  | Lam of string * Types.ty * block
  | Call of atom * atom (* not in tail position: pushes a frame *)
  | Prim of string * atom list
  | Record of (label * atom) list (* sorted; a tuple has the labels 1..n *)
  | Con of Types.constr * atom option
  | Field of atom * label
  | Payload of atom (* what a constructor was applied to *)

and block =
  | Let of string * Types.ty * rhs * block
  (* A group of bindings that can see each other.  SML/NJ calls this FIX and
     so does this: there is no `let rec` in the language, only `fun`, and a
     `fun` group that turns out not to recur is emitted as plain [Let]s -- so
     a `fix` in a dump means something really does refer to itself.  Every
     right-hand side here is a [Lam]; a function has one representation, not
     two. *)
  | Fix of (string * Types.ty * rhs) list * block
  | Join of label * (string * Types.ty) list * block * block
  | Tail of tail

and tail =
  | Ret of atom
  | TCall of atom * atom
  (* Before pattern-match compilation. *)
  | Case of atom * Types.ty * arm list * Loc.t
  (* After it. *)
  | Switch of atom * (key * block) list * block option
  | Jump of label * atom list
  (* The one thing a program can do that is not returning a value. *)
  | Fail of Loc.t * string

and arm = { apat : pat; abody : block }

(* Names.  A binder keeps the name it was written with when that name is still
   free, so a dump reads like the source; a shadowed one gets a number.  The
   result is that every binder in a program is unique, which is what lets a
   join point read the environment it lands in instead of capturing one. *)
let used : (string, int) Hashtbl.t = Hashtbl.create 128

let reset () = Hashtbl.reset used

let fresh_name base =
  match Hashtbl.find_opt used base with
  | None ->
      Hashtbl.replace used base 1;
      base
  | Some n ->
      Hashtbl.replace used base (n + 1);
      let name = Printf.sprintf "%s.%d" base (n + 1) in
      Hashtbl.replace used name 1;
      name

(* A whole program: bindings, run in order.  [ilabel] is what the driver prints
   before the `=`; a binding with none is one the program made up. *)
type item = {
  iname : string;
  ibody : block option;
  (* Delayed, because a binding's type is not finished until the whole
     program is: a monomorphic array can learn what it holds three
     declarations later. *)
  ilabel : string Lazy.t option;
  ishow : bool;
}

(* Free variables.  Closure conversion needs them to decide what to capture,
   and the elaborator needs them one question at a time: does this `fun` group
   actually refer to itself?  A join label is not a variable, so a [Jump]
   contributes only its arguments. *)
module Vars = Set.Make (String)

let atom_var = function AVar x -> Vars.singleton x | _ -> Vars.empty

let atoms_var ats =
  List.fold_left (fun s a -> Vars.union s (atom_var a)) Vars.empty ats

let rec free_vars (b : block) =
  match b with
  | Let (x, _, rhs, rest) -> Vars.union (free_rhs rhs) (Vars.remove x (free_vars rest))
  | Fix (defs, rest) ->
      let names = List.map (fun (x, _, _) -> x) defs in
      let inside =
        List.fold_left (fun s (_, _, r) -> Vars.union s (free_rhs r)) (free_vars rest) defs
      in
      List.fold_left (fun s n -> Vars.remove n s) inside names
  | Join (_, ps, body, rest) ->
      let bound = List.map fst ps in
      Vars.union
        (List.fold_left (fun s x -> Vars.remove x s) (free_vars body) bound)
        (free_vars rest)
  | Tail t -> free_tail t

and free_rhs = function
  | Atom a -> atom_var a
  | Lam (x, _, body) -> Vars.remove x (free_vars body)
  | Call (f, a) -> Vars.union (atom_var f) (atom_var a)
  | Prim (_, ats) -> atoms_var ats
  | Record fs -> atoms_var (List.map snd fs)
  | Con (_, None) -> Vars.empty
  | Con (_, Some a) | Field (a, _) | Payload a -> atom_var a

and free_tail = function
  | Ret a -> atom_var a
  | TCall (f, a) -> Vars.union (atom_var f) (atom_var a)
  | Jump (_, ats) -> atoms_var ats
  | Fail _ -> Vars.empty
  | Switch (a, bs, d) ->
      let s = List.fold_left (fun s (_, b) -> Vars.union s (free_vars b)) (atom_var a) bs in
      (match d with None -> s | Some b -> Vars.union s (free_vars b))
  | Case (a, _, arms, _) ->
      List.fold_left (fun s arm -> Vars.union s (free_vars arm.abody)) (atom_var a) arms

(* A `fun` group is only a [Fix] if one of its names really occurs in one of
   its bodies.  `fun swap (a, b) = (b, a)` does not recur, and saying `fix`
   about it would be a lie the dump repeats on every line. *)
let recursive (defs : (string * Types.ty * rhs) list) =
  let names = List.map (fun (x, _, _) -> x) defs in
  List.exists
    (fun (_, _, r) ->
      let free = free_rhs r in
      List.exists (fun n -> Vars.mem n free) names)
    defs

(* Printing, for `--dump-core`. *)

let atom_str = function
  | AVar x -> x
  | AInt n -> if n < 0 then Printf.sprintf "~%d" (-n) else string_of_int n
  | AStr s -> Printf.sprintf "%S" s
  | AUnit -> "()"

let rec pat_str = function
  | PAny None -> "_"
  | PAny (Some x) -> x
  | PInt n -> string_of_int n
  | PStr s -> Printf.sprintf "%S" s
  | PCon (c, None) -> c.Types.cname
  | PCon (c, Some p) -> Printf.sprintf "%s %s" c.Types.cname (pat_str p)
  | PRec fs when Types.tuple_shaped fs ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map (fun (_, p) -> pat_str p) fs))
  | PRec [] -> "()"
  | PRec fs ->
      Printf.sprintf "{ %s }"
        (String.concat ", "
           (List.map (fun (l, p) -> Printf.sprintf "%s = %s" l (pat_str p)) fs))
  | PAs (x, p) -> Printf.sprintf "%s as %s" x (pat_str p)

let key_str = function
  | Ktag c -> c.Types.cname
  | Kint n -> string_of_int n
  | Kstr s -> Printf.sprintf "%S" s

let add = Buffer.add_string

let rec print_block b ind out =
  let pad = String.make ind ' ' in
  match b with
  | Let (x, t, r, rest) ->
      add out (Printf.sprintf "%slet %s : %s = " pad x (Types.show t));
      print_rhs r ind out;
      print_block rest ind out
  | Fix (defs, rest) ->
      List.iteri
        (fun i (x, t, r) ->
          add out
            (Printf.sprintf "%s%s %s : %s = " pad
               (if i = 0 then "fix" else "and")
               x (Types.show t));
          print_rhs r ind out)
        defs;
      print_block rest ind out
  | Join (j, ps, body, rest) ->
      add out
        (Printf.sprintf "%sjoin %s (%s) =\n" pad j
           (String.concat ", "
              (List.map (fun (x, t) -> Printf.sprintf "%s : %s" x (Types.show t)) ps)));
      print_block body (ind + 2) out;
      print_block rest ind out
  | Tail t -> print_tail t ind out

(* A right-hand side prints its own newline, because a lambda's is at the end
   of its body and everything else's is at the end of its line. *)
and print_rhs r ind out =
  match r with
  | Lam (x, t, body) ->
      add out (Printf.sprintf "fn %s : %s =>\n" x (Types.show t));
      print_block body (ind + 2) out
  | r ->
      print_flat r out;
      add out "\n"

and print_flat r out =
  match r with
  | Atom a -> add out (atom_str a)
  | Lam _ -> assert false
  | Call (f, a) -> add out (Printf.sprintf "%s %s" (atom_str f) (atom_str a))
  | Prim (op, ats) ->
      add out
        (Printf.sprintf "%s(%s)" op (String.concat ", " (List.map atom_str ats)))
  | Record fs when Types.tuple_shaped fs ->
      add out
        (Printf.sprintf "(%s)" (String.concat ", " (List.map (fun (_, a) -> atom_str a) fs)))
  | Record [] -> add out "()"
  | Record fs ->
      add out
        (Printf.sprintf "{ %s }"
           (String.concat ", "
              (List.map (fun (l, a) -> Printf.sprintf "%s = %s" l (atom_str a)) fs)))
  | Con (c, None) -> add out c.Types.cname
  | Con (c, Some a) -> add out (Printf.sprintf "%s %s" c.Types.cname (atom_str a))
  | Field (a, l) -> add out (Printf.sprintf "#%s %s" l (atom_str a))
  | Payload a -> add out (Printf.sprintf "payload %s" (atom_str a))

and print_tail t ind out =
  let pad = String.make ind ' ' in
  match t with
  | Ret a -> add out (Printf.sprintf "%sret %s\n" pad (atom_str a))
  | TCall (f, a) ->
      add out (Printf.sprintf "%stailcall %s %s\n" pad (atom_str f) (atom_str a))
  | Jump (j, ats) ->
      add out
        (Printf.sprintf "%sjump %s (%s)\n" pad j
           (String.concat ", " (List.map atom_str ats)))
  | Fail (_, m) -> add out (Printf.sprintf "%sfail %S\n" pad m)
  | Case (a, ty, arms, _) ->
      add out (Printf.sprintf "%scase %s : %s of\n" pad (atom_str a) (Types.show ty));
      List.iter
        (fun arm ->
          add out (Printf.sprintf "%s| %s =>\n" pad (pat_str arm.apat));
          print_block arm.abody (ind + 4) out)
        arms
  | Switch (a, arms, dflt) ->
      add out (Printf.sprintf "%sswitch %s of\n" pad (atom_str a));
      List.iter
        (fun (k, body) ->
          add out (Printf.sprintf "%s| %s =>\n" pad (key_str k));
          print_block body (ind + 4) out)
        arms;
      (match dflt with
      | None -> ()
      | Some body ->
          add out (Printf.sprintf "%s| _ =>\n" pad);
          print_block body (ind + 4) out)

let block_to_string b =
  let out = Buffer.create 256 in
  print_block b 0 out;
  Buffer.contents out
