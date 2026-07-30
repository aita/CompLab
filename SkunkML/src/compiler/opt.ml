(* Optimisation on value SSA.

   Four passes and one loop around them:

     fold    constant folding and algebraic identities, value by value
     sccp    sparse conditional constant propagation -- the dataflow analysis
             that finds constants and unreachable blocks *together*, because
             each one is what makes the other visible
     gvn     global value numbering: two values with the same operation and the
             same arguments are the same value, if one dominates the other
     dce     anything with no uses and no effect goes

   The order matters and the loop matters.  sccp turns a comparison into `true`,
   which turns a switch into a jump, which makes a block unreachable, which
   makes a phi have one argument, which is a copy, which gvn removes, which can
   make another comparison constant.  Running each pass once catches the first
   step of that chain; running them in a loop catches the chain.

   Value SSA earns its keep here more than anywhere else.

     * A use count is a field, so "is this dead" is a lookup, not an analysis.
     * There are no names, so replacing a value everywhere is one walk over the
       argument lists -- no scope to respect, no shadowing to worry about.
     * Two values with the same operation and arguments *are* the same value,
       which is the statement gvn exists to exploit; here it is almost the
       definition of the representation.

   What is *not* safe to touch is worth as much as what is:

     * `ref` is a constructor like any other in the source, but two `ref 1`s
       have to be two cells.  It is the one constructor gvn must not share.
     * `mkclos` allocates a closure that `setcap` then writes into, so sharing
       two of them would alias a recursive group into one closure.
     * `div` and `mod` can fail.  Sharing two of them is fine -- the first
       dominates the second, so the failure happens where it already would --
       but deleting an unused one is not.
     * A `global` is a word that gets written, but only by `skunk_program`
       between items, never while a function body is running, so within a
       function it is a constant. *)

module S = Ssa

(* ---- keys ---------------------------------------------------------------- *)

(* What makes two values the same value.  A string rather than a structured key
   because the operations carry types and label lists, and comparing those
   properly is more work than printing them. *)
let op_key (v : S.value) =
  let args = String.concat "," (List.map (fun a -> string_of_int a.S.vid) v.S.args) in
  let op =
    match v.S.op with
    | S.Const (S.CInt n) -> Printf.sprintf "i%d" n
    | S.Const (S.CStr s) -> Printf.sprintf "s%S" s
    | S.Const S.CUnit -> "u"
    | S.Global g -> "g" ^ g
    | S.Param -> "p"
    | S.Capture i -> Printf.sprintf "c%d" i
    | S.Prim p -> "P" ^ p
    | S.Record ls -> "R" ^ String.concat "/" ls
    | S.Con c -> Printf.sprintf "K%d:%d" c.Types.cres.Types.tid c.Types.cidx
    | S.Field (l, i) -> Printf.sprintf "F%s:%d" l i
    | S.Payload -> "L"
    | S.Phi -> Printf.sprintf "H%d" v.S.home.S.bid
    | S.Call | S.MkClos _ | S.SetCap _ -> "!"
  in
  op ^ "(" ^ args ^ ")"

(* A pure value can be moved, shared or deleted; the comments at the top say why
   each of these is not one. *)
let pure (v : S.value) =
  match v.S.op with
  | S.Call | S.SetCap _ | S.MkClos _ -> false
  | S.Prim ":=" -> false
  | S.Con c -> c.Types.cres.Types.tid <> Types.ref_tc.Types.tid
  | _ -> true

(* Shareable but not deletable: the failure is the point. *)
let shareable v = pure v || match v.S.op with S.Prim ("div" | "mod") -> true | _ -> false

(* ---- rewriting ----------------------------------------------------------- *)

type ctx = { mutable next_vid : int; repl : (int, S.value) Hashtbl.t; mutable changed : bool }

let rec find ctx (v : S.value) =
  match Hashtbl.find_opt ctx.repl v.S.vid with Some w -> find ctx w | None -> v

let replace ctx (v : S.value) (w : S.value) =
  if v != w then begin
    Hashtbl.replace ctx.repl v.S.vid w;
    ctx.changed <- true
  end

let map_term ctx = function
  | S.Ret v -> S.Ret (find ctx v)
  | S.TailCall (f, a) -> S.TailCall (find ctx f, find ctx a)
  | S.Switch (v, arms, d) -> S.Switch (find ctx v, arms, d)
  | (S.Jump _ | S.Fail _) as t -> t

