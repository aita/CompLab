(* Human-readable dumps of the intermediate forms, for `--dump-...`. *)

open Printf

let indent n = String.make (n * 2) ' '

let rec anf out level exp =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  let vars = String.concat " " in
  match exp with
  | Anf.Int n -> say "%d" n
  | Anf.Var x -> say "%s" x
  | Anf.Neg x -> say "- %s" x
  | Anf.Bin (op, x, y) -> say "%s %s %s" x (Anf.string_of_binop op) y
  | Anf.Static l -> say "&%s" l
  | Anf.Field (x, i) -> say "%s[%d]" x i
  | Anf.Byte (x, i) -> say "%s.[%s]" x i
  | Anf.Block (tag, xs) -> say "block %d (%s)" tag (vars xs)
  (* Commas, not the spaces the other forms use: `(a b)` reads as an
     application. *)
  | Anf.Tuple xs -> say "(%s)" (String.concat ", " xs)
  | Anf.Array (n, v) -> say "Array.make %s %s" n v
  | Anf.Get (a, i) -> say "%s.(%s)" a i
  | Anf.Put (a, i, v) -> say "%s.(%s) <- %s" a i v
  | Anf.App (f, xs) -> say "%s %s" f (vars xs)
  | Anf.App_external (f, xs) -> say "external %s %s" f (vars xs)
  | Anf.If_eq (x, y, e1, e2) -> conditional out level "=" x y e1 e2
  | Anf.If_le (x, y, e1, e2) -> conditional out level "<=" x y e1 e2
  | Anf.Let ((x, t), e1, e2) ->
    say "let %s : %s =" x (Types.to_string t);
    anf out (level + 1) e1;
    say "in";
    anf out level e2
  | Anf.Let_tuple (xts, y, e) ->
    say "let (%s) = %s in" (String.concat ", " (List.map fst xts)) y;
    anf out level e
  | Anf.Let_rec (fds, e) ->
    List.iter
      (fun (fd : Anf.fundef) ->
        say "let rec %s %s =" (fst fd.name) (vars (List.map fst fd.args));
        anf out (level + 1) fd.body)
      fds;
    say "in";
    anf out level e

and conditional out level op x y e1 e2 =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  say "if %s %s %s then" x op y;
  anf out (level + 1) e1;
  say "else";
  anf out (level + 1) e2

let rec closure out level exp =
  let say fmt = fprintf out ("%s" ^^ fmt ^^ "\n") (indent level) in
  let vars = String.concat " " in
  match exp with
  | Closure.Int n -> say "%d" n
  | Closure.Var x -> say "%s" x
  | Closure.Neg x -> say "- %s" x
  | Closure.Bin (op, x, y) -> say "%s %s %s" x (Anf.string_of_binop op) y
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
  fprintf out "sable_main () =\n";
  closure out 1 program.main
