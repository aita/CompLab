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
   the temporaries -- exists only in the IR. *)

open Ir

let ty_name = function VNum -> "number" | VBool -> "true or false"

type ctx = {
  g : Graph.t;
  slots : (string, int) Hashtbl.t;  (* internal key -> local index *)
  used : (string, unit) Hashtbl.t;  (* display names already taken *)
  mutable params : string list;
  mutable vars : (string * vtype) list;
  mutable errs : Graph.error list;  (* collected, reported all at once *)
  active : (string, unit) Hashtbl.t;  (* data nodes on the current path *)
  entered : (string, unit) Hashtbl.t;  (* exec nodes already emitted *)
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

let slot ctx ~key ~display =
  match Hashtbl.find_opt ctx.slots key with
  | Some i -> i
  | None ->
      let i = Hashtbl.length ctx.slots in
      Hashtbl.replace ctx.slots key i;
      ctx.vars <- ctx.vars @ [ (fresh_display ctx display, VNum) ];
      i

let state_slot ctx (n : Graph.node) name =
  slot ctx ~key:(n.id ^ "\000" ^ name) ~display:name

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

let untrue = Cmp (Ne, Num 0., Num 0.)

let rec value ctx (e : Graph.edge) : expr * vtype =
  let n = Graph.find ctx.g e.src in
  if Hashtbl.mem ctx.active n.id then (
    complain ctx ~node:n.id "this node's value depends on itself";
    (Num 0., VNum))
  else (
    Hashtbl.replace ctx.active n.id ();
    let built = value_of ctx n e.src_port in
    Hashtbl.remove ctx.active n.id;
    built)

and value_of ctx (n : Graph.node) port : expr * vtype =
  let bad fmt = Printf.ksprintf (fun s -> complain ctx ~node:n.id "%s" s) fmt in
  match n.kind with
  | "start" ->
      let name = after_colon port in
      if List.mem name ctx.params then
        (Local (slot ctx ~key:("\001" ^ name) ~display:name), VNum)
      else (
        bad "the start node has no input called %s" name;
        (Num 0., VNum))
  | "while" ->
      (* Reading a loop's state stops the backward walk: the value is a local,
         so the cond and the next-value expressions may name it without that
         being a cycle. *)
      let name = after_colon port in
      if List.mem name (declared_names n "states") then
        (Local (state_slot ctx n name), VNum)
      else (
        bad "this loop has no state called %s" name;
        (Num 0., VNum))
  | "const" -> (Num (Graph.number_field n "value" ~default:0.), VNum)
  | "binop" -> (
      let op = Graph.string_field n "op" ~default:"add" in
      match binop_of_string op with
      | None ->
          bad "unknown arithmetic operator %s" op;
          (Num 0., VNum)
      | Some op ->
          let a = number ctx n "a" in
          let b = number ctx n "b" in
          (Bin (op, a, b), VNum))
  | "unop" -> (
      let op = Graph.string_field n "op" ~default:"neg" in
      match unop_of_string op with
      | None ->
          bad "unknown operator %s" op;
          (Num 0., VNum)
      | Some op -> (Un (op, number ctx n "a"), VNum))
  | "compare" -> (
      let op = Graph.string_field n "op" ~default:"lt" in
      match cmpop_of_string op with
      | None ->
          bad "unknown comparison %s" op;
          (untrue, VBool)
      | Some op ->
          let a = number ctx n "a" in
          let b = number ctx n "b" in
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
      (Select (c, a, b), VNum)
  | kind ->
      bad "the %s node produces no value" kind;
      (Num 0., VNum)

(* An input port takes an edge or, failing that, a number typed into it. *)
and number ctx (n : Graph.node) port : expr =
  match Graph.into ctx.g ~node:n.id ~port with
  | None -> (
      match Graph.port_value n port with
      | Some x -> Num x
      | None ->
          complain ctx ~node:n.id "the %s input is not connected" port;
          Num 0.)
  | Some e ->
      let expr, ty = value ctx e in
      if ty = VNum then expr
      else (
        complain ctx ~node:n.id "the %s input wants a number but is given a %s"
          port (ty_name ty);
        Num 0.)

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
          (ty_name ty);
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
      let v = number ctx n "value" in
      let rest = chain ctx n "next" in
      Log v :: rest
  | "end" -> [ Ret (number ctx n "value") ]
  | "while" -> loop ctx n
  | kind ->
      complain ctx ~node:n.id "the %s node cannot be part of the flow" kind;
      chain ctx n "next"

and loop ctx (n : Graph.node) : block =
  check_names ctx n "states" "loop states";
  let states = declared_names n "states" in
  (* The slots come first so that the condition and the next-value
     expressions, which read them, resolve to locals rather than recursing. *)
  let slots = List.map (fun s -> state_slot ctx n s) states in
  let inits =
    List.map2 (fun i s -> Assign (i, number ctx n ("init:" ^ s))) slots states
  in
  let cond = condition ctx n "cond" in
  let body = chain ctx n "body" in
  (* Every next-value expression reads the state as it was at the top of the
     iteration, so with more than one slot they land in temporaries before any
     of them is written back. *)
  let steps = List.map (fun s -> number ctx n ("step:" ^ s)) states in
  let updates =
    match (slots, steps) with
    | [], _ | _, [] -> []
    | [ i ], [ e ] -> [ Assign (i, e) ]
    | _ ->
        let temps =
          List.map
            (fun s ->
              slot ctx ~key:(n.id ^ "\000next\000" ^ s) ~display:(s ^ "_next"))
            states
        in
        List.map2 (fun t e -> Assign (t, e)) temps steps
        @ List.map2 (fun i t -> Assign (i, Local t)) slots temps
  in
  let rest = chain ctx n "next" in
  inits @ [ While (cond, body @ updates) ] @ rest

(* --------------------------------------------------------------- entry *)

let func_of_graph (g : Graph.t) : func =
  let ctx =
    {
      g;
      slots = Hashtbl.create 16;
      used = Hashtbl.create 16;
      params = [];
      vars = [];
      errs = [];
      active = Hashtbl.create 16;
      entered = Hashtbl.create 16;
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
          (fun p -> ignore (slot ctx ~key:("\001" ^ p) ~display:p))
          ctx.params;
        ctx.vars <- [];
        Hashtbl.replace ctx.entered start.id ();
        chain ctx start "next"
  in
  (match ctx.errs with [] -> () | errs -> raise (Graph.Errors (List.rev errs)));
  { params = ctx.params; vars = ctx.vars; body }
