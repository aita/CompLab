(* Graph -> IR.
   Data ports are pulled on demand: asking for the value of an input port
   walks backwards through the data edges and builds an expression tree.
   Exec ports are pushed: the walk starts at the start node and follows the
   exec edges forward, turning each node it meets into a statement.

   There is no assignment in the graph language. A value either comes from an
   edge or from a loop's own state, and the only node that owns state is the
   loop: it declares named slots, takes an initial value and a next value for
   each, and offers the current value as an output. So the loop node is the
   phi, written down. Everything the lowering emits below -- the assignments,
   the temporaries -- exists only in the IR.

   A node whose output feeds several inputs is computed once, into a local,
   because with no way to name an intermediate value in the graph, feeding one
   output into many places is how you are meant to work: expanding it at every
   use doubles the code at every level, and a chain twenty deep would not
   finish. See [share] below for what makes that safe.  It also settles what a
   random node means when it is read twice: the node is the value, so one draw
   reaches every reader of it.

   Numbers are typed as they are lowered.  A literal that is whole is an i64,
   and so is anything built only out of those; everything else is an f64.  A
   loop's slot cannot be typed by looking at it once -- its next value reads
   the slot -- so the whole lowering is its own fixpoint: it starts by
   assuming every slot is whole, and runs again whenever that turns out to be
   too narrow.  Assumptions only ever loosen, so it settles. *)

open Ir

type ctx = {
  g : Graph.t;
  slots : (string, int) Hashtbl.t;  (* internal key -> local index *)
  used : (string, unit) Hashtbl.t;  (* display names already taken *)
  fanout : (string, int) Hashtbl.t;  (* "node\000port" -> how many edges leave *)
  mutable params : string list;
  mutable vars : (string * vtype) list;
  mutable errs : Graph.error list;  (* collected, reported all at once *)
  active : (string, unit) Hashtbl.t;  (* data nodes on the current path *)
  entered : (string, unit) Hashtbl.t;  (* exec nodes already emitted *)
  (* the group being lowered: what it has already computed, and the
     assignments that have to run before it *)
  mutable shared : (string, int * vtype) Hashtbl.t;
  mutable prelude : stmt list;  (* reversed *)
  mutable temps : int;
  (* Every breakpoint the lowering has planted, in the order the module's
     watch indices run; the editor turns these back into node highlights. *)
  mutable watches : (string * string) list;  (* reversed: node id, label *)
  slot_ty : (string, vtype) Hashtbl.t;  (* loop slot key -> assumed type *)
  mutable too_narrow : bool;  (* an assumption did not survive this pass *)
}

let complain ctx ?node fmt =
  Printf.ksprintf
    (fun s ->
      let e = Graph.error ?node s in
      (* A name declared twice asks the same question twice; say it once. *)
      if not (List.mem e ctx.errs) then ctx.errs <- e :: ctx.errs)
    fmt

(* Two loops may both call a slot "i"; the graph tells them apart by node id,
   but the IR dump and the wat need distinct names. *)
let fresh_display ctx name =
  let ok c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c = '_'
  in
  let name = String.map (fun c -> if ok c then c else '_') name in
  let name = if name = "" then "t" else name in
  let rec pick n =
    let candidate = if n = 1 then name else Printf.sprintf "%s_%d" name n in
    if Hashtbl.mem ctx.used candidate then pick (n + 1)
    else (
      Hashtbl.replace ctx.used candidate ();
      candidate)
  in
  pick 1

let slot ctx ~key ~display ~ty =
  match Hashtbl.find_opt ctx.slots key with
  | Some i -> i
  | None ->
      let i = Hashtbl.length ctx.slots in
      Hashtbl.replace ctx.slots key i;
      ctx.vars <- ctx.vars @ [ (fresh_display ctx display, ty) ];
      i

(* Plant a breakpoint and hand back the index the module will report it by. *)
let watch_point ctx ~node ~label =
  ctx.watches <- (node, label) :: ctx.watches;
  List.length ctx.watches - 1

