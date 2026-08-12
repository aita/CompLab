(* The grammar of spec/grammar.ebnf, as an LALR(1) grammar.

   Two productions are deliberately wider than the file:

   - "type-application = atomic-type , type-constructor" allows exactly one
     postfix constructor, so "int list list" is not derivable from the file.
     Here a chain is allowed, since (int list) list is plainly what is meant.
   - "atomic-pattern" cannot carry a type, so there is nowhere to say what a
     parameter is; here a pattern inside brackets may be annotated, which is
     what "(r : point)" needs.
   - "record-type" is closed, and a row-polymorphic record type cannot be
     written down at all; "{x : int | 'r}" is one here.
   - only "function-name" and "import-name" can name an operator, which leaves
     one definable and importable and nothing else.  Here "( operator )" is
     also a primary-expression, a value-declaration and a value-spec, so that
     an operator can be passed to a function, annotated, and let out of a
     sealed mod.

   The operator ladder of the file -- or, and, comparison, ::, additive,
   multiplicative -- is not in this grammar at all.  An infix chain is parsed
   flat and shaped by Fixity, whose default table is exactly that ladder;
   otherwise "infixl / infixr / infix" would have nothing to change. *)

%{
open Ast

(* An operator names a value everywhere a lower-case identifier does: in an
   expression, in a val, and in a val specification.  The file allows it in
   function-name and import-name only, which leaves an operator definable and
   importable but impossible to write down, to annotate, or to put in the
   signature that would let it out of a mod. *)
let not_a_constructor loc o =
  if is_cons_op o then
    Diag.at loc "%s is a constructor, so it cannot be bound as a value" o
  else o

let digit_of_int loc n =
  if n < 0 || n > 9 then Diag.at loc "a fixity precedence is a single digit, not %d" n else n
%}

%token <int> INT
%token <float> REAL
%token <char> CHAR
%token <string> STRING
%token <string> LIDENT
%token <string> UIDENT
%token <string> TYVAR
%token <string> OP
%token <string list * string> QLIDENT
%token <string list * string> QUIDENT

%token VAL FUN TYPE INFIXL INFIXR INFIX
%token SIG END MOD INCLUDE WHERE IMPORT AS
%token FN LET IN BEGIN IF THEN ELSE CASE OF AND OR NOT TRUE FALSE

%token LPAREN RPAREN LBRACK RBRACK LBRACE RBRACE
%token COMMA SEMI COLON DOT BAR EQ ARROW DARROW UNDERSCORE STAR MINUS CONS
%token EOF

(* The grammar in the file is ambiguous wherever one of the open-ended forms
   -- fn, if, case -- sits in primary position, because the expression that
   ends it can always be continued instead.  Every such choice is resolved the
   greedy way, so that the open form runs as far right as it can:

     f if a then b else c d   is   f (if a then b else (c d))
     case x of A => case y of B => 1 | C => 2

   parses with both bars belonging to the inner case, and (if ...).x needs the
   parentheses.  LOW is never lexed; it exists only to sit below every token
   that could continue an expression, so that shifting wins.  The four
   productions marked %prec LOW below are the ones that would otherwise stop
   an expression early. *)
%token LOW
%nonassoc LOW
%nonassoc BAR
%nonassoc DOT
%nonassoc OP MINUS STAR CONS AND OR
%nonassoc INT REAL CHAR STRING TRUE FALSE
%nonassoc LIDENT UIDENT QLIDENT QUIDENT
%nonassoc LPAREN LBRACK LBRACE LET BEGIN IF CASE

%start <Ast.decl list> program

%%

program:
  | ds = list(declaration) EOF { ds }

(* ------------------------------------------------------------------
 * Declarations
 * ------------------------------------------------------------------ *)

declaration:
  | d = value_declaration    { d }
  | d = function_declaration { d }
  | d = type_declaration     { d }
  | d = fixity_declaration   { d }
  | d = signature_definition { d }
  | d = module_declaration   { d }
  | d = import_declaration   { d }

value_declaration:
  | VAL p = pattern t = option(preceded(COLON, ty)) EQ e = expression
      { mk_d $startpos (DVal (p, t, e)) }
  | VAL LPAREN o = operator RPAREN t = option(preceded(COLON, ty)) EQ e = expression
      { let n = not_a_constructor $startpos(o) o in
        mk_d $startpos (DVal (mk_p $startpos (PVar n), t, e)) }

