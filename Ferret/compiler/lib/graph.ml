(* The editor hands us React Flow's own save format, so this module reads
   that shape directly: a node's [type] is the node kind, and an edge's
   [sourceHandle]/[targetHandle] are the port names. *)

type error = { node : string option; msg : string }

exception Errors of error list

let error ?node msg = { node; msg }
let fail ?node fmt = Printf.ksprintf (fun s -> raise (Errors [ error ?node s ])) fmt

type node = { id : string; kind : string; data : Yojson.Safe.t }

type edge = {
  src : string;
  src_port : string;
  dst : string;
  dst_port : string;
}

type t = {
  nodes : node list;
  edges : edge list;
  by_id : (string, node) Hashtbl.t;
}

let member key = function
  | `Assoc fields -> ( try List.assoc key fields with Not_found -> `Null)
  | _ -> `Null

let to_string_opt = function `String s -> Some s | _ -> None

let node_data n key = member key n.data

let string_field n key ~default =
  match to_string_opt (node_data n key) with Some s -> s | None -> default

(* A number typed straight into an input port, rather than fed to it by an
   edge.  The editor writes these under "values", keyed by the port name. *)
let port_value n port =
  match member port (node_data n "values") with
  | `Int i -> Some (float_of_int i)
  | `Float f -> Some f
  | `String s -> float_of_string_opt s
  | _ -> None

let number_field n key ~default =
  match node_data n key with
  | `Int i -> float_of_int i
  | `Float f -> f
  | `String s -> ( match float_of_string_opt s with Some f -> f | None -> default)
  | _ -> default

let of_json (json : Yojson.Safe.t) : t =
  let node = function
    | `Assoc _ as j ->
        let id =
          match to_string_opt (member "id" j) with
          | Some id -> id
          | None -> fail "a node has no id"
        in
        let kind =
          match to_string_opt (member "type" j) with
          | Some k -> k
          | None -> fail ~node:id "node %s has no type" id
        in
        { id; kind; data = member "data" j }
    | _ -> fail "a node is not an object"
  in
  let edge = function
    | `Assoc _ as j ->
        let str key default =
          match to_string_opt (member key j) with Some s -> s | None -> default
        in
        let src = str "source" "" and dst = str "target" "" in
        if src = "" || dst = "" then fail "an edge has no source or target";
        {
          src;
          src_port = str "sourceHandle" "out";
          dst;
          dst_port = str "targetHandle" "in";
        }
    | _ -> fail "an edge is not an object"
  in
  let list key =
    match member key json with
    | `List xs -> xs
    | `Null -> fail "the graph has no %s" key
    | _ -> fail "%s is not a list" key
  in
  let nodes = List.map node (list "nodes") in
  let edges = List.map edge (list "edges") in
  let by_id = Hashtbl.create 32 in
  List.iter
    (fun n ->
      if Hashtbl.mem by_id n.id then fail ~node:n.id "duplicate node id %s" n.id;
      Hashtbl.replace by_id n.id n)
    nodes;
  List.iter
    (fun e ->
      if not (Hashtbl.mem by_id e.src) then
        fail "an edge starts at the unknown node %s" e.src;
      if not (Hashtbl.mem by_id e.dst) then
        fail "an edge ends at the unknown node %s" e.dst)
    edges;
  { nodes; edges; by_id }

let find g id =
  match Hashtbl.find_opt g.by_id id with
  | Some n -> n
  | None -> fail "no node %s" id

let nodes_of_kind g kind = List.filter (fun n -> n.kind = kind) g.nodes

(* Every port is at most 1:1 on the input side, so [into] returns an option:
   a port with two things plugged into it is rejected here rather than
   silently picking one. *)
let into g ~node ~port =
  match List.filter (fun e -> e.dst = node && e.dst_port = port) g.edges with
  | [] -> None
  | [ e ] -> Some e
  | _ -> fail ~node "more than one connection into the %s port" port

let out_of g ~node ~port =
  match List.filter (fun e -> e.src = node && e.src_port = port) g.edges with
  | [] -> None
  | [ e ] -> Some e
  | _ -> fail ~node "the %s port leads to more than one node" port