(* One walk: every argument and every terminator follows the replacements, and
   the values that were replaced leave their blocks. *)
let apply ctx (f : S.func) =
  List.iter
    (fun (b : S.block) ->
      List.iter (fun (v : S.value) -> v.S.args <- List.map (find ctx) v.S.args) (b.S.phis @ b.S.values);
      b.S.term <- map_term ctx b.S.term)
    f.S.blocks;
  List.iter
    (fun (b : S.block) ->
      let keep (v : S.value) = not (Hashtbl.mem ctx.repl v.S.vid) in
      b.S.phis <- List.filter keep b.S.phis;
      b.S.values <- List.filter keep b.S.values)
    f.S.blocks;
  Hashtbl.reset ctx.repl

(* Hoisting one of these to the front of the entry block is what makes it usable
   from anywhere in the function, and it costs nothing to do: a constant and a
   nullary constructor have no arguments, so no position in the block is too
   early for them.

   It also has to be done to the one that is *already there*.  The builder
   defines a constant in the block that uses it ([10章](../doc/10-ssa.md)), so
   an equal one found in the entry block can perfectly well sit below the value
   about to be pointed at it -- and within a block, later is not dominated. *)
let to_front (b : S.block) (v : S.value) =
  if not (match b.S.values with w :: _ -> w == v | [] -> false) then
    b.S.values <- v :: List.filter (fun (w : S.value) -> not (w == v)) b.S.values;
  v

(* A constant lives at the top of the entry block, where it dominates
   everything, and is shared with any equal one already there. *)
let entry_const ctx (f : S.func) (c : S.const) =
  let entry = f.S.entry in
  let same (v : S.value) = match v.S.op with S.Const c' -> c' = c | _ -> false in
  match List.find_opt same entry.S.values with
  | Some v -> to_front entry v
  | None ->
      let v = { S.vid = ctx.next_vid; op = S.Const c; args = []; home = entry; uses = 0;
                origin = "" } in
      ctx.next_vid <- ctx.next_vid + 1;
      (* Before anything that might use it, and after the phis, which the block
         list does not hold anyway. *)
      entry.S.values <- v :: entry.S.values;
      v

let bool_con b =
  List.find
    (fun (c : Types.constr) -> c.Types.cname = (if b then "true" else "false"))
    Types.bool_tc.Types.tcons

let entry_bool ctx (f : S.func) b =
  let c = bool_con b in
  let entry = f.S.entry in
  (* Which constructor a value is takes *both* numbers: an index on its own says
     "the first one" or "the second one" of some datatype, and every datatype
     has those.  `nil` and `false` are both the first, `::` and `true` are both
     the second, so matching on the index alone hands back whichever nullary
     constructor happened to be in the entry block already -- and `false` comes
     out printing as `[]`. *)
  let same (v : S.value) =
    match v.S.op with
    | S.Con c' ->
        c'.Types.cres.Types.tid = c.Types.cres.Types.tid
        && c'.Types.cidx = c.Types.cidx
        && v.S.args = []
    | _ -> false
  in
  match List.find_opt same entry.S.values with
  | Some v -> to_front entry v
  | None ->
      let v = { S.vid = ctx.next_vid; op = S.Con c; args = []; home = entry; uses = 0; origin = "" } in
      ctx.next_vid <- ctx.next_vid + 1;
      entry.S.values <- v :: entry.S.values;
      v

(* ---- folding ------------------------------------------------------------- *)

(* The lattice, up here because two passes share it: what a value is known to
   be.  Top means nothing is known yet -- nothing has reached it. *)
type cell = Top | Const of S.const | ConBool of bool | Bottom

let meet a b =
  match (a, b) with
  | Top, x | x, Top -> x
  | Bottom, _ | _, Bottom -> Bottom
  | Const x, Const y -> if x = y then a else Bottom
  | ConBool x, ConBool y -> if x = y then a else Bottom
  | _ -> Bottom

(* The whole arithmetic table, once.  Cells in, a cell out, and no side
   effects: both the rewriter and the dataflow analysis ask this same function,
   so the two cannot disagree about what `3 * 4` is. *)
