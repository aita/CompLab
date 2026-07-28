(* Graphs that should not compile.  The editor shows these messages next to
   the offending node, so what they say is part of the interface. *)

let case name json =
  Printf.printf "# %s\n" name;
  (match Ferret.Compile.of_string json with
  | Ok _ -> print_endline "  (compiled -- expected errors)"
  | Error errs ->
      List.iter
        (fun (e : Ferret.Graph.error) ->
          match e.node with
          | Some id -> Printf.printf "  %s: %s\n" id e.msg
          | None -> Printf.printf "  %s\n" e.msg)
        errs);
  print_newline ()

let () =
  case "no start node" {|{ "nodes": [], "edges": [] }|};

  case "two start nodes"
    {|{ "nodes": [ { "id": "s1", "type": "start", "data": {} },
                   { "id": "s2", "type": "start", "data": {} } ],
        "edges": [] }|};

  case "an unconnected input"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" } ] }|};

  case "a number where a condition belongs"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "c", "type": "const", "data": { "value": 1 } },
                   { "id": "w", "type": "while",
                     "data": { "states": [ { "name": "i" } ] } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "w", "targetHandle": "cond" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "w", "targetHandle": "init:i" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "w", "targetHandle": "step:i" } ] }|};

  case "a condition where a number belongs"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "a", "type": "const", "data": { "value": 1 } },
                   { "id": "b", "type": "const", "data": { "value": 2 } },
                   { "id": "cmp", "type": "compare", "data": { "op": "lt" } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "a", "sourceHandle": "out",
                     "target": "cmp", "targetHandle": "a" },
                   { "source": "b", "sourceHandle": "out",
                     "target": "cmp", "targetHandle": "b" },
                   { "source": "cmp", "sourceHandle": "out",
                     "target": "e", "targetHandle": "value" } ] }|};

  case "a data cycle"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "add", "type": "binop", "data": { "op": "add" } },
                   { "id": "one", "type": "const", "data": { "value": 1 } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "add", "sourceHandle": "out",
                     "target": "e", "targetHandle": "value" },
                   { "source": "add", "sourceHandle": "out",
                     "target": "add", "targetHandle": "a" },
                   { "source": "one", "sourceHandle": "out",
                     "target": "add", "targetHandle": "b" } ] }|};

  case "two chains running into one node"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "w", "type": "while", "data": { "states": [] } },
                   { "id": "c", "type": "const", "data": { "value": 1 } },
                   { "id": "cmp", "type": "compare", "data": { "op": "lt" } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "cmp", "targetHandle": "a" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "cmp", "targetHandle": "b" },
                   { "source": "cmp", "sourceHandle": "out",
                     "target": "w", "targetHandle": "cond" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "e", "targetHandle": "value" },
                   { "source": "w", "sourceHandle": "body",
                     "target": "e", "targetHandle": "in" },
                   { "source": "w", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" } ] }|};

  case "an unknown start input"
    {|{ "nodes": [ { "id": "s", "type": "start",
                     "data": { "params": [ { "name": "n" } ] } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "s", "sourceHandle": "var:m",
                     "target": "e", "targetHandle": "value" } ] }|};

  case "an unknown loop state"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "w", "type": "while",
                     "data": { "states": [ { "name": "i" } ] } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" },
                   { "source": "w", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "w", "sourceHandle": "var:j",
                     "target": "e", "targetHandle": "value" } ] }|};

  case "a loop state declared twice"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "w", "type": "while",
                     "data": { "states": [ { "name": "i" }, { "name": "i" } ] } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" } ] }|};

  case "not JSON at all" {|{ "nodes": [ |}
