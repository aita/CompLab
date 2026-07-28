(* Human-readable dumps of the intermediate forms, for `--dump-...`. *)

open Printf

let indent n = String.make (n * 2) ' '

let rec knormal out level exp =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  let vars = String.concat " " in
  match exp with
  | Knormal.Int n -> say "%d" n
  | Knormal.Var x -> say "%s" x
  | Knormal.Neg x -> say "- %s" x
  | Knormal.Bin (op, x, y) -> say "%s %s %s" x (Knormal.string_of_binop op) y
  | Knormal.Static l -> say "&%s" l
  | Knormal.Field (x, i) -> say "%s[%d]" x i
  | Knormal.Byte (x, i) -> say "%s.[%s]" x i
  | Knormal.Block (tag, xs) -> say "block %d (%s)" tag (vars xs)
  (* Commas, not the spaces the other forms use: `(a b)` reads as an
     application. *)
  | Knormal.Tuple xs -> say "(%s)" (String.concat ", " xs)
  | Knormal.Array (n, v) -> say "Array.make %s %s" n v
  | Knormal.Get (a, i) -> say "%s.(%s)" a i
  | Knormal.Put (a, i, v) -> say "%s.(%s) <- %s" a i v
  | Knormal.App (f, xs) -> say "%s %s" f (vars xs)
  | Knormal.App_external (f, xs) -> say "external %s %s" f (vars xs)
  | Knormal.If_eq (x, y, e1, e2) -> conditional out level "=" x y e1 e2
  | Knormal.If_le (x, y, e1, e2) -> conditional out level "<=" x y e1 e2
  | Knormal.Let ((x, t), e1, e2) ->
    say "let %s : %s =" x (Types.to_string t);
    knormal out (level + 1) e1;
    say "in";
    knormal out level e2
  | Knormal.Let_tuple (xts, y, e) ->
    say "let (%s) = %s in" (String.concat ", " (List.map fst xts)) y;
    knormal out level e
  | Knormal.Let_rec (fds, e) ->
    List.iter
      (fun (fd : Knormal.fundef) ->
        say "let rec %s %s =" (fst fd.name) (vars (List.map fst fd.args));
        knormal out (level + 1) fd.body)
      fds;
    say "in";
    knormal out level e

and conditional out level op x y e1 e2 =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  say "if %s %s %s then" x op y;
  knormal out (level + 1) e1;
  say "else";
  knormal out (level + 1) e2

let rec closure out level exp =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  let vars = String.concat " " in
  match exp with
  | Closure.Int n -> say "%d" n
  | Closure.Var x -> say "%s" x
  | Closure.Neg x -> say "- %s" x
  | Closure.Bin (op, x, y) -> say "%s %s %s" x (Knormal.string_of_binop op) y
  | Closure.Static l -> say "&%s" l
  | Closure.Field (x, i) -> say "%s[%d]" x i
  | Closure.Byte (x, i) -> say "%s.[%s]" x i
  | Closure.Block (tag, xs) -> say "block %d (%s)" tag (vars xs)
  | Closure.Tuple xs -> say "(%s)" (String.concat ", " xs)
  | Closure.Array (n, v) -> say "Array.make %s %s" n v
  | Closure.Get (a, i) -> say "%s.(%s)" a i
  | Closure.Put (a, i, v) -> say "%s.(%s) <- %s" a i v
  | Closure.Call_direct (l, xs) -> say "call %s (%s)" l (vars xs)
  | Closure.Call_closure (f, xs) -> say "call closure %s (%s)" f (vars xs)
  | Closure.If_eq (x, y, e1, e2) -> closure_if out level "=" x y e1 e2
  | Closure.If_le (x, y, e1, e2) -> closure_if out level "<=" x y e1 e2
  | Closure.Let ((x, t), e1, e2) ->
    say "let %s : %s =" x (Types.to_string t);
    closure out (level + 1) e1;
    say "in";
    closure out level e2
  | Closure.Let_tuple (xts, y, e) ->
    say "let (%s) = %s in" (String.concat ", " (List.map fst xts)) y;
    closure out level e
  | Closure.Make_closures (definitions, e) ->
    List.iter
      (fun ((x, _), (c : Closure.closure)) ->
        say "let %s = closure %s capturing (%s)" x c.entry (vars c.captured))
      definitions;
    say "in";
    closure out level e

