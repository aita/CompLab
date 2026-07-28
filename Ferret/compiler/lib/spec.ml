(* The node catalogue.

   What a node is called, what colour it is, which ports it draws and what the
   inspector offers for it all live here, next to the lowering that gives the
   node its meaning.  The editor asks for this over the same bridge it asks
   for a compile, so there is one list of node kinds rather than two that have
   to be kept in step.

   Ports are the part that matters: their ids are what `lower.ml` reads out of
   `sourceHandle` / `targetHandle`, so a port drawn here and a port read there
   cannot drift apart. *)

type port_kind = Exec | Num | Bool

type port = { id : string; label : string; kind : port_kind }

(* What the inspector puts in its form for a node of this kind. *)
type field =
  | Number of { key : string; label : string }
  | Text of { key : string; label : string }
  | Select of { key : string; label : string; options : (string * string) list }
  | Names of { key : string; label : string; item : string }

(* One operator of a family.  [short] is what the palette calls it where the
   full name does not fit; [sign] is what goes in the icon. *)
type op = { op : string; name : string; short : string option; sign : string option }

type t = {
  kind : string;
  title : string;
  glyph : string;
  color : string;
  category : string;
  hint : string;
  (* The ways in.  The first is drawn on the header, along the line the flow
     runs; any others get a row of their own. *)
  exec_in : port list;
  exec_out : port list;
  inputs : port list;
  outputs : port list;
  data : (string * Yojson.Safe.t) list;
  fields : field list;
  (* A line of text edited on the card, for a node that mostly *is* its text *)
  entry : (string * string) option;  (* key, placeholder *)
  (* The operators this one kind stands for, offered one at a time *)
  variants : (string * op list) option;  (* key, operators *)
  unique : bool;
}

let exec id label = { id; label; kind = Exec }
let num id label = { id; label; kind = Num }
let cond id label = { id; label; kind = Bool }
let op ?short ?sign op name = { op; name; short; sign }

let next = [ exec "next" "next" ]

let blank =
  {
    kind = "";
    title = "";
    glyph = "";
    color = "#667085";
    category = "Values";
    hint = "";
    exec_in = [];
    exec_out = [];
    inputs = [];
    outputs = [];
    data = [];
    fields = [];
    entry = None;
    variants = None;
    unique = false;
  }

(* ------------------------------------------------------- the operators *)

let arith =
  [
    op "add" "Add" ~sign:"+";
    op "sub" "Subtract" ~sign:"−";
    op "mul" "Multiply" ~sign:"×";
    op "div" "Divide" ~sign:"÷";
    op "mod" "Remainder" ~sign:"%";
    op "min" "Minimum" ~sign:"min";
    op "max" "Maximum" ~sign:"max";
  ]

let funcs =
  [
    op "neg" "Negate" ~sign:"neg";
    op "abs" "Absolute value" ~short:"Absolute" ~sign:"abs";
    op "sqrt" "Square root" ~sign:"sqrt";
    op "floor" "Round down" ~sign:"floor";
    op "ceil" "Round up" ~sign:"ceil";
    op "round" "Round" ~sign:"round";
  ]

let cmps =
  [
    op "lt" "Less than" ~sign:"<";
    op "le" "At most" ~sign:"≤";
    op "gt" "Greater than" ~short:"Greater" ~sign:">";
    op "ge" "At least" ~sign:"≥";
    op "eq" "Equal" ~sign:"=";
    op "ne" "Not equal" ~sign:"≠";
  ]

let logic =
  [ op "and" "And" ~sign:"and"; op "or" "Or" ~sign:"or"; op "not" "Not" ~sign:"not" ]

(* The sign goes next to the name in the dropdown unless it only repeats it:
   "Minimum  min" is worth saying, "And  and" is not. *)
let options ops =
  List.map
    (fun o ->
      match o.sign with
      | Some s when s <> String.lowercase_ascii o.name -> (o.op, o.name ^ "  " ^ s)
      | _ -> (o.op, o.name))
    ops

(* ------------------------------------------------------- the catalogue *)

