(* Inlining, on Flat.

   Every call in this language is an indirect call through a closure: read the
   global, load the code address out of the word it points at, `call *reg`.  In
   an ML program that is everything, and the four instructions are not the
   point.  The point is that a call is a wall every other pass stops at.  Put
   the callee's body at the call site and the wall goes:

     * gvn can share a computation across what used to be a call boundary;
     * sccp can follow a constant argument into the body, so a `switch` on it
       goes away and one arm with it;
     * a tuple built to be the argument is taken apart in the same block it was
       built in, so `fold` reads the fields straight and dce removes the record;
     * a closure whose only use was the call has no uses left, so dce removes
       the allocation too.

   Why here and not on SSA.  A call in the middle of a block has a continuation
   -- the rest of the block, and everything the block reaches -- and inlining
   means giving the callee's returns somewhere to arrive.  On SSA that is block
   surgery: split the block at the call, thread the callee's graph in, put a phi
   at the split for the returned value, and fix up every predecessor list.  On
   Flat it is already written down.  A join point *is* "the code after this,
   with the result as a parameter", so

     let x = f a          becomes      join k (x) = <rest>
     <rest>                            <f's body, with `ret v` as `jump k (v)`>

   and nothing else moves.  There is no CFG to operate on yet, phis do not exist
   yet, and the one thing that does have to be done -- fresh names for the
   copied binders -- is a substitution.  [10章](../doc/10-ssa.md) says the join
   point was the phi all along; this is the pass that spends that.

   What may be inlined is what `loops.ml` already asks about a call before it
   turns one into a jump: a global that exactly one top-level item binds, whose
   item does nothing but allocate a closure over a code block and capture
   nothing.  Captureless is what makes the code block enough: with no captures
   there is nothing for the body to read out of the closure it was reached
   through, so any closure over that label behaves the same.

   Two rules keep it finite and keep it small.

     * A stack of the labels being expanded, which the code block being
       rewritten is already on.  A label may appear on it [unroll] + 1 times, so
       a recursive function peels one turn and the call inside the copy stays a
       call, and [depth] stops a mutually recursive group from unrolling through
       each other instead.  In tail position the rule is absolute: a self tail
       call is a loop and 17章 makes it one.
     * A function called from exactly one place is always inlined -- the copy
       replaces the original rather than joining it.  Anything else has to fit
       under [threshold] nodes.

   The second half of the file spends the same analysis a second way.  Knowing
   which code block a call reaches is also what it takes to say that every call
   to a function passes the same constant, and then the parameter is not a
   parameter.  That is at the bottom, under "interprocedural constant
   propagation", and it runs after inlining because inlining is what decides
   which call sites are still there to agree with each other. *)

module F = Flat
module SM = Map.Make (String)
module SS = Set.Make (String)

(* Flat nodes, not instructions.  It is a size to compare against itself: what
   matters is that it orders two functions the same way an instruction count
   would, and that a `switch` counts its arms. *)
let rec size (b : F.block) =
  match b with
  | F.Let (_, _, rest) -> 1 + size rest
  | F.Fix (defs, rest) -> List.length defs + size rest
  | F.Join (_, _, body, rest) -> 1 + size body + size rest
  | F.Tail t -> size_tail t

and size_tail = function
  | F.Switch (_, arms, d) ->
      1
      + List.fold_left (fun n (_, b) -> n + size b) 0 arms
      + (match d with None -> 0 | Some b -> size b)
  | F.Ret _ | F.TCall _ | F.Jump _ | F.Fail _ -> 1

(* Big enough for the shapes worth copying -- a comparison and two arms, a
   tuple taken apart, a list constructor -- and small enough that a function
   called from a dozen places does not get copied a dozen times.  The number was
   picked by measuring; see 16.8 in doc/16-opt.md. *)
let threshold = 36

