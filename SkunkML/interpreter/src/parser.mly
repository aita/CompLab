%{
open Ast

let mk startpos e = { e; eloc = Loc.of_lexing startpos }
let mkp startpos p = { p; ploc = Loc.of_lexing startpos }
let bin startpos op a b = mk startpos (EBin (op, a, b))

(* `fun f 0 = 1 | f n = n * f (n - 1)` is one binding with two clauses, and
   every clause has to name the same function and take the same number of
   arguments.  Both are checked here, where the offending clause is still in
   hand. *)
let fun_bind startpos (clauses : (string * pat list * ty option * exp) list) =
  match clauses with
  | [] -> assert false
  | (name, ps, _, _) :: _ ->
      let arity = List.length ps in
      List.iter
        (fun (n, qs, _, body) ->
          if n <> name then
            Loc.syntax_error body.eloc
              "this clause defines %s, but the ones before it define %s" n name;
          if List.length qs <> arity then
            Loc.syntax_error body.eloc
              "this clause of %s takes %d argument%s, the first takes %d" name
              (List.length qs)
              (if List.length qs = 1 then "" else "s")
              arity)
        clauses;
      {
        fname = name;
        fclauses = List.map (fun (_, ps, r, b) -> (ps, r, b)) clauses;
        floc = Loc.of_lexing startpos;
      }
%}

%token <int> INT
%token <string> STRING LID UID TYVAR SELECT
%token <string list * string> QID
%token VAL FUN FN LET IN END IF THEN ELSE CASE OF AS
%token DATATYPE TYPE AND ANDALSO ORELSE DIV MOD OPEN
%token STRUCTURE SIGNATURE FUNCTOR STRUCT SIG WHERE INCLUDE
%token DARROW ARROW CONS COLONGT COLON EQ NE LE GE LT GT
%token PLUS MINUS STAR CARET AT TILDE BAR COMMA SEMI DOTS UNDERSCORE
%token LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE EOF

(* Lowest first.  The interesting entries are the two at the bottom.  A match
   rule `p => e` swallows everything to its right, so `DARROW` sits below every
   operator; and a one-rule `match_rules` is given `LOWEST`, which is below
   `BAR`, so a `|` is always shifted into the innermost match.  That is SML's
   rule, and it is why a `case` inside a `fun` clause has to be parenthesised:
   the bar that was meant to start the next clause joins the case instead.

   Everything else is SML's operator table -- `*` and `div` tightest, then
   `+`, then the right-associative `::` and `@`, then the comparisons. *)
%nonassoc LOWEST
%nonassoc BAR DARROW
%right SEMI
%nonassoc IF_PREC
%right ORELSE
%right ANDALSO
%left EQ NE LT LE GT GE
%nonassoc AS
%right CONS AT
%left PLUS MINUS CARET
%left STAR DIV MOD
%nonassoc TILDE

%start <Ast.program> program

%%

program:
  | ds = list(topdec); EOF { ds }

(* Declarations, at the top level and inside `struct`. *)

topdec:
  | d = dec
    { { t = TDec d; tloc = d.dloc } }
  | STRUCTURE; x = UID; EQ; s = strexp
    { { t = TStr (x, s); tloc = Loc.of_lexing $startpos } }
  | STRUCTURE; x = UID; COLON; si = sigexp; EQ; s = strexp
    { { t = TStr (x, { st = StrAsc (s, si, false); stloc = s.stloc });
        tloc = Loc.of_lexing $startpos } }
  | STRUCTURE; x = UID; COLONGT; si = sigexp; EQ; s = strexp
    { { t = TStr (x, { st = StrAsc (s, si, true); stloc = s.stloc });
        tloc = Loc.of_lexing $startpos } }
  | SIGNATURE; x = UID; EQ; si = sigexp
    { { t = TSig (x, si); tloc = Loc.of_lexing $startpos } }
  | FUNCTOR; f = UID; LPAREN; a = UID; COLON; ps = sigexp; RPAREN;
    r = result_sig; EQ; body = strexp
    { { t = TFun (f, a, ps, r, body); tloc = Loc.of_lexing $startpos } }

result_sig:
  |                       { None }
  | COLON; s = sigexp     { Some (s, false) }
  | COLONGT; s = sigexp   { Some (s, true) }

dec:
  | VAL; p = pat; EQ; e = term
    { { d = DVal (p, e); dloc = Loc.of_lexing $startpos } }
  | VAL; p = pat; COLON; t = ty; EQ; e = term
    { { d = DVal ({ p with p = PAnn (p, t) }, e); dloc = Loc.of_lexing $startpos } }
  | FUN; fs = separated_nonempty_list(AND, fun_bind)
    { { d = DFun fs; dloc = Loc.of_lexing $startpos } }
  | TYPE; bs = separated_nonempty_list(AND, tybind)
    { { d = DType bs; dloc = Loc.of_lexing $startpos } }
  | DATATYPE; bs = separated_nonempty_list(AND, databind)
    { { d = DData bs; dloc = Loc.of_lexing $startpos } }
  | OPEN; ps = nonempty_list(path)
    { { d = DOpen ps; dloc = Loc.of_lexing $startpos } }

