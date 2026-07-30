(* Closure conversion.

   A lambda is a piece of code plus the values it needs from where it was
   written.  This pass separates the two: the code goes to the top of the
   program as a [Flat.code] block with one parameter, and the values become a
   list of captures that the code reads back with [Capture i].  After it, no
   function is inside another function, and calling one needs no environment
   from the caller.

   What is *not* converted is the interesting part.  A join point stays where
   it is, and its free variables stay free.  They can, because a join point is
   only ever jumped to from inside the block that defines it, so the values are
   still there -- that is the whole difference between a label and a closure,
   and it is why compilers bother to tell them apart.  This pass simply never
   looks inside a `join` for something to capture.

   Two more things are not captured: the top-level bindings, which the machine
   keeps in one global table, and the parameter, which arrives by other
   means. *)

module C = Core
module F = Flat
module Set = Set.Make (String)

let atom : C.atom -> F.atom = function
  | C.AVar x -> F.AVar x
  | C.AInt n -> F.AInt n
  | C.AStr s -> F.AStr s
  | C.AUnit -> F.AUnit

let atom_var = function C.AVar x -> Set.singleton x | _ -> Set.empty
let atoms_var ats = List.fold_left (fun s a -> Set.union s (atom_var a)) Set.empty ats

(* The free variables of a block.  Join labels are not variables and are not
   collected; a jump contributes only its arguments. *)
let rec fv_block (b : C.block) =
  match b with
  | C.Let (x, _, rhs, rest) -> Set.union (fv_rhs rhs) (Set.remove x (fv_block rest))
  | C.LetRec (fns, rest) ->
      let names = List.map (fun f -> f.C.fn_name) fns in
      let inside =
        List.fold_left
          (fun s f -> Set.union s (Set.remove f.C.fn_param (fv_block f.C.fn_body)))
          (fv_block rest) fns
      in
      List.fold_left (fun s n -> Set.remove n s) inside names
  | C.Join (_, ps, body, rest) ->
      let bound = List.map fst ps in
      Set.union
        (List.fold_left (fun s x -> Set.remove x s) (fv_block body) bound)
        (fv_block rest)
  | C.Tail t -> fv_tail t

and fv_rhs = function
  | C.Atom a -> atom_var a
  | C.Lam (x, _, body) -> Set.remove x (fv_block body)
  | C.Call (f, a) -> Set.union (atom_var f) (atom_var a)
  | C.Prim (_, ats) | C.Tuple ats -> atoms_var ats
  | C.Record fs -> atoms_var (List.map snd fs)
  | C.Con (_, None) -> Set.empty
  | C.Con (_, Some a) | C.Proj (a, _) | C.Field (a, _) | C.Payload a -> atom_var a

and fv_tail = function
  | C.Ret a -> atom_var a
  | C.TCall (f, a) -> Set.union (atom_var f) (atom_var a)
  | C.Jump (_, ats) -> atoms_var ats
  | C.Fail _ -> Set.empty
  | C.Switch (a, bs, d) ->
      let s = List.fold_left (fun s (_, b) -> Set.union s (fv_block b)) (atom_var a) bs in
      (match d with None -> s | Some b -> Set.union s (fv_block b))
  | C.Case (a, _, arms, _) ->
      (* Gone by now, but the traversal has to be total. *)
      List.fold_left (fun s arm -> Set.union s (fv_block arm.C.abody)) (atom_var a) arms

type state = { mutable codes : F.code list; globals : Set.t }

let counter = ref 0

let fresh_label base =
  incr counter;
  Printf.sprintf "%s$%d" base !counter

let rec conv st (b : C.block) : F.block =
  match b with
  | C.Let (x, _, C.Lam (p, _, body), rest) ->
      let label, caps = make_closure st x p body in
      F.Let (x, F.Closure (label, caps), conv st rest)
  | C.Let (x, _, rhs, rest) -> F.Let (x, conv_rhs rhs, conv st rest)
  | C.LetRec (fns, rest) ->
      let defs =
        List.map
          (fun f ->
            let label, caps = make_closure st f.C.fn_name f.C.fn_param f.C.fn_body in
            (f.C.fn_name, label, caps))
          fns
      in
      F.LetRec (defs, conv st rest)
  | C.Join (j, ps, body, rest) ->
      F.Join (j, List.map fst ps, conv st body, conv st rest)
  | C.Tail t -> conv_tail st t

and conv_rhs (r : C.rhs) : F.rhs =
  match r with
  | C.Atom a -> F.Atom (atom a)
  | C.Lam _ -> assert false (* handled above: a lambda only ever binds a name *)
  | C.Call (f, a) -> F.Call (atom f, atom a)
  | C.Prim (op, ats) -> F.Prim (op, List.map atom ats)
  | C.Tuple ats -> F.Tuple (List.map atom ats)
  | C.Record fs -> F.Record (List.map (fun (l, a) -> (l, atom a)) fs)
  | C.Con (c, a) -> F.Con (c, Option.map atom a)
  | C.Proj (a, i) -> F.Proj (atom a, i)
  | C.Field (a, l) -> F.Field (atom a, l)
  | C.Payload a -> F.Payload (atom a)

and conv_tail st (t : C.tail) : F.block =
  match t with
  | C.Ret a -> F.Tail (F.Ret (atom a))
  | C.TCall (f, a) -> F.Tail (F.TCall (atom f, atom a))
  | C.Jump (j, ats) -> F.Tail (F.Jump (j, List.map atom ats))
  | C.Fail (loc, m) -> F.Tail (F.Fail (loc, m))
  | C.Switch (a, bs, d) ->
      F.Tail
        (F.Switch (atom a, List.map (fun (k, b) -> (k, conv st b)) bs, Option.map (conv st) d))
  | C.Case _ -> assert false (* patmat.ml removed these *)

(* Lift one lambda out.  The captures are its free variables minus its
   parameter and minus the globals, in a fixed order, and the code block starts
   by naming them again so that its body needs no rewriting. *)
and make_closure st name param body =
  let free = Set.diff (Set.remove param (fv_block body)) st.globals in
  let caps = Set.elements free in
  let label = fresh_label name in
  let inner = conv st body in
  let body =
    List.fold_right
      (fun (x, i) rest -> F.Let (x, F.Capture i, rest))
      (List.mapi (fun i x -> (x, i)) caps)
      inner
  in
  st.codes <- st.codes @ [ { F.c_label = label; c_param = param; c_body = body } ];
  (label, List.map (fun x -> F.AVar x) caps)

let program (globals : string list) (items : C.item list) : F.program =
  counter := 0;
  let st = { codes = []; globals = Set.of_list globals } in
  let items =
    List.map
      (fun (i : C.item) ->
        {
          F.iname = i.C.iname;
          ibody = Option.map (conv st) i.C.ibody;
          ilabel = i.C.ilabel;
          ishow = i.C.ishow;
        })
      items
  in
  { F.codes = st.codes; items }
