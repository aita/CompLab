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
  case "a graph with nothing in it" {|{ "nodes": [], "edges": [] }|};

  case "two out nodes"
    {|{ "nodes": [ { "id": "a", "type": "out", "data": { "values": { "value": 1 } } },
                   { "id": "b", "type": "out", "data": { "values": { "value": 2 } } } ],
        "edges": [] }|};

  case "an unconnected input"
    {|{ "nodes": [ { "id": "o", "type": "out", "data": {} } ],
        "edges": [] }|};

  case "a number where a condition belongs"
    {|{ "nodes": [ { "id": "c", "type": "const", "data": { "value": 1 } },
                   { "id": "p", "type": "select",
                     "data": { "values": { "a": 1, "b": 2 } } },
                   { "id": "o", "type": "out", "data": {} } ],
        "edges": [ { "source": "c", "sourceHandle": "out",
                     "target": "p", "targetHandle": "cond" },
                   { "source": "p", "sourceHandle": "out",
                     "target": "o", "targetHandle": "value" } ] }|};

  case "a condition where a number belongs"
    {|{ "nodes": [ { "id": "cmp", "type": "compare",
                     "data": { "op": "lt", "values": { "a": 1, "b": 2 } } },
                   { "id": "sum", "type": "binop",
                     "data": { "op": "add", "values": { "b": 1 } } },
                   { "id": "o", "type": "out", "data": {} } ],
        "edges": [ { "source": "cmp", "sourceHandle": "out",
                     "target": "sum", "targetHandle": "a" },
                   { "source": "sum", "sourceHandle": "out",
                     "target": "o", "targetHandle": "value" } ] }|};

  (* Within a cook the graph is a DAG.  A ring of nodes has no value to give,
     and the node that closes it is where to say so. *)
  case "a cycle with no feedback in it"
    {|{ "nodes": [ { "id": "add", "type": "binop", "data": { "op": "add" } },
                   { "id": "one", "type": "const", "data": { "value": 1 } },
                   { "id": "o", "type": "out", "data": {} } ],
        "edges": [ { "source": "add", "sourceHandle": "out",
                     "target": "o", "targetHandle": "value" },
                   { "source": "add", "sourceHandle": "out",
                     "target": "add", "targetHandle": "a" },
                   { "source": "one", "sourceHandle": "out",
                     "target": "add", "targetHandle": "b" } ] }|};

  (* A feedback that says it holds a yes-or-no wants one on the way in too,
     the same as any other port that takes a condition. *)
  case "a flag fed a number"
    {|{ "nodes": [ { "id": "f", "type": "feedback",
                     "data": { "name": "lit", "holds": "flag" } },
                   { "id": "one", "type": "const", "data": { "value": 1 } },
                   { "id": "o", "type": "out", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "one", "sourceHandle": "out",
                     "target": "f", "targetHandle": "value" } ] }|};

  (* There is no memory in a graph to build a piece of text in, so the only
     thing a Say can be given is a written-down one. *)
  case "a number said"
    {|{ "nodes": [ { "id": "n", "type": "const", "data": { "value": 1 } },
                   { "id": "s", "type": "say", "data": {} } ],
        "edges": [ { "source": "n", "sourceHandle": "out",
                     "target": "s", "targetHandle": "text" } ] }|};

  (* The parser's complaints reach the same place a wiring mistake does, so
     they are written for the person who typed the line, not for a compiler. *)
  case "an expression that does not parse"
    {|{ "nodes": [ { "id": "f", "type": "expr", "data": { "text": "n * * 2" } },
                   { "id": "o", "type": "out", "data": {} } ],
        "edges": [ { "source": "f", "sourceHandle": "out",
                     "target": "o", "targetHandle": "value" } ] }|};

  case "an expression naming something that is not there"
    {|{ "nodes": [ { "id": "f", "type": "expr", "data": { "text": "wobble(2)" } },
                   { "id": "o", "type": "out", "data": {} } ],
        "edges": [ { "source": "f", "sourceHandle": "out",
                     "target": "o", "targetHandle": "value" } ] }|};

  (* A graph saved when the language still ran on a thread of control.  Read
     as a dataflow one it would quietly compute something else. *)
  case "a graph from the control-flow days"
    {|{ "nodes": [ { "id": "s", "type": "start", "data": {} },
                   { "id": "e", "type": "end", "data": { "values": { "value": 0 } } } ],
        "edges": [ { "source": "s", "sourceHandle": "next",
                     "target": "e", "targetHandle": "in" } ] }|};

  case "not JSON at all" {|{ "nodes": [ |}
