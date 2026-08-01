(* Optimisation on SSA.

   Five small passes run to a fixed point.  Each is cheap because SSA makes it
   cheap: a register has one definition, so constant folding and copy propagation
   are a lookup rather than a dataflow problem, and a phi whose arguments all
   agree is a copy that was never needed.

   {v
   fold constants   ->  arithmetic on known values
   propagate copies ->  Move, and phis that turned into one
   simplify phis    ->  a phi with one distinct argument is that argument
   fold branches    ->  a branch on a known value, and the blocks it strands
   dead code        ->  anything computed and not used
   v} *)

open Ir

(* -- rewriting -------------------------------------------------------------- *)

(* Replace registers everywhere they are read, phi arguments included. *)
let rewrite f mapping =
  if not (IntMap.is_empty mapping) then begin
    let resolve r =
      let seen = ref IntSet.empty in
      let at = ref r in
      let go = ref true in
      while !go do
        match IntMap.find_opt !at mapping with
        | Some next when not (IntSet.mem !at !seen) ->
            seen := IntSet.add !at !seen;
            at := next
        | _ -> go := false
      done;
      !at
    in
    iter_blocks f (fun b ->
        List.iter (fun phi -> List.iter (fun a -> a.arg <- resolve a.arg) phi.args) b.phis;
        iter_instrs b (map_uses resolve))
  end

let constants f =
  let known = ref IntMap.empty in
  iter_blocks f (fun b ->
      iter_instrs b (function
        | Const c -> known := IntMap.add c.dst c.value !known
        | _ -> ()));
  !known

(* The language's arithmetic, in the 64 bits it is done in.

   [Int64] already wraps, and [div] and [rem] already truncate towards zero the
   way [sdiv] does, [min_int / -1] included.  The shifts are the only ones that
   need saying, because OCaml leaves a shift of 64 or more undefined and the
   language does not. *)
let arith op a b =
  match op with
  | "+" -> Some (Int64.add a b)
  | "-" -> Some (Int64.sub a b)
  | "*" -> Some (Int64.mul a b)
  | "/" -> if b = 0L then None else Some (Int64.div a b)
  | "mod" -> if b = 0L then None else Some (Int64.rem a b)
  | "and" -> Some (Int64.logand a b)
  | "or" -> Some (Int64.logor a b)
  | "xor" -> Some (Int64.logxor a b)
  | "shl" ->
      if b < 0L then None
      else if b >= 64L then Some 0L
      else Some (Int64.shift_left a (Int64.to_int b))
  | "shr" ->
      if b < 0L then None
      else if b >= 64L then Some (if a < 0L then -1L else 0L)
      else Some (Int64.shift_right a (Int64.to_int b))
  | _ -> None

let order op a b =
  match op with
  | "=" -> a = b
  | "<>" -> a <> b
  | "<" -> a < b
  | "<=" -> a <= b
  | ">" -> a > b
  | ">=" -> a >= b
  | "u<" -> Int64.unsigned_compare a b < 0
  | "u>=" -> Int64.unsigned_compare a b >= 0
  | _ -> failwith ("unknown comparison " ^ op)

let fold instr known =
  let value r = IntMap.find_opt r known in
  match instr with
  | Bin b -> (
      match (value b.lhs, value b.rhs) with
      | Some a, Some c -> (
          match arith b.op a c with
          | Some v -> Some (Const { dst = b.dst; value = v })
          | None -> None)
      | _, Some 0L when List.mem b.op [ "+"; "-"; "or"; "xor"; "shl"; "shr" ] ->
          Some (Move { dst = b.dst; src = b.lhs })
      | _, Some 1L when List.mem b.op [ "*"; "/" ] -> Some (Move { dst = b.dst; src = b.lhs })
      | Some 0L, _ when b.op = "+" -> Some (Move { dst = b.dst; src = b.rhs })
      | _ -> None)
  | Cmp c -> (
      match (value c.lhs, value c.rhs) with
      | Some a, Some b ->
          Some (Const { dst = c.dst; value = (if order c.op a b then 1L else 0L) })
      | _ -> None)
  | _ -> None

