(* A Pratt parser.

   Every expression form is either a prefix form (nud, in [atom]) or an infix one
   (led, in [exp]), and the table below is the whole of the precedence.  The
   prefix forms that end in an expression — [if], [while], [for], [:=] — take
   their tail at binding power 0, so [if c then x := 1 else x := 2] reads the way
   it looks. *)

open Lexer

(* The left binding power and the power the right side is read at.  Left < right
   is left-associative; left > right is right-associative, which only [:=] is. *)
let binding_power = function
  | ASSIGN -> Some (2, 1)
  | ORELSE -> Some (4, 5)
  | ANDALSO -> Some (6, 7)
  | EQ | NE | LT | LE | GT | GE -> Some (8, 9)
  | CARET -> Some (10, 11)
  | PLUS | MINUS -> Some (12, 13)
  | STAR | SLASH | MOD -> Some (14, 15)
  | _ -> None

let unary_bp = 16

let binop = function
  | PLUS -> "+"
  | MINUS -> "-"
  | STAR -> "*"
  | SLASH -> "/"
  | MOD -> "mod"
  | CARET -> "^"
  | EQ -> "="
  | NE -> "<>"
  | LT -> "<"
  | LE -> "<="
  | GT -> ">"
  | GE -> ">="
  | k -> failwith ("no such operator as " ^ name k)

let declares = function VAL | VAR | FUN | TYPE -> true | _ -> false

type state = { toks : token array; mutable pos : int }

(* -- token plumbing -------------------------------------------------------- *)

let cur p = p.toks.(p.pos)
let at p kind = (cur p).kind = kind

let take p kind =
  if (cur p).kind = kind then begin
    let t = cur p in
    p.pos <- p.pos + 1;
    Some t
  end
  else None

let took p kind = take p kind <> None

let expect p kind =
  match take p kind with
  | Some t -> t
  | None ->
      Diag.parse_error (cur p).at "expected `%s`, found %s" (text kind)
        (show_token (cur p))

let expect_ident p =
  match take p IDENT with
  | Some t -> t
  | None -> Diag.parse_error (cur p).at "expected a name, found %s" (show_token (cur p))

(* -- expressions ----------------------------------------------------------- *)

let check_lvalue (e : Ast.exp) =
  match e.node with
  | Ast.Var _ | Ast.Index _ | Ast.Field _ -> ()
  | _ -> Diag.parse_error e.at "the left of `:=` is not assignable"

(* Integers are 64 bits and wrap, so the largest literal is the one written
   [~9223372036854775808]. *)
let integer (t : token) =
  match Int64.of_string_opt ("0u" ^ t.text) with
  | Some v -> v
  | None -> Diag.parse_error t.at "`%s` does not fit in 64 bits" t.text

let rec exp p min_bp =
  let left = ref (atom p) in
  let finished = ref false in
  while not !finished do
    match binding_power (cur p).kind with
    | Some (lbp, rbp) when lbp >= min_bp ->
        let t = cur p in
        p.pos <- p.pos + 1;
        let node =
          match t.kind with
          | ASSIGN ->
              check_lvalue !left;
              Ast.Assign (!left, exp p rbp)
          | ANDALSO | ORELSE -> Ast.Logic (t.text, !left, exp p rbp)
          | k -> Ast.Bin (binop k, !left, exp p rbp)
        in
        left := Ast.exp t.at node
    | _ -> finished := true
  done;
  !left

and atom p =
  let t = cur p in
  let start = t.at in
  match t.kind with
  | INT ->
      p.pos <- p.pos + 1;
      postfix p (Ast.exp start (Ast.Int_lit (integer t)))
  | STRING ->
      p.pos <- p.pos + 1;
      postfix p (Ast.exp start (Ast.Str_lit t.text))
  | TRUE | FALSE ->
      p.pos <- p.pos + 1;
      Ast.exp start (Ast.Bool_lit (t.kind = TRUE))
  | NIL ->
      p.pos <- p.pos + 1;
      Ast.exp start Ast.Nil_lit
  | BREAK ->
      p.pos <- p.pos + 1;
      Ast.exp start Ast.Break
  | TILDE ->
      p.pos <- p.pos + 1;
      Ast.exp start (Ast.Neg (exp p unary_bp))
  | MINUS -> Diag.parse_error start "negation is written `~`, not `-`"
  | LPAREN -> postfix p (parens p)
  | IDENT -> postfix p (named p)
  | IF -> if_exp p
  | WHILE -> while_exp p
  | FOR -> for_exp p
  | LET -> let_exp p
  | _ -> Diag.parse_error start "expected an expression, found %s" (show_token t)