fun_bind:
  | cs = clauses { fun_bind $startpos cs }

clauses:
  | c = clause                    { [ c ] }
  | c = clause; BAR; cs = clauses { c :: cs }

clause:
  | f = LID; ps = nonempty_list(pat_atom); r = ret_opt; EQ; e = term
    { (f, ps, r, e) }

ret_opt:
  |                 { None }
  | COLON; t = ty   { Some t }

tybind:
  | vs = tyvars; n = LID; EQ; t = ty
    { { tbparams = vs; tbname = n; tbody = t } }

databind:
  | vs = tyvars; n = LID; EQ; cs = separated_nonempty_list(BAR, conbind)
    { { dbparams = vs; dbname = n; dbcons = cs;
        dbloc = Loc.of_lexing $startpos } }

conbind:
  | c = con_name                { (c, None) }
  | c = con_name; OF; t = ty    { (c, Some t) }

con_name:
  | c = UID { c }
  | c = LID { c }

tyvars:
  |                                                     { [] }
  | v = TYVAR                                           { [ v ] }
  | LPAREN; vs = separated_nonempty_list(COMMA, TYVAR); RPAREN { vs }

(* Structures and signatures. *)

strexp:
  | STRUCT; ds = list(topdec); END
    { { st = StrBody ds; stloc = Loc.of_lexing $startpos } }
  | p = path
    { { st = StrId p; stloc = Loc.of_lexing $startpos } }
  | f = UID; LPAREN; a = strexp; RPAREN
    { { st = StrApp (f, a); stloc = Loc.of_lexing $startpos } }

sigexp:
  | SIG; ss = list(spec); END
    { { s = SigBody ss; sloc = Loc.of_lexing $startpos } }
  | x = UID
    { { s = SigId x; sloc = Loc.of_lexing $startpos } }
  | s = sigexp; WHERE; TYPE; b = tybind
    { { s = SigWhere (s, b); sloc = Loc.of_lexing $startpos } }

spec:
  | VAL; x = LID; COLON; t = ty
    { { sp = SpVal (x, t); sploc = Loc.of_lexing $startpos } }
  | TYPE; vs = tyvars; n = LID
    { { sp = SpType (vs, n, None); sploc = Loc.of_lexing $startpos } }
  | TYPE; vs = tyvars; n = LID; EQ; t = ty
    { { sp = SpType (vs, n, Some t); sploc = Loc.of_lexing $startpos } }
  | DATATYPE; bs = separated_nonempty_list(AND, databind)
    { { sp = SpData bs; sploc = Loc.of_lexing $startpos } }
  | STRUCTURE; x = UID; COLON; s = sigexp
    { { sp = SpStruct (x, s); sploc = Loc.of_lexing $startpos } }
  | INCLUDE; s = sigexp
    { { sp = SpInclude s; sploc = Loc.of_lexing $startpos } }

(* Types.  A separate grammar from terms, because a signature declares type
   components with no term in sight. *)

ty:
  | t = ty_tuple                    { t }
  | a = ty_tuple; ARROW; b = ty     { TyArrow (a, b) }

ty_tuple:
  | t = ty_app                                          { t }
  | t = ty_app; STAR; ts = separated_nonempty_list(STAR, ty_app)
    { TyTuple (t :: ts) }

(* Type application is postfix and left-associative: `int list list` is a list
   of lists of ints. *)
ty_app:
  | t = ty_atom                     { t }
  | t = ty_app; c = path            { TyCon (c, [ t ]) }
  | LPAREN; t = ty; COMMA; ts = separated_nonempty_list(COMMA, ty); RPAREN;
    c = path
    { TyCon (c, t :: ts) }

ty_atom:
  | v = TYVAR                       { TyVar v }
  | c = path                        { TyCon (c, []) }
  | LPAREN; t = ty; RPAREN          { t }
  | LBRACE; RBRACE                  { TyRecord [] }
  | LBRACE; fs = separated_nonempty_list(COMMA, ty_field); RBRACE
    { TyRecord fs }

ty_field:
  | l = LID; COLON; t = ty          { (l, t) }

(* Patterns. *)

pat:
  | p = pat_app                     { p }
  | a = pat; CONS; b = pat          { mkp $startpos (PCon (ident "::", Some (mkp $startpos (PTuple [ a; b ])))) }
  | x = LID; AS; p = pat            { mkp $startpos (PAs (x, p)) }

pat_app:
  | p = pat_atom                    { p }
  | c = path; p = pat_atom          { mkp $startpos (PCon (c, Some p)) }

