(* The intermediate language every system runs on: A-normal form.

   Three invariants hold everywhere in this tree, and the machine in
   machine.ml is written to depend on all three:

     1. Every operand is an atom -- a variable or a literal.  Nothing has to
        be evaluated to find the argument of a call or a primitive, so one
        step of the machine never recurses into a subterm.
     2. A block is a straight run of bindings ending in a tail form.  A `let`
        never binds another block, so tail position is a syntactic property:
        [TCall] is a tail call and reuses the caller's frame, [Call] is not
        and pushes one.
     3. Application is unary.  Currying is done by the normaliser, so the
        machine needs no partial applications and no arity check.

   Types are gone by this point, and that is the point: the five type systems
   disagree about which programs are well typed and agree completely about how
   a well-typed program runs, so they share this language and its machine. *)

type label = string

type atom = AVar of string | AInt of int | ABool of bool | AUnit

(* The right-hand side of a binding: exactly one step of work. *)
type rhs =
  | Atom of atom
  | Lam of string * block
  | Prim of string * atom list
  | Call of atom * atom (* not in tail position: pushes a frame *)
  | MkPair of atom * atom
  | MkRecord of (label * atom) list * atom option (* { l = a, ..r } *)
  | Proj of atom * label
  | Restrict of atom * label
  | Inject of label * atom
  (* The session primitives.  They are [rhs] of their own rather than calls to
     library functions because the machine has to be able to suspend a process
     in the middle of one. *)
  | Fork of atom (* fork f: run f on one endpoint, return the other *)
  | Send of atom * atom (* send v c: returns the continued channel *)
  | Recv of atom (* recv c: returns (value, continued channel) *)
  | Close of atom
  | Select of label * atom

and block =
  | Let of string * rhs * block
  | LetRec of string * string * block * block (* let rec f = fun x -> _ in _ *)
  | Tail of tail

and tail =
  | Ret of atom
  | TCall of atom * atom
  | If of atom * block * block
  | Case of atom * arm list * (string * block) option
  | Branch of atom * (label * string * block) list

and arm = { alabel : label; abinder : string; abody : block }

(* Names introduced by normalisation.  The dot keeps them out of the source
   language's namespace, so a generated name cannot capture a written one. *)
let counter = ref 0

let fresh base =
  incr counter;
  Printf.sprintf "%s.%d" base !counter

(* Printing, for `--dump-anf`.  The output is meant to be read beside the
   source, so it keeps the source's names. *)

let atom_str = function
  | AVar x -> x
  | AInt n -> string_of_int n
  | ABool b -> if b then "true" else "false"
  | AUnit -> "()"

let add = Buffer.add_string

let rec print_block b ind out =
  let pad = String.make ind ' ' in
  match b with
  | Let (x, r, rest) ->
      add out (Printf.sprintf "%slet %s = " pad x);
      print_rhs r ind out;
      add out "\n";
      print_block rest ind out
  | LetRec (f, x, body, rest) ->
      add out (Printf.sprintf "%slet rec %s = fun %s ->\n" pad f x);
      print_block body (ind + 2) out;
      print_block rest ind out
  | Tail t -> print_tail t ind out

and print_rhs r ind out =
  match r with
  | Atom a -> add out (atom_str a)
  | Lam (p, body) ->
      add out (Printf.sprintf "fun %s ->\n" p);
      print_block body (ind + 2) out
  | Prim (op, ats) ->
      add out (Printf.sprintf "%s(%s)" op (String.concat ", " (List.map atom_str ats)))
  | Call (f, a) -> add out (Printf.sprintf "%s %s" (atom_str f) (atom_str a))
  | MkPair (a, b) -> add out (Printf.sprintf "(%s, %s)" (atom_str a) (atom_str b))
  | MkRecord (fs, tail) ->
      let fields = List.map (fun (l, a) -> Printf.sprintf "%s = %s" l (atom_str a)) fs in
      let tl = match tail with None -> [] | Some a -> [ ".." ^ atom_str a ] in
      add out (Printf.sprintf "{ %s }" (String.concat ", " (fields @ tl)))
  | Proj (a, l) -> add out (Printf.sprintf "%s.%s" (atom_str a) l)
  | Restrict (a, l) -> add out (Printf.sprintf "%s \\ %s" (atom_str a) l)
  | Inject (l, a) -> add out (Printf.sprintf "`%s %s" l (atom_str a))
  | Fork a -> add out (Printf.sprintf "fork %s" (atom_str a))
  | Send (v, c) -> add out (Printf.sprintf "send %s %s" (atom_str v) (atom_str c))
  | Recv c -> add out (Printf.sprintf "recv %s" (atom_str c))
  | Close c -> add out (Printf.sprintf "close %s" (atom_str c))
  | Select (l, c) -> add out (Printf.sprintf "select `%s %s" l (atom_str c))

and print_tail t ind out =
  let pad = String.make ind ' ' in
  match t with
  | Ret a -> add out (Printf.sprintf "%sret %s\n" pad (atom_str a))
  | TCall (f, a) ->
      add out (Printf.sprintf "%stailcall %s %s\n" pad (atom_str f) (atom_str a))
  | If (c, a, b) ->
      add out (Printf.sprintf "%sif %s then\n" pad (atom_str c));
      print_block a (ind + 2) out;
      add out (Printf.sprintf "%selse\n" pad);
      print_block b (ind + 2) out
  | Case (a, arms, dflt) ->
      add out (Printf.sprintf "%scase %s of\n" pad (atom_str a));
      List.iter
        (fun { alabel; abinder; abody } ->
          add out (Printf.sprintf "%s| `%s %s ->\n" pad alabel abinder);
          print_block abody (ind + 4) out)
        arms;
      (match dflt with
      | None -> ()
      | Some (x, body) ->
          add out (Printf.sprintf "%s| %s ->\n" pad x);
          print_block body (ind + 4) out)
  | Branch (c, arms) ->
      add out (Printf.sprintf "%sbranch %s of\n" pad (atom_str c));
      List.iter
        (fun (l, x, body) ->
          add out (Printf.sprintf "%s| `%s %s ->\n" pad l x);
          print_block body (ind + 4) out)
        arms

(* The first instruction of a block, for `--trace`: one line per step. *)
let head_to_string b =
  let out = Buffer.create 64 in
  (match b with
  | Let (x, r, _) ->
      add out (Printf.sprintf "let %s = " x);
      print_rhs r 0 out
  | LetRec (f, x, _, _) -> add out (Printf.sprintf "let rec %s = fun %s -> ..." f x)
  | Tail (Ret a) -> add out (Printf.sprintf "ret %s" (atom_str a))
  | Tail (TCall (f, a)) ->
      add out (Printf.sprintf "tailcall %s %s" (atom_str f) (atom_str a))
  | Tail (If (c, _, _)) -> add out (Printf.sprintf "if %s" (atom_str c))
  | Tail (Case (a, _, _)) -> add out (Printf.sprintf "case %s" (atom_str a))
  | Tail (Branch (c, _)) -> add out (Printf.sprintf "branch %s" (atom_str c)));
  (* A lambda's body would run to several lines; the head is one line by
     construction otherwise. *)
  match String.index_opt (Buffer.contents out) '\n' with
  | Some i -> String.sub (Buffer.contents out) 0 i ^ " ..."
  | None -> Buffer.contents out

let block_to_string b =
  let out = Buffer.create 256 in
  print_block b 0 out;
  Buffer.contents out
