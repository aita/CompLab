(* Graph -> IR.

   The graph is a dataflow network and there is nothing to walk forwards: the
   sinks -- Out, Log, Say -- are what a cook is for, and everything else is
   evaluated because one of them asked for it.  Asking for the value of an
   input port walks backwards along the data edges and builds an expression
   tree, so the evaluation order falls out of what depends on what rather than
   being drawn.

   A Feedback is the only node that holds anything, and it holds it between
   cooks: reading it gives what the last cook left, and the new value it is
   fed is taken up at the end of this one.  Every feedback takes its new value
   at the same moment, which is what lets two of them read each other.

   A node whose output feeds several inputs is computed once, into a local,
   because with no way to name an intermediate value in the graph, feeding one
   output into many places is how you are meant to work: expanding it at every
   use doubles the code at every level, and a chain twenty deep would not
   finish. See [share] below for what makes that safe.  It also settles what a
   random node means when it is read twice: the node is the value, so one draw
   reaches every reader of it.

   Numbers are typed as they are lowered.  A literal that is whole is an i64,
   and so is anything built only out of those; everything else is an f64.  A
   feedback cannot be typed by looking at it once -- its new value reads the
   feedback -- so the whole lowering is its own fixpoint: it starts by
   assuming every one is whole, and runs again whenever that turns out to be
   too narrow.  Assumptions only ever loosen, so it settles. *)

open Ir