let fold_cells op (cs : cell list) =
  let i n = Some (Const (S.CInt n)) and st t = Some (Const (S.CStr t)) in
  let bl b = Some (ConBool b) in
  match (op, cs) with
  | _, [ Const (S.CInt x); Const (S.CInt y) ] -> (
      match op with
      | "+" -> i (x + y)
      | "-" -> i (x - y)
      | "*" -> i (x * y)
      (* Division by zero is not folded: the program is supposed to fail. *)
      | "div" -> if y = 0 then None else i (x / y)
      | "mod" -> if y = 0 then None else i (x mod y)
      | "<" -> bl (x < y)
      | "<=" -> bl (x <= y)
      | ">" -> bl (x > y)
      | ">=" -> bl (x >= y)
      | "=" -> bl (x = y)
      | "<>" -> bl (x <> y)
      | _ -> None)
  | _, [ Const (S.CStr x); Const (S.CStr y) ] -> (
      match op with
      | "^" -> st (x ^ y)
      | "<" -> bl (x < y)
      | "<=" -> bl (x <= y)
      | ">" -> bl (x > y)
      | ">=" -> bl (x >= y)
      | "=" -> bl (x = y)
      | "<>" -> bl (x <> y)
      | _ -> None)
  | "~", [ Const (S.CInt x) ] -> i (-x)
  | "not", [ ConBool x ] -> bl (not x)
  (* The identities, which a constant on one side is enough for. *)
  | ("+" | "-"), [ _; Const (S.CInt 0) ] -> Some Top
  | "*", [ _; Const (S.CInt 1) ] -> Some Top
  | _ -> None

let as_int (v : S.value) = match v.S.op with S.Const (S.CInt n) -> Some n | _ -> None

let cell_of (v : S.value) =
  match (v.S.op, v.S.args) with
  | S.Const c, _ -> Const c
  | S.Con c, [] when c.Types.cres.Types.tid = Types.bool_tc.Types.tid ->
      ConBool (c.Types.cname = "true")
  | _ -> Bottom

(* What one value folds to on its own.  [None] means "leave it alone".  The
   arithmetic comes from [fold_cells]; what is left here is the cases a lattice
   cannot express, because the answer is another value rather than a constant. *)
let fold ctx f (v : S.value) =
  let materialise = function
    | Const c -> Some (entry_const ctx f c)
    | ConBool b -> Some (entry_bool ctx f b)
    | Top | Bottom -> None
  in
  match (v.S.op, v.S.args) with
  | S.Prim p, args -> (
      match fold_cells p (List.map cell_of args) with
      | Some Top -> (
          (* An identity: the answer is one of the arguments. *)
          match (p, args) with
          | ("+" | "-" | "*"), [ a; _ ] -> Some a
          | _ -> None)
      | Some c -> materialise c
      | None -> (
          match (p, args) with
          | "+", [ a; b ] when as_int a = Some 0 -> Some b
          | "*", [ a; b ] when as_int a = Some 1 -> Some b
          | "*", [ a; b ] when as_int a = Some 0 || as_int b = Some 0 ->
              ignore a;
              ignore b;
              materialise (Const (S.CInt 0))
          | _ -> None))
  (* A phi whose arguments are all the same value is that value.  This is where
     most of the work after sccp lands: pruning an edge leaves a one-argument
     phi behind. *)
  | S.Phi, (a :: rest as all) when List.for_all (fun x -> x == a) rest && all <> [] -> Some a
  (* Reading a field straight out of a record that was just built. *)
  | S.Field (l, _), [ a ] -> (
      match (a.S.op, a.S.args) with
      | S.Record ls, fields when List.length ls = List.length fields ->
          let rec pick ls fs =
            match (ls, fs) with
            | l' :: _, x :: _ when l' = l -> Some x
            | _ :: ls, _ :: fs -> pick ls fs
            | _ -> None
          in
          pick ls fields
      | _ -> None)
  | S.Payload, [ a ] -> ( match (a.S.op, a.S.args) with S.Con _, [ x ] -> Some x | _ -> None)
  | _ -> None

let fold_pass ctx (f : S.func) =
  List.iter
    (fun (b : S.block) ->
      List.iter
        (fun (v : S.value) -> match fold ctx f v with Some w -> replace ctx v w | None -> ())
        (b.S.phis @ b.S.values))
    f.S.blocks;
  apply ctx f