function_declaration:
  | FUN cs = fun_clauses { mk_d $startpos (DFun (List.rev cs)) }

fun_clauses:
  | c = function_clause                       { [ c ] }
  | cs = fun_clauses BAR c = function_clause  { c :: cs }

function_clause:
  | n = function_name ps = list(atomic_pattern) t = option(preceded(COLON, ty))
    EQ e = expression
      { { c_name = n; c_params = ps; c_ret = t; c_body = e; c_loc = $startpos } }

function_name:
  | n = LIDENT                 { n }
  | LPAREN o = operator RPAREN { not_a_constructor $startpos o }

type_declaration:
  | TYPE h = type_head EQ d = type_definition { mk_d $startpos (DType (h, d)) }

type_head:
  | n = LIDENT           { { th_params = []; th_name = n; th_loc = $startpos } }
  | v = TYVAR n = LIDENT { { th_params = [ v ]; th_name = n; th_loc = $startpos } }
  | LPAREN vs = separated_nonempty_list(COMMA, TYVAR) RPAREN n = LIDENT
      { { th_params = vs; th_name = n; th_loc = $startpos } }

type_definition:
  | t = ty                 { TDAlias t }
  | v = variant_definition { TDVariant v }

variant_definition:
  | option(BAR) cs = constructor_definitions { List.rev cs }

constructor_definitions:
  | c = constructor_definition                              { [ c ] }
  | cs = constructor_definitions BAR c = constructor_definition { c :: cs }

constructor_definition:
  | n = UIDENT a = option(atomic_ty) { (n, a, $startpos) }

fixity_declaration:
  | INFIXL p = INT os = nonempty_list(operator)
      { mk_d $startpos (DFixity (Left, digit_of_int $startpos p, os)) }
  | INFIXR p = INT os = nonempty_list(operator)
      { mk_d $startpos (DFixity (Right, digit_of_int $startpos p, os)) }
  | INFIX p = INT os = nonempty_list(operator)
      { mk_d $startpos (DFixity (Non, digit_of_int $startpos p, os)) }

(* ------------------------------------------------------------------
 * Signatures
 * ------------------------------------------------------------------ *)

signature_definition:
  | SIG n = UIDENT items = list(signature_item) END { mk_d $startpos (DSig (n, items)) }

signature_item:
  | TYPE h = type_head                { mk_sp $startpos (SpType (h, None)) }
  | TYPE h = type_head EQ t = ty      { mk_sp $startpos (SpType (h, Some t)) }
  | VAL n = LIDENT COLON t = ty       { mk_sp $startpos (SpVal (n, t)) }
  | VAL LPAREN o = operator RPAREN COLON t = ty
      { mk_sp $startpos (SpVal (not_a_constructor $startpos o, t)) }
  | MOD n = UIDENT COLON s = sig_exp  { mk_sp $startpos (SpMod (n, s)) }
  | INCLUDE s = sig_exp               { mk_sp $startpos (SpInclude s) }

sig_exp:
  | p = module_path ws = list(where_type_clause)
      { { se_path = p; se_where = ws; se_loc = $startpos } }

where_type_clause:
  | WHERE TYPE p = type_path EQ t = ty { (p, t) }

type_path:
  | n = LIDENT  { ([], n) }
  | q = QLIDENT { q }

(* ------------------------------------------------------------------
 * Modules
 * ------------------------------------------------------------------ *)

module_declaration:
  | MOD n = UIDENT ps = list(module_parameter) a = option(preceded(COLON, sig_exp))
    EQ m = module_expression
      { if ps <> [] then
          Diag.at $startpos "a parameterized mod is defined with items, not with =";
        mk_d $startpos (DMod (MBindTo (n, a, m))) }
  | MOD n = UIDENT ps = list(module_parameter) a = option(preceded(COLON, sig_exp))
    items = list(module_item) END
      { mk_d $startpos (DMod (MDefine (n, ps, a, items))) }

module_parameter:
  | LPAREN n = UIDENT COLON s = sig_exp RPAREN { (n, s) }

module_item:
  | d = value_declaration    { d }
  | d = function_declaration { d }
  | d = type_declaration     { d }
  | d = module_declaration   { d }
  | d = import_declaration   { d }
  | INCLUDE p = module_path  { mk_d $startpos (DInclude p) }