let catalogue : t list =
  [
    {
      blank with
      kind = "start";
      title = "Start";
      glyph = "▶";
      color = "#12b76a";
      category = "Flow";
      hint =
        "Where the flow begins. It hands out one thing: when the run started, \
         in milliseconds, from the host. A graph takes no arguments.";
      exec_out = next;
      outputs = [ num "time" "started at" ];
      unique = true;
    };
    {
      blank with
      kind = "end";
      title = "End";
      glyph = "■";
      color = "#f79009";
      category = "Flow";
      hint = "Return a value and stop.";
      exec_in = [ exec "in" "in" ];
      inputs = [ num "value" "result" ];
    };
    {
      blank with
      kind = "select";
      title = "Choose";
      glyph = "?";
      color = "#f04438";
      category = "Flow";
      hint =
        "The only branch there is: pick one of two numbers by a condition. \
         Both are evaluated, which is safe because nothing in an expression \
         has an effect.";
      inputs = [ cond "cond" "if"; num "a" "then"; num "b" "else" ];
      outputs = [ num "out" "result" ];
    };
    {
      blank with
      kind = "condition";
      title = "Condition";
      glyph = "Y";
      color = "#f04438";
      category = "Flow";
      hint =
        "Sends the flow one way or the other. A loop is a Condition with a \
         wire running back into it from the end of the body.";
      exec_in = [ exec "in" "in" ];
      exec_out = [ exec "true" "true"; exec "false" "false" ];
      inputs = [ cond "cond" "test" ];
    };
    {
      blank with
      kind = "counter";
      title = "Counter";
      glyph = "i";
      color = "#06aed4";
      category = "Flow";
      hint =
        "Counts. It starts at one value and, every time the flow passes \
         through it, adds another to what it holds. Wire `by` to something \
         other than a constant and it accumulates.";
      exec_in = [ exec "in" "in" ];
      exec_out = next;
      inputs = [ num "from" "starts at"; num "by" "moves by" ];
      outputs = [ num "value" "value" ];
      data =
        [
          ("name", `String "i");
          ("values", `Assoc [ ("from", `Int 0); ("by", `Int 1) ]);
        ];
      fields = [ Text { key = "name"; label = "Name" } ];
    };
    {
      blank with
      kind = "state";
      title = "State";
      glyph = "S";
      color = "#15b79e";
      category = "Flow";
      hint =
        "Remembers one number. Passing through stores what it is fed, and \
         reading its output anywhere gives back the last thing stored. There \
         is a second way through, `reset`, that puts back what it started \
         with -- which is what a state inside a loop needs and a Counter \
         cannot say.";
      exec_in = [ exec "in" "in"; exec "reset" "reset" ];
      exec_out = [ exec "next" "next"; exec "after" "after reset" ];
      inputs = [ num "initial" "starts at"; num "value" "stores" ];
      outputs = [ num "value" "value" ];
      data =
        [
          ("name", `String "s");
          ("values", `Assoc [ ("initial", `Int 0) ]);
        ];
      fields = [ Text { key = "name"; label = "Name" } ];
    };
    {
      blank with
      kind = "wait";
      title = "Wait for Event";
      glyph = "wait";
      color = "#f63d68";
      category = "Flow";
      hint =
        "Stops until the host has an event, and hands over the number it sent. \
         The only node that takes time: a loop with one of these in it is an \
         event loop, and the loop is drawn rather than hidden in the runtime.";
      exec_in = [ exec "in" "in" ];
      exec_out = next;
      outputs = [ num "value" "event" ];
      data = [ ("name", `String "e") ];
      fields = [ Text { key = "name"; label = "Name" } ];
    };
    {
      blank with
      kind = "forloop";
      title = "For Loop";
      glyph = "1..n";
      color = "#d444f1";
      category = "Flow";
      hint =
        "Counts from the first value to the last, running the body once for \
         each. It is a Counter and a Condition wired into a loop, drawn as one \
         node: the end of the body goes back to it on its own.";
      exec_in = [ exec "in" "in" ];
      exec_out = [ exec "body" "body"; exec "done" "done" ];
      inputs = [ num "first" "from"; num "last" "to" ];
      outputs = [ num "index" "index" ];
      data =
        [
          ("name", `String "i");
          ("values", `Assoc [ ("first", `Int 1); ("last", `Int 10) ]);
        ];
      fields = [ Text { key = "name"; label = "Name" } ];
    };
    {
      blank with
      kind = "log";
      title = "Log";
      glyph = "✎";
      color = "#0ba5ec";
      category = "Flow";
      hint = "Hand a value to the host. In the module this is a call to env.log.";
      exec_in = [ exec "in" "in" ];
      exec_out = next;
      inputs = [ num "value" "value" ];
    };
    {
      blank with
      kind = "binop";
      title = "Arithmetic";
      glyph = "+";
      color = "#2e90fa";
      category = "Operators";
      hint = "Combine two numbers.";
      inputs = [ num "a" "A"; num "b" "B" ];
      outputs = [ num "out" "result" ];
      data = [ ("op", `String "add") ];
      fields =
        [ Select { key = "op"; label = "Operator"; options = options arith } ];
      variants = Some ("op", arith);
    };
    {
      blank with
      kind = "unop";
      title = "Math function";
      glyph = "ƒ";
      color = "#2e90fa";
      category = "Operators";
      hint = "A built-in that takes one number.";
      inputs = [ num "a" "A" ];
      outputs = [ num "out" "result" ];
      data = [ ("op", `String "abs") ];
      fields =
        [ Select { key = "op"; label = "Function"; options = options funcs } ];
      variants = Some ("op", funcs);
    };
    {
      blank with
      kind = "compare";
      title = "Comparison";
      glyph = "<";
      color = "#7a5af8";
      category = "Operators";
      hint = "Compare two numbers and produce true or false.";
      inputs = [ num "a" "A"; num "b" "B" ];
      outputs = [ cond "out" "result" ];
      data = [ ("op", `String "lt") ];
      fields = [ Select { key = "op"; label = "Test"; options = options cmps } ];
      variants = Some ("op", cmps);
    };
    {
      blank with
      kind = "logic";
      title = "Logic";
      glyph = "&";
      color = "#7a5af8";
      category = "Operators";
      hint = "Combine true and false. And and Or evaluate both sides.";
      inputs = [ cond "a" "A"; cond "b" "B" ];
      outputs = [ cond "out" "result" ];
      data = [ ("op", `String "and") ];
      fields =
        [ Select { key = "op"; label = "Operator"; options = options logic } ];
      variants = Some ("op", logic);
    };
    {
      blank with
      kind = "expr";
      title = "Expression";
      glyph = "()";
      color = "#2e90fa";
      category = "Operators";
      hint =
        "A whole calculation typed as text, instead of a chain of a dozen \
         nodes. The names it uses become its input ports, so it wires up like \
         anything else. min, max, abs, sqrt, floor, ceil, round and random are \
         available.";
      outputs = [ num "out" "result" ];
      data = [ ("text", `String "x * x + y * y") ];
      fields = [ Text { key = "text"; label = "Expression" } ];
      entry = Some ("text", "x * x + y * y");
    };
    {
      blank with
      kind = "const";
      title = "Constant";
      glyph = "#";
      color = "#667085";
      category = "Values";
      hint =
        "One f64.const, for when the same number is wanted in several places. \
         A single use can be typed into the port instead.";
      outputs = [ num "out" "value" ];
      data = [ ("value", `Int 0) ];
      fields = [ Number { key = "value"; label = "Value" } ];
    };
    {
      blank with
      kind = "random";
      title = "Random";
      glyph = "~";
      color = "#ee46bc";
      category = "Values";
      hint =
        "A number in [min, max), drawn from the host. The one impure node: it \
         is drawn once each time the node is reached, and every reader of that \
         node sees the same draw.";
      inputs = [ num "min" "min"; num "max" "max" ];
      outputs = [ num "out" "value" ];
      data = [ ("values", `Assoc [ ("min", `Int 0); ("max", `Int 1) ]) ];
    };
  ]

let find kind = List.find_opt (fun s -> s.kind = kind) catalogue

(* The categories in the order the palette should show them, taken from the
   order the kinds are listed in above. *)
let categories =
  List.fold_left
    (fun seen s -> if List.mem s.category seen then seen else seen @ [ s.category ])
    [] catalogue

(* ------------------------------------- what one node of a kind looks like *)

type described = {
  d_title : string;
  d_glyph : string;
  d_badge : string option;
  d_inputs : port list;
  d_outputs : port list;
}

(* A badge shows a number the way it was typed, not the way an f64 prints. *)
let show_number v =
  if Float.is_integer v && Float.abs v < 1e16 then Printf.sprintf "%.0f" v
  else Printf.sprintf "%.12g" v

let chosen ops n =
  let id = Graph.string_field n "op" ~default:"" in
  List.find_opt (fun o -> o.op = id) ops

let of_op ops (s : t) n =
  match chosen ops n with
  | Some o -> (o.name, Option.value o.sign ~default:s.glyph)
  | None -> (s.title, s.glyph)

let describe ~kind ~(data : Yojson.Safe.t) : described =
  let n = { Graph.id = ""; kind; data } in
  let s = Option.value (find kind) ~default:{ blank with kind; title = kind; glyph = "?" } in
  let plain =
    {
      d_title = s.title;
      d_glyph = s.glyph;
      d_badge = None;
      d_inputs = s.inputs;
      d_outputs = s.outputs;
    }
  in
  let name_field default = Graph.string_field n "name" ~default in
  match kind with
  | "counter" ->
      (* Two of them in a row both saying "Counter" is what makes a loop look
         like ceremony; the name is the thing that tells them apart. *)
      { plain with d_title = name_field "Counter" }
  | "forloop" -> { plain with d_title = "For " ^ name_field "i" }
  | "state" ->
      (* Like a counter, what tells two of them apart is the name. *)
      { plain with d_title = name_field "State" }
  | "wait" -> { plain with d_title = "Wait for " ^ name_field "e" }
  | "const" ->
      {
        plain with
        d_badge = Some (show_number (Graph.number_field n "value" ~default:0.));
      }
  | "expr" ->
      (* The names the text leaves free are the ports.  Reading them off the
         tokens rather than the parse keeps the ports still while a formula is
         half-typed and does not parse yet. *)
      let text = Graph.string_field n "text" ~default:"" in
      let out =
        if Formula.is_condition text then cond "out" "result" else num "out" "result"
      in
      {
        plain with
        d_inputs = List.map (fun v -> num v v) (Formula.free_names text);
        d_outputs = [ out ];
      }
  | "logic" ->
      let title, glyph = of_op logic s n in
      {
        plain with
        d_title = title;
        d_glyph = glyph;
        d_inputs =
          (if Graph.string_field n "op" ~default:"and" = "not" then [ cond "a" "A" ]
           else [ cond "a" "A"; cond "b" "B" ]);
      }
  | "binop" | "unop" | "compare" ->
      let ops =
        match kind with "binop" -> arith | "unop" -> funcs | _ -> cmps
      in
      let title, glyph = of_op ops s n in
      { plain with d_title = title; d_glyph = glyph }
  | _ -> plain

(* ---------------------------------------------------------------- JSON *)

let json_of_kind = function Exec -> "exec" | Num -> "num" | Bool -> "bool"

let json_of_port p : Yojson.Safe.t =
  `Assoc
    [
      ("id", `String p.id);
      ("label", `String p.label);
      ("kind", `String (json_of_kind p.kind));
    ]

let json_of_ports ps : Yojson.Safe.t = `List (List.map json_of_port ps)

let json_of_field : field -> Yojson.Safe.t = function
  | Number { key; label } ->
      `Assoc [ ("key", `String key); ("label", `String label); ("kind", `String "number") ]
  | Text { key; label } ->
      `Assoc [ ("key", `String key); ("label", `String label); ("kind", `String "text") ]
  | Select { key; label; options } ->
      `Assoc
        [
          ("key", `String key);
          ("label", `String label);
          ("kind", `String "select");
          ( "options",
            `List (List.map (fun (v, l) -> `List [ `String v; `String l ]) options) );
        ]
  | Names { key; label; item } ->
      `Assoc
        [
          ("key", `String key);
          ("label", `String label);
          ("kind", `String "names");
          ("itemLabel", `String item);
        ]

let json_of_op o : Yojson.Safe.t =
  `Assoc
    ([ ("id", `String o.op); ("name", `String o.name) ]
    @ (match o.short with Some s -> [ ("short", `String s) ] | None -> [])
    @ match o.sign with Some s -> [ ("sign", `String s) ] | None -> [])

let json_of_spec s : Yojson.Safe.t =
  `Assoc
    [
      ("type", `String s.kind);
      ("title", `String s.title);
      ("glyph", `String s.glyph);
      ("color", `String s.color);
      ("category", `String s.category);
      ("hint", `String s.hint);
      ("execIn", json_of_ports s.exec_in);
      ("execOut", json_of_ports s.exec_out);
      ("inputs", json_of_ports s.inputs);
      ("outputs", json_of_ports s.outputs);
      ("data", `Assoc s.data);
      ("fields", `List (List.map json_of_field s.fields));
      ( "entry",
        match s.entry with
        | Some (key, placeholder) ->
            `Assoc [ ("key", `String key); ("placeholder", `String placeholder) ]
        | None -> `Null );
      ( "variants",
        match s.variants with
        | Some (key, ops) ->
            `Assoc [ ("key", `String key); ("of", `List (List.map json_of_op ops)) ]
        | None -> `Null );
      ("unique", `Bool s.unique);
    ]

let to_json () : Yojson.Safe.t =
  `Assoc
    [
      ("categories", `List (List.map (fun c -> `String c) categories));
      ("nodes", `List (List.map json_of_spec catalogue));
    ]

let json_of_described d : Yojson.Safe.t =
  `Assoc
    [
      ("title", `String d.d_title);
      ("glyph", `String d.d_glyph);
      ("badge", match d.d_badge with Some b -> `String b | None -> `Null);
      ("inputs", json_of_ports d.d_inputs);
      ("outputs", json_of_ports d.d_outputs);
    ]

let describe_json ~kind ~data = json_of_described (describe ~kind ~data)