and closure_if out level op x y e1 e2 =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  say "if %s %s %s then" x op y;
  closure out (level + 1) e1;
  say "else";
  closure out (level + 1) e2

let closure_program out (program : Closure.program) =
  List.iter
    (fun (fd : Closure.fundef) ->
      fprintf out "%s (%s)%s =\n" fd.label
        (String.concat " " (List.map fst fd.args))
        (if fd.captures = [] then ""
         else " capturing (" ^ String.concat " " (List.map fst fd.captures) ^ ")");
      closure out 1 fd.body)
    program.functions;
  fprintf out "martenml_main () =\n";
  closure out 1 program.main

(* -------------------------------------------------------------------- Linear *)

let linear_op out = function
  | Linear.Int n -> fprintf out "%d" n
  | Linear.Move x -> fprintf out "%s" x
  | Linear.Neg x -> fprintf out "- %s" x
  | Linear.Bin (op, x, y) -> fprintf out "%s %s %s" x (Knormal.string_of_binop op) y
  | Linear.Cmp (c, x, y, negated) ->
    let op = match (c, negated) with
      | Linear.Eq, false -> "=" | Linear.Eq, true -> "<>"
      | Linear.Le, false -> "<=" | Linear.Le, true -> ">"
    in
    fprintf out "%s %s %s" x op y
  | Linear.Static l -> fprintf out "&%s" l
  | Linear.Field (x, i) -> fprintf out "%s[%d]" x i
  | Linear.Byte (x, i) -> fprintf out "%s.[%s]" x i
  | Linear.Block (tag, xs) -> fprintf out "block %d (%s)" tag (String.concat " " xs)
  | Linear.Tuple xs -> fprintf out "(%s)" (String.concat ", " xs)
  | Linear.Array (n, v) -> fprintf out "Array.make %s %s" n v
  | Linear.Get (a, i) -> fprintf out "%s.(%s)" a i
  | Linear.Put (a, i, v) -> fprintf out "%s.(%s) <- %s" a i v
  | Linear.Call (Linear.Direct l, xs) -> fprintf out "call %s (%s)" l (String.concat " " xs)
  | Linear.Call (Linear.Closure f, xs) -> fprintf out "call closure %s (%s)" f (String.concat " " xs)

let linear_instr out = function
  | Linear.Let (x, op) ->
    fprintf out "    %s <- " x;
    linear_op out op;
    fprintf out "\n"
  | Linear.Closures definitions ->
    List.iter
      (fun (x, entry, captured) ->
        fprintf out "    %s <- closure %s capturing (%s)\n" x entry
          (String.concat " " captured))
      definitions

let linear_terminator out = function
  | Linear.Jump l -> fprintf out "    jump %s\n" l
  | Linear.Branch (c, x, y, t, f) ->
    let op = match c with Linear.Eq -> "=" | Linear.Le -> "<=" in
    fprintf out "    if %s %s %s then %s else %s\n" x op y t f
  | Linear.Return x -> fprintf out "    return %s\n" x
  | Linear.Tail (Linear.Direct l, xs) -> fprintf out "    tail %s (%s)\n" l (String.concat " " xs)
  | Linear.Tail (Linear.Closure f, xs) ->
    fprintf out "    tail closure %s (%s)\n" f (String.concat " " xs)

let linear out functions =
  List.iter
    (fun (f : Linear.func) ->
      fprintf out "function %s (%s)%s\n" f.label (String.concat " " f.args)
        (if f.captures = [] then ""
         else " capturing (" ^ String.concat " " f.captures ^ ")");
      List.iter
        (fun (b : Linear.block) ->
          fprintf out "  %s:\n" b.label;
          List.iter (linear_instr out) b.body;
          linear_terminator out b.terminator)
        f.blocks)
    functions