and parens p =
  let start = (expect p LPAREN).at in
  if took p RPAREN then Ast.exp start Ast.Unit_lit
  else begin
    let items = sequence p RPAREN in
    ignore (expect p RPAREN);
    match items with [ one ] -> one | many -> Ast.exp start (Ast.Seq many)
  end

and sequence p stop =
  let items = ref [ exp p 0 ] in
  let finished = ref false in
  while (not !finished) && took p SEMI do
    if at p stop then finished := true else items := exp p 0 :: !items
  done;
  List.rev !items

and named p =
  let t = expect_ident p in
  match (cur p).kind with
  | LPAREN ->
      p.pos <- p.pos + 1;
      let args = ref [] in
      if not (took p RPAREN) then begin
        let more = ref true in
        while !more do
          args := exp p 0 :: !args;
          more := took p COMMA
        done;
        ignore (expect p RPAREN)
      end;
      Ast.exp t.at (Ast.Call { callee = t.text; args = List.rev !args; fun_sym = None })
  | LBRACE ->
      p.pos <- p.pos + 1;
      let inits = ref [] in
      if not (took p RBRACE) then begin
        let more = ref true in
        while !more do
          let fname = expect_ident p in
          ignore (expect p EQ);
          inits :=
            { Ast.init_name = fname.text; value = exp p 0; init_at = fname.at } :: !inits;
          more := took p COMMA
        done;
        ignore (expect p RBRACE)
      end;
      Ast.exp t.at (Ast.Record_lit { tyname = t.text; inits = List.rev !inits })
  | _ -> Ast.exp t.at (Ast.Var { name = t.text; var_sym = None })

and postfix p base =
  let out = ref base in
  let finished = ref false in
  while not !finished do
    match (cur p).kind with
    | LBRACK ->
        let start = (cur p).at in
        p.pos <- p.pos + 1;
        let index = exp p 0 in
        ignore (expect p RBRACK);
        out := Ast.exp start (Ast.Index (!out, index))
    | DOT ->
        let start = (cur p).at in
        p.pos <- p.pos + 1;
        let field = expect_ident p in
        out := Ast.exp start (Ast.Field { record = !out; select = field.text; offset = -1 })
    | _ -> finished := true
  done;
  !out

and if_exp p =
  let start = (expect p IF).at in
  let cond = exp p 0 in
  ignore (expect p THEN);
  let then_ = exp p 0 in
  let else_ = if took p ELSE then Some (exp p 0) else None in
  Ast.exp start (Ast.If (cond, then_, else_))

and while_exp p =
  let start = (expect p WHILE).at in
  let cond = exp p 0 in
  ignore (expect p DO);
  Ast.exp start (Ast.While (cond, exp p 0))

and for_exp p =
  let start = (expect p FOR).at in
  let binder = expect_ident p in
  ignore (expect p EQ);
  let lo = exp p 0 in
  ignore (expect p TO);
  let hi = exp p 0 in
  ignore (expect p DO);
  Ast.exp start
    (Ast.For { binder = binder.text; lo; hi; body = exp p 0; loop_sym = None })

and let_exp p =
  let start = (expect p LET).at in
  let decls = ref [] in
  while declares (cur p).kind do
    decls := decl p :: !decls
  done;
  ignore (expect p IN);
  let body =
    if at p END then Ast.exp start Ast.Unit_lit
    else match sequence p END with [ one ] -> one | many -> Ast.exp start (Ast.Seq many)
  in
  ignore (expect p END);
  Ast.exp start (Ast.Let (List.rev !decls, body))

