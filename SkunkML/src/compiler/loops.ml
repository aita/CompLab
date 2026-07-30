(* Loops.

   There are none.  A join point can only jump outwards -- to a label defined
   further out than itself -- so a function's control-flow graph is a directed
   acyclic graph, and every loop in a SkunkML program is a tail call
   ([10章](../doc/10-ssa.md)).  Which means the loop optimisation that matters
   here is not one that improves a loop; it is the one that *makes* one.

   So this file has two halves.

   The first turns a self tail call into a jump.  `f` calling itself in tail
   position already costs no stack -- the frame is dropped before the jump
   ([13章](../doc/13-regalloc.md)) -- but it still goes through the closure: load
   the code address out of it, tear the frame down, jump indirectly, build the
   frame back up.  If the callee is known to be this same function, all of that
   is a jump to the top, and the parameter becomes a phi.  That is tail-recursion
   elimination, and it is where the CFG stops being acyclic.

   The second is loop-invariant code motion, which now has something to work on.
   A value inside a loop whose arguments all come from outside it computes the
   same thing every time round, so it belongs in the block before the loop.

   The two are in one file because the second only ever sees loops the first
   made. *)

module S = Ssa

(* ---- which globals are which functions ----------------------------------- *)

(* `fun f x = ...` becomes a code block plus a top-level binding whose body is
   nothing but `mkclos` for it.  So a global holds a known function when its
   item looks exactly like that -- and it has to capture nothing, or the closure
   this call reaches might not be the closure this code is running in. *)
let known (p : S.prog) =
  let t = Hashtbl.create 16 in
  List.iter
    (fun (i : S.item) ->
      match i.S.ibody with
      | Some f when i.S.iname <> "" -> (
          match (f.S.entry.S.values, f.S.entry.S.term) with
          | [ v ], S.Ret r when r == v -> (
              match v.S.op with
              | S.MkClos (label, 0) -> Hashtbl.replace t i.S.iname label
              | _ -> ())
          | _ -> ())
      | _ -> ())
    p.S.items;
  t

(* ---- self tail call to jump ---------------------------------------------- *)

let next_bid (f : S.func) =
  List.fold_left (fun m (b : S.block) -> max m (b.S.bid + 1)) 0 f.S.blocks

let next_vid (f : S.func) =
  List.fold_left
    (fun m (b : S.block) ->
      List.fold_left (fun m (v : S.value) -> max m (v.S.vid + 1)) m (b.S.phis @ b.S.values))
    0 f.S.blocks

(* Values that mean the same thing on every iteration and so belong above the
   loop: the parameter itself, and the constants and globals the builder put at
   the top of the entry block. *)
let invariant (v : S.value) =
  match v.S.op with S.Param | S.Const _ | S.Global _ -> true | _ -> false

let tailrec (f : S.func) (self : string list) =
  let calls =
    List.filter
      (fun (b : S.block) ->
        match b.S.term with
        | S.TailCall (g, _) -> (
            match g.S.op with S.Global n -> List.mem n self | _ -> false)
        | _ -> false)
      f.S.blocks
  in
  if calls = [] then false
  else begin
    let header = f.S.entry in
    (* The entry cannot be a loop header: a phi needs one argument per
       predecessor, and the argument that arrives from outside the function has
       no block to come from.  So a block is put in front to be that block. *)
    let pre =
      {
        S.bid = next_bid f;
        phis = [];
        values = [];
        term = S.Jump header;
        preds = [];
      }
    in
    let moved, stayed = List.partition invariant header.S.values in
    List.iter (fun (v : S.value) -> v.S.home <- pre) moved;
    pre.S.values <- moved;
    header.S.values <- stayed;
    let param = List.find_opt (fun (v : S.value) -> v.S.op = S.Param) moved in
    let preds = pre :: calls in
    let args = List.map (fun (b : S.block) ->
        match b.S.term with S.TailCall (_, a) -> a | _ -> assert false) calls in
    (match param with
    | None -> header.S.preds <- preds
    | Some p ->
        let phi =
          {
            S.vid = next_vid f;
            op = S.Phi;
            args = [];
            home = header;
            uses = 0;
            origin = p.S.origin;
          }
        in
        (* Every use of the parameter inside the loop becomes a use of the phi.
           The phi's own first argument is the exception, and it is set after the
           rewrite so that it cannot be caught by it. *)
        let swap (v : S.value) = if v == p then phi else v in
        List.iter
          (fun (b : S.block) ->
            List.iter
              (fun (v : S.value) -> v.S.args <- List.map swap v.S.args)
              (b.S.phis @ b.S.values);
            b.S.term <-
              (match b.S.term with
              | S.Ret v -> S.Ret (swap v)
              | S.TailCall (g, a) -> S.TailCall (swap g, swap a)
              | S.Switch (v, arms, d) -> S.Switch (swap v, arms, d)
              | t -> t))
          f.S.blocks;
        phi.S.args <- p :: List.map swap args;
        header.S.phis <- phi :: header.S.phis;
        header.S.preds <- preds);
    List.iter (fun (b : S.block) -> b.S.term <- S.Jump header) calls;
    f.S.blocks <- pre :: f.S.blocks;
    (* [Ssa.func] holds the entry block itself, so the record has to be rebuilt;
       everything else is mutable. *)
    true
  end