(* How far a copy may nest inside a copy.  The stack starts with the code block
   being rewritten, so a function is already on it once before it has inlined
   anything: [unroll] = 1 lets a recursive function hold one copy of itself and
   no more, which is one iteration peeled, and [depth] is what stops a mutually
   recursive group from unrolling through each other instead.  Both are what
   make the pass terminate.

   In tail position the rule is stricter -- a label already being expanded is
   not expanded at all -- because a self tail call is a loop and
   [17章](../doc/17-loops.md) turns it into one.  Unrolling a loop is a
   different decision, made with the loop in front of you. *)
let unroll = 1
let depth = 3

(* Where a body hands a result back: a `ret`, and a tail call, which is a `ret`
   of what it calls.  A body with none of either never returns -- it fails, or
   it loops -- and inlining that at a call in the middle of a block would leave
   the join point with no predecessor at all: an unreachable block, which the
   builder would still make and the verifier would still have to look at.  Not
   worth the special case. *)
let rec exits (b : F.block) =
  match b with
  | F.Let (_, _, rest) | F.Fix (_, rest) -> exits rest
  | F.Join (_, _, body, rest) -> exits body || exits rest
  | F.Tail (F.Ret _ | F.TCall _) -> true
  | F.Tail (F.Switch (_, arms, d)) ->
      List.exists (fun (_, b) -> exits b) arms
      || (match d with None -> false | Some b -> exits b)
  | F.Tail (F.Jump _ | F.Fail _) -> false

(* ---- what the whole program says ----------------------------------------- *)

(* The names a block uses and does not bind.  Everything left is a global, and
   the guard at the call site is that none of them is shadowed where the copy is
   going: a body that says `f` has to still mean the global `f` after it
   moves. *)
let rec fv_block bound acc (b : F.block) =
  match b with
  | F.Let (x, r, rest) -> fv_block (SS.add x bound) (fv_rhs bound acc r) rest
  | F.Fix (defs, rest) ->
      let bound = List.fold_left (fun s (x, _) -> SS.add x s) bound defs in
      let acc = List.fold_left (fun a (_, r) -> fv_rhs bound a r) acc defs in
      fv_block bound acc rest
  | F.Join (_, ps, body, rest) ->
      let acc = fv_block (List.fold_left (fun s p -> SS.add p s) bound ps) acc body in
      fv_block bound acc rest
  | F.Tail t -> fv_tail bound acc t

and fv_atom bound acc = function
  | F.AVar x when not (SS.mem x bound) -> SS.add x acc
  | _ -> acc

and fv_rhs bound acc (r : F.rhs) =
  let a = fv_atom bound in
  match r with
  | F.Atom x | F.Con (_, Some x) | F.Field (x, _, _) | F.Payload x -> a acc x
  | F.Closure (_, caps) -> List.fold_left a acc caps
  | F.Capture _ | F.Con (_, None) -> acc
  | F.Call (f, x) -> a (a acc f) x
  | F.Prim (_, ats) -> List.fold_left a acc ats
  | F.Record fs -> List.fold_left (fun acc (_, x) -> a acc x) acc fs

and fv_tail bound acc (t : F.tail) =
  let a = fv_atom bound in
  match t with
  | F.Ret x -> a acc x
  | F.TCall (f, x) -> a (a acc f) x
  | F.Jump (_, ats) -> List.fold_left a acc ats
  | F.Fail _ -> acc
  | F.Switch (x, arms, d) ->
      let acc = List.fold_left (fun acc (_, b) -> fv_block bound acc b) (a acc x) arms in
      (match d with None -> acc | Some b -> fv_block bound acc b)

type t = {
  (* A global name to the code block it holds, for the names that qualify. *)
  known : (string, string) Hashtbl.t;
  code : (string, F.code) Hashtbl.t;
  (* Labels two units both claim.  There should be none: a label is a Core
     binder and a counter, and Core binders are unique for a whole run.  But
     splicing the wrong body is the worst thing this pass could do, and one
     lookup is what it costs to know it did not. *)
  ambiguous : (string, unit) Hashtbl.t;
  size_of : (string, int) Hashtbl.t;
  free_of : (string, SS.t) Hashtbl.t;
  (* How many places call this global, and how many mention it any other way.
     A name mentioned any other way has escaped: something else can hold the
     closure, so the call sites are not all of them. *)
  called : (string, int) Hashtbl.t;
  escaped : (string, int) Hashtbl.t;
  mutable next : int;
}

