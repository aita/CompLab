(* What a node looks like once its own settings are read: the title on the
   card, the sign in its icon, and above all the ports.  The editor draws
   exactly this, so the shapes here are the shapes on screen. *)

let case kind data =
  let json = Yojson.Safe.from_string data in
  let d = Ferret.Spec.describe ~kind ~data:json in
  let ports ps =
    String.concat ", "
      (List.map
         (fun (p : Ferret.Spec.port) ->
           Printf.sprintf "%s:%s(%s)" p.id p.label
             (match p.kind with
             | Ferret.Spec.Exec -> "exec"
             | Ferret.Spec.Num -> "num"
             | Ferret.Spec.Bool -> "bool"))
         ps)
  in
  Printf.printf "%-9s %s\n" kind data;
  Printf.printf "  %s [%s]%s\n" d.d_title d.d_glyph
    (match d.d_badge with Some b -> " badge " ^ b | None -> "");
  Printf.printf "  in   %s\n" (ports d.d_inputs);
  Printf.printf "  out  %s\n\n" (ports d.d_outputs)

let () =
  (* The start node's inputs are ports to wire from. *)
  case "start" {|{ "params": [ { "name": "n" }, { "name": "size" } ] }|};
  case "start" {|{ "params": [] }|};

  (* A counter says what it is called, and what its step means. *)
  case "counter" {|{ "name": "total", "mode": "by" }|};
  case "counter" {|{ "name": "cur", "mode": "becomes" }|};
  case "counter" {|{}|};

  case "forloop" {|{ "name": "row" }|};


  (* An operator names itself after the operator it is on. *)
  case "binop" {|{ "op": "mul" }|};
  case "unop" {|{ "op": "sqrt" }|};
  case "compare" {|{ "op": "ge" }|};
  case "logic" {|{ "op": "not" }|};
  case "logic" {|{ "op": "or" }|};
  case "binop" {|{ "op": "wat" }|};

  case "const" {|{ "value": 12 }|};
  case "const" {|{ "value": 0.25 }|};

  case "nonesuch" {|{}|}
