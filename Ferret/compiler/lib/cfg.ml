(* The control-flow graph of the exec edges, and what has to be known about it
   before it can be turned back into wasm's block structure.

   Exec edges used to form a tree, and the back end got the nesting for free.
   Now a Condition node branches and a wire runs back to close a loop, so the
   edges form a real graph and the nesting has to be recovered: dominators,
   which node heads a loop, and where two branches join again. *)

type t = {
  entry : string;
  succs : (string, string list) Hashtbl.t;
  preds : (string, string list) Hashtbl.t;
  order : string array;  (* reverse postorder *)
  rank : (string, int) Hashtbl.t;  (* node -> index into [order] *)
  idom : (string, string) Hashtbl.t;  (* immediate dominator *)
  back : (string * string) list;  (* edges that close a loop: from, to *)
}

let successors g n = Option.value (Hashtbl.find_opt g.succs n) ~default:[]
let predecessors g n = Option.value (Hashtbl.find_opt g.preds n) ~default:[]
let rank g n = Option.value (Hashtbl.find_opt g.rank n) ~default:max_int
let reachable g n = Hashtbl.mem g.rank n

(* h heads a loop when some edge runs back into it. *)
let is_header g h = List.exists (fun (_, t) -> t = h) g.back

let is_back_edge g u v = List.mem (u, v) g.back

(* The edges that reach n from before it, rather than around a loop. *)
let forward_preds g n =
  List.filter (fun p -> not (is_back_edge g p n)) (predecessors g n)

(* Two or more ways in means the branches join here, and the join has to be
   somewhere both of them can reach with a br. *)
let is_join g n = List.length (forward_preds g n) > 1

let rec dominates g a b =
  a = b
  ||
  match Hashtbl.find_opt g.idom b with
  | Some d when d <> b -> dominates g a d
  | _ -> false

(* --------------------------------------------------------------- build *)

let reverse_postorder entry succs =
  let seen = Hashtbl.create 32 in
  let out = ref [] in
  let rec go n =
    if not (Hashtbl.mem seen n) then (
      Hashtbl.replace seen n ();
      List.iter go (Option.value (Hashtbl.find_opt succs n) ~default:[]);
      out := n :: !out)
  in
  go entry;
  Array.of_list !out

(* Cooper, Harvey and Kennedy: walk in reverse postorder and intersect, until
   nothing moves.  On graphs this size it settles in two or three passes. *)
let dominators order rank preds entry =
  let idom = Hashtbl.create 32 in
  Hashtbl.replace idom entry entry;
  let intersect a b =
    let a = ref a and b = ref b in
    while !a <> !b do
      while Hashtbl.find rank !a > Hashtbl.find rank !b do
        a := Hashtbl.find idom !a
      done;
      while Hashtbl.find rank !b > Hashtbl.find rank !a do
        b := Hashtbl.find idom !b
      done
    done;
    !a
  in
  let changed = ref true in
  while !changed do
    changed := false;
    Array.iter
      (fun n ->
        if n <> entry then
          let ready =
            List.filter
              (fun p -> Hashtbl.mem rank p && Hashtbl.mem idom p)
              (Option.value (Hashtbl.find_opt preds n) ~default:[])
          in
          match ready with
          | [] -> ()
          | first :: rest ->
              let d = List.fold_left intersect first rest in
              if Hashtbl.find_opt idom n <> Some d then (
                Hashtbl.replace idom n d;
                changed := true))
      order
  done;
  idom

(* An edge into one of its own ancestors closes a loop.  Finding them by the
   depth-first stack rather than by dominance is what lets an irreducible
   graph -- two ways into the middle of a loop -- be spotted and refused. *)
let back_edges entry succs =
  let colour = Hashtbl.create 32 in
  let out = ref [] in
  let rec go n =
    Hashtbl.replace colour n `Open;
    List.iter
      (fun s ->
        match Hashtbl.find_opt colour s with
        | Some `Open -> out := (n, s) :: !out
        | Some `Done -> ()
        | None -> go s)
      (Option.value (Hashtbl.find_opt succs n) ~default:[]);
    Hashtbl.replace colour n `Done
  in
  go entry;
  !out

let build ~entry ~succs =
  let preds = Hashtbl.create 32 in
  Hashtbl.iter
    (fun n ss ->
      List.iter
        (fun s ->
          Hashtbl.replace preds s
            (n :: Option.value (Hashtbl.find_opt preds s) ~default:[]))
        ss)
    succs;
  let order = reverse_postorder entry succs in
  let rank = Hashtbl.create 32 in
  Array.iteri (fun i n -> Hashtbl.replace rank n i) order;
  let idom = dominators order rank preds entry in
  let back = back_edges entry succs in
  { entry; succs; preds; order; rank; idom; back }

(* A loop whose header does not dominate the edge that closes it cannot be
   written with wasm's blocks without duplicating code.  Say so rather than
   emitting something that does not mean what was drawn. *)
let irreducible g =
  List.filter (fun (u, h) -> not (dominates g h u)) g.back
