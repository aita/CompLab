%{
open Ast

let at (pos : Lexing.position) desc = { desc; line = pos.Lexing.pos_lnum }
%}

%token <int> INT
%token <float> FLOAT
%token <string> STRING
%token <string> IDENT
%token FUN FN CLASS LET IF ELSE WHILE FOR IN RETURN BREAK CONTINUE
%token TRUE FALSE NIL SUPER
%token PLUS MINUS TIMES DIV MOD
%token EQEQ BANGEQ LT LE GT GE
%token ANDAND OROR BANG
%token ASSIGN
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET
%token COMMA SEMI DOT COLON
%token EOF

(* Lowest precedence first.  RETURN sits below everything so that
   'return a + b' swallows the whole expression.  'else' needs no precedence:
   an 'else' branch is always a block or a nested 'if', so it can only ever
   belong to the innermost 'if'. *)
%nonassoc RETURN
%right ASSIGN
%left OROR
%left ANDAND
%left EQEQ BANGEQ
%left LT LE GT GE
%left PLUS MINUS
%left TIMES DIV MOD
%right BANG UMINUS
%left DOT LPAREN LBRACKET

%start <Ast.block> program

%%

program:
  | b = block_items EOF { b }
  ;

(* Declarations stand on their own; expressions are separated by ';'.
   A trailing expression without ';' is the value of the block. *)
block_items:
  |                                     { [] }
  | d = decl rest = block_items         { d :: rest }
  | e = expr                            { [ at $startpos(e) (SExpr e) ] }
  | e = expr SEMI rest = block_items    { at $startpos(e) (SExpr e) :: rest }
  ;

block:
  | LBRACE b = block_items RBRACE { b }
  ;

decl:
  | f = fundecl { at $startpos (SFun f) }
  | CLASS name = IDENT bs = bases LBRACE ms = list(fundecl) RBRACE
      { at $startpos (SClass { cname = name; bases = bs; meths = ms }) }
  ;

fundecl:
  | FUN name = IDENT LPAREN ps = params RPAREN body = block
      { { fname = name; params = ps; body } }
  ;

params:
  | ps = separated_list(COMMA, IDENT) { ps }
  ;

bases:
  |                                                  { [] }
  | COLON bs = separated_nonempty_list(COMMA, IDENT) { bs }
  ;

args:
  | es = separated_list(COMMA, expr) { es }
  ;

expr:
  | LET x = IDENT ASSIGN e = expr   { Let (x, e) }
  | RETURN                          { Return None }
  | RETURN e = expr                 { Return (Some e) }
  | BREAK                           { Break }
  | CONTINUE                        { Continue }
  | lhs = expr ASSIGN rhs = expr
      { if is_lvalue lhs then Assign (lhs, rhs)
        else raise (Syntax_error ($startpos(lhs), "the left of '=' is not assignable")) }
  | a = expr OROR b = expr          { Or (a, b) }
  | a = expr ANDAND b = expr        { And (a, b) }
  | a = expr EQEQ b = expr          { Binop (Eq, a, b) }
  | a = expr BANGEQ b = expr        { Binop (Ne, a, b) }
  | a = expr LT b = expr            { Binop (Lt, a, b) }
  | a = expr LE b = expr            { Binop (Le, a, b) }
  | a = expr GT b = expr            { Binop (Gt, a, b) }
  | a = expr GE b = expr            { Binop (Ge, a, b) }
  | a = expr PLUS b = expr          { Binop (Add, a, b) }
  | a = expr MINUS b = expr         { Binop (Sub, a, b) }
  | a = expr TIMES b = expr         { Binop (Mul, a, b) }
  | a = expr DIV b = expr           { Binop (Div, a, b) }
  | a = expr MOD b = expr           { Binop (Mod, a, b) }
  | MINUS e = expr %prec UMINUS     { Unop (Neg, e) }
  | BANG e = expr                   { Unop (Not, e) }
  | f = expr LPAREN a = args RPAREN { Call (f, a) }
  | e = expr DOT name = IDENT       { Field (e, name) }
  | e = expr LBRACKET i = expr RBRACKET { Index (e, i) }
  | e = primary                     { e }
  ;

primary:
  | n = INT                         { Int n }
  | f = FLOAT                       { Float f }
  | s = STRING                      { Str s }
  | TRUE                            { Bool true }
  | FALSE                           { Bool false }
  | NIL                             { Nil }
  | x = IDENT                       { Var x }
  | SUPER DOT name = IDENT          { Super name }
  | LPAREN e = expr RPAREN          { e }
  | LBRACKET es = args RBRACKET     { ListLit es }
  | FN LPAREN ps = params RPAREN b = block { Fn (ps, b) }
  | e = if_expr                     { e }
  | WHILE c = expr b = block        { While (c, b) }
  | FOR x = IDENT IN e = expr b = block { For (x, e, b) }
  ;

if_expr:
  | IF c = expr t = block e = else_part { If (c, t, e) }
  ;

else_part:
  |                         { None }
  | ELSE b = block          { Some b }
  | ELSE e = if_expr        { Some [ at $startpos(e) (SExpr e) ] }
  ;
