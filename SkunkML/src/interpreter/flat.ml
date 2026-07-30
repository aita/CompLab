(* The last intermediate language: A-normal form with explicit join points and
   explicit closures.

   Everything that was implicit in Core is written down here.

     * A function is a [code] block at the top of the program, taking one
       argument and reading whatever else it needs out of its captures.  A
       [Closure] pairs a code label with the values it captured; [Capture i]
       reads one back.  Nothing is nested any more.
     * A join point is still a join point.  It is *not* a closure and that is
       the whole point of the distinction: it captures nothing, allocates
       nothing, and a [Jump] to it is a goto.  The two live side by side here
       so that the difference is visible -- one is in [codes] and the other is
       in the block that uses it.
     * Types are gone.  They chose the decision tree and matched the
       signatures, and there is nothing left for them to decide. *)

type label = string
type atom = AVar of string | AInt of int | AStr of string | AUnit

type rhs =
  | Atom of atom
  | Closure of string * atom list (* code label, captured values *)
  | Capture of int (* the i'th capture of the running code block *)
  | Call of atom * atom
  | Prim of string * atom list
  | Record of (string * atom) list (* a tuple has the labels 1..n *)
  | Con of Types.constr * atom option
  | Field of atom * string
  | Payload of atom

and block =
  | Let of string * rhs * block
  (* A group of closures that can see each other, so the captures are filled
     in after all of them exist.  Only a group that really recurs gets here;
     everything else is an ordinary [Let]. *)
  | Fix of (string * rhs) list * block
  | Join of label * string list * block * block
  | Tail of tail

and tail =
  | Ret of atom
  | TCall of atom * atom
  | Switch of atom * (Core.key * block) list * block option
  | Jump of label * atom list
  | Fail of Loc.t * string

type code = { c_label : string; c_param : string; c_body : block }

type item = {
  iname : string;
  ibody : block option;
  ilabel : string Lazy.t option;
  ishow : bool;
}

type program = { codes : code list; items : item list }

(* Printing, for `--dump-flat`. *)

let atom_str = function
  | AVar x -> x
  | AInt n -> if n < 0 then Printf.sprintf "~%d" (-n) else string_of_int n
  | AStr s -> Printf.sprintf "%S" s
  | AUnit -> "()"

let add = Buffer.add_string

let rec print_block b ind out =
  let pad = String.make ind ' ' in
  match b with
  | Let (x, r, rest) ->
      add out (Printf.sprintf "%slet %s = %s\n" pad x (rhs_str r));
      print_block rest ind out
  | Fix (defs, rest) ->
      List.iteri
        (fun i (x, r) ->
          add out
            (Printf.sprintf "%s%s %s = %s\n" pad (if i = 0 then "fix" else "and") x
               (rhs_str r)))
        defs;
      print_block rest ind out
  | Join (j, ps, body, rest) ->
      add out (Printf.sprintf "%sjoin %s (%s) =\n" pad j (String.concat ", " ps));
      print_block body (ind + 2) out;
      print_block rest ind out
  | Tail t -> print_tail t ind out

and rhs_str = function
  | Atom a -> atom_str a
  | Closure (c, caps) ->
      Printf.sprintf "closure %s [%s]" c (String.concat ", " (List.map atom_str caps))
  | Capture i -> Printf.sprintf "capture %d" i
  | Call (f, a) -> Printf.sprintf "%s %s" (atom_str f) (atom_str a)
  | Prim (op, ats) ->
      Printf.sprintf "%s(%s)" op (String.concat ", " (List.map atom_str ats))
  | Record fs when Types.tuple_shaped fs ->
      Printf.sprintf "(%s)" (String.concat ", " (List.map (fun (_, a) -> atom_str a) fs))
  | Record [] -> "()"
  | Record fs ->
      Printf.sprintf "{ %s }"
        (String.concat ", "
           (List.map (fun (l, a) -> Printf.sprintf "%s = %s" l (atom_str a)) fs))
  | Con (c, None) -> c.Types.cname
  | Con (c, Some a) -> Printf.sprintf "%s %s" c.Types.cname (atom_str a)
  | Field (a, l) -> Printf.sprintf "#%s %s" l (atom_str a)
  | Payload a -> Printf.sprintf "payload %s" (atom_str a)

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
  | Switch (a, bs, d) ->
      add out (Printf.sprintf "%sswitch %s of\n" pad (atom_str a));
      List.iter
        (fun (k, body) ->
          add out (Printf.sprintf "%s| %s =>\n" pad (Core.key_str k));
          print_block body (ind + 4) out)
        bs;
      (match d with
      | None -> ()
      | Some body ->
          add out (Printf.sprintf "%s| _ =>\n" pad);
          print_block body (ind + 4) out)

let program_to_string (p : program) =
  let out = Buffer.create 1024 in
  List.iter
    (fun c ->
      add out (Printf.sprintf "code %s (%s) =\n" c.c_label c.c_param);
      print_block c.c_body 2 out;
      add out "\n")
    p.codes;
  List.iter
    (fun i ->
      match i.ibody with
      | None -> ()
      | Some b ->
          add out
            (Printf.sprintf "-- %s\n"
               (match i.ilabel with Some l -> Lazy.force l | None -> i.iname));
          print_block b 0 out;
          add out "\n")
    p.items;
  Buffer.contents out