(* ---- loop-invariant code motion ------------------------------------------ *)

(* A back edge is one whose target dominates its source; the natural loop of that
   edge is the target plus everything that reaches the source without leaving
   through the target. *)
let loops (f : S.func) =
  let d = Dom.build f in
  let out = ref [] in
  List.iter
    (fun (b : S.block) ->
      List.iter
        (fun (h : S.block) ->
          if Dom.dominates d h b then begin
            let body = Hashtbl.create 8 in
            Hashtbl.replace body h.S.bid h;
            let rec up (x : S.block) =
              if not (Hashtbl.mem body x.S.bid) then begin
                Hashtbl.replace body x.S.bid x;
                List.iter up x.S.preds
              end
            in
            up b;
            out := (h, body) :: !out
          end)
        (S.succs b))
    f.S.blocks;
  !out

(* Pure, and not something whose failure is the point: hoisting a `div` out of a
   loop that never runs would make a program fail that did not. *)
let hoistable (v : S.value) = Opt.pure v && not (S.effectful v)

let licm (f : S.func) =
  let moved = ref 0 in
  List.iter
    (fun ((h : S.block), body) ->
      (* The block before the loop: the one predecessor of the header that is not
         in it.  If there is more than one, there is nowhere to hoist to. *)
      let outside =
        List.filter (fun (p : S.block) -> not (Hashtbl.mem body p.S.bid)) h.S.preds
      in
      match outside with
      | [ pre ] ->
          let inside (v : S.value) = Hashtbl.mem body v.S.home.S.bid in
          let go = ref true in
          while !go do
            go := false;
            Hashtbl.iter
              (fun _ (b : S.block) ->
                let stay, hoist =
                  List.partition
                    (fun (v : S.value) ->
                      not (hoistable v && List.for_all (fun a -> not (inside a)) v.S.args))
                    b.S.values
                in
                if hoist <> [] then begin
                  b.S.values <- stay;
                  List.iter (fun (v : S.value) -> v.S.home <- pre) hoist;
                  pre.S.values <- pre.S.values @ hoist;
                  moved := !moved + List.length hoist;
                  go := true
                end)
              body
          done
      | _ -> ())
    (loops f);
  !moved

(* ---- the pass ------------------------------------------------------------ *)

let program (p : S.prog) =
  let k = known p in
  (* Which globals name this code block.  Usually one, but a program can bind
     the same function twice. *)
  let names_of label =
    Hashtbl.fold (fun g l acc -> if l = label then g :: acc else acc) k []
  in
  let funcs =
    List.map
      (fun (f : S.func) ->
        let self = names_of f.S.fn in
        if self = [] then f
        else if tailrec f self then begin
          (* The entry moved, so the record is rebuilt around the new one. *)
          let pre = List.hd f.S.blocks in
          let g = { f with S.entry = pre } in
          ignore (licm g);
          S.recount g;
          S.renumber g;
          g
        end
        else f)
      p.S.funcs
  in
  { p with S.funcs }