(* ---- sparse conditional constant propagation ----------------------------- *)

(* Wegman and Zadeck.  Two worklists and one lattice:

     Top      nothing known yet -- this value has not been reached
     Const c  every execution that reaches here produces c
     Bottom   more than one value

   The reason to do it this way rather than as two passes is in the name.
   *Conditional*: a block is only analysed once something reaches it, so a
   switch whose scrutinee is a known constant contributes only one arm, and the
   other arms' blocks stay Top -- which is what lets their phi arguments be
   ignored rather than met.  *Sparse*: the propagation follows the SSA edges
   rather than sweeping the whole function, so a value is revisited only when
   one of its arguments changes. *)

let sccp ctx (f : S.func) =
  let cell = Hashtbl.create 64 in
  let get (v : S.value) = match Hashtbl.find_opt cell v.S.vid with Some c -> c | None -> Top in
  let reachable = Hashtbl.create 16 in
  let edge = Hashtbl.create 32 in (* (from, to) has been taken *)
  let bwork = ref [] and vwork = ref [] in
  let users = Hashtbl.create 64 in
  List.iter
    (fun (b : S.block) ->
      List.iter
        (fun (v : S.value) ->
          List.iter
            (fun (a : S.value) ->
              Hashtbl.replace users a.S.vid (v :: Option.value (Hashtbl.find_opt users a.S.vid) ~default:[]))
            v.S.args)
        (b.S.phis @ b.S.values))
    f.S.blocks;
  let set (v : S.value) c =
    if get v <> c then begin
      Hashtbl.replace cell v.S.vid c;
      vwork := Option.value (Hashtbl.find_opt users v.S.vid) ~default:[] @ !vwork;
      (* A terminator is not in [users], so a switch on this value has to be
         woken up by hand. *)
      List.iter
        (fun (b : S.block) ->
          match b.S.term with
          | S.Switch (s, _, _) when s == v && Hashtbl.mem reachable b.S.bid ->
              bwork := b :: !bwork
          | _ -> ())
        f.S.blocks
    end
  in
  (* Only a *new* edge or a *newly* reachable block is worth queueing.  Queuing
     unconditionally is an infinite loop: the block re-reaches its successors,
     which re-reach it. *)
  let reach (from_ : S.block option) (b : S.block) =
    let fresh_edge =
      match from_ with
      | Some p ->
          if Hashtbl.mem edge (p.S.bid, b.S.bid) then false
          else begin
            Hashtbl.replace edge (p.S.bid, b.S.bid) ();
            true
          end
      | None -> false
    in
    let fresh_block = not (Hashtbl.mem reachable b.S.bid) in
    if fresh_block then Hashtbl.replace reachable b.S.bid ();
    if fresh_block || fresh_edge then bwork := b :: !bwork
  in
  (* A value's cell from its arguments'.  Anything not a fold of constants is
     Bottom as soon as it is reached. *)
  let eval (v : S.value) =
    match v.S.op with
    | S.Phi ->
        let preds = v.S.home.S.preds in
        let rec go ps args acc =
          match (ps, args) with
          | (p : S.block) :: ps, (a : S.value) :: args ->
              let acc =
                if Hashtbl.mem edge (p.S.bid, v.S.home.S.bid) then meet acc (get a) else acc
              in
              go ps args acc
          | _ -> acc
        in
        go preds v.S.args Top
    | S.Const _ | S.Con _ -> cell_of v
    | S.Prim p ->
        if List.exists (fun a -> get a = Top) v.S.args && v.S.args <> [] then Top
        else (
          match fold_cells p (List.map get v.S.args) with
          | Some Top | None -> Bottom (* an identity is not a constant *)
          | Some c -> c)
    | _ -> Bottom
  in
  reach None f.S.entry;
  let rec loop () =
    match (!bwork, !vwork) with
    | b :: rest, _ ->
        bwork := rest;
        List.iter (fun (v : S.value) -> set v (eval v)) (b.S.phis @ b.S.values);
        (match b.S.term with
        | S.Jump t -> reach (Some b) t
        | S.Switch (s, arms, dflt) -> (
            let taken =
              match get s with
              | Const (S.CInt n) ->
                  Some (List.filter (fun (k, _) -> k = Core.Kint n) arms)
              | Const (S.CStr t) ->
                  Some (List.filter (fun (k, _) -> k = Core.Kstr t) arms)
              | ConBool bl ->
                  Some
                    (List.filter
                       (fun (k, _) ->
                         match k with
                         | Core.Ktag c -> c.Types.cname = (if bl then "true" else "false")
                         | _ -> false)
                       arms)
              | Top -> Some []
              | Const S.CUnit | Bottom -> None
            in
            match taken with
            | None ->
                List.iter (fun (_, t) -> reach (Some b) t) arms;
                Option.iter (fun d -> reach (Some b) d) dflt
            | Some [ (_, t) ] -> reach (Some b) t
            | Some [] -> ( match dflt with Some d -> reach (Some b) d | None -> ())
            | Some more -> List.iter (fun (_, t) -> reach (Some b) t) more)
        | S.Ret _ | S.TailCall _ | S.Fail _ -> ());
        loop ()
    | [], v :: rest ->
        vwork := rest;
        if Hashtbl.mem reachable v.S.home.S.bid then set v (eval v);
        loop ()
    | [], [] -> ()
  in
  loop ();
  (* Now use it.  Constants first, then the switches, then the blocks nothing
     reached. *)
  List.iter
    (fun (b : S.block) ->
      if Hashtbl.mem reachable b.S.bid then
        List.iter
          (fun (v : S.value) ->
            match get v with
            | Const c when (match v.S.op with S.Const _ -> false | _ -> true) ->
                replace ctx v (entry_const ctx f c)
            | ConBool bl when (match (v.S.op, v.S.args) with S.Con _, [] -> false | _ -> true) ->
                replace ctx v (entry_bool ctx f bl)
            | _ -> ())
          (b.S.phis @ b.S.values))
    f.S.blocks;
  apply ctx f;
  List.iter
    (fun (b : S.block) ->
      if Hashtbl.mem reachable b.S.bid then
        match b.S.term with
        | S.Switch (_, arms, dflt) ->
            let live =
              List.filter (fun (_, (t : S.block)) -> Hashtbl.mem edge (b.S.bid, t.S.bid)) arms
            in
            let dlive =
              match dflt with
              | Some d when Hashtbl.mem edge (b.S.bid, d.S.bid) -> Some d
              | _ -> None
            in
            if List.length live + (match dlive with Some _ -> 1 | None -> 0) = 1 then begin
              let t = match (live, dlive) with (_, t) :: _, _ -> t | _, Some d -> d | _ -> assert false in
              b.S.term <- S.Jump t;
              ctx.changed <- true
            end
              (* Never `=` on a block: a block points at values whose home
                 points back at the block, so structural comparison does not
                 terminate.  Counting is enough here. *)
            else if
              List.length live <> List.length arms
              || Option.is_some dlive <> Option.is_some dflt
            then begin
              b.S.term <- S.Switch ((match b.S.term with S.Switch (s, _, _) -> s | _ -> assert false), live, dlive);
              ctx.changed <- true
            end
        | _ -> ())
    f.S.blocks;
  (* Drop the blocks nothing reached, and the phi arguments that came from
     them. *)
  let dead = List.filter (fun (b : S.block) -> not (Hashtbl.mem reachable b.S.bid)) f.S.blocks in
  if dead <> [] then begin
    ctx.changed <- true;
    f.S.blocks <- List.filter (fun (b : S.block) -> Hashtbl.mem reachable b.S.bid) f.S.blocks
  end;
  List.iter
    (fun (b : S.block) ->
      let keep = List.map (fun (p : S.block) -> Hashtbl.mem reachable p.S.bid
                                                && List.exists (fun (s : S.block) -> s == b) (S.succs p)) b.S.preds in
      if List.exists not keep then begin
        ctx.changed <- true;
        let filter l = List.filteri (fun i _ -> List.nth keep i) l in
        List.iter (fun (v : S.value) -> v.S.args <- filter v.S.args) b.S.phis;
        b.S.preds <- filter b.S.preds
      end)
    f.S.blocks