(* -- the passes ------------------------------------------------------------- *)

let fold_constants f =
  let known = ref (constants f) in
  let changed = ref false in
  iter_blocks f (fun b ->
      for at = 0 to count b - 1 do
        match fold (nth b at) !known with
        | None -> ()
        | Some folded ->
            Dynarray.set b.instrs at folded;
            (match folded with
            | Const c -> known := IntMap.add c.dst c.value !known
            | _ -> ());
            changed := true
      done);
  !changed

let propagate_copies f =
  let mapping = ref IntMap.empty in
  iter_blocks f (fun b ->
      iter_instrs b (function
        | Move mv -> mapping := IntMap.add mv.dst mv.src !mapping
        | _ -> ()));
  let mapping = !mapping in
  if IntMap.is_empty mapping then false
  else begin
    rewrite f mapping;
    List.iter
      (fun b ->
        set_instrs b (List.filter (function Move _ -> false | _ -> true) (instrs b)))
      (walk f);
    true
  end

let simplify_phis f =
  let mapping = ref IntMap.empty in
  let changed = ref false in
  List.iter
    (fun b ->
      let keep =
        List.filter
          (fun phi ->
            let others =
              List.fold_left
                (fun acc a -> if a.arg <> phi.phi_dst then IntSet.add a.arg acc else acc)
                IntSet.empty phi.args
            in
            if IntSet.cardinal others = 1 then begin
              mapping := IntMap.add phi.phi_dst (IntSet.choose others) !mapping;
              changed := true;
              false
            end
            else true)
          b.phis
      in
      b.phis <- keep)
    (walk f);
  if !changed then rewrite f !mapping;
  !changed

let fold_branches f =
  let known = constants f in
  let changed = ref false in
  List.iter
    (fun b ->
      match terminator b with
      | Cbr c -> (
          let value = IntMap.find_opt c.cond known in
          match value with
          | None when c.then_ <> c.else_ -> ()
          | _ ->
              let taken =
                match value with Some 0L -> c.else_ | _ -> c.then_
              in
              Dynarray.set b.instrs (count b - 1) (Jmp { target = taken });
              changed := true)
      | _ -> ())
    (walk f);
  if !changed then drop_unreachable f;
  !changed

let dead_code f =
  let changed = ref false in
  let round_changed = ref true in
  while !round_changed do
    round_changed := false;
    let used = ref IntSet.empty in
    iter_blocks f (fun b ->
        List.iter (fun phi -> List.iter (fun a -> used := IntSet.add a.arg !used) phi.args) b.phis;
        iter_instrs b (fun instr -> List.iter (fun r -> used := IntSet.add r !used) (uses instr)));
    List.iter
      (fun b ->
        let phis = List.filter (fun phi -> IntSet.mem phi.phi_dst !used) b.phis in
        if List.length phis <> List.length b.phis then begin
          b.phis <- phis;
          round_changed := true
        end;
        let kept =
          List.filter
            (fun instr ->
              let d = defs instr in
              if d <> no_reg && (not (IntSet.mem d !used)) && not (has_effect instr) then begin
                round_changed := true;
                false
              end
              else true)
            (instrs b)
        in
        set_instrs b kept)
      (walk f);
    if !round_changed then changed := true
  done;
  !changed

let optimise_func f =
  let passes = [ fold_constants; propagate_copies; simplify_phis; fold_branches; dead_code ] in
  let go = ref true in
  while !go do
    (* Every pass runs every round: they are cheap, and one enables another. *)
    let changes = Util.map_in_order (fun run -> run f) passes in
    if not (List.exists (fun c -> c) changes) then go := false
  done

let optimise m = List.iter optimise_func m.funcs