let bump t x = Hashtbl.replace t x (1 + Option.value (Hashtbl.find_opt t x) ~default:0)
let count t x = Option.value (Hashtbl.find_opt t x) ~default:0

(* The same walk as [fv_block], but it separates "called here" from "mentioned
   here", which is the difference between a function whose call sites are all of
   its uses and one that got passed somewhere. *)
let rec refs_block e bound (b : F.block) =
  match b with
  | F.Let (x, r, rest) ->
      refs_rhs e bound r;
      refs_block e (SS.add x bound) rest
  | F.Fix (defs, rest) ->
      let bound = List.fold_left (fun s (x, _) -> SS.add x s) bound defs in
      List.iter (fun (_, r) -> refs_rhs e bound r) defs;
      refs_block e bound rest
  | F.Join (_, ps, body, rest) ->
      refs_block e (List.fold_left (fun s p -> SS.add p s) bound ps) body;
      refs_block e bound rest
  | F.Tail t -> refs_tail e bound t

and refs_use e bound = function
  | F.AVar x when not (SS.mem x bound) -> bump e.escaped x
  | _ -> ()

and refs_call e bound = function
  | F.AVar x when not (SS.mem x bound) -> bump e.called x
  | a -> refs_use e bound a

and refs_rhs e bound (r : F.rhs) =
  let u = refs_use e bound in
  match r with
  | F.Atom x | F.Con (_, Some x) | F.Field (x, _, _) | F.Payload x -> u x
  | F.Closure (_, caps) -> List.iter u caps
  | F.Capture _ | F.Con (_, None) -> ()
  | F.Call (f, x) ->
      refs_call e bound f;
      u x
  | F.Prim (_, ats) -> List.iter u ats
  | F.Record fs -> List.iter (fun (_, x) -> u x) fs

and refs_tail e bound (t : F.tail) =
  let u = refs_use e bound in
  match t with
  | F.Ret x -> u x
  | F.TCall (f, x) ->
      refs_call e bound f;
      u x
  | F.Jump (_, ats) -> List.iter u ats
  | F.Fail _ -> ()
  | F.Switch (x, arms, d) ->
      u x;
      List.iter (fun (_, b) -> refs_block e bound b) arms;
      Option.iter (refs_block e bound) d

(* `fun f x = ...` becomes a code block plus an item that does nothing but
   allocate a closure over it and hand it back.  Anything else -- a capture, a
   second binding of the name, a body that computes something -- and the global
   is not known to hold that code block wherever it is read.  It is the question
   `loops.ml` asks in `known`, asked one IR earlier. *)
let item_label (i : F.item) =
  match i.F.ibody with
  | Some (F.Fix ([ (x, F.Closure (l, [])) ], F.Tail (F.Ret (F.AVar r))))
  | Some (F.Let (x, F.Closure (l, []), F.Tail (F.Ret (F.AVar r))))
    when x = r ->
      Some l
  | _ -> None