(* ---- global value numbering ---------------------------------------------- *)

(* One scoped table, walked down the dominator tree.  A value is only replaced
   by one that dominates it, which is exactly what "found in an enclosing scope"
   means -- so the walk is the dominance test, and no separate check is
   needed. *)
let gvn ctx (f : S.func) =
  let d = Dom.build f in
  let children = Hashtbl.create 16 in
  List.iter
    (fun (b : S.block) ->
      match Hashtbl.find_opt d.Dom.idom b.S.bid with
      | Some p when p.S.bid <> b.S.bid ->
          Hashtbl.replace children p.S.bid (b :: Option.value (Hashtbl.find_opt children p.S.bid) ~default:[])
      | _ -> ())
    f.S.blocks;
  let table = Hashtbl.create 64 in
  let rec walk (b : S.block) =
    let added = ref [] in
    List.iter
      (fun (v : S.value) ->
        if shareable v then begin
          let k = op_key v in
          match Hashtbl.find_opt table k with
          | Some w -> replace ctx v w
          | None ->
              Hashtbl.replace table k v;
              added := k :: !added
        end)
      (b.S.phis @ b.S.values);
    List.iter walk (Option.value (Hashtbl.find_opt children b.S.bid) ~default:[]);
    List.iter (Hashtbl.remove table) !added
  in
  walk f.S.entry;
  apply ctx f

