(* Graph -> IR.
   Data ports are pulled on demand: asking for the value of an input port
   walks backwards through the data edges and builds an expression tree.
   Exec ports are pushed: the walk starts at the start node and follows the
   exec edges forward, turning each node it meets into a statement.

   A Counter is the only node that holds anything: it starts at one value and
   moves by another every time execution passes through it.  A Condition only
   branches.  So a loop is drawn rather than declared -- a wire runs from the
   end of the body back into the Condition -- and the exec edges form a real
   graph.  Recovering wasm's block structure from it is [structure] below.

   A node whose output feeds several inputs is computed once, into a local,
   because with no way to name an intermediate value in the graph, feeding one
   output into many places is how you are meant to work: expanding it at every
   use doubles the code at every level, and a chain twenty deep would not
   finish. See [share] below for what makes that safe.  It also settles what a
   random node means when it is read twice: the node is the value, so one draw
   reaches every reader of it.

   Numbers are typed as they are lowered.  A literal that is whole is an i64,
   and so is anything built only out of those; everything else is an f64.  A
   counter cannot be typed by looking at it once -- its step reads the counter
   -- so the whole lowering is its own fixpoint: it starts by assuming every
   counter is whole, and runs again whenever that turns out to be too narrow.
   Assumptions only ever loosen, so it settles. *)

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

let slot_key (n : Graph.node) = n.id

let assumed ctx key =
  Option.value (Hashtbl.find_opt ctx.slot_ty key) ~default:VInt

(* Every counter owns one local, named after the node so two counters called
   the same thing in the editor still come out apart. *)
