(* Graph -> IR.
   Data ports are pulled on demand: asking for the value of an input port
   walks backwards through the data edges and builds an expression tree.
   Exec ports are pushed: the walk starts at the start node and follows the
   exec edges forward, turning each node it meets into a statement.

   Control flow is structured by construction.  An [if] node owns three exec
   outputs -- then, else and next -- and the branch chains cannot jump back
   into the outer chain, so the exec edges always form a tree and no
   post-dominator analysis is needed to rebuild wasm's block structure. *)

open Ir

type ty = TNum | TBool

let ty_name = function TNum -> "number" | TBool -> "boolean"

type ctx = {
  g : Graph.t;
  slots : (string, int) Hashtbl.t;  (* name -> local index *)
  mutable params : string list;
  mutable vars : string list;
  mutable errs : Graph.error list;  (* collected, reported all at once *)
  active : (string, unit) Hashtbl.t;  (* data nodes on the current path *)
  entered : (string, unit) Hashtbl.t;  (* exec nodes already emitted *)
}

let complain ctx ?node fmt =
  Printf.ksprintf (fun s -> ctx.errs <- Graph.error ?node s :: ctx.errs) fmt

let slot ctx name =
  match Hashtbl.find_opt ctx.slots name with
  | Some i -> i
  | None ->
      let i = Hashtbl.length ctx.slots in
      Hashtbl.replace ctx.slots name i;
      ctx.vars <- ctx.vars @ [ name ];
      i

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

let rec value ctx (e : Graph.edge) : expr * ty =
  let n = Graph.find ctx.g e.src in
  if Hashtbl.mem ctx.active n.id then (
    complain ctx ~node:n.id "this node's value depends on itself";
    (Num 0., TNum))
  else (
    Hashtbl.replace ctx.active n.id ();
    let result = value_of ctx n e.src_port in
    Hashtbl.remove ctx.active n.id;
    result)

and value_of ctx (n : Graph.node) port : expr * ty =
  let bad fmt = Printf.ksprintf (fun s -> complain ctx ~node:n.id "%s" s) fmt in
  match n.kind with
  | "start" ->
      let name =
        match String.index_opt port ':' with
        | Some i -> String.sub port (i + 1) (String.length port - i - 1)
        | None -> port
      in
      if List.mem name ctx.params then (Local (slot ctx name), TNum)
      else (
        bad "the start node has no input called %s" name;
        (Num 0., TNum))
  | "const" -> (Num (Graph.number_field n "value" ~default:0.), TNum)
  | "get" ->
      let name = Graph.string_field n "name" ~default:"" in
      if name = "" then (
        bad "this node reads a variable with no name";
        (Num 0., TNum))
      else (Local (slot ctx name), TNum)
  | "binop" -> (
      let op = Graph.string_field n "op" ~default:"add" in
      match binop_of_string op with
      | None ->
          bad "unknown arithmetic operator %s" op;
          (Num 0., TNum)
      | Some op ->
          let a = num ctx n "a" in
          let b = num ctx n "b" in
          (Bin (op, a, b), TNum))
  | "unop" -> (
      let op = Graph.string_field n "op" ~default:"neg" in
      match unop_of_string op with
      | None ->
          bad "unknown operator %s" op;
          (Num 0., TNum)
      | Some op -> (Un (op, num ctx n "a"), TNum))
  | "compare" -> (
      let op = Graph.string_field n "op" ~default:"lt" in
      match cmpop_of_string op with
      | None ->
          bad "unknown comparison %s" op;
          (Num 0., TBool)
      | Some op ->
          let a = num ctx n "a" in
          let b = num ctx n "b" in
          (Cmp (op, a, b), TBool))
  | "logic" -> (
      match Graph.string_field n "op" ~default:"and" with
      | "not" -> (Not (bool ctx n "a"), TBool)
      | "or" ->
          let a = bool ctx n "a" in
          let b = bool ctx n "b" in
          (Or (a, b), TBool)
      | "and" ->
          let a = bool ctx n "a" in
          let b = bool ctx n "b" in
          (And (a, b), TBool)
      | op ->
          bad "unknown logical operator %s" op;
          (Num 0., TBool))
  | kind ->
      bad "the %s node produces no value" kind;
      (Num 0., TNum)

and input ctx (n : Graph.node) port ~want : expr =
  match Graph.into ctx.g ~node:n.id ~port with
  | None ->
      complain ctx ~node:n.id "the %s input is not connected" port;
      if want = TBool then Cmp (Ne, Num 0., Num 0.) else Num 0.
  | Some e ->
      let expr, got = value ctx e in
      if got <> want then (
        complain ctx ~node:n.id "the %s input wants a %s but is given a %s" port
          (ty_name want) (ty_name got);
        if want = TBool then Cmp (Ne, Num 0., Num 0.) else Num 0.)
      else expr

and num ctx n port = input ctx n port ~want:TNum
and bool ctx n port = input ctx n port ~want:TBool

(* ---------------------------------------------------------------- exec *)

let rec chain ctx (from : Graph.node) port : block =
  match Graph.out_of ctx.g ~node:from.id ~port with
  | None -> []
  | Some e ->
      let n = Graph.find ctx.g e.dst in
      if Hashtbl.mem ctx.entered n.id then (
        complain ctx ~node:n.id
          "two branches run into this node; give each branch its own chain";
        [])
      else (
        Hashtbl.replace ctx.entered n.id ();
        step ctx n)

and step ctx (n : Graph.node) : block =
  let rest () = chain ctx n "next" in
  match n.kind with
  | "set" ->
      let name = Graph.string_field n "name" ~default:"" in
      if name = "" then (
        complain ctx ~node:n.id "this node writes a variable with no name";
        rest ())
      else
        let target = slot ctx name in
        let v = num ctx n "value" in
        Assign (target, v) :: rest ()
  | "log" ->
      let v = num ctx n "value" in
      Log v :: rest ()
  | "end" -> [ Ret (num ctx n "value") ]
  | "if" ->
      let c = bool ctx n "cond" in
      let t = chain ctx n "then" in
      let e = chain ctx n "else" in
      If (c, t, e) :: rest ()
  | "while" ->
      let c = bool ctx n "cond" in
      let body = chain ctx n "body" in
      While (c, body) :: rest ()
  | kind ->
      complain ctx ~node:n.id "the %s node cannot be part of the flow" kind;
      rest ()

(* --------------------------------------------------------------- entry *)

let params_of ctx (start : Graph.node) =
  let name = function
    | `String s -> Some s
    | `Assoc _ as j -> (
        match Graph.member "name" j with `String s -> Some s | _ -> None)
    | _ -> None
  in
  match Graph.node_data start "params" with
  | `List items ->
      List.filter_map
        (fun j ->
          match name j with
          | Some "" | None ->
              complain ctx ~node:start.id "an input of the start node has no name";
              None
          | Some s -> Some s)
        items
  | `Null -> []
  | _ ->
      complain ctx ~node:start.id "the start node's inputs are not a list";
      []

let func_of_graph (g : Graph.t) : func =
  let ctx =
    {
      g;
      slots = Hashtbl.create 16;
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
        ctx.params <- params_of ctx start;
        (* Parameters take the first local slots, in the order the start node
           lists them, so the wasm signature matches the editor's form. *)
        List.iter (fun p -> ignore (slot ctx p)) ctx.params;
        ctx.vars <- [];
        Hashtbl.replace ctx.entered start.id ();
        chain ctx start "next"
  in
  (match ctx.errs with [] -> () | errs -> raise (Graph.Errors (List.rev errs)));
  { params = ctx.params; vars = ctx.vars; body }
