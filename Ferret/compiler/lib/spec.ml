(* The node catalogue.

   What a node is called, what colour it is, which ports it draws and what the
   inspector offers for it all live here, next to the lowering that gives the
   node its meaning.  The editor asks for this over the same bridge it asks
   for a compile, so there is one list of node kinds rather than two that have
   to be kept in step.

   Ports are the part that matters: their ids are what `lower.ml` reads out of
   `sourceHandle` / `targetHandle`, so a port drawn here and a port read there
   cannot drift apart. *)

type port_kind = Num | Bool | Text

type port = { id : string; label : string; kind : port_kind }

(* What the inspector puts in its form for a node of this kind. *)
type field =
  | Number of { key : string; label : string }
  | Text of { key : string; label : string }
  | Select of { key : string; label : string; options : (string * string) list }

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

let num id label = { id; label; kind = Num }
let cond id label = { id; label; kind = Bool }
let text id label = { id; label; kind = Text }
let op ?short ?sign op name = { op; name; short; sign }

let blank =
  {
    kind = "";
    title = "";
    glyph = "";
    color = "#667085";
    category = "Values";
    hint = "";
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
      kind = "out";
      title = "Out";
      glyph = "■";
      color = "#f79009";
      category = "Out";
      hint =
        "What a cook comes back with. A graph does not have to have one -- \
         Log and Say are ways out too -- but it can only have one.";
      inputs = [ num "value" "value" ];
      unique = true;
    };
    {
      blank with
      kind = "log";
      title = "Log";
      glyph = "✎";
      color = "#0ba5ec";
      category = "Out";
      hint =
        "Hand a number to the host, every cook. In the module this is a call \
         to env.log.";
      inputs = [ num "value" "value" ];
    };
    {
      blank with
      kind = "say";
      title = "Say";
      glyph = "say";
      color = "#0ba5ec";
      category = "Out";
      hint =
        "Hand a piece of text to the host, the way Log hands it a number. The \
         text is a literal: there is no memory in a graph to build one in.";
      inputs = [ text "text" "text" ];
    };
    {
      blank with
      kind = "feedback";
      title = "Feedback";
      glyph = "↺";
      color = "#15b79e";
      category = "Values";
      hint =
        "What the last cook left. Reading it gives that; what it is fed is \
         taken up at the end of this cook, at the same moment as every other \
         feedback. This is the only way a graph can depend on itself, and the \
         only way one cook can tell the next anything.";
      outputs = [ num "out" "held" ];
      inputs = [ num "value" "next" ];
      data =
        [
          ("name", `String "held");
          ("holds", `String "number");
          ("start", `Int 0);
        ];
      fields =
        [
          Text { key = "name"; label = "Name" };
          Select
            {
              key = "holds";
              label = "Holds";
              options = [ ("number", "a number"); ("flag", "a yes or no") ];
            };
          Number { key = "start"; label = "Starts at" };
        ];
    };
    {
      blank with
      kind = "select";
      title = "Choose";
      glyph = "?";
      color = "#f04438";
      category = "Operators";
      hint =
        "One of two values, by a condition. Both are worked out, which is \
         safe because nothing in a graph has an effect where it is read.";
      inputs = [ cond "cond" "if"; num "a" "then"; num "b" "else" ];
      outputs = [ num "out" "result" ];
      data = [ ("holds", `String "number") ];
      fields =
        [
          Select
            {
              key = "holds";
              label = "Chooses between";
              options = [ ("number", "numbers"); ("flag", "yes and no") ];
            };
        ];
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
      hint = "Combine true and false. And and Or work out both sides.";
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
         anything else. min, max, abs, sqrt, floor, ceil, round and random \
         are available.";
      outputs = [ num "out" "result" ];
      data = [ ("text", `String "x * x + y * y") ];
      fields = [ Text { key = "text"; label = "Expression" } ];
      entry = Some ("text", "x * x + y * y");
    };
    {
      blank with
      kind = "input";
      title = "Input";
      glyph = "in";
      color = "#7a5af8";
      category = "Values";
      hint =
        "A number the Run panel asks for before the run starts. It keeps what \
         it is given, so every cook reads the same value until it is changed.";
      outputs = [ num "value" "value" ];
      data = [ ("name", `String "n"); ("value", `Int 10) ];
      fields =
        [
          Text { key = "name"; label = "Name" };
          Number { key = "value"; label = "Default" };
        ];
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
      kind = "flag";
      title = "Yes or No";
      glyph = "T/F";
      color = "#7a5af8";
      category = "Values";
      hint =
        "A true or false, written down. Everything else that makes one -- a \
         comparison, an and -- works it out; this is the one that just says it.";
      outputs = [ cond "out" "value" ];
      data = [ ("value", `String "yes") ];
      fields =
        [
          Select
            {
              key = "value";
              label = "Value";
              options = [ ("yes", "yes (true)"); ("no", "no (false)") ];
            };
        ];
    };
    {
      blank with
      kind = "text";
      title = "Text";
      glyph = "abc";
      color = "#0ba5ec";
      category = "Values";
      hint =
        "A piece of text, to be said. It is a literal and stays one -- nothing \
         in the language takes text apart or puts it together.";
      outputs = [ text "out" "text" ];
      data = [ ("text", `String "hello") ];
      fields = [ Text { key = "text"; label = "Text" } ];
      entry = Some ("text", "hello");
    };
    {
      blank with
      kind = "time";
      title = "Time";
      glyph = "⏱";
      color = "#12b76a";
      category = "Values";
      hint =
        "What the host says the time is, in milliseconds, asked afresh every \
         cook. Two readers of it in one cook see the same moment.";
      outputs = [ num "out" "now" ];
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
         is drawn once per cook per node, and every reader of that node sees \
         the same draw.";
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
  (* What the inspector's form should offer, which a node's own settings can
     change as much as its ports: what a feedback starts at is a number or a
     yes-or-no depending on what it holds. *)
  d_fields : field list;
}

(* A badge shows a number the way it was typed, not the way an f64 prints. *)
let show_number v =
  if Float.is_integer v && Float.abs v < 1e16 then Printf.sprintf "%.0f" v
  else Printf.sprintf "%.12g" v

(* A node that works on either sort says which in its own settings, because
   the ports are drawn before anything is wired to them. *)
let flagged (n : Graph.node) =
  Graph.string_field n "holds" ~default:"number" = "flag"

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
      d_fields = s.fields;
    }
  in
  let name_field default = Graph.string_field n "name" ~default in
  match kind with
  | "feedback" ->
      (* What tells two of them apart is the name; what it holds decides what
         its ports take. *)
      let port = if flagged n then cond else num in
      {
        plain with
        d_title = name_field "Feedback";
        d_badge = (if flagged n then Some "yes/no" else None);
        d_inputs = [ port "value" "next" ];
        d_outputs = [ port "out" "held" ];
        d_fields =
          (if not (flagged n) then s.fields
           else
             List.map
               (function
                 | Number { key = "start"; label } ->
                     Select
                       {
                         key = "start";
                         label;
                         options = [ ("no", "no (false)"); ("yes", "yes (true)") ];
                       }
                 | f -> f)
               s.fields);
      }
  | "select" ->
      (* Both arms and the answer are the one sort of thing, and which sort is
         the node's to say: the ports have to be drawn before anything is
         wired to them. *)
      let port = if flagged n then cond else num in
      {
        plain with
        d_inputs = [ cond "cond" "if"; port "a" "then"; port "b" "else" ];
        d_outputs = [ port "out" "result" ];
      }
  | "input" -> { plain with d_title = name_field "Input" }
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

let json_of_kind = function
  | Num -> "num"
  | Bool -> "bool"
  | Text -> "text"

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
      ("fields", `List (List.map json_of_field d.d_fields));
    ]

let describe_json ~kind ~data = json_of_described (describe ~kind ~data)