let analyse (units : F.program list) =
  let e =
    {
      known = Hashtbl.create 32;
      code = Hashtbl.create 32;
      ambiguous = Hashtbl.create 4;
      size_of = Hashtbl.create 32;
      free_of = Hashtbl.create 32;
      called = Hashtbl.create 32;
      escaped = Hashtbl.create 32;
      next = 0;
    }
  in
  List.iter
    (fun (p : F.program) ->
      List.iter
        (fun (c : F.code) ->
          if Hashtbl.mem e.code c.F.c_label then Hashtbl.replace e.ambiguous c.F.c_label ();
          Hashtbl.replace e.code c.F.c_label c;
          Hashtbl.replace e.size_of c.F.c_label (size c.F.c_body);
          Hashtbl.replace e.free_of c.F.c_label
            (fv_block (SS.singleton c.F.c_param) SS.empty c.F.c_body))
        p.F.codes;
      List.iter (fun (c : F.code) -> refs_block e (SS.singleton c.F.c_param) c.F.c_body) p.F.codes;
      List.iter (fun (i : F.item) -> Option.iter (refs_block e SS.empty) i.F.ibody) p.F.items)
    units;
  (* A name bound twice is a name whose value depends on where you read it.
     `val ! = fn x => 0` is a legal program, and so is binding `map` again after
     the basis did: count the bindings and only trust the ones that are one. *)
  let bindings = Hashtbl.create 32 in
  List.iter
    (fun (p : F.program) ->
      List.iter
        (fun (i : F.item) -> if i.F.iname <> "" then bump bindings i.F.iname)
        p.F.items)
    units;
  List.iter
    (fun (p : F.program) ->
      List.iter
        (fun (i : F.item) ->
          if i.F.iname <> "" && count bindings i.F.iname = 1 then
            match item_label i with
            | Some l when Hashtbl.mem e.code l && not (Hashtbl.mem e.ambiguous l) ->
                Hashtbl.replace e.known i.F.iname l
            | _ -> ())
        p.F.items)
    units;
  e

(* ---- copying ------------------------------------------------------------- *)

(* Flat's binders are unique per compilation unit ([4章](../doc/04-core.md)) and
   `build.ml` relies on it: one table, no scopes, no shadowing.  A copy would
   break that, so every binder in the copy gets a name nothing else has.  The
   suffix is deliberately unspellable in the source, and it survives into the
   `; origin` comments of a `--dump-opt`, where it says which call a value came
   through. *)
let fresh e x =
  e.next <- e.next + 1;
  Printf.sprintf "%s#%d" x e.next

let at sub = function
  | F.AVar x -> ( match SM.find_opt x sub with Some a -> a | None -> F.AVar x)
  | a -> a

let rhs sub (r : F.rhs) : F.rhs =
  let a = at sub in
  match r with
  | F.Atom x -> F.Atom (a x)
  | F.Closure (l, caps) -> F.Closure (l, List.map a caps)
  | F.Capture i -> F.Capture i
  | F.Call (f, x) -> F.Call (a f, a x)
  | F.Prim (p, ats) -> F.Prim (p, List.map a ats)
  | F.Record fs -> F.Record (List.map (fun (l, x) -> (l, a x)) fs)
  | F.Con (c, x) -> F.Con (c, Option.map a x)
  | F.Field (x, l, i) -> F.Field (a x, l, i)
  | F.Payload x -> F.Payload (a x)

let var = function F.AVar x -> x | _ -> assert false

(* [k] is where a `ret` goes: [None] keeps it a `ret`, which is what a tail call
   wants, and [Some j] turns it into a jump to the join point that holds the
   rest of the caller. *)
let rec copy e sub jsub k (b : F.block) : F.block =
  match b with
  | F.Let (x, r, rest) ->
      let r = rhs sub r in
      let x' = fresh e x in
      F.Let (x', r, copy e (SM.add x (F.AVar x') sub) jsub k rest)
  | F.Fix (defs, rest) ->
      (* The group sees itself, so every name is in the substitution before any
         right-hand side is rewritten. *)
      let sub = List.fold_left (fun s (x, _) -> SM.add x (F.AVar (fresh e x)) s) sub defs in
      let defs = List.map (fun (x, r) -> (var (SM.find x sub), rhs sub r)) defs in
      F.Fix (defs, copy e sub jsub k rest)
  | F.Join (j, ps, body, rest) ->
      let j' = fresh e j in
      let ps' = List.map (fresh e) ps in
      let inner = List.fold_left2 (fun s p p' -> SM.add p (F.AVar p') s) sub ps ps' in
      let jsub = SM.add j j' jsub in
      F.Join (j', ps', copy e inner jsub k body, copy e sub jsub k rest)
  | F.Tail t -> copy_tail e sub jsub k t