let slot_key (n : Graph.node) name = n.id ^ "\000" ^ name

let assumed ctx key =
  Option.value (Hashtbl.find_opt ctx.slot_ty key) ~default:VInt

let state_slot ctx (n : Graph.node) name =
  let key = slot_key n name in
  slot ctx ~key ~display:name ~ty:(assumed ctx key)

(* A group is one place in the emitted code where a set of expressions is
   evaluated together: a statement, a loop's condition, a loop's whole set of
   next values.  Sharing is scoped to a group, and the assignments it hoists
   run at the head of it -- which is only sound because a group never writes a
   local that its own expressions read.  Between groups nothing is shared, so
   a value read on either side of an update is read twice, as it must be. *)
let group ctx f =
  let outer_shared = ctx.shared and outer_prelude = ctx.prelude in
  ctx.shared <- Hashtbl.create 8;
  ctx.prelude <- [];
  let result = f () in
  let pre = List.rev ctx.prelude in
  ctx.shared <- outer_shared;
  ctx.prelude <- outer_prelude;
  (pre, result)

(* ------------------------------------------------------------- numbers *)

(* An i64 covers this and more exactly; past it a literal stays an f64. *)
let whole_limit = 4_611_686_018_427_387_904.

let literal x =
  if Float.is_integer x && Float.abs x < whole_limit then
    (Int (int_of_float x), VInt)
  else (Num x, VFloat)

let widen = function
  | Int n, _ -> (Num (float_of_int n), VFloat)
  | e, VInt -> (Widen e, VFloat)
  | e, _ -> (e, VFloat)

let as_float p = fst (widen p)

(* Give two numbers a type they share, which is only ever done by widening. *)
let unify a b =
  match (snd a, snd b) with
  | ta, tb when ta = tb -> (fst a, fst b, ta)
  | VInt, _ -> (as_float a, fst b, VFloat)
  | _, VInt -> (fst a, as_float b, VFloat)
  | _ -> (fst a, fst b, VFloat)

(* Narrowing never happens in a settled pass: reaching it means a loop slot
   was assumed to be whole and is not, so this pass is about to be thrown
   away and what it emits does not matter. *)
let coerce ctx (e, ty) want =
  if ty = want then e
  else if ty = VInt then as_float (e, ty)
  else (
    ctx.too_narrow <- true;
    Int 0)

(* ------------------------------------------------------- declared names *)