module_expression:
  | p = module_path { mk_me $startpos (MEPath p) }
  | p = module_path LPAREN m = module_expression RPAREN { mk_me $startpos (MEApp (p, m)) }

module_path:
  | n = UIDENT          { [ n ] }
  | q = QUIDENT         { fst q @ [ snd q ] }

import_declaration:
  | IMPORT p = module_path c = option(import_clause) { mk_d $startpos (DImport (p, c)) }

import_clause:
  | AS n = UIDENT                                                    { IAs n }
  | LPAREN ns = separated_nonempty_list(COMMA, import_name) RPAREN   { INames ns }

import_name:
  | n = LIDENT                 { n }
  | n = UIDENT                 { n }
  | LPAREN o = operator RPAREN { o }

(* ------------------------------------------------------------------
 * Expressions
 * ------------------------------------------------------------------ *)

expression:
  | FN rs = lambda_rules %prec LOW { mk_e $startpos (EFn (List.rev rs)) }
  | e = infix_expression           { e }

lambda_rules:
  | r = lambda_rule                     { [ r ] }
  | rs = lambda_rules BAR r = lambda_rule { r :: rs }

lambda_rule:
  | p = pattern DARROW e = expression { { r_pat = p; r_guard = None; r_body = e } }

infix_expression:
  | c = infix_chain %prec LOW
      { match snd c with
        | [] -> fst c
        | ops -> mk_e (fst c).eloc (EInfix (fst c, List.rev ops)) }

infix_chain:
  | e = prefix_expression                                  { (e, []) }
  | c = infix_chain o = binop e = prefix_expression        { (fst c, (o, $startpos(o), e) :: snd c) }

binop:
  | o = OP { o }
  | MINUS  { "-" }
  | STAR   { "*" }
  | CONS   { "::" }
  | AND    { "and" }
  | OR     { "or" }

operator:
  | o = OP { o }
  | MINUS  { "-" }
  | STAR   { "*" }
  | CONS   { "::" }

prefix_expression:
  | MINUS e = prefix_expression        { mk_e $startpos (EUn ("-", e)) }
  | NOT e = prefix_expression          { mk_e $startpos (EUn ("not", e)) }
  | e = application_expression %prec LOW { e }

application_expression:
  | e = postfix_expression %prec LOW                              { e }
  | f = application_expression a = postfix_expression %prec LOW   { mk_e f.eloc (EApp (f, a)) }

postfix_expression:
  | e = primary_expression                  { e }
  | e = postfix_expression DOT f = LIDENT   { mk_e e.eloc (EProj (e, f)) }

primary_expression:
  | l = literal                { mk_e $startpos (ELit l) }
  | n = LIDENT                 { mk_e $startpos (EVar ([], n)) }
  | q = QLIDENT                { mk_e $startpos (EVar q) }
  | n = UIDENT                 { mk_e $startpos (ECon ([], n)) }
  | q = QUIDENT                { mk_e $startpos (ECon q) }
  | LPAREN o = operator RPAREN
      { mk_e $startpos (if is_cons_op o then ECon cons_path else EVar ([], o)) }
  | LPAREN e = expression RPAREN { e }
  | LPAREN e = expression COMMA es = separated_nonempty_list(COMMA, expression) RPAREN
      { mk_e $startpos (ETuple (e :: es)) }
  | LBRACK es = separated_list(COMMA, expression) RBRACK
      { list_exp $startpos es }
  | LBRACE fs = separated_list(COMMA, field_expression) RBRACE
      { mk_e $startpos (ERec fs) }
  | LET ds = list(local_declaration) IN e = expression END
      { mk_e $startpos (ELet (ds, e)) }
  | BEGIN e = expression es = list(preceded(SEMI, expression)) END
      { mk_e $startpos (ESeq (e :: es)) }
  | IF c = expression THEN t = expression ELSE f = expression
      { mk_e $startpos (EIf (c, t, f)) }
  | CASE e = expression OF option(BAR) rs = case_rules %prec LOW
      { mk_e $startpos (ECase (e, List.rev rs)) }

field_expression:
  | f = LIDENT                     { (f, mk_e $startpos (EVar ([], f))) }
  | f = LIDENT EQ e = expression   { (f, e) }

