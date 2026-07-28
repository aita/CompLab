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
                   { "id": "w", "type": "condition", "data": {} },
                   { "id": "e", "type": "end", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" },
                   { "source": "c", "sourceHandle": "out",
                     "target": "w", "targetHandle": "cond" },
                   { "source": "w", "sourceHandle": "true",
                     "target": "e", "targetHandle": "in" },
                   { "source": "w", "sourceHandle": "false",
                     "target": "e", "targetHandle": "in" } ] }|};

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

  case "a condition with only one way out"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "t", "type": "compare",
                     "data": { "op": "lt", "values": { "a": 1, "b": 2 } } },
                   { "id": "w", "type": "condition", "data": {} },
                   { "id": "e", "type": "end", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "w", "targetHandle": "in" },
                   { "source": "t", "sourceHandle": "out",
                     "target": "w", "targetHandle": "cond" },
                   { "source": "w", "sourceHandle": "true",
                     "target": "e", "targetHandle": "in" } ] }|};

  (* Two ways into the middle of a loop is the shape wasm's blocks cannot
     express without duplicating code, so it is refused rather than guessed
     at. *)
  case "a loop entered two ways"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "t", "type": "compare",
                     "data": { "op": "lt", "values": { "a": 1, "b": 2 } } },
                   { "id": "c1", "type": "condition", "data": {} },
                   { "id": "c2", "type": "condition", "data": {} },
                   { "id": "a", "type": "log", "data": { "values": { "value": 1 } } },
                   { "id": "b", "type": "log", "data": { "values": { "value": 2 } } },
                   { "id": "e", "type": "end", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "c1", "targetHandle": "in" },
                   { "source": "t", "sourceHandle": "out",
                     "target": "c1", "targetHandle": "cond" },
                   { "source": "t", "sourceHandle": "out",
                     "target": "c2", "targetHandle": "cond" },
                   { "source": "c1", "sourceHandle": "true",
                     "target": "a", "targetHandle": "in" },
                   { "source": "c1", "sourceHandle": "false",
                     "target": "b", "targetHandle": "in" },
                   { "source": "a", "sourceHandle": "next",
                     "target": "c2", "targetHandle": "in" },
                   { "source": "b", "sourceHandle": "next",
                     "target": "c2", "targetHandle": "in" },
                   { "source": "c2", "sourceHandle": "true",
                     "target": "a", "targetHandle": "in" },
                   { "source": "c2", "sourceHandle": "false",
                     "target": "e", "targetHandle": "in" } ] }|};

  (* The parser's complaints reach the same place a wiring mistake does, so
     they are written for the person who typed the line, not for a compiler. *)
  case "an expression that does not parse"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "f", "type": "expr", "data": { "text": "n * * 2" } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "f", "sourceHandle": "out",
                     "target": "e", "targetHandle": "value" } ] }|};

  case "an expression naming something that is not there"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "f", "type": "expr", "data": { "text": "wobble(2)" } },
                   { "id": "e", "type": "end", "data": {} } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" },
                   { "source": "f", "sourceHandle": "out",
                     "target": "e", "targetHandle": "value" } ] }|};

  case "a for loop with nothing after it"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "l", "type": "forloop",
                     "data": { "name": "i", "values": { "first": 1, "last": 3 } } },
                   { "id": "a", "type": "log", "data": { "values": { "value": 1 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "l", "targetHandle": "in" },
                   { "source": "l", "sourceHandle": "body",
                     "target": "a", "targetHandle": "in" } ] }|};

  (* A graph saved when a Counter could take a value outright.  Reading it as
     a counting one would quietly compute something else. *)
  case "a counter carrying the old mode"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "c", "type": "counter",
                     "data": { "name": "c", "mode": "becomes",
                               "values": { "from": 0, "by": 1 } } },
                   { "id": "e", "type": "end", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "c", "targetHandle": "in" },
                   { "source": "c", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" } ] }|};

  case "not JSON at all" {|{ "nodes": [ |}
