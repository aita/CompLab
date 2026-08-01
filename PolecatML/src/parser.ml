(* Recursive descent over the token array, with one function per precedence
   level.  Nothing here backtracks: at every point the next token decides which
   branch to take.

   The grammar, in the order the functions below appear:

     program   := decl* eof
     decl      := "val" pat (":" ty)? "=" expr
                | "fun" clause ("and" clause)*
     clause    := ident params (":" ty)? "=" expr
     params    := "(" ")" | "(" pat ("," pat)* ")"

     expr      := "if" expr "then" expr "else" expr
                | "fn" params "=>" expr
                | orelse
     orelse    := andalso ("orelse" andalso)*
     andalso   := compare ("andalso" compare)*
     compare   := sum (("=" | "<>" | "<" | "<=" | ">" | ">=") sum)?
     sum       := product (("+" | "-") product)*
     product   := unary (("*" | "/" | "mod") unary)*
     unary     := "~" unary | "not" unary | "#" n unary | apply
     apply     := atom args*
     args      := "(" ")" | "(" expr ("," expr)* ")"
     atom      := int | "true" | "false" | ident
                | "(" ")" | "(" expr (":" ty)? ")" | "(" expr ("," expr)+ ")"
                | "let" decl* "in" expr "end"

   The one thing to know about the syntax is that a parenthesised list after a
   function is an *argument list*, not a tuple: `f (a, b)` calls `f` with two
   arguments, and `f ((a, b))` calls it with one, which is a pair.  Arity is a
   property of a function here, not of the value it happens to be applied to,
   and the machine's [Call] takes that arity — so the syntax says it too. *)

type state = { toks : Lexer.token array; mutable i : int }

let peek st = st.toks.(st.i)
let kind st = (peek st).Lexer.kind
let here st = (peek st).Lexer.pos

let advance st =
  let tok = st.toks.(st.i) in
  if tok.Lexer.kind <> Lexer.Eof then st.i <- st.i + 1;
  tok

let looking_at st k = kind st = k

let eat st k =
  if looking_at st k then ignore (advance st)
  else
    Diag.error (here st) "expected %s, found %s" (Lexer.describe k)
      (Lexer.describe (kind st))

let ident st =
  match kind st with
  | Lexer.Ident name ->
      ignore (advance st);
      name
  | k ->
      Diag.error (here st) "expected a name, found %s" (Lexer.describe k)

(* A comma-separated list already past its opening `(`, up to and including the
   closing one.  Empty lists are allowed: `()` and `f ()`. *)
let comma_list st item =
  if looking_at st Lexer.Rparen then (
    eat st Lexer.Rparen;
    [])
  else
    let first = item st in
    let rec rest acc =
      if looking_at st Lexer.Comma then (
        eat st Lexer.Comma;
        rest (item st :: acc))
      else (
        eat st Lexer.Rparen;
        List.rev acc)
    in
    rest [ first ]

(* ---------------------------------------------------------------- types *)

(* `*` binds tighter than `->`, and `->` goes to the right: `int * int -> int`
   is a one-argument function over a pair. *)
let rec ty st =
  let p = here st in
  let left = ty_product st in
  if looking_at st Lexer.Arrow then (
    eat st Lexer.Arrow;
    Ast.Ty_arrow ([ left ], ty st, p))
  else left

and ty_product st =
  let p = here st in
  let rec go acc =
    if looking_at st Lexer.Star then (
      eat st Lexer.Star;
      go (ty_atom st :: acc))
    else List.rev acc
  in
  match go [ ty_atom st ] with [ one ] -> one | items -> Ast.Ty_tuple (items, p)

(* A comma inside a type is an argument list, and an argument list only ever
   stands before an arrow — a pair is `int * int`, not `(int, int)`.  So a
   parenthesised list of one is just a grouping, and anything else has to be
   the left side of a `->` right here. *)
and ty_atom st =
  let p = here st in
  match kind st with
  | Lexer.Ident name ->
      ignore (advance st);
      Ast.Ty_name (name, p)
  | Lexer.Tyvar name ->
      ignore (advance st);
      Ast.Ty_var (name, p)
  | Lexer.Lparen -> (
      eat st Lexer.Lparen;
      match comma_list st ty with
      | [ one ] -> one
      | items ->
          if not (looking_at st Lexer.Arrow) then
            Diag.error p
              "a parenthesised list of types is an argument list and must be \
               followed by `->`";
          eat st Lexer.Arrow;
          Ast.Ty_arrow (items, ty st, p))
  | k -> Diag.error p "expected a type, found %s" (Lexer.describe k)

(* ------------------------------------------------------------- patterns *)

and pat st =
  let p = here st in
  let inner =
    match kind st with
    | Lexer.Ident name ->
        ignore (advance st);
        Ast.P_var (name, p)
    | Lexer.Underscore ->
        ignore (advance st);
        Ast.P_wild p
    | Lexer.Lparen -> (
        eat st Lexer.Lparen;
        match comma_list st pat with
        | [] -> Ast.P_unit p
        | [ one ] -> one
        | items -> Ast.P_tuple (items, p))
    | k -> Diag.error p "expected a pattern, found %s" (Lexer.describe k)
  in
  if looking_at st Lexer.Colon then (
    eat st Lexer.Colon;
    Ast.P_annot (inner, ty st, p))
  else inner

(* A parameter list is always parenthesised, even when it is empty. *)
and params st =
  let p = here st in
  if not (looking_at st Lexer.Lparen) then
    Diag.error p "expected a parameter list in parentheses, found %s"
      (Lexer.describe (kind st));
  eat st Lexer.Lparen;
  comma_list st pat

(* ---------------------------------------------------------- expressions *)

and expr st =
  let p = here st in
  match kind st with
  | Lexer.If ->
      eat st Lexer.If;
      let c = expr st in
      eat st Lexer.Then;
      let t = expr st in
      eat st Lexer.Else;
      let f = expr st in
      Ast.If (c, t, f, p)
  | Lexer.Fn ->
      eat st Lexer.Fn;
      let ps = params st in
      eat st Lexer.Darrow;
      Ast.Fn (ps, expr st, p)
  | _ -> orelse st

and orelse st =
  let p = here st in
  let rec go left =
    if looking_at st Lexer.Orelse then (
      eat st Lexer.Orelse;
      go (Ast.Orelse (left, andalso st, p)))
    else left
  in
  go (andalso st)

and andalso st =
  let p = here st in
  let rec go left =
    if looking_at st Lexer.Andalso then (
      eat st Lexer.Andalso;
      go (Ast.Andalso (left, compare_expr st, p)))
    else left
  in
  go (compare_expr st)

(* Comparison does not associate: `a < b < c` is a type error in most languages
   that allow it at all, and here it is a syntax error, which is a better one. *)
and compare_expr st =
  let p = here st in
  let left = sum st in
  let op =
    match kind st with
    | Lexer.Equal -> Some Ast.Eq
    | Lexer.Ne -> Some Ast.Ne
    | Lexer.Lt -> Some Ast.Lt
    | Lexer.Le -> Some Ast.Le
    | Lexer.Gt -> Some Ast.Gt
    | Lexer.Ge -> Some Ast.Ge
    | _ -> None
  in
  match op with
  | None -> left
  | Some op ->
      ignore (advance st);
      Ast.Bin (op, left, sum st, p)

and sum st =
  let rec go left =
    let p = here st in
    match kind st with
    | Lexer.Plus ->
        eat st Lexer.Plus;
        go (Ast.Bin (Ast.Add, left, product st, p))
    | Lexer.Minus ->
        eat st Lexer.Minus;
        go (Ast.Bin (Ast.Sub, left, product st, p))
    | _ -> left
  in
  go (product st)

and product st =
  let rec go left =
    let p = here st in
    match kind st with
    | Lexer.Star ->
        eat st Lexer.Star;
        go (Ast.Bin (Ast.Mul, left, unary st, p))
    | Lexer.Slash ->
        eat st Lexer.Slash;
        go (Ast.Bin (Ast.Div, left, unary st, p))
    | Lexer.Mod ->
        eat st Lexer.Mod;
        go (Ast.Bin (Ast.Mod, left, unary st, p))
    | _ -> left
  in
  go (unary st)

and unary st =
  let p = here st in
  match kind st with
  | Lexer.Tilde ->
      eat st Lexer.Tilde;
      Ast.Neg (unary st, p)
  | Lexer.Not ->
      eat st Lexer.Not;
      Ast.Not (unary st, p)
  | Lexer.Hash n ->
      ignore (advance st);
      Ast.Proj (n, unary st, p)
  | _ -> apply st

(* Application binds tighter than everything but projection, and a function may
   be applied twice: `adder (3) (4)`. *)
and apply st =
  let rec go f =
    if looking_at st Lexer.Lparen then (
      let p = here st in
      eat st Lexer.Lparen;
      go (Ast.App (f, comma_list st expr, p)))
    else f
  in
  go (atom st)

and atom st =
  let p = here st in
  match kind st with
  | Lexer.Int n ->
      ignore (advance st);
      Ast.Int (n, p)
  | Lexer.True ->
      ignore (advance st);
      Ast.Bool (true, p)
  | Lexer.False ->
      ignore (advance st);
      Ast.Bool (false, p)
  | Lexer.Ident name ->
      ignore (advance st);
      Ast.Var (name, p)
  | Lexer.Let ->
      eat st Lexer.Let;
      let ds = decls_until st Lexer.In in
      eat st Lexer.In;
      let body = expr st in
      eat st Lexer.End;
      Ast.Let (ds, body, p)
  | Lexer.Lparen -> (
      eat st Lexer.Lparen;
      if looking_at st Lexer.Rparen then (
        eat st Lexer.Rparen;
        Ast.Unit p)
      else
        let first = expr st in
        match kind st with
        | Lexer.Colon ->
            eat st Lexer.Colon;
            let t = ty st in
            eat st Lexer.Rparen;
            Ast.Annot (first, t, p)
        | Lexer.Comma ->
            let rec rest acc =
              if looking_at st Lexer.Comma then (
                eat st Lexer.Comma;
                rest (expr st :: acc))
              else (
                eat st Lexer.Rparen;
                List.rev acc)
            in
            Ast.Tuple (rest [ first ], p)
        | _ ->
            eat st Lexer.Rparen;
            first)
  | k -> Diag.error p "expected an expression, found %s" (Lexer.describe k)

(* -------------------------------------------------------- declarations *)

and decl st =
  let p = here st in
  match kind st with
  | Lexer.Val ->
      eat st Lexer.Val;
      let target = pat st in
      let annot =
        if looking_at st Lexer.Colon then (
          eat st Lexer.Colon;
          Some (ty st))
        else None
      in
      eat st Lexer.Equal;
      Ast.D_val (target, annot, expr st, p)
  | Lexer.Fun ->
      eat st Lexer.Fun;
      let rec clauses acc =
        let q = here st in
        let name = ident st in
        let ps = params st in
        let ret =
          if looking_at st Lexer.Colon then (
            eat st Lexer.Colon;
            Some (ty st))
          else None
        in
        eat st Lexer.Equal;
        let body = expr st in
        let clause =
          { Ast.f_name = name; f_params = ps; f_ret = ret; f_body = body; f_pos = q }
        in
        if looking_at st Lexer.And then (
          eat st Lexer.And;
          clauses (clause :: acc))
        else List.rev (clause :: acc)
      in
      Ast.D_fun (clauses [], p)
  | k ->
      Diag.error p "expected `val` or `fun`, found %s" (Lexer.describe k)

and decls_until st stop =
  let rec go acc = if looking_at st stop then List.rev acc else go (decl st :: acc) in
  go []

let program src =
  let st = { toks = Lexer.tokens src; i = 0 } in
  let ds = decls_until st Lexer.Eof in
  eat st Lexer.Eof;
  ds