(* ---- dead code elimination ----------------------------------------------- *)

(* No uses and no effect.  Repeated, because removing a value drops the use
   count of its arguments, which is the whole reason a chain of dead code
   disappears rather than just its last value. *)
let dce (f : S.func) =
  let go = ref true and any = ref false in
  while !go do
    go := false;
    S.recount f;
    List.iter
      (fun (b : S.block) ->
        let keep (v : S.value) = v.S.uses > 0 || S.effectful v in
        let before = List.length b.S.values + List.length b.S.phis in
        b.S.values <- List.filter keep b.S.values;
        b.S.phis <- List.filter keep b.S.phis;
        if List.length b.S.values + List.length b.S.phis <> before then begin
          go := true;
          any := true
        end)
      f.S.blocks
  done;
  !any

(* ---- straightening ------------------------------------------------------- *)

(* A block whose only successor has only this block as a predecessor is the same
   block: nothing can arrive in between.  Merging the two is what turns the jump
   chain sccp leaves behind -- one empty block per pruned arm -- back into
   straight-line code.  Repeated, because a chain collapses one link at a
   time. *)
let merge_blocks (f : S.func) =
  let any = ref false in
  let go = ref true in
  while !go do
    go := false;
    let candidate =
      List.find_opt
        (fun (b : S.block) ->
          match b.S.term with
          | S.Jump t ->
              (not (t == f.S.entry))
              && (match t.S.preds with [ p ] -> p == b | _ -> false)
              && t.S.phis = []
          | _ -> false)
        f.S.blocks
    in
    match candidate with
    | None -> ()
    | Some b ->
        let t = match b.S.term with S.Jump t -> t | _ -> assert false in
        List.iter (fun (v : S.value) -> v.S.home <- b) t.S.values;
        b.S.values <- b.S.values @ t.S.values;
        b.S.term <- t.S.term;
        f.S.blocks <- List.filter (fun (x : S.block) -> not (x == t)) f.S.blocks;
        (* Whoever named t as a predecessor now means b. *)
        List.iter
          (fun (x : S.block) ->
            x.S.preds <- List.map (fun (p : S.block) -> if p == t then b else p) x.S.preds)
          f.S.blocks;
        go := true;
        any := true
  done;
  !any

(* ---- the pipeline -------------------------------------------------------- *)

let func (f : S.func) =
  let next =
    List.fold_left
      (fun m (b : S.block) ->
        List.fold_left (fun m (v : S.value) -> max m (v.S.vid + 1)) m (b.S.phis @ b.S.values))
      0 f.S.blocks
  in
  let ctx = { next_vid = next; repl = Hashtbl.create 64; changed = false } in
  let rounds = ref 0 in
  let continue_ = ref true in
  while !continue_ && !rounds < 8 do
    incr rounds;
    ctx.changed <- false;
    fold_pass ctx f;
    sccp ctx f;
    gvn ctx f;
    let d = dce f in
    let m = merge_blocks f in
    continue_ := ctx.changed || d || m
  done;
  S.recount f;
  S.renumber f

let program (p : S.prog) =
  List.iter func p.S.funcs;
  List.iter (fun (i : S.item) -> Option.iter func i.S.ibody) p.S.items