pat_atom:
  | UNDERSCORE                      { mkp $startpos PWild }
  (* A bare name is a variable here and a constructor after elaboration has
     looked it up: `nil` and `true` are ordinary constructors in SML, and only
     the environment knows which names are. *)
  | x = LID                         { mkp $startpos (PVar x) }
  | c = UID                         { mkp $startpos (PVar c) }
  | c = QID                         { mkp $startpos (PCon ({ quals = fst c; base = snd c }, None)) }
  | n = INT                         { mkp $startpos (PInt n) }
  | TILDE; n = INT                  { mkp $startpos (PInt (-n)) }
  | s = STRING                      { mkp $startpos (PStr s) }
  | LPAREN; RPAREN                  { mkp $startpos (PTuple []) }
  | LPAREN; p = pat; RPAREN         { p }
  | LPAREN; p = pat; COLON; t = ty; RPAREN { mkp $startpos (PAnn (p, t)) }
  | LPAREN; p = pat; COMMA; ps = separated_nonempty_list(COMMA, pat); RPAREN
    { mkp $startpos (PTuple (p :: ps)) }
  | LBRACK; RBRACK                  { mkp $startpos (PList []) }
  | LBRACK; ps = separated_nonempty_list(COMMA, pat); RBRACK
    { mkp $startpos (PList ps) }
  | LBRACE; RBRACE                  { mkp $startpos (PRecord ([], false)) }
  | LBRACE; r = pat_row; RBRACE     { mkp $startpos (PRecord (fst r, snd r)) }

(* `{ x = p, y = q }` is closed, `{ x = p, ... }` is flexible: the fields not
   written may exist, and inference has to find out what they are. *)
pat_row:
  | DOTS                            { ([], true) }
  | f = pat_field                   { ([ f ], false) }
  | f = pat_field; COMMA; r = pat_row { (f :: fst r, snd r) }

pat_field:
  | l = LID; EQ; p = pat            { (l, p) }
  | l = LID                         { (l, mkp $startpos (PVar l)) }

(* Terms. *)

term:
  | FN; m = match_rules
    { mk $startpos (EFn m) }
  | CASE; e = term; OF; m = match_rules
    { mk $startpos (ECase (e, m)) }
  | LET; ds = list(dec); IN; e = term; END
    { mk $startpos (ELet (ds, e)) }
  | IF; c = term; THEN; a = term; ELSE; b = term %prec IF_PREC
    { mk $startpos (EIf (c, a, b)) }
  | a = term; SEMI; b = term        { mk $startpos (ESeq (a, b)) }
  | a = term; ORELSE; b = term      { mk $startpos (EOrelse (a, b)) }
  | a = term; ANDALSO; b = term     { mk $startpos (EAndalso (a, b)) }
  | a = term; EQ; b = term          { bin $startpos "=" a b }
  | a = term; NE; b = term          { bin $startpos "<>" a b }
  | a = term; LT; b = term          { bin $startpos "<" a b }
  | a = term; LE; b = term          { bin $startpos "<=" a b }
  | a = term; GT; b = term          { bin $startpos ">" a b }
  | a = term; GE; b = term          { bin $startpos ">=" a b }
  | a = term; CONS; b = term        { bin $startpos "::" a b }
  | a = term; AT; b = term          { bin $startpos "@" a b }
  | a = term; PLUS; b = term        { bin $startpos "+" a b }
  | a = term; MINUS; b = term       { bin $startpos "-" a b }
  | a = term; CARET; b = term       { bin $startpos "^" a b }
  | a = term; STAR; b = term        { bin $startpos "*" a b }
  | a = term; DIV; b = term         { bin $startpos "div" a b }
  | a = term; MOD; b = term         { bin $startpos "mod" a b }
  | TILDE; e = term %prec TILDE     { mk $startpos (ENeg e) }
  | e = app                         { e }

match_rules:
  | r = rule %prec LOWEST           { [ r ] }
  | r = rule; BAR; rs = match_rules { r :: rs }

rule:
  | p = pat; DARROW; e = term       { (p, e) }

app:
  | e = atom                        { e }
  | f = app; a = atom               { mk $startpos (EApp (f, a)) }

atom:
  | p = path                        { mk $startpos (EVar p) }
  | n = INT                         { mk $startpos (EInt n) }
  | s = STRING                      { mk $startpos (EStr s) }
  | l = SELECT                      { mk $startpos (ESelect l) }
  | LPAREN; RPAREN                  { mk $startpos (ETuple []) }
  | LPAREN; e = term; RPAREN        { e }
  | LPAREN; e = term; COLON; t = ty; RPAREN { mk $startpos (EAnn (e, t)) }
  | LPAREN; e = term; COMMA; es = separated_nonempty_list(COMMA, term); RPAREN
    { mk $startpos (ETuple (e :: es)) }
  | LBRACK; RBRACK                  { mk $startpos (EList []) }
  | LBRACK; es = separated_nonempty_list(COMMA, term); RBRACK
    { mk $startpos (EList es) }
  | LBRACE; RBRACE                  { mk $startpos (ETuple []) }
  | LBRACE; fs = separated_nonempty_list(COMMA, exp_field); RBRACE
    { mk $startpos (ERecord fs) }

exp_field:
  | l = LID; EQ; e = term           { (l, e) }

path:
  | x = LID   { ident x }
  | x = UID   { ident x }
  | q = QID   { { quals = fst q; base = snd q } }
