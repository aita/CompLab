(* A-normal form with join points, to SSA.

   Mostly a change of shape:

     a code block   ->  a function with an entry block
     a `let`        ->  a value appended to the block being filled
     a `join`       ->  a new block, whose parameters become phi values
     a `jump`       ->  a terminator, and one argument appended to each phi
     a `switch`     ->  a terminator, and one new block per branch

   Phi arguments are collected as the jumps are met, which is why a `join`
   converts its continuation before its body: the jumps are in the
   continuation.

   Two places are not a plain rewriting.

   Flat's operands are atoms -- a name, or a literal written in place.  Here
   everything is a value, so a literal becomes a `Const` value.  They are
   hash-consed into the entry block, which dominates everything, so one
   occurrence of `0` in a program is one value however many blocks use it.

   And a recursive group defines closures that hold each other, which SSA
   cannot express: there is no order in which to write a cycle of definitions.
   So a closure is allocated first and filled in afterwards.  That is what the
   machine did at run time anyway; here it is forced by the form. *)

module F = Flat
module S = Ssa
module Map = Map.Make (String)

type state = {
  mutable next_value : int;
  mutable next_block : int;
  mutable blocks : S.block list; (* newest first *)
  (* Flat's binders are unique, so one table per function is enough and
     nothing is ever shadowed. *)
  mutable names : S.value Map.t;
  mutable joins : (string * S.block) list;
  (* The parameter, which lives at the top of the entry block.  Nothing else
     does: a constant is defined in the block that uses it. *)
  mutable head : S.value list;
  globals : (string, unit) Hashtbl.t;
}

let new_block st =
  let b =
    { S.bid = st.next_block; phis = []; values = []; term = S.Fail (Loc.unknown, "?"); preds = [] }
  in
  st.next_block <- st.next_block + 1;
  st.blocks <- b :: st.blocks;
  b

let mk st ?(origin = "") ?(args = []) home op =
  let v = { S.vid = st.next_value; op; args; home; uses = 0; origin } in
  st.next_value <- st.next_value + 1;
  v

(* A value that belongs to a block, appended in order. *)
let emit st ?(origin = "") ?(args = []) (b : S.block) op =
  let v = mk st ~origin ~args b op in
  b.S.values <- b.S.values @ [ v ];
  v

(* A value that belongs at the top of the entry block: parameters and
   constants.  The entry dominates every block, so one of these can be used
   from anywhere. *)
let emit_head st ?(origin = "") entry op =
  let v = mk st ~origin entry op in
  st.head <- st.head @ [ v ];
  v

(* A constant is defined in the block that uses it.  Putting them all at the top
   of the entry block would also be correct -- the entry dominates everything --
   but it is not what the program says, and it costs: a string constant is the
   address of a static block, so it is an instruction, and hoisting it makes the
   arm that does not want it pay for it anyway.

   Sharing within the block is free, because a definition there dominates every
   later use in it.  Sharing *across* blocks is what [16章] gvn is for, and it
   knows where dominance allows it; this pass does not have to guess. *)
let constant st (blk : S.block) (c : S.const) =
  let same v = match v.S.op with S.Const c' -> c' = c | _ -> false in
  match List.find_opt same blk.S.values with
  | Some v -> v
  | None -> emit st blk (S.Const c)

let global st (blk : S.block) name =
  let same v = match v.S.op with S.Global g -> g = name | _ -> false in
  match List.find_opt same blk.S.values with
  | Some v -> v
  | None -> emit st blk (S.Global name)

(* A structure the front end declares and `stubs.ml` does not provide.  That is
   what `Real` and `Math` are until the back end has a representation for
   `real`, and it has to be caught here: the name is a global like any other, so
   without this it would become a word nobody ever fills in and the program
   would call through a null pointer instead of failing to compile. *)
let unstubbed x =
  List.mem_assoc x Basis.structures && not (List.mem_assoc x Stubs.structures)

let atom st blk : F.atom -> S.value = function
  (* A local binding first: a top-level `val x = ...` binds `x` locally inside
     its own body before it becomes the global of that name, and the local is
     what the body means. *)
  | F.AVar x -> (
      match Map.find_opt x st.names with
      | Some v -> v
      | None ->
          if unstubbed x then
            failwith
              ("build: " ^ x
             ^ " is not compiled yet -- the back end has no representation for real \
                (see doc/18-abi.md)")
          else if Hashtbl.mem st.globals x then global st blk x
          else failwith ("build: unbound " ^ x))
  | F.AInt n -> constant st blk (S.CInt n)
  (* A real does not fit in an SSA constant, because `Ssa.const` is an int, a
     string or unit, and a tagged word cannot hold a double.  Deciding what it
     should be is the back end's next piece of work (doc/18-abi.md), so until
     then say so instead of guessing. *)
  | F.AReal _ ->
      failwith
        "build: real is not compiled yet -- the value representation has no real \
         (see doc/18-abi.md)"
  | F.AStr s -> constant st blk (S.CStr s)
  | F.AUnit -> constant st blk S.CUnit

let bind st x v = st.names <- Map.add x v st.names

(* The operation a Flat right-hand side becomes, and the values it uses.  They
   are two functions because the operation is a property of the syntax and the
   arguments have to be looked up. *)