and copy_tail e sub jsub k (t : F.tail) : F.block =
  let a = at sub in
  match t with
  | F.Ret x -> (
      match k with None -> F.Tail (F.Ret (a x)) | Some j -> F.Tail (F.Jump (j, [ a x ])))
  | F.TCall (f, x) -> (
      match k with
      | None -> F.Tail (F.TCall (a f, a x))
      | Some j ->
          (* It was a tail call of the callee; it is not one of the caller, whose
             frame is still there waiting for the result. *)
          let r = fresh e "t" in
          F.Let (r, F.Call (a f, a x), F.Tail (F.Jump (j, [ F.AVar r ]))))
  | F.Jump (j, ats) ->
      let j = match SM.find_opt j jsub with Some j' -> j' | None -> j in
      F.Tail (F.Jump (j, List.map a ats))
  | F.Fail (loc, m) -> F.Tail (F.Fail (loc, m))
  | F.Switch (x, arms, d) ->
      F.Tail
        (F.Switch
           ( a x,
             List.map (fun (key, b) -> (key, copy e sub jsub k b)) arms,
             Option.map (copy e sub jsub k) d ))

(* ---- landing ------------------------------------------------------------- *)

(* How many places jump to [k].  Copying is the only thing that makes such a
   jump and it makes one per exit, so this counts the callee's exits after
   everything the copy inlined in its turn has settled. *)
let rec landings k (b : F.block) =
  match b with
  | F.Let (_, _, rest) | F.Fix (_, rest) -> landings k rest
  | F.Join (_, _, body, rest) -> landings k body + landings k rest
  | F.Tail (F.Jump (j, _)) -> if j = k then 1 else 0
  | F.Tail (F.Switch (_, arms, d)) ->
      List.fold_left (fun n (_, b) -> n + landings k b) 0 arms
      + (match d with None -> 0 | Some b -> landings k b)
  | F.Tail (F.Ret _ | F.TCall _ | F.Fail _) -> 0

(* Put [rest] at the one place that jumps to [k].  Only called when there is
   exactly one, so nothing is duplicated. *)
let rec splice k x rest (b : F.block) =
  match b with
  | F.Let (y, r, tl) -> F.Let (y, r, splice k x rest tl)
  | F.Fix (defs, tl) -> F.Fix (defs, splice k x rest tl)
  | F.Join (j, ps, body, tl) -> F.Join (j, ps, splice k x rest body, splice k x rest tl)
  | F.Tail (F.Jump (j, [ a ])) when j = k -> F.Let (x, F.Atom a, rest)
  | F.Tail (F.Switch (s, arms, d)) ->
      F.Tail
        (F.Switch
           ( s,
             List.map (fun (key, br) -> (key, splice k x rest br)) arms,
             Option.map (splice k x rest) d ))
  | F.Tail _ -> b

