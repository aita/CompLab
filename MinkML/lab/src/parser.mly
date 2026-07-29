%{
open Ast

let mk startpos it = Ast.mk (Loc.of_lexing startpos) it

(* `(x : A) -> B` and `(x : A) * B` are read out of an annotation node: the
   parser cannot know whether a parenthesised annotation is a binder until it
   sees what follows it, and by then the annotation is already built. *)
let arrow mult startpos dom cod =
  match dom.it with
  | Ann ({ it = Var x; _ }, a) -> mk startpos (Arrow (mult, Some x, a, cod))
  | _ -> mk startpos (Arrow (mult, None, dom, cod))

let star startpos a b =
  match a.it with
  | Ann ({ it = Var x; _ }, t) -> mk startpos (Prod (Some x, t, b))
  | _ -> mk startpos (Bin ("*", a, b))

let var_pat = function "_" -> PWild | x -> PVar x

(* The operators the machine knows are the ML ones; `div`, `mod` and `<>` are
   spelled the way SML spells them and mean what `/`, `%` and `!=` mean
   inside. *)
let bin startpos op a b = mk startpos (Bin (op, a, b))
%}

%token <int> INT
%token <string> IDENT TICK SYSTEM
%token VAL FUN FN LET IN END IF THEN ELSE CASE OF TYPE
%token ANDALSO ORELSE DIV MOD FORALL SELECT BRANCH TRUE FALSE
%token DARROW ARROW LOLLI IMPLIES EQEQ NEQ LE GE PLUSBRACE AMPBRACE DOTDOT
%token EQ LT GT PLUS MINUS STAR BANG QUERY DOT COMMA COLON SEMI
%token PIPE BACKSLASH LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET EOF

(* Lowest first.  LOWEST is for the forms that swallow everything to their
   right -- `fn`, `case` -- so that a `|` or a `;` after one of them belongs to
   it.  IF_PREC sits above SEMI instead, so that `if p then a else b; c` is
   `(if p then a else b); c`, as in ML. *)
%nonassoc LOWEST
%nonassoc PIPE
%right SEMI
%nonassoc IF_PREC
%right ARROW LOLLI
%right IMPLIES
%right ORELSE
%right ANDALSO
%nonassoc EQEQ NEQ LT LE GT GE
%left PLUS MINUS
%left STAR DIV MOD
%nonassoc UNARY

%start <Ast.program> program

%%

program:
  | s = system_opt; items = list(toplevel); EOF { { system = s; items } }

system_opt:
  |             { None }
  | s = SYSTEM  { Some s }

toplevel:
  | d = decl
    { TLet d }
  | TYPE; name = IDENT; ps = list(IDENT); EQ; body = term
    { TType { tname = name; tparams = ps; tbody = body;
              tloc = Loc.of_lexing $startpos } }

(* `val` binds a value and is not recursive; `fun` binds a function and is.
   That is SML's rule, and it is the one place where the surface syntax decides
   something the checkers care about. *)
decl:
  | VAL; p = dpat; ret = ret_opt; EQ; body = term
    { { drec = false; dpat = p; dparams = []; dret = ret; dbody = body;
        dloc = Loc.of_lexing $startpos } }
  | FUN; f = IDENT; ps = nonempty_list(binder); ret = ret_opt; EQ; body = term
    { { drec = true; dpat = DName f; dparams = ps; dret = ret; dbody = body;
        dloc = Loc.of_lexing $startpos } }

dpat:
  | x = IDENT                                   { DName x }
  | LPAREN; RPAREN                              { DUnit }
  | LPAREN; x = IDENT; COMMA; y = IDENT; RPAREN { DPair (x, y) }

ret_opt:
  |                  { None }
  | COLON; t = term  { Some t }

binder:
  | x = IDENT
    { { bname = x; bann = None } }
  | LPAREN; x = IDENT; COLON; t = term; RPAREN
    { { bname = x; bann = Some t } }

term:
  | FN; bs = nonempty_list(binder); DARROW; body = term %prec LOWEST
    { mk $startpos (Lam (bs, body)) }
  | LET; ds = nonempty_list(decl); IN; body = term; END
    { List.fold_right (fun d acc -> mk $startpos (LetIn (d, acc))) ds body }
  | CASE; scrut = term; OF; cs = cases
    { mk $startpos (Match (scrut, cs)) }
  | BRANCH; c = term; OF; bs = bcases
    { mk $startpos (Branch (c, bs)) }
  | FORALL; vs = nonempty_list(IDENT); DOT; body = term %prec LOWEST
    { mk $startpos (Forall (vs, body)) }
  | IF; c = term; THEN; a = term; ELSE; b = term %prec IF_PREC
    { mk $startpos (If (c, a, b)) }
  | SELECT; l = TICK; c = app
    { mk $startpos (Select (l, c)) }
  | a = term; SEMI; b = term      { bin $startpos ";" a b }
  | a = term; ARROW; b = term     { arrow Many $startpos a b }
  | a = term; LOLLI; b = term     { arrow One $startpos a b }
  | a = term; IMPLIES; b = term   { bin $startpos "==>" a b }
  | a = term; ORELSE; b = term    { bin $startpos "||" a b }
  | a = term; ANDALSO; b = term   { bin $startpos "&&" a b }
  | a = term; EQEQ; b = term      { bin $startpos "==" a b }
  | a = term; NEQ; b = term       { bin $startpos "!=" a b }
  | a = term; LT; b = term        { bin $startpos "<" a b }
  | a = term; LE; b = term        { bin $startpos "<=" a b }
  | a = term; GT; b = term        { bin $startpos ">" a b }
  | a = term; GE; b = term        { bin $startpos ">=" a b }
  | a = term; PLUS; b = term      { bin $startpos "+" a b }
  | a = term; MINUS; b = term     { bin $startpos "-" a b }
  | a = term; STAR; b = term      { star $startpos a b }
  | a = term; DIV; b = term       { bin $startpos "/" a b }
  | a = term; MOD; b = term       { bin $startpos "%" a b }
  | MINUS; a = term %prec UNARY   { mk $startpos (Uop ("-", a)) }
  | BANG; a = term %prec UNARY    { mk $startpos (Uop ("!", a)) }
  | QUERY; a = term %prec UNARY   { mk $startpos (Uop ("?", a)) }
  | e = app                       { e }