let state_slot ctx (n : Graph.node) =
  let key = slot_key n in
  slot ctx ~key
    ~display:(Graph.string_field n "name" ~default:"i")
    ~ty:(assumed ctx key)

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
  if n.kind = "counter" || n.kind = "start" || not (Graph.flag n "breakpoint")
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
  | "counter" | "forloop" ->
      (* Reading what a counter holds stops the backward walk: the value is a
         local, so the step may name the counter itself without that being a
         cycle.  A for loop's index is the same thing. *)
      (Local (state_slot ctx n), assumed ctx (slot_key n))
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

(* The parsed text, node by node, using the same helpers the wired-up version
   goes through -- so it types and shares exactly the same way. *)
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

(* The host takes f64s, so what log and end hand over is widened -- after the
   breakpoint, which reports the value in the type it was worked out in. *)
let reported ctx (n : Graph.node) v = as_float (watched ctx n v)

(* Loosen the assumption about a counter if what feeds it does not fit. *)
let note_type ctx (n : Graph.node) (e, ty) =
  let key = slot_key n in
  let want = join (assumed ctx key) ty in
  if want <> assumed ctx key then (
    Hashtbl.replace ctx.slot_ty key want;
    ctx.too_narrow <- true);
  (e, ty)

let exec_kinds = [ "log"; "end"; "condition"; "counter"; "forloop" ]

(* A for loop is three places rather than one: the setup it is entered at, the
   test it comes back to, and the step the body falls into.  So a vertex of
   the control-flow graph is a node and the door it was entered by. *)
let vertex_for ctx ~dst ~port =
  let n = Graph.find ctx.g dst in
  if n.kind = "forloop" && port = "in" then dst ^ "#init" else dst

(* A way out that was left unwired is a vertex of its own rather than a
   missing successor, so that a node with two exits keeps two of them however
   little is drawn: which pin is dangling is the whole question, and a list
   with a hole in it cannot say. *)
let gap ~node ~port = node ^ "#gap:" ^ port
let is_gap part = String.starts_with ~prefix:"gap:" part

let node_of v =
  match String.index_opt v '#' with Some i -> String.sub v 0 i | None -> v

let part_of v =
  match String.index_opt v '#' with
  | Some i -> String.sub v (i + 1) (String.length v - i - 1)
  | None -> ""

(* A breakpoint on a node that carries no value of its own -- a counter, a
   condition -- reports what it works out as it passes through. *)

let watched_as ctx (n : Graph.node) label (expr, ty) =
  if not (Graph.flag n "breakpoint") then (expr, ty)
  else (Watch (watch_point ctx ~node:n.id ~label, ty, expr), ty)

(* What each vertex does, before it hands control on. *)
let rec statements ctx v : block =
  let n = Graph.find ctx.g (node_of v) in
  match (n.kind, part_of v) with
  | _, part when is_gap part -> []
  | "forloop", "init" ->
      let i = state_slot ctx n in
      let want = assumed ctx (slot_key n) in
      let pre, e = group ctx (fun () -> note_type ctx n (number ctx n "first")) in
      pre @ [ Assign (i, coerce ctx e want) ]
  | "forloop", "step" ->
      let i = state_slot ctx n in
      let want = assumed ctx (slot_key n) in
      let a, b, ty = unify (Local i, want) (Int 1, VInt) in
      ignore (note_type ctx n (Bin (Add, a, b), ty));
      [ Assign (i, coerce ctx (Bin (Add, a, b), ty) want) ]
  | "forloop", _ -> []
  | _ -> statements_of ctx n

and statements_of ctx (n : Graph.node) : block =
  match n.kind with
  | "log" ->
      let pre, v = group ctx (fun () -> reported ctx n (number ctx n "value")) in
      pre @ [ Log v ]
  | "end" ->
      let pre, v = group ctx (fun () -> reported ctx n (number ctx n "value")) in
      pre @ [ Ret v ]
  | "condition" -> []
  | "forloop" -> []
  | "counter" ->
      (* Passing through moves it.  Usually that means adding the step to what
         it holds; a counter set to "becomes" takes the value outright, which
         is what a state that is not counting anything needs. *)
      let i = state_slot ctx n in
      let want = assumed ctx (slot_key n) in
      let replace = Graph.string_field n "mode" ~default:"by" = "becomes" in
      let pre, v =
        group ctx (fun () ->
            let step = number ctx n "by" in
            note_type ctx n
              (if replace then step
               else
                 let a, b, ty = unify (Local i, want) step in
                 (Bin (Add, a, b), ty)))
      in
      let e, ty = watched_as ctx n "value" v in
      pre @ [ Assign (i, coerce ctx (e, ty) want) ]
  | kind ->
      complain ctx ~node:n.id "the %s node cannot be part of the flow" kind;
      []

(* The successors of a vertex, in the order its ports are drawn. *)
let exec_succs ctx v =
  let n = Graph.find ctx.g (node_of v) in
  let out port =
    match Graph.out_of ctx.g ~node:n.id ~port with
    | Some e -> [ vertex_for ctx ~dst:e.dst ~port:e.dst_port ]
    | None -> []
  in
  let way port =
    match Graph.out_of ctx.g ~node:n.id ~port with
    | Some e -> vertex_for ctx ~dst:e.dst ~port:e.dst_port
    | None -> gap ~node:n.id ~port
  in
  match (n.kind, part_of v) with
  | _, part when is_gap part -> []
  | "forloop", "init" -> [ n.id ]
  | "forloop", "step" -> [ n.id ]
  | "forloop", _ -> [ way "body"; way "done" ]
  | "condition", _ -> [ way "true"; way "false" ]
  | "end", _ -> []
  | _ -> out "next"

(* ------------------------------------------------- structure recovery *)

(* Turn the control-flow graph back into blocks and loops.  Every node is
   written out exactly once: at the dominator that owns it if only one path
   reaches it, and otherwise inside a block that both paths can branch to.
   This is the standard reducible-CFG shape -- a loop header becomes a [loop],
   a node two branches join at becomes a [block] wrapped round everything that
   branches to it, and everything else is written where it is reached. *)
type frame = { at : string; label : Ir.label }

let structure ctx (g : Cfg.t) =
  let next_label = ref 0 in
  let fresh () =
    incr next_label;
    !next_label
  in
  let node id = Graph.find ctx.g (node_of id) in
  let dom_children =
    let t = Hashtbl.create 32 in
    Array.iter
      (fun n ->
        match Hashtbl.find_opt g.idom n with
        | Some d when d <> n ->
            Hashtbl.replace t d (n :: Option.value (Hashtbl.find_opt t d) ~default:[])
        | _ -> ())
      g.order;
    t
  in
  let rec do_tree frames n : block =
    if Cfg.is_header g n then
      let l = fresh () in
      [ Loop (l, within ({ at = n; label = l } :: frames) n) ]
    else within frames n
  and within frames n : block =
    (* The joins this node owns, outermost last, so that a branch to one lands
       just before its code. *)
    let joins =
      Option.value (Hashtbl.find_opt dom_children n) ~default:[]
      |> List.filter (Cfg.is_join g)
      |> List.sort (fun a b -> compare (Cfg.rank g b) (Cfg.rank g a))
    in
    let rec wrap frames = function
      | [] -> code frames n
      | m :: rest ->
          let l = fresh () in
          Block (l, wrap ({ at = m; label = l } :: frames) rest)
          :: do_tree frames m
    in
    wrap frames joins
  and code frames n : block =
    let stmts = statements ctx n in
    let go target =
      match List.find_opt (fun f -> f.at = target) frames with
      | Some f -> [ Br f.label ]
      | None -> do_tree frames target
    in
    match ((node n).kind, part_of n, Cfg.successors g n) with
    | "condition", _, [ t; f ] ->
        let pre, c =
          group ctx (fun () ->
              fst
                (watched_as ctx (node n) "test"
                   (condition ctx (node n) "cond", VBool)))
        in
        stmts @ pre @ [ If (c, go t, go f) ]
    | "forloop", "", [ body; after ] ->
        (* index <= last, worked out afresh at the top of every pass *)
        let m = node n in
        let i = state_slot ctx m in
        let want = assumed ctx (slot_key m) in
        let pre, c =
          group ctx (fun () ->
              let a, b, _ = unify (Local i, want) (number ctx m "last") in
              fst (watched_as ctx m "index" (Cmp (Le, a, b), VBool)))
        in
        stmts @ pre @ [ If (c, go body, go after) ]
    (* Reaching a pin that was never wired.  Inside a loop body this would
       have been closed back to the step; anywhere else there is nothing it
       could sensibly mean. *)
    | _, part, [] when is_gap part ->
        complain ctx ~node:(node_of n)
          "both ways out of this node have to go somewhere";
        stmts
    | _, _, [ s ] -> stmts @ go s
    | _, _, _ -> stmts
  in
  do_tree [] g.entry

(* A branch to the end of the block you are already at the end of does
   nothing, and both arms of an if that joins immediately after it end that
   way.  Dropping those is what makes a plain if/else read like one. *)
let rec settle l = function
  | [ Br m ] when m = l -> []
  | [ If (c, t, e) ] -> [ If (c, settle l t, settle l e) ]
  | s :: rest -> s :: settle l rest
  | [] -> []

let rec tidy_block b = List.map tidy b

and tidy = function
  | Block (l, body) -> Block (l, settle l (tidy_block body))
  | Loop (l, body) -> Loop (l, tidy_block body)
  | If (c, t, e) -> If (c, tidy_block t, tidy_block e)
  | s -> s

(* Which counters a counter's starting value reads.  The walk stops at a
   counter, because that is where the backward walk stops when the value is
   built for real. *)
let start_reads ctx (n : Graph.node) =
  let seen = Hashtbl.create 8 in
  let found = ref [] in
  let rec walk node port =
    match Graph.into ctx.g ~node ~port with
    | None -> ()
    | Some e ->
        let src = Graph.find ctx.g e.src in
        if src.kind = "counter" then found := src.id :: !found
        else if not (Hashtbl.mem seen src.id) then (
          Hashtbl.replace seen src.id ();
          List.iter
            (fun (edge : Graph.edge) ->
              if edge.dst = src.id then walk src.id edge.dst_port)
            ctx.g.edges)
  in
  walk n.id "from";
  !found

let ordered_counters ctx counters =
  let done_ = Hashtbl.create 16 and busy = Hashtbl.create 16 in
  let out = ref [] in
  let by_id = List.map (fun (n : Graph.node) -> (n.id, n)) counters in
  let rec visit (n : Graph.node) =
    if not (Hashtbl.mem done_ n.id) then
      if Hashtbl.mem busy n.id then
        complain ctx ~node:n.id
          "these counters' starting values depend on each other"
      else (
        Hashtbl.replace busy n.id ();
        List.iter
          (fun id ->
            match List.assoc_opt id by_id with
            | Some m when m.Graph.id <> n.id -> visit m
            | _ -> ())
          (start_reads ctx n);
        Hashtbl.remove busy n.id;
        Hashtbl.replace done_ n.id ();
        out := n :: !out)
  in
  List.iter visit counters;
  List.rev !out

(* --------------------------------------------------------------- entry *)

let once (g : Graph.t) slot_ty =
  let fanout = Hashtbl.create 32 in
  List.iter
    (fun (e : Graph.edge) ->
      let k = e.src ^ "\000" ^ e.src_port in
      Hashtbl.replace fanout k
        (1 + Option.value (Hashtbl.find_opt fanout k) ~default:0))
    g.edges;
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
        (* Every counter is set up before anything runs, whichever loop it
           later turns out to sit inside.  One counter's starting value may
           read another's, so they go in an order that respects that rather
           than in whatever order the file happens to list them: moving a node
           in the editor must not change what a program means. *)
        let counters = ordered_counters ctx (Graph.nodes_of_kind g "counter") in
        let starts =
          List.concat_map
            (fun n ->
              let i = state_slot ctx n in
              let want = assumed ctx (slot_key n) in
              let pre, v = group ctx (fun () -> number ctx n "from") in
              ignore (note_type ctx n v);
              pre @ [ Assign (i, coerce ctx v want) ])
            counters
        in
        (match Graph.out_of g ~node:start.id ~port:"next" with
        | None -> starts
        | Some e ->
            let succs = Hashtbl.create 32 in
            let rec walk v =
              if not (Hashtbl.mem succs v) then (
                let n = Graph.find g (node_of v) in
                if not (List.mem n.kind exec_kinds) then
                  complain ctx ~node:(node_of v)
                    "the %s node cannot be part of the flow" n.kind;
                let ss = exec_succs ctx v in
                Hashtbl.replace succs v ss;
                List.iter walk ss)
            in
            let entry = vertex_for ctx ~dst:e.dst ~port:e.dst_port in
            walk entry;
            (* A for loop's body returns to it when the chain runs out, the
               way a Blueprint macro does: whatever the body reaches that
               leads nowhere goes back to the step. *)
            List.iter
              (fun (l : Graph.node) ->
                match Graph.out_of g ~node:l.id ~port:"body" with
                | None -> ()
                | Some b ->
                    let seen = Hashtbl.create 16 in
                    let rec close v =
                      (* Coming back round to the loop itself is the end of
                         the walk, not another leaf to tie down. *)
                      if node_of v <> l.id && not (Hashtbl.mem seen v) then (
                        Hashtbl.replace seen v ();
                        let n = Graph.find g (node_of v) in
                        match Hashtbl.find_opt succs v with
                        | Some [] when n.kind <> "end" ->
                            Hashtbl.replace succs v [ l.id ^ "#step" ]
                        | Some [ _; after ] when n.kind = "forloop" ->
                            (* Another loop's body is that loop's own affair;
                               only what comes after it belongs to this one. *)
                            close after
                        | Some ss -> List.iter close ss
                        | None -> ())
                    in
                    close (vertex_for ctx ~dst:b.dst ~port:b.dst_port);
                    if not (Hashtbl.mem succs (l.id ^ "#step")) then
                      Hashtbl.replace succs (l.id ^ "#step") [ l.id ])
              (Graph.nodes_of_kind g "forloop");
            let cfg = Cfg.build ~entry ~succs in
            (match Cfg.irreducible cfg with
            | [] -> ()
            | (u, h) :: _ ->
                complain ctx ~node:h
                  "this loop has two ways in, which cannot be written with \
                   wasm's blocks; route both through one condition (the wire \
                   from %s closes it)"
                  u);
            starts @ tidy_block (structure ctx cfg))
  in
  (ctx, { params = ctx.params; vars = ctx.vars; body })

let func_of_graph (g : Graph.t) : func * (string * string) list =
  let slot_ty = Hashtbl.create 16 in
  (* Every pass that is thrown away has loosened at least one counter, and a
     counter only loosens once, so this settles well inside the bound. *)
  let budget = List.length (Graph.nodes_of_kind g "counter") + 2 in
  let rec attempt left =
    let ctx, f = once g slot_ty in
    if ctx.too_narrow && left > 0 then attempt (left - 1) else (ctx, f)
  in
  let ctx, f = attempt budget in
  (match ctx.errs with [] -> () | errs -> raise (Graph.Errors (List.rev errs)));
  (f, List.rev ctx.watches)