(* A callee with one exit does not need a join point, and must not get one: the
   builder would make a block whose phi has one argument, at a place nothing
   merges.  `fold` folds such a phi away and `merge_blocks` puts the block back
   where it came from, but the verifier runs before either of them, and "a phi
   where nothing merges" is exactly what it is there to say. *)
let land_ k x rest (b : F.block) =
  if landings k b = 1 then splice k x rest b else F.Join (k, [ x ], rest, b)

(* ---- the rewrite --------------------------------------------------------- *)

let decide e stack bound ~tail (f : string) =
  if SS.mem f bound then None
  else
    match Hashtbl.find_opt e.known f with
    | None -> None
    | Some l -> (
        match Hashtbl.find_opt e.code l with
        | None -> None
        | Some c ->
            let free = Option.value (Hashtbl.find_opt e.free_of l) ~default:SS.empty in
            let once = count e.called f = 1 && count e.escaped f = 0 in
            let copies = List.length (List.filter (fun x -> x = l) stack) in
            if
              (if tail then copies = 0 else copies <= unroll && List.length stack <= depth)
              (* A name the copy reads has to still reach the same place after it
                 moves; if the caller binds it, it does not. *)
              && SS.is_empty (SS.inter free bound)
              && (tail || exits c.F.c_body)
              && (once || Option.value (Hashtbl.find_opt e.size_of l) ~default:max_int <= threshold)
            then Some (l, c)
            else None)

let rec walk e stack bound (b : F.block) : F.block =
  match b with
  | F.Let (x, F.Call (F.AVar f, arg), rest) -> (
      match decide e stack bound ~tail:false f with
      | Some (l, c) ->
          let k = fresh e "k" in
          let body = copy e (SM.singleton c.F.c_param arg) SM.empty (Some k) c.F.c_body in
          (* The continuation is the rest of the caller and its parameter is the
             very binder the call was bound to, which is why nothing in the rest
             has to be rewritten: `x` was bound in one place before and is bound
             in one place now.  The copy is walked with this label on the stack,
             and only then landed -- so that whatever it inlined in its turn is
             counted before the choice between a join point and a splice. *)
          land_ k x
            (walk e stack (SS.add x bound) rest)
            (walk e (l :: stack) bound body)
      | None -> F.Let (x, F.Call (F.AVar f, arg), walk e stack (SS.add x bound) rest))
  | F.Let (x, r, rest) -> F.Let (x, r, walk e stack (SS.add x bound) rest)
  | F.Fix (defs, rest) ->
      let bound = List.fold_left (fun s (x, _) -> SS.add x s) bound defs in
      F.Fix (defs, walk e stack bound rest)
  | F.Join (j, ps, body, rest) ->
      let inner = List.fold_left (fun s p -> SS.add p s) bound ps in
      F.Join (j, ps, walk e stack inner body, walk e stack bound rest)
  | F.Tail (F.TCall (F.AVar f, arg)) -> (
      match decide e stack bound ~tail:true f with
      | Some (l, c) ->
          (* In tail position there is no continuation to build: the callee's
             returns are the caller's returns, and its tail calls stay tail
             calls. *)
          let body = copy e (SM.singleton c.F.c_param arg) SM.empty None c.F.c_body in
          walk e (l :: stack) bound body
      | None -> b)
  | F.Tail (F.Switch (x, arms, d)) ->
      F.Tail
        (F.Switch
           ( x,
             List.map (fun (key, br) -> (key, walk e stack bound br)) arms,
             Option.map (walk e stack bound) d ))
  | F.Tail _ -> b

let rewrite e (p : F.program) : F.program =
  {
    F.codes =
      List.map
        (fun (c : F.code) ->
          { c with F.c_body = walk e [ c.F.c_label ] (SS.singleton c.F.c_param) c.F.c_body })
        p.F.codes;
    items =
      List.map
        (fun (i : F.item) -> { i with F.ibody = Option.map (walk e [] SS.empty) i.F.ibody })
        p.F.items;
  }

(* ---- interprocedural constant propagation -------------------------------- *)

(* Callahan, Cooper, Kennedy and Torczon.  Knowing which code block a call
   reaches is what the pass above needed, and it is the whole of what this one
   needs too: if every call to a known function passes the same constant, and
   nothing holds the function any other way, then the parameter *is* that
   constant inside the body, wherever the body runs from.  Put it there and sccp
   does the rest.

   It is what is left over when inlining has finished.  A function called from
   one place was copied and its call site is gone; what stays behind is the ones
   called from several places and the ones too big to copy, and those are
   exactly the ones worth asking this about. *)

type arg = Nowhere | Same of F.atom | Various

let join a b =
  match (a, b) with
  | Nowhere, x | x, Nowhere -> x
  | Various, _ | _, Various -> Various
  | Same x, Same y -> if x = y then a else Various

let constant = function F.AInt _ | F.AStr _ | F.AUnit -> true | F.AVar _ | F.AReal _ -> false

(* A call argument is an atom, and after inlining it is very often a name bound
   to one -- `let x = 3` then `f x`, because the copy bound the callee's
   parameter to whatever the caller passed.  Following those `Let`s is what lets
   a constant reach a second function through the first.  Only atom bindings are
   followed, and Flat's binders are unique and defined before use, so this
   terminates. *)
let rec resolve defs (a : F.atom) =
  match a with
  | F.AVar x -> ( match SM.find_opt x defs with Some b when b <> a -> resolve defs b | _ -> a)
  | _ -> a

type facts = {
  arg : (string, arg) Hashtbl.t; (* global -> what its call sites pass *)
  held : (string, int) Hashtbl.t; (* global -> mentions that are not calls *)
  clos : (string, int) Hashtbl.t; (* code label -> closures made over it *)
}

let note f x a =
  Hashtbl.replace f.arg x (join (Option.value (Hashtbl.find_opt f.arg x) ~default:Nowhere) a)

let rec facts_block f bound defs (b : F.block) =
  match b with
  | F.Let (x, r, rest) ->
      facts_rhs f bound defs r;
      let defs = match r with F.Atom a -> SM.add x (resolve defs a) defs | _ -> SM.remove x defs in
      facts_block f (SS.add x bound) defs rest
  | F.Fix (defs_, rest) ->
      let bound = List.fold_left (fun s (x, _) -> SS.add x s) bound defs_ in
      List.iter (fun (_, r) -> facts_rhs f bound defs r) defs_;
      facts_block f bound defs rest
  | F.Join (_, ps, body, rest) ->
      facts_block f (List.fold_left (fun s p -> SS.add p s) bound ps) defs body;
      facts_block f bound defs rest
  | F.Tail t -> facts_tail f bound defs t

and facts_use f bound = function
  | F.AVar x when not (SS.mem x bound) -> bump f.held x
  | _ -> ()

and facts_callee f bound defs g a =
  match g with
  | F.AVar x when not (SS.mem x bound) -> note f x (Same (resolve defs a))
  | _ -> facts_use f bound g

and facts_rhs f bound defs (r : F.rhs) =
  let u = facts_use f bound in
  match r with
  | F.Atom x | F.Con (_, Some x) | F.Field (x, _, _) | F.Payload x -> u x
  | F.Closure (l, caps) ->
      bump f.clos l;
      List.iter u caps
  | F.Capture _ | F.Con (_, None) -> ()
  | F.Call (g, x) ->
      facts_callee f bound defs g x;
      u x
  | F.Prim (_, ats) -> List.iter u ats
  | F.Record fs -> List.iter (fun (_, x) -> u x) fs

and facts_tail f bound defs (t : F.tail) =
  let u = facts_use f bound in
  match t with
  | F.Ret x -> u x
  | F.TCall (g, x) ->
      facts_callee f bound defs g x;
      u x
  | F.Jump (_, ats) -> List.iter u ats
  | F.Fail _ -> ()
  | F.Switch (x, arms, d) ->
      u x;
      List.iter (fun (_, b) -> facts_block f bound defs b) arms;
      Option.iter (facts_block f bound defs) d

(* The parameter is one name and the body's binders are unique, so this is a
   substitution over the atoms and not a renaming: nothing else moves.  The
   [bound] check is there because "unique" is a fact about the front end rather
   than about this type.

   [hit] is set when something really was replaced.  Asking afterwards whether
   the block changed is not an option: a `Con` carries a `Types.constr` whose
   result type lists its own constructors, so structural comparison goes round
   and does not come back -- the same trap `opt.ml` fell into with blocks. *)
let rec sub_block hit p (c : F.atom) bound (b : F.block) =
  match b with
  | F.Let (x, r, rest) ->
      F.Let
        ( x,
          sub_rhs hit p c bound r,
          sub_block hit p c (if x = p then SS.add x bound else bound) rest )
  | F.Fix (defs, rest) ->
      let bound = List.fold_left (fun s (x, _) -> if x = p then SS.add x s else s) bound defs in
      F.Fix
        ( List.map (fun (x, r) -> (x, sub_rhs hit p c bound r)) defs,
          sub_block hit p c bound rest )
  | F.Join (j, ps, body, rest) ->
      let inner = List.fold_left (fun s x -> if x = p then SS.add x s else s) bound ps in
      F.Join (j, ps, sub_block hit p c inner body, sub_block hit p c bound rest)
  | F.Tail t -> F.Tail (sub_tail hit p c bound t)

and sub_atom hit p c bound = function
  | F.AVar x when x = p && not (SS.mem x bound) ->
      hit := true;
      c
  | a -> a

and sub_rhs hit p c bound (r : F.rhs) : F.rhs =
  let a = sub_atom hit p c bound in
  match r with
  | F.Atom x -> F.Atom (a x)
  | F.Closure (l, caps) -> F.Closure (l, List.map a caps)
  | F.Capture i -> F.Capture i
  | F.Call (g, x) -> F.Call (a g, a x)
  | F.Prim (o, ats) -> F.Prim (o, List.map a ats)
  | F.Record fs -> F.Record (List.map (fun (l, x) -> (l, a x)) fs)
  | F.Con (k, x) -> F.Con (k, Option.map a x)
  | F.Field (x, l, i) -> F.Field (a x, l, i)
  | F.Payload x -> F.Payload (a x)

and sub_tail hit p c bound (t : F.tail) : F.tail =
  let a = sub_atom hit p c bound in
  match t with
  | F.Ret x -> F.Ret (a x)
  | F.TCall (g, x) -> F.TCall (a g, a x)
  | F.Jump (j, ats) -> F.Jump (j, List.map a ats)
  | F.Fail _ -> t
  | F.Switch (x, arms, d) ->
      F.Switch
        ( a x,
          List.map (fun (key, b) -> (key, sub_block hit p c bound b)) arms,
          Option.map (sub_block hit p c bound) d )

(* One round.  Constants reach further one function at a time -- a constant put
   into `f` can make the argument `f` passes to `g` constant too -- so the caller
   repeats this until a round changes nothing. *)
let round e (units : F.program list) =
  let f = { arg = Hashtbl.create 32; held = Hashtbl.create 32; clos = Hashtbl.create 32 } in
  List.iter
    (fun (p : F.program) ->
      List.iter
        (fun (c : F.code) -> facts_block f (SS.singleton c.F.c_param) SM.empty c.F.c_body)
        p.F.codes;
      List.iter
        (fun (i : F.item) -> Option.iter (facts_block f SS.empty SM.empty) i.F.ibody)
        p.F.items)
    units;
  (* What the parameter of each label may be replaced by.  Three things have to
     hold at once, and each one closes a different way in.  Nothing may hold the
     function except its call sites, or it could be called from somewhere this
     did not look.  Only one closure may exist over the label, or two different
     functions share the body.  And every call site has to agree. *)
  let fixed = Hashtbl.create 16 in
  Hashtbl.iter
    (fun g l ->
      if count f.held g = 0 && count f.clos l = 1 then
        match Hashtbl.find_opt f.arg g with
        | Some (Same a) when constant a -> Hashtbl.replace fixed l a
        | _ -> ())
    e.known;
  if Hashtbl.length fixed = 0 then None
  else
    let hit = ref false in
    let one (c : F.code) =
      match Hashtbl.find_opt fixed c.F.c_label with
      | Some a -> { c with F.c_body = sub_block hit c.F.c_param a SS.empty c.F.c_body }
      | None -> c
    in
    let units = List.map (fun (p : F.program) -> { p with F.codes = List.map one p.F.codes }) units in
    if !hit then Some units else None

let rec settle e units n =
  if n = 0 then units else match round e units with None -> units | Some u -> settle e u (n - 1)

(* ---- the pass ------------------------------------------------------------ *)

(* The two compilation units a program is made of: the basis, and the file.
   They are looked at together and rewritten together, because the file calls
   the basis and may rebind its names, which is what decides whether a global
   still holds the function it was defined with. *)
let program (basis : F.program) (file : F.program) =
  let e = analyse [ basis; file ] in
  let basis = rewrite e basis and file = rewrite e file in
  match settle e [ basis; file ] 4 with
  | [ basis; file ] -> (basis, file)
  | _ -> assert false