app:
  | e = atom              { e }
  | f = app; a = atom     { mk $startpos (App (f, a)) }
  | l = TICK; a = atom    { mk $startpos (Inject (l, Some a)) }

atom:
  | x = IDENT                     { mk $startpos (Var x) }
  | n = INT                       { mk $startpos (Int n) }
  | TRUE                          { mk $startpos (Bool true) }
  | FALSE                         { mk $startpos (Bool false) }
  | LPAREN; RPAREN                { mk $startpos Unit }
  | LPAREN; e = term; RPAREN      { e }
  | LPAREN; e = term; COLON; t = term; RPAREN { mk $startpos (Ann (e, t)) }
  | LPAREN; a = term; COMMA; b = term; RPAREN { mk $startpos (Pair (a, b)) }
  | e = atom; DOT; l = IDENT      { mk $startpos (Proj (e, l)) }
  | e = atom; BACKSLASH; l = IDENT { mk $startpos (Restrict (e, l)) }
  | LBRACE; RBRACE                { mk $startpos (Rec (Eq, [], None)) }
  | LBRACE; r = eq_row; RBRACE
    { mk $startpos (Rec (Eq, fst r, snd r)) }
  | LBRACE; r = colon_row; RBRACE
    { mk $startpos (Rec (Colon, fst r, snd r)) }
  | LBRACE; v = IDENT; COLON; base = term; PIPE; p = term; RBRACE
    { mk $startpos (Refine (v, base, p)) }
  | LBRACKET; RBRACKET            { mk $startpos (VariantTy ([], None)) }
  | LBRACKET; r = tick_row; RBRACKET
    { mk $startpos (VariantTy (fst r, snd r)) }
  | PLUSBRACE; r = tick_row; RBRACE { mk $startpos (Choice ("+", fst r)) }
  | AMPBRACE; r = tick_row; RBRACE  { mk $startpos (Choice ("&", fst r)) }

(* The row tail is left-factored into the field list -- `, ..r` and `, l : t`
   share their comma, and one token of lookahead after it is enough. *)
eq_row:
  | l = IDENT; EQ; e = term
    { ([ { flabel = l; fbody = e } ], None) }
  | l = IDENT; EQ; e = term; COMMA; DOTDOT; t = term
    { ([ { flabel = l; fbody = e } ], Some t) }
  | l = IDENT; EQ; e = term; COMMA; rest = eq_row
    { ({ flabel = l; fbody = e } :: fst rest, snd rest) }

colon_row:
  | l = IDENT; COLON; t = term
    { ([ { flabel = l; fbody = t } ], None) }
  | l = IDENT; COLON; t = term; COMMA; DOTDOT; r = term
    { ([ { flabel = l; fbody = t } ], Some r) }
  | l = IDENT; COLON; t = term; COMMA; rest = colon_row
    { ({ flabel = l; fbody = t } :: fst rest, snd rest) }

(* Record fields are plain names; the arms of a variant and the branches of a
   session choice are constructors, and wear a backquote wherever they appear. *)
tick_row:
  | l = TICK; COLON; t = term
    { ([ { flabel = l; fbody = t } ], None) }
  | l = TICK; COLON; t = term; COMMA; DOTDOT; r = term
    { ([ { flabel = l; fbody = t } ], Some r) }
  | l = TICK; COLON; t = term; COMMA; rest = tick_row
    { ({ flabel = l; fbody = t } :: fst rest, snd rest) }

(* A `|` right after a case body belongs to the innermost `case`, which is what
   shifting gives us: the one-arm list has the lowest precedence, so the bar
   wins. *)
cases:
  | ioption(PIPE); c = case %prec LOWEST { [ c ] }
  | ioption(PIPE); c = case; PIPE; cs = cases { c :: cs }

case:
  | p = pat; DARROW; e = term %prec LOWEST { (p, e) }

bcases:
  | ioption(PIPE); c = bcase %prec LOWEST { [ c ] }
  | ioption(PIPE); c = bcase; PIPE; cs = bcases { c :: cs }

bcase:
  | l = TICK; x = IDENT; DARROW; e = term %prec LOWEST { (l, x, e) }

pat:
  | p = pat_atom           { p }
  | l = TICK               { PInject (l, None) }
  | l = TICK; p = pat_atom { PInject (l, Some p) }

pat_atom:
  | x = IDENT                                 { var_pat x }
  | LPAREN; RPAREN                            { PUnit }
  | LPAREN; p = pat; RPAREN                   { p }
  | LPAREN; a = pat; COMMA; b = pat; RPAREN   { PPair (a, b) }