case_rules:
  | r = case_rule                       { [ r ] }
  | rs = case_rules BAR r = case_rule   { r :: rs }

case_rule:
  | p = pattern g = option(preceded(IF, expression)) DARROW e = expression
      { { r_pat = p; r_guard = g; r_body = e } }

local_declaration:
  | d = value_declaration    { d }
  | d = function_declaration { d }
  | d = type_declaration     { d }
  | d = import_declaration   { d }

literal:
  | n = INT      { LInt n }
  | r = REAL     { LReal r }
  | c = CHAR     { LChar c }
  | s = STRING   { LString s }
  | TRUE         { LBool true }
  | FALSE        { LBool false }
  | LPAREN RPAREN { LUnit }

(* ------------------------------------------------------------------
 * Patterns
 * ------------------------------------------------------------------ *)

pattern:
  | p = cons_pattern { p }

cons_pattern:
  | p = constructor_pattern                        { p }
  | h = constructor_pattern CONS t = cons_pattern  { cons_pat $startpos h t }

constructor_pattern:
  | p = atomic_pattern                { p }
  | n = UIDENT a = atomic_pattern     { mk_p $startpos (PCon (([], n), Some a)) }
  | q = QUIDENT a = atomic_pattern    { mk_p $startpos (PCon (q, Some a)) }

atomic_pattern:
  | UNDERSCORE   { mk_p $startpos PWild }
  | l = literal  { mk_p $startpos (PLit l) }
  | n = LIDENT   { mk_p $startpos (PVar n) }
  | n = UIDENT   { mk_p $startpos (PCon (([], n), None)) }
  | q = QUIDENT  { mk_p $startpos (PCon (q, None)) }
  | LPAREN p = typed_pattern RPAREN { p }
  | LPAREN p = typed_pattern COMMA ps = separated_nonempty_list(COMMA, typed_pattern) RPAREN
      { mk_p $startpos (PTuple (p :: ps)) }
  | LBRACK ps = separated_list(COMMA, typed_pattern) RBRACK
      { list_pat $startpos ps }
  | LBRACE fs = separated_list(COMMA, field_pattern) RBRACE
      { mk_p $startpos (PRec fs) }

(* A pattern may say what it matches wherever a bracket closes it, which is
   the one place where ": type" cannot be read as the annotation of the val or
   the clause the pattern belongs to. *)
typed_pattern:
  | p = pattern                { p }
  | p = pattern COLON t = ty   { mk_p $startpos (PAnn (p, t)) }

field_pattern:
  | f = LIDENT                       { (f, mk_p $startpos (PVar f)) }
  | f = LIDENT EQ p = typed_pattern  { (f, p) }

(* ------------------------------------------------------------------
 * Types
 * ------------------------------------------------------------------ *)

ty:
  | t = tuple_ty                 { t }
  | t = tuple_ty ARROW u = ty    { mk_t $startpos (TArrow (t, u)) }

tuple_ty:
  | t = app_ty { t }
  | t = app_ty STAR ts = separated_nonempty_list(STAR, app_ty)
      { mk_t $startpos (TTuple (t :: ts)) }

app_ty:
  | t = atomic_ty cs = list(tycon_name)
      { let l = $startpos in
        List.fold_left (fun acc c -> mk_t l (TCon (c, [ acc ]))) t cs }
  | LPAREN t = ty COMMA ts = separated_nonempty_list(COMMA, ty) RPAREN
    c = tycon_name cs = list(tycon_name)
      { let l = $startpos in
        List.fold_left (fun acc c -> mk_t l (TCon (c, [ acc ]))) (mk_t l (TCon (c, t :: ts))) cs }

tycon_name:
  | n = LIDENT  { ([], n) }
  | q = QLIDENT { q }

atomic_ty:
  | v = TYVAR    { mk_t $startpos (TVar v) }
  | n = LIDENT   { mk_t $startpos (TCon (([], n), [])) }
  | q = QLIDENT  { mk_t $startpos (TCon (q, [])) }
  | LBRACE fs = separated_list(COMMA, field_ty) r = option(preceded(BAR, TYVAR)) RBRACE
      { mk_t $startpos (TRec (fs, r)) }
  | LPAREN t = ty RPAREN { t }

field_ty:
  | f = LIDENT COLON t = ty { (f, t) }