let name_of_entry = function
  | `String s -> Some s
  | `Assoc _ as j -> (
      match Graph.member "name" j with `String s -> Some s | _ -> None)
  | _ -> None

let declared_names (n : Graph.node) key =
  match Graph.node_data n key with
  | `List items ->
      List.filter_map
        (fun j -> match name_of_entry j with Some "" | None -> None | s -> s)
        items
  | _ -> []

let check_names ctx (n : Graph.node) key what =
  let items =
    match Graph.node_data n key with
    | `List items -> items
    | `Null -> []
    | _ ->
        complain ctx ~node:n.id "the %s of this node are not a list" what;
        []
  in
  let seen = Hashtbl.create 8 in
  List.iter
    (fun j ->
      match name_of_entry j with
      | Some "" | None -> complain ctx ~node:n.id "one of the %s has no name" what
      | Some s ->
          if Hashtbl.mem seen s then
            complain ctx ~node:n.id "%s is declared twice" s
          else Hashtbl.replace seen s ())
    items

(* ---------------------------------------------------------------- data *)

let binop_of_string = function
  | "add" -> Some Add
  | "sub" -> Some Sub
  | "mul" -> Some Mul
  | "div" -> Some Div
  | "mod" -> Some Mod
  | "min" -> Some Min
  | "max" -> Some Max
  | _ -> None

let unop_of_string = function
  | "neg" -> Some Neg
  | "abs" -> Some Abs
  | "sqrt" -> Some Sqrt
  | "floor" -> Some Floor
  | "ceil" -> Some Ceil
  | "round" -> Some Round
  | _ -> None

let cmpop_of_string = function
  | "lt" -> Some Lt
  | "le" -> Some Le
  | "gt" -> Some Gt
  | "ge" -> Some Ge
  | "eq" -> Some Eq
  | "ne" -> Some Ne
  | _ -> None

let after_colon port =
  match String.index_opt port ':' with
  | Some i -> String.sub port (i + 1) (String.length port - i - 1)
  | None -> port

let untrue = Cmp (Ne, Int 0, Int 0)

let rec value ctx (e : Graph.edge) : expr * vtype =
  let key = e.src ^ "\000" ^ e.src_port in
  match Hashtbl.find_opt ctx.shared key with
  | Some (i, ty) -> (Local i, ty)
  | None ->
      let n = Graph.find ctx.g e.src in
      if Hashtbl.mem ctx.active n.id then (
        complain ctx ~node:n.id "this node's value depends on itself";
        (Int 0, VInt))
      else (
        Hashtbl.replace ctx.active n.id ();
        let built = value_of ctx n e.src_port in
        Hashtbl.remove ctx.active n.id;
        share ctx ~key ~from:n (watched ctx n built))

and share ctx ~key ~from (expr, ty) =
  let uses = Option.value (Hashtbl.find_opt ctx.fanout key) ~default:1 in
  match expr with
  | Local _ | Num _ | Int _ -> (expr, ty) (* already as cheap as a local read *)
  | _ when uses < 2 -> (expr, ty)
  | _ ->
      ctx.temps <- ctx.temps + 1;
      let i =
        slot ctx
          ~key:(Printf.sprintf "\002%d" ctx.temps)
          ~display:(from.Graph.id ^ "_value") ~ty
      in
      ctx.prelude <- Assign (i, expr) :: ctx.prelude;
      Hashtbl.replace ctx.shared key (i, ty);
      (Local i, ty)

(* A breakpoint wraps the value where it is computed, which -- because a node
   feeding several inputs is computed once -- means one hit per evaluation
   rather than one per reader. *)
and watched ctx (n : Graph.node) (expr, ty) =
  (* A loop reports its whole state once per iteration, from the top of the
     loop, rather than every time a slot is read; the start node has nothing
     to report that its caller does not already know. *)
  if n.kind = "while" || n.kind = "for" || n.kind = "start"
     || not (Graph.flag n "breakpoint")
  then (expr, ty)
  else
    let i = watch_point ctx ~node:n.id ~label:"value" in
    (Watch (i, ty, expr), ty)

and value_of ctx (n : Graph.node) port : expr * vtype =
  let bad fmt = Printf.ksprintf (fun s -> complain ctx ~node:n.id "%s" s) fmt in
  match n.kind with
  | "start" ->
      (* Whatever the host passes in arrives as an f64. *)
      let name = after_colon port in
      if List.mem name ctx.params then
        (Local (slot ctx ~key:("\001" ^ name) ~display:name ~ty:VFloat), VFloat)
      else (
        bad "the start node has no input called %s" name;
        (Int 0, VInt))
  | "while" ->
      (* Reading a loop's state stops the backward walk: the value is a local,
         so the cond and the next-value expressions may name it without that
         being a cycle. *)
      let name = after_colon port in
      if List.mem name (declared_names n "states") then
        (Local (state_slot ctx n name), assumed ctx (slot_key n name))
      else (
        bad "this loop has no state called %s" name;
        (Int 0, VInt))
  | "for" ->
      (* The counter has a port of its own; the state slots are named. *)
      let name =
        if port = "i" then Graph.string_field n "name" ~default:"i"
        else after_colon port
      in
      if port = "i" || List.mem name (declared_names n "states") then
        (Local (state_slot ctx n name), assumed ctx (slot_key n name))
      else (
        bad "this loop has no state called %s" name;
        (Int 0, VInt))
  | "const" -> literal (Graph.number_field n "value" ~default:0.)
  | "binop" -> (
      let op = Graph.string_field n "op" ~default:"add" in
      match binop_of_string op with
      | None ->
          bad "unknown arithmetic operator %s" op;
          (Int 0, VInt)
      | Some ((Div | Min | Max) as op) ->
          (* A quotient is not whole even when both ends are, and wasm has no
             i64 minimum or maximum to reach for. *)
          let a = number ctx n "a" in
          let b = number ctx n "b" in
          (Bin (op, as_float a, as_float b), VFloat)
      | Some op ->
          let a = number ctx n "a" in
          let b = number ctx n "b" in
          let a, b, ty = unify a b in
          (Bin (op, a, b), ty))
  | "unop" -> (
      let op = Graph.string_field n "op" ~default:"neg" in
      match unop_of_string op with
      | None ->
          bad "unknown operator %s" op;
          (Int 0, VInt)
      | Some ((Neg | Abs) as op) ->
          let a, ty = number ctx n "a" in
          (Un (op, a), ty)
      | Some op -> (Un (op, as_float (number ctx n "a")), VFloat))
  | "compare" -> (
      let op = Graph.string_field n "op" ~default:"lt" in
      match cmpop_of_string op with
      | None ->
          bad "unknown comparison %s" op;
          (untrue, VBool)
      | Some op ->
          let a = number ctx n "a" in
          let b = number ctx n "b" in
          let a, b, _ = unify a b in
          (Cmp (op, a, b), VBool))
  | "logic" -> (
      match Graph.string_field n "op" ~default:"and" with
      | "not" -> (Not (condition ctx n "a"), VBool)
      | "or" ->
          let a = condition ctx n "a" in
          let b = condition ctx n "b" in
          (Or (a, b), VBool)
      | "and" ->
          let a = condition ctx n "a" in
          let b = condition ctx n "b" in
          (And (a, b), VBool)
      | op ->
          bad "unknown logical operator %s" op;
          (untrue, VBool))
  | "select" ->
      let c = condition ctx n "cond" in
      let a = number ctx n "a" in
      let b = number ctx n "b" in
      let a, b, ty = unify a b in
      (Select (c, a, b), ty)
  | "random" ->
      let lo = as_float (number ctx n "min") in
      let hi = as_float (number ctx n "max") in
      (Rand (lo, hi), VFloat)
  | kind ->
      bad "the %s node produces no value" kind;
      (Int 0, VInt)

(* An input port takes an edge or, failing that, a number typed into it. *)
and number ctx (n : Graph.node) port : expr * vtype =
  match Graph.into ctx.g ~node:n.id ~port with
  | None -> (
      match Graph.port_value n port with
      | Some x -> literal x
      | None ->
          complain ctx ~node:n.id "the %s input is not connected" port;
          (Int 0, VInt))
  | Some e ->
      let expr, ty = value ctx e in
      if is_num ty then (expr, ty)
      else (
        complain ctx ~node:n.id "the %s input wants a number but is given a %s"
          port (type_name ty);
        (Int 0, VInt))

and condition ctx (n : Graph.node) port : expr =
  match Graph.into ctx.g ~node:n.id ~port with
  | None ->
      complain ctx ~node:n.id "the %s input is not connected" port;
      untrue
  | Some e ->
      let expr, ty = value ctx e in
      if ty = VBool then expr
      else (
        complain ctx ~node:n.id
          "the %s input wants a true or false but is given a %s" port
          (type_name ty);
        untrue)

(* ---------------------------------------------------------------- exec *)

let rec chain ctx (from : Graph.node) port : block =
  match Graph.out_of ctx.g ~node:from.id ~port with
  | None -> []
  | Some e ->
      let n = Graph.find ctx.g e.dst in
      if Hashtbl.mem ctx.entered n.id then (
        complain ctx ~node:n.id
          "two chains run into this node; a node belongs to one chain";
        [])
      else (
        Hashtbl.replace ctx.entered n.id ();
        step ctx n)

and step ctx (n : Graph.node) : block =
  match n.kind with
  | "log" ->
      let pre, v = group ctx (fun () -> reported ctx n (number ctx n "value")) in
      let rest = chain ctx n "next" in
      (pre @ [ Log v ]) @ rest
  | "end" ->
      let pre, v = group ctx (fun () -> reported ctx n (number ctx n "value")) in
      pre @ [ Ret v ]
  | "while" -> loop ctx n
  | "for" -> counted ctx n
  | kind ->
      complain ctx ~node:n.id "the %s node cannot be part of the flow" kind;
      chain ctx n "next"

(* The host takes f64s, so what log and end hand over is widened -- after the
   breakpoint, which reports the value in the type it was worked out in. *)
and reported ctx (n : Graph.node) v = as_float (watched ctx n v)

and loop ctx (n : Graph.node) : block =
  check_names ctx n "states" "loop states";
  (* A plain loop's condition is whatever is plugged into it. *)
  carry ctx n (declared_names n "states") (fun _ ->
      condition ctx n "cond")

(* A counted loop is the same machine with one slot the node owns: the
   counter starts at [from], gains [by] every pass along with everything else,
   and the condition is written for you.  Accumulators go in the state slots
   beside it, because a count with nothing to add up is rarely the point. *)
and counted ctx (n : Graph.node) : block =
  check_names ctx n "states" "loop states";
  let name = Graph.string_field n "name" ~default:"i" in
  if name = "" then complain ctx ~node:n.id "the counter has no name";
  if List.mem name (declared_names n "states") then
    complain ctx ~node:n.id "%s is both the counter and a state slot" name;
  carry ctx n (name :: declared_names n "states") (fun slots ->
      match slots with
      | (i, ty) :: _ -> counter_test ctx n (Local i, ty)
      | [] -> untrue)

(* Keep going while the counter has not passed [to].  Which way that is
   depends on the sign of the step, and when the step is a literal -- which it
   nearly always is -- the compiler knows it and the loop tests one thing.  A
   computed step falls back to a form that reads the same either way:
   (i - to) * by is at most zero exactly while the counter is on the near side
   of the end. *)
and counter_test ctx (n : Graph.node) cur =
  let bound = number ctx n "to" in
  let by = number ctx n "by" in
  let compare op =
    let a, b, _ = unify cur bound in
    Cmp (op, a, b)
  in
  match by with
  | Int k, _ -> compare (if k >= 0 then Le else Ge)
  | Num x, _ -> compare (if x >= 0. then Le else Ge)
  | _ ->
      let a, b, t = unify cur bound in
      let gap, step, t = unify (Bin (Sub, a, b), t) by in
      Cmp (Le, Bin (Mul, gap, step), if t = VInt then Int 0 else Num 0.)

(* The shared part: slots that all move together at the end of each pass. *)
and carry ctx (n : Graph.node) names cond_of : block =
  (* The slots come first so that the condition and the next-value
     expressions, which read them, resolve to locals rather than recursing. *)
  let slots = List.map (fun s -> state_slot ctx n s) names in
  let types = List.map (fun s -> assumed ctx (slot_key n s)) names in
  let counted = n.kind = "for" in
  (* The counter's ends belong to the node rather than to a named port. *)
  let init_of s = if counted && s == List.hd names then "from" else "init:" ^ s in
  let next_of i s ty =
    if counted && s == List.hd names then
      let a, b, t = unify (Local i, ty) (number ctx n "by") in
      (Bin (Add, a, b), t)
    else number ctx n ("step:" ^ s)
  in
  (* One group per initial value: the group's own assignment writes a state
     slot, which a later initial value is allowed to read. *)
  let inits =
    List.concat
      (List.map2
         (fun i (s, want) ->
           let pre, v = group ctx (fun () -> number ctx n (init_of s)) in
           note_type ctx n s (snd v);
           pre @ [ Assign (i, coerce ctx v want) ])
         slots
         (List.combine names types))
  in
  let watching =
    if Graph.flag n "breakpoint" then
      List.map2
        (fun name (i, ty) ->
          Drop (Watch (watch_point ctx ~node:n.id ~label:name, ty, Local i)))
        names
        (List.combine slots types)
    else []
  in
  let pre_cond, cond =
    group ctx (fun () -> cond_of (List.combine slots types))
  in
  let body = chain ctx n "body" in
  (* Every next-value expression reads the state as it was at the top of the
     iteration, so they share one group, and with more than one slot they land
     in temporaries before any of them is written back. *)
  let pre_steps, steps =
    group ctx (fun () ->
        List.map2
          (fun (i, s) want ->
            let v = next_of i s want in
            note_type ctx n s (snd v);
            coerce ctx v want)
          (List.combine slots names)
          types)
  in
  let updates =
    match (slots, steps) with
    | [], _ | _, [] -> []
    | [ i ], [ e ] -> [ Assign (i, e) ]
    | _ ->
        let temps =
          List.map2
            (fun s ty ->
              slot ctx
                ~key:(n.id ^ "\000next\000" ^ s)
                ~display:(s ^ "_next") ~ty)
            names types
        in
        List.map2 (fun t e -> Assign (t, e)) temps steps
        @ List.map2 (fun i t -> Assign (i, Local t)) slots temps
  in
  let rest = chain ctx n "next" in
  inits
  @ [ While (watching @ pre_cond, cond, body @ pre_steps @ updates) ]
  @ rest

(* Loosen the assumption about a slot if what feeds it does not fit. *)
and note_type ctx (n : Graph.node) name ty =
  let key = slot_key n name in
  let want = join (assumed ctx key) ty in
  if want <> assumed ctx key then (
    Hashtbl.replace ctx.slot_ty key want;
    ctx.too_narrow <- true)

(* --------------------------------------------------------------- entry *)

let once (g : Graph.t) fanout slot_ty =
  let ctx =
    {
      g;
      slots = Hashtbl.create 16;
      used = Hashtbl.create 16;
      fanout;
      params = [];
      vars = [];
      errs = [];
      active = Hashtbl.create 16;
      entered = Hashtbl.create 16;
      shared = Hashtbl.create 8;
      prelude = [];
      temps = 0;
      watches = [];
      slot_ty;
      too_narrow = false;
    }
  in
  let start =
    match Graph.nodes_of_kind g "start" with
    | [ s ] -> Some s
    | [] ->
        complain ctx "the graph has no start node";
        None
    | _ :: rest ->
        List.iter
          (fun (n : Graph.node) ->
            complain ctx ~node:n.id "there can only be one start node")
          rest;
        None
  in
  let body =
    match start with
    | None -> []
    | Some start ->
        check_names ctx start "params" "inputs";
        ctx.params <- declared_names start "params";
        (* Parameters take the first local slots, in the order the start node
           lists them, so the wasm signature matches the editor's form. *)
        List.iter
          (fun p -> ignore (slot ctx ~key:("\001" ^ p) ~display:p ~ty:VFloat))
          ctx.params;
        ctx.vars <- [];
        Hashtbl.replace ctx.entered start.id ();
        chain ctx start "next"
  in
  (ctx, { params = ctx.params; vars = ctx.vars; body })

let func_of_graph (g : Graph.t) : func * (string * string) list =
  let fanout = Hashtbl.create 32 in
  List.iter
    (fun (e : Graph.edge) ->
      let k = e.src ^ "\000" ^ e.src_port in
      Hashtbl.replace fanout k
        (1 + Option.value (Hashtbl.find_opt fanout k) ~default:0))
    g.edges;
  let slot_ty = Hashtbl.create 16 in
  (* Every pass that is thrown away has loosened at least one slot, and a slot
     only loosens once, so this settles well inside the bound. *)
  let budget =
    List.fold_left
      (fun n node -> n + 1 + List.length (declared_names node "states"))
      2
      (Graph.nodes_of_kind g "while" @ Graph.nodes_of_kind g "for")
  in
  let rec attempt left =
    let ctx, f = once g fanout slot_ty in
    if ctx.too_narrow && left > 0 then attempt (left - 1) else (ctx, f)
  in
  let ctx, f = attempt budget in
  (match ctx.errs with [] -> () | errs -> raise (Graph.Errors (List.rev errs)));
  (f, List.rev ctx.watches)