(* -- types ----------------------------------------------------------------- *)

and ty p : Ast.ty_exp =
  let start = (cur p).at in
  let base = ref (ty_atom p start) in
  while (cur p).kind = IDENT && (cur p).text = "array" do
    p.pos <- p.pos + 1;
    base := { Ast.ty_at = start; ty_node = Ast.Ty_array !base }
  done;
  !base

and ty_atom p start : Ast.ty_exp =
  if took p LBRACE then begin
    let fields = ref [] in
    if not (took p RBRACE) then begin
      let more = ref true in
      while !more do
        let fname = expect_ident p in
        ignore (expect p COLON);
        fields :=
          { Ast.field_name = fname.text; field_ty = ty p; field_at = fname.at } :: !fields;
        more := took p COMMA
      done;
      ignore (expect p RBRACE)
    end;
    { Ast.ty_at = start; ty_node = Ast.Ty_record (List.rev !fields) }
  end
  else if took p LPAREN then begin
    let inner = ty p in
    ignore (expect p RPAREN);
    inner
  end
  else { Ast.ty_at = start; ty_node = Ast.Ty_name (expect_ident p).text }

(* -- declarations ---------------------------------------------------------- *)

and decl p : Ast.decl =
  match (cur p).kind with
  | TYPE -> type_decl p
  | VAL | VAR -> val_decl p
  | FUN -> fun_decl p
  | _ ->
      Diag.parse_error (cur p).at
        "expected a declaration (`val`, `var`, `fun`, `type`), found %s"
        (show_token (cur p))

and type_decl p =
  ignore (expect p TYPE);
  let binds = ref [ type_bind p ] in
  while took p AND do
    binds := type_bind p :: !binds
  done;
  Ast.Type_decl (List.rev !binds)

and type_bind p : Ast.type_bind =
  let name = expect_ident p in
  ignore (expect p EQ);
  { bind_name = name.text; bound = ty p; bind_at = name.at }

and val_decl p =
  let is_var = (cur p).kind = VAR in
  let start = (cur p).at in
  p.pos <- p.pos + 1;
  let bound_name =
    if took p LPAREN then begin
      ignore (expect p RPAREN);
      None
    end
    else Some (expect_ident p).text
  in
  let written = if took p COLON then Some (ty p) else None in
  ignore (expect p EQ);
  Ast.Val_decl
    { decl_at = start; bound_name; written; init = exp p 0; is_var; decl_sym = None }

and fun_decl p =
  ignore (expect p FUN);
  let binds = ref [ fun_bind p ] in
  while took p AND do
    binds := fun_bind p :: !binds
  done;
  Ast.Fun_decl (List.rev !binds)

and fun_bind p : Ast.fun_bind =
  let name = expect_ident p in
  ignore (expect p LPAREN);
  let params = ref [] in
  if not (took p RPAREN) then begin
    let more = ref true in
    while !more do
      let pname = expect_ident p in
      ignore (expect p COLON);
      params :=
        { Ast.param_name = pname.text; param_ty = ty p; param_at = pname.at;
          param_sym = None }
        :: !params;
      more := took p COMMA
    done;
    ignore (expect p RPAREN)
  end;
  let result = if took p COLON then Some (ty p) else None in
  ignore (expect p EQ);
  { fun_label = name.text; fun_params = List.rev !params; result;
    fun_body = exp p 0; fun_at = name.at; sym = None }

(* -- entry points ---------------------------------------------------------- *)

let of_tokens toks = { toks = Array.of_list toks; pos = 0 }

let parse source : Ast.program =
  let p = of_tokens (lex source) in
  let decls = ref [] in
  while not (at p EOF) do
    decls := decl p :: !decls
  done;
  List.rev !decls

(* [parse_exp] reads a single expression — the tests use it, the compiler does not. *)
let parse_exp source =
  let p = of_tokens (lex source) in
  let e = exp p 0 in
  if not (at p EOF) then
    Diag.parse_error (cur p).at "unexpected %s after the expression" (show_token (cur p));
  e
