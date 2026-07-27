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
  | Knormal.Block (tag, xs) -> say "block %d (%s)" tag (vars xs)
  | Knormal.Tuple xs -> say "(%s)" (vars xs)
  | Knormal.Array (n, v) -> say "Array.make %s %s" n v
  | Knormal.Get (a, i) -> say "%s.(%s)" a i
  | Knormal.Put (a, i, v) -> say "%s.(%s) <- %s" a i v
  | Knormal.App (f, xs) -> say "%s %s" f (vars xs)
  | Knormal.ExtFunApp (f, xs) -> say "external %s %s" f (vars xs)
  | Knormal.IfEq (x, y, e1, e2) -> conditional out level "=" x y e1 e2
  | Knormal.IfLe (x, y, e1, e2) -> conditional out level "<=" x y e1 e2
  | Knormal.Let ((x, t), e1, e2) ->
    say "let %s : %s =" x (Types.to_string t);
    knormal out (level + 1) e1;
    say "in";
    knormal out level e2
  | Knormal.LetTuple (xts, y, e) ->
    say "let (%s) = %s in" (String.concat ", " (List.map fst xts)) y;
    knormal out level e
  | Knormal.LetRec (fds, e) ->
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
  | Closure.Block (tag, xs) -> say "block %d (%s)" tag (vars xs)
  | Closure.Tuple xs -> say "(%s)" (vars xs)
  | Closure.Array (n, v) -> say "Array.make %s %s" n v
  | Closure.Get (a, i) -> say "%s.(%s)" a i
  | Closure.Put (a, i, v) -> say "%s.(%s) <- %s" a i v
  | Closure.Call_direct (l, xs) -> say "call %s (%s)" l (vars xs)
  | Closure.Call_closure (f, xs) -> say "call closure %s (%s)" f (vars xs)
  | Closure.IfEq (x, y, e1, e2) -> closure_if out level "=" x y e1 e2
  | Closure.IfLe (x, y, e1, e2) -> closure_if out level "<=" x y e1 e2
  | Closure.Let ((x, t), e1, e2) ->
    say "let %s : %s =" x (Types.to_string t);
    closure out (level + 1) e1;
    say "in";
    closure out level e2
  | Closure.LetTuple (xts, y, e) ->
    say "let (%s) = %s in" (String.concat ", " (List.map fst xts)) y;
    closure out level e
  | Closure.Make_closure ((x, _), { entry; captured }, e) ->
    say "let %s = closure %s capturing (%s) in" x entry (vars captured);
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