let op_of (r : F.rhs) : S.op =
  match r with
  | F.Atom _ | F.Closure _ -> assert false (* handled where they are bound *)
  | F.Capture i -> S.Capture i
  | F.Call _ -> S.Call
  | F.Prim (p, _) -> S.Prim p
  | F.Record fs -> S.Record (List.map fst fs)
  | F.Con (c, _) -> S.Con c
  | F.Field (_, l, i) -> S.Field (l, i)
  | F.Payload _ -> S.Payload

let args_of st blk (r : F.rhs) =
  let a x = atom st blk x in
  match r with
  | F.Atom _ | F.Closure _ | F.Capture _ | F.Con (_, None) -> []
  | F.Call (f, x) -> [ a f; a x ]
  | F.Prim (_, ats) -> List.map a ats
  | F.Record fs -> List.map (fun (_, x) -> a x) fs
  | F.Con (_, Some x) | F.Field (x, _, _) | F.Payload x -> [ a x ]

let goto (from : S.block) (target : S.block) args =
  target.S.preds <- target.S.preds @ [ from ];
  List.iter2 (fun (p : S.value) a -> p.S.args <- p.S.args @ [ a ]) target.S.phis args;
  from.S.term <- S.Jump target

let rec go st entry (blk : S.block) (b : F.block) =
  let atom a = atom st blk a in
  match b with
  | F.Let (x, r, rest) ->
      (match r with
      | F.Closure (l, caps) ->
          let c = emit st ~origin:x blk (S.MkClos (l, List.length caps)) in
          bind st x c;
          List.iteri
            (fun i a -> ignore (emit st ~args:[ c; atom a ] blk (S.SetCap i)))
            caps
      | F.Atom a -> bind st x (atom a)
      | _ ->
          let args = args_of st blk r in
          bind st x (emit st ~origin:x ~args blk (op_of r)));
      go st entry blk rest
  | F.Fix (defs, rest) ->
      (* Every closure of the group exists before any capture is written. *)
      List.iter
        (fun (name, r) ->
          match r with
          | F.Closure (l, caps) ->
              bind st name (emit st ~origin:name blk (S.MkClos (l, List.length caps)))
          | _ -> failwith "build: a fix binding must be a closure")
        defs;
      List.iter
        (fun (name, r) ->
          match r with
          | F.Closure (_, caps) ->
              let c = Map.find name st.names in
              List.iteri
                (fun i a -> ignore (emit st ~args:[ c; atom a ] blk (S.SetCap i)))
                caps
          | _ -> ())
        defs;
      go st entry blk rest
  | F.Join (j, ps, body, rest) ->
      let jb = new_block st in
      jb.S.phis <- List.map (fun p -> mk st ~origin:p jb S.Phi) ps;
      List.iter2 (fun p v -> bind st p v) ps jb.S.phis;
      st.joins <- (j, jb) :: st.joins;
      (* The jumps are in the continuation, so it is converted first: by the
         time the body is reached, the phis know their arguments. *)
      go st entry blk rest;
      go st entry jb body
  | F.Tail t -> (
      match t with
      | F.Ret a -> blk.S.term <- S.Ret (atom a)
      | F.TCall (f, a) -> blk.S.term <- S.TailCall (atom f, atom a)
      | F.Fail (loc, m) -> blk.S.term <- S.Fail (loc, m)
      | F.Jump (j, args) -> (
          match List.assoc_opt j st.joins with
          | Some jb -> goto blk jb (List.map atom args)
          | None -> failwith ("build: no join point " ^ j))
      | F.Switch (a, arms, dflt) ->
          let scrutinee = atom a in
          let branch body =
            let nb = new_block st in
            nb.S.preds <- [ blk ];
            go st entry nb body;
            nb
          in
          let arms = List.map (fun (k, body) -> (k, branch body)) arms in
          let dflt = Option.map branch dflt in
          blk.S.term <- S.Switch (scrutinee, arms, dflt))

let func globals name (param : string option) body =
  let st =
    {
      next_value = 0;
      next_block = 0;
      blocks = [];
      names = Map.empty;
      joins = [];
      head = [];
      globals;
    }
  in
  let entry = new_block st in
  (match param with
  | None -> ()
  | Some p -> bind st p (emit_head st ~origin:p entry S.Param));
  go st entry entry body;
  entry.S.values <- st.head @ entry.S.values;
  let f = { S.fn = name; entry; blocks = List.rev st.blocks } in
  S.renumber f;
  S.recount f;
  f

let program (globals : string list) (p : F.program) : S.prog =
  let tbl = Hashtbl.create 64 in
  List.iter (fun g -> Hashtbl.replace tbl g ()) globals;
  let funcs =
    List.map
      (fun (c : F.code) -> func tbl c.F.c_label (Some c.F.c_param) c.F.c_body)
      p.F.codes
  in
  let items =
    List.map
      (fun (i : F.item) ->
        {
          S.iname = i.F.iname;
          ibody = Option.map (fun b -> func tbl ("$" ^ i.F.iname) None b) i.F.ibody;
          ilabel = i.F.ilabel;
          ishow = i.F.ishow;
        })
      p.F.items
  in
  { S.funcs; items }