type ctx = {
  g : Graph.t;
  (* What the graph holds outlives one call, so it lives in globals; the
     temporaries a single expression needs are locals of the function being
     lowered, and start again for each of them. *)
  gslots : (string, int) Hashtbl.t;  (* internal key -> global index *)
  mutable globals : (string * vtype * float) list;
  used : (string, unit) Hashtbl.t;  (* display names already taken *)
  fanout : (string, int) Hashtbl.t;  (* "node\000port" -> how many edges leave *)
  (* The one thing the host gives a graph, and only if it is asked for. *)
  mutable wants_time : bool;
  (* The numbers the Run panel asks for: export name, label, default. *)
  mutable inputs : (string * string * float) list;
  (* Every piece of text the graph says, in the order it is laid out. *)
  mutable strings : string list;
  mutable vars : (string * vtype) list;  (* the current function's locals *)
  mutable errs : Graph.error list;  (* collected, reported all at once *)
  active : (string, unit) Hashtbl.t;  (* data nodes on the current path *)
  (* the group being lowered: what it has already computed, and the
     assignments that have to run before it *)
  mutable shared : (string, int * vtype) Hashtbl.t;
  mutable prelude : stmt list;  (* reversed *)
  mutable temps : int;
  (* Every breakpoint the lowering has planted, in the order the module's
     watch indices run; the editor turns these back into node highlights. *)
  mutable watches : (string * string) list;  (* reversed: node id, label *)
  slot_ty : (string, vtype) Hashtbl.t;  (* feedback key -> assumed type *)
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

(* A global: the graph's own state, which every way into the graph shares. *)
let global ctx ~key ~display ~ty ?(init = 0.) () =
  match Hashtbl.find_opt ctx.gslots key with
  | Some i -> i
  | None ->
      let i = Hashtbl.length ctx.gslots in
      Hashtbl.replace ctx.gslots key i;
      ctx.globals <- ctx.globals @ [ (fresh_display ctx display, ty, init) ];
      i

(* A local of the cook: a value that is wanted twice, or a feedback's new
   value while the others are still being worked out. *)
let local ctx ~display ~ty =
  let i = List.length ctx.vars in
  ctx.vars <- ctx.vars @ [ (fresh_display ctx display, ty) ];
  i

(* Plant a breakpoint and hand back the index the module will report it by. *)
let watch_point ctx ~node ~label =
  ctx.watches <- (node, label) :: ctx.watches;
  List.length ctx.watches - 1

let slot_key (n : Graph.node) = n.id

(* A node that works on either sort of value says which in its own settings:
   a Feedback because its slot has to be one or the other, a Choose because
   its ports are drawn before anything is wired to them.  A yes-or-no is not a
   number that has not settled yet, so this is said rather than worked out. *)
let flagged (n : Graph.node) =
  Graph.string_field n "holds" ~default:"number" = "flag"

let declared (n : Graph.node) =
  if n.kind = "feedback" && flagged n then Some VBool else None

let assumed ctx key =
  Option.value (Hashtbl.find_opt ctx.slot_ty key) ~default:VInt

let holds ctx (n : Graph.node) =
  match declared n with Some t -> t | None -> assumed ctx (slot_key n)

(* An Input is a global the host writes before the run, so the graph only ever
   reads it and every way in sees the same number.  Asking for it is the point
   of the node, so the panel is told about it whether or not anything reads
   it: a node put down and not yet wired up still shows a box. *)
let input_slot ctx (n : Graph.node) =
  let name = Graph.string_field n "name" ~default:"n" in
  let init = Graph.number_field n "value" ~default:0. in
  let i = global ctx ~key:("\003" ^ n.id) ~display:name ~ty:VFloat ~init () in
  let export =
    Ir.global_export (let v, _, _ = List.nth ctx.globals i in v)
  in
  if not (List.exists (fun (e, _, _) -> e = export) ctx.inputs) then
    ctx.inputs <-
      ctx.inputs @ [ (export, name, init) ];
  i

let display_of (n : Graph.node) = Graph.string_field n "name" ~default:"held"

(* Every feedback owns one global, named after the node so two called the same
   thing in the editor still come out apart.  What it starts at is a number
   typed into the node, which is what lets it be the global's own initial
   value: there is no first cook that runs anything the others do not. *)
let state_slot ctx (n : Graph.node) =
  let key = slot_key n in
  let start =
    if declared n = Some VBool then
      if Graph.string_field n "start" ~default:"no" = "yes" then 1. else 0.
    else Graph.number_field n "start" ~default:0.
  in
  global ctx ~key ~display:(display_of n) ~ty:(holds ctx n) ~init:start ()

(* A group is one place in the emitted code where a set of expressions is
   evaluated together: one sink, or the whole set of new values the feedbacks
   take.  Sharing is scoped to a group, and the assignments it hoists
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

(* Narrowing never happens in a settled pass: reaching it means a feedback
   slot was assumed to be whole and is not, so this pass is about to be thrown
   away and what it emits does not matter. *)
let coerce ctx (e, ty) want =
  if ty = want then e
  else if ty = VInt && want = VFloat then as_float (e, ty)
  else if is_num ty && is_num want then (
    ctx.too_narrow <- true;
    Int 0)
  else
    (* A yes-or-no and a number never meet: the complaint is made where the
       mismatch is seen, and this pass is thrown away either way. *)
    e

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

(* The same operators, spelled the way they are typed into an Expression. *)
let cmpop_of_string_symbol = function
  | "<" -> Some Lt
  | "<=" -> Some Le
  | ">" -> Some Gt
  | ">=" -> Some Ge
  | "==" -> Some Eq
  | "!=" -> Some Ne
  | _ -> None

let binop_of_string_symbol = function
  | "+" -> Some Add
  | "-" -> Some Sub
  | "*" -> Some Mul
  | "/" -> Some Div
  | "%" -> Some Mod
  | _ -> None

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
        let built = value_of ctx n in
        Hashtbl.remove ctx.active n.id;
        share ctx ~key ~from:n (watched ctx n built))

and share ctx ~key ~from (expr, ty) =
  let uses = Option.value (Hashtbl.find_opt ctx.fanout key) ~default:1 in
  (* A node that asks the host something is its answer: one draw, one reading
     of the clock, and every reader sees that one.  It is worked out into a
     local however few edges leave it, because the edge count is not the whole
     story -- a formula that names it twice leaves one edge and reads it
     twice. *)
  let impure = List.mem from.Graph.kind [ "random"; "time" ] in
  match expr with
  (* already as cheap as the read that would replace it *)
  | Local _ | Global _ | Num _ | Int _ -> (expr, ty)
  | _ when uses < 2 && not impure -> (expr, ty)
  | _ ->
      ctx.temps <- ctx.temps + 1;
      let i = local ctx ~display:(from.Graph.id ^ "_value") ~ty in
      ctx.prelude <- Assign (i, expr) :: ctx.prelude;
      Hashtbl.replace ctx.shared key (i, ty);
      (Local i, ty)

(* A breakpoint wraps the value where it is computed, which -- because a node
   feeding several inputs is computed once -- means one hit per evaluation
   rather than one per reader. *)
and watched ctx (n : Graph.node) (expr, ty) =
  (* A feedback reports the new value it takes, at the end of the cook, rather
     than every time what it holds is read. *)
  if n.kind = "feedback" || not (Graph.flag n "breakpoint") then (expr, ty)
  else
    let i = watch_point ctx ~node:n.id ~label:"value" in
    (Watch (i, ty, expr), ty)

(* Every node that carries a value carries exactly one, so which output port
   was asked for does not come into it. *)
and value_of ctx (n : Graph.node) : expr * vtype =
  let bad fmt = Printf.ksprintf (fun s -> complain ctx ~node:n.id "%s" s) fmt in
  match n.kind with
  | "time" ->
      (* What the host says the time is.  Asked for afresh in every cook, but
         once within one: the same rule that makes one Random node one draw. *)
      (Now, VFloat)
  | "input" -> (Global (input_slot ctx n), VFloat)
  | "feedback" ->
      (* Reading a feedback stops the backward walk: what comes out is what
         the last cook left, so the value it is fed may name the feedback
         itself without that being a cycle.  This is the only way a graph can
         depend on itself. *)
      (Global (state_slot ctx n), holds ctx n)
  | "const" -> literal (Graph.number_field n "value" ~default:0.)
  | "flag" ->
      if Graph.string_field n "value" ~default:"yes" = "yes" then
        (Cmp (Eq, Int 0, Int 0), VBool)
      else (untrue, VBool)
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
  | "expr" -> (
      (* One card standing in for a chain of arithmetic nodes.  The names the
         text leaves free are this node's input ports, so it plugs into the
         graph like anything else. *)
      match Formula.of_string (Graph.string_field n "text" ~default:"") with
      | Error m ->
          bad "%s" m;
          (Int 0, VInt)
      | Ok e -> formula ctx n e)
  | "select" ->
      (* Both arms are the sort of thing the node says it chooses between, and
         so is what comes out. *)
      let c = condition ctx n "cond" in
      if flagged n then
        let a = condition ctx n "a" in
        let b = condition ctx n "b" in
        (Select (c, a, b), VBool)
      else
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
and formula ctx (n : Graph.node) (f : Formula.t) : expr * vtype =
  let bad fmt = Printf.ksprintf (fun s -> complain ctx ~node:n.id "%s" s) fmt in
  let num f =
    let e, ty = formula ctx n f in
    if is_num ty then (e, ty)
    else (
      bad "this needs a number, not a true or false";
      (Int 0, VInt))
  in
  let bool f =
    let e, ty = formula ctx n f in
    if ty = VBool then e
    else (
      bad "this needs a true or false, not a number";
      untrue)
  in
  let arith op a b =
    match op with
    | Div | Min | Max -> (Bin (op, as_float (num a), as_float (num b)), VFloat)
    | _ ->
        let x, y, ty = unify (num a) (num b) in
        (Bin (op, x, y), ty)
  in
  match f with
  | Formula.Num v -> literal v
  | Formula.Var name -> number ctx n name
  | Formula.Un ("-", a) ->
      let e, ty = num a in
      (Un (Neg, e), ty)
  | Formula.Un ("!", a) -> (Not (bool a), VBool)
  | Formula.Un (op, _) ->
      bad "%s is not an operator here" op;
      (Int 0, VInt)
  | Formula.Bin ("&&", a, b) -> (And (bool a, bool b), VBool)
  | Formula.Bin ("||", a, b) -> (Or (bool a, bool b), VBool)
  | Formula.Bin (op, a, b) -> (
      match cmpop_of_string_symbol op with
      | Some c ->
          let x, y, _ = unify (num a) (num b) in
          (Cmp (c, x, y), VBool)
      | None -> (
          match binop_of_string_symbol op with
          | Some o -> arith o a b
          | None ->
              bad "%s is not an operator here" op;
              (Int 0, VInt)))
  | Formula.Call (name, args) -> (
      match (name, args) with
      | "min", [ a; b ] -> arith Min a b
      | "max", [ a; b ] -> arith Max a b
      | "abs", [ a ] ->
          let e, ty = num a in
          (Un (Abs, e), ty)
      | ("sqrt" | "floor" | "ceil" | "round"), [ a ] ->
          let u =
            match name with
            | "sqrt" -> Sqrt
            | "floor" -> Floor
            | "ceil" -> Ceil
            | _ -> Round
          in
          (Un (u, as_float (num a)), VFloat)
      | "random", [ a; b ] ->
          (Rand (as_float (num a), as_float (num b)), VFloat)
      | _ ->
          bad "%s is not one of the functions this understands" name;
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


(* --------------------------------------------------------------- sinks *)

(* The host takes f64s, so what a sink hands over is widened -- after the
   breakpoint, which reports the value in the type it was worked out in. *)
let reported ctx (n : Graph.node) v = as_float (watched ctx n v)

(* What a feedback is fed decides how wide its slot has to be: a whole number
   stays whole until something hands it a fraction.  Noticing that here is
   what makes the next pass necessary, and there is no next pass once the
   width has stopped moving. *)
let note_type ctx (n : Graph.node) (e, ty) =
  let key = slot_key n in
  let want = join (assumed ctx key) ty in
  if want <> assumed ctx key then (
    Hashtbl.replace ctx.slot_ty key want;
    ctx.too_narrow <- true);
  (e, ty)

(* A text port leads to a Text node and nothing else, so it is read here
   rather than built as an expression: with no memory to work in, a piece of
   text is a literal or it does not exist. *)
let text_of ctx (n : Graph.node) port =
  match Graph.into ctx.g ~node:n.id ~port with
  | None ->
      complain ctx ~node:n.id "the %s input is not connected" port;
      0
  | Some e -> (
      let src = Graph.find ctx.g e.src in
      match src.kind with
      | "text" ->
          let text = Graph.string_field src "text" ~default:"" in
          let rec index i = function
            | [] ->
                ctx.strings <- ctx.strings @ [ text ];
                i
            | x :: _ when x = text -> i
            | _ :: rest -> index (i + 1) rest
          in
          index 0 ctx.strings
      | kind ->
          complain ctx ~node:src.id "a %s node does not make text" kind;
          0)

let watched_as ctx (n : Graph.node) label (expr, ty) =
  if not (Graph.flag n "breakpoint") then (expr, ty)
  else (Watch (watch_point ctx ~node:n.id ~label, ty, expr), ty)

(* The nodes a cook is for.  Everything else in the graph is only there
   because one of these asks for it: nothing is evaluated that nothing wants,
   which is the whole of the evaluation order. *)
let sink_kinds = [ "out"; "log"; "say" ]

(* In the order the graph lists them, so that what a cook does is settled by
   the file rather than by where the nodes happen to sit. *)
let sinks (g : Graph.t) = List.filter (fun n -> List.mem n.Graph.kind sink_kinds) g.nodes

let feedbacks (g : Graph.t) = Graph.nodes_of_kind g "feedback"

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
      gslots = Hashtbl.create 16;
      globals = [];
      used = Hashtbl.create 16;
      fanout;
      wants_time = false;
      inputs = [];
      strings = [];
      vars = [];
      errs = [];
      active = Hashtbl.create 16;
      shared = Hashtbl.create 8;
      prelude = [];
      temps = 0;
      watches = [];
      slot_ty;
      too_narrow = false;
    }
  in
  (* Before anything is lowered, so that the panel asks for every Input in the
     graph rather than only the ones something happens to read, and so that a
     feedback has its slot even if this cook does not read it. *)
  List.iter
    (fun n -> ignore (input_slot ctx n))
    (List.sort
       (fun (a : Graph.node) b ->
         compare
           (Graph.string_field a "name" ~default:"")
           (Graph.string_field b "name" ~default:""))
       (Graph.nodes_of_kind g "input"));
  List.iter (fun n -> ignore (state_slot ctx n)) (feedbacks g);

  (* The whole cook is one group: a node is worked out once and every sink
     reads the same answer, which is what makes a Random node one draw a cook
     rather than one draw a reader.  The hoisted values come out first, which
     is sound because nothing in a cook writes what a cook reads -- the
     feedbacks take their new values at the end. *)
  (* A kind the catalogue has never heard of is a graph saved by an older
     Ferret or a hand-written one with a typo.  Either way it is better said
     than passed over: a node nothing reads would otherwise vanish quietly. *)
  List.iter
    (fun (n : Graph.node) ->
      if Spec.find n.kind = None then
        complain ctx ~node:n.id "there is no %s node in this language" n.kind)
    g.nodes;
  if sinks g = [] && feedbacks g = [] then
    complain ctx "the graph has nothing to work out: there is no Out, Log or Say";
  let out = ref None in
  let pre, (sunk, held) =
    group ctx (fun () ->
        let sunk =
          List.concat_map
            (fun (n : Graph.node) ->
              match n.kind with
              | "log" -> [ Log (reported ctx n (number ctx n "value")) ]
              | "say" -> [ Say (text_of ctx n "text") ]
              | _ -> (
                  match !out with
                  | Some _ ->
                      complain ctx ~node:n.id "there can only be one out node";
                      []
                  | None ->
                      (* Worked out in its place among the sinks, but handed
                         back at the very end, after the feedbacks have moved
                         on -- so it waits in a local. *)
                      let v = reported ctx n (number ctx n "value") in
                      let i = local ctx ~display:"result" ~ty:VFloat in
                      out := Some i;
                      [ Assign (i, v) ]))
            (sinks g)
        in
        (* Every feedback takes its new value at the end of the cook, and they
           all take it at once: the new values go into locals first, so that
           one feedback reading another reads what it held rather than what it
           is about to hold. *)
        let held =
          List.map
            (fun (n : Graph.node) ->
              let want = holds ctx n in
              let v =
                (* A feedback that says it holds a yes-or-no is taken at its
                   word; one that holds a number has its width worked out. *)
                if want = VBool then (condition ctx n "value", VBool)
                else note_type ctx n (number ctx n "value")
              in
              let e, ty = watched_as ctx n "value" v in
              let tmp = local ctx ~display:(display_of n ^ "_next") ~ty:want in
              (Assign (tmp, coerce ctx (e, ty) want), (n, tmp)))
            (List.filter
               (fun (n : Graph.node) ->
                 Graph.into g ~node:n.id ~port:"value" <> None)
               (feedbacks g))
        in
        (sunk, held))
  in
  let work = List.map fst held in
  let commit =
    List.map (fun (_, (n, tmp)) -> Store (state_slot ctx n, Local tmp)) held
  in
  let back =
    match !out with Some i -> Ret (Local i) | None -> Ret (Num 0.)
  in
  let body = pre @ sunk @ work @ commit @ [ back ] in
  ( ctx,
    {
      globals = ctx.globals;
      strings = ctx.strings;
      funcs = [ { name = "main"; vars = ctx.vars; body } ];
    } )

type built = {
  m : modul;
  watches : (string * string) list;
  (* export name, label, default -- what the Run panel asks for *)
  inputs : (string * string * float) list;
}

let module_of_graph (g : Graph.t) : built =
  let slot_ty = Hashtbl.create 16 in
  (* Every pass that is thrown away has loosened at least one feedback, and a
     feedback only loosens once, so this settles well inside the bound. *)
  let budget = List.length (Graph.nodes_of_kind g "feedback") + 2 in
  let rec attempt left =
    let ctx, f = once g slot_ty in
    if ctx.too_narrow && left > 0 then attempt (left - 1) else (ctx, f)
  in
  let ctx, f = attempt budget in
  (match ctx.errs with [] -> () | errs -> raise (Graph.Errors (List.rev errs)));
  { m = f; watches = List.rev ctx.watches; inputs = ctx.inputs }
