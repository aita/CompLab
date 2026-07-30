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
   keeps in one global table, and the parameter, which arrives by other means.

   The free variables themselves are computed in `core.ml`: the elaborator
   wants them too, to decide whether a `fun` group really recurs. *)

module C = Core
module F = Flat
module Set = Core.Vars

let atom : C.atom -> F.atom = function
  | C.AVar x -> F.AVar x
  | C.AInt n -> F.AInt n
  | C.AStr s -> F.AStr s
  | C.AUnit -> F.AUnit

type state = { mutable codes : F.code list; globals : Set.t }

let counter = ref 0

let fresh_label base =
  incr counter;
  Printf.sprintf "%s$%d" base !counter

let rec conv st (b : C.block) : F.block =
  match b with
  | C.Let (x, _, (C.Lam _ as r), rest) -> F.Let (x, conv_closure st x r, conv st rest)
  | C.Let (x, _, rhs, rest) -> F.Let (x, conv_rhs rhs, conv st rest)
  | C.Fix (defs, rest) ->
      F.Fix (List.map (fun (x, _, r) -> (x, conv_closure st x r)) defs, conv st rest)
  | C.Join (j, ps, body, rest) ->
      F.Join (j, List.map fst ps, conv st body, conv st rest)
  | C.Tail t -> conv_tail st t

(* The one place a lambda becomes a closure.  There is one lambda form in Core,
   so there is one of these, whether the binding recurs or not. *)
and conv_closure st name (r : C.rhs) : F.rhs =
  match r with
  | C.Lam (p, _, body) ->
      let label, caps = make_closure st name p body in
      F.Closure (label, caps)
  | _ -> assert false

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
  let free = Set.diff (Set.remove param (C.free_vars body)) st.globals in
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
