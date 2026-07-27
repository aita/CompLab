%{
open Syntax

let typed x = (x, Types.fresh_var ())

(* `e1; e2` is a let of a name nobody can write, so the elimination pass can
   drop it once e1 is known to be pure. *)
let sequence e1 e2 = Let ((Ident.fresh "seq", Types.Unit), e1, e2)

(* `fun x y -> e` is a one-shot recursive definition whose value is the
   function itself, so anonymous and named functions share one code path. *)
let lambda args body =
  let f = Ident.fresh "fun" in
  Let_rec ([ { name = typed f; args; body } ], Var f)

let base_type = function
  | "int" -> Types.Int
  | "bool" -> Types.Bool
  | "unit" -> Types.Unit
  | name -> Types.Named name

(* `Node (l, v, r)` parses as an application of `Node` to one parenthesized
   tuple; a constructor of matching arity takes the components as its
   arguments, exactly as in OCaml.  Doing this here rather than in the grammar
   keeps constructor application from conflicting with function application. *)
let constr_args name args =
  match (Datatype.find_constr name, args) with
  | Some c, [ Tuple es ] when List.length c.Datatype.arg_types = List.length es -> es
  | _ -> args

let constr_pattern_args name args =
  match (Datatype.find_constr name, args) with
  | Some c, Ptuple ps when List.length c.Datatype.arg_types = List.length ps -> ps
  | _ -> [ args ]
%}

%token <int> INT
%token <bool> BOOL
%token <string> IDENT
%token <string> UIDENT
%token LET IN REC AND IF THEN ELSE FUN NOT ARRAY_MAKE
%token TYPE OF MATCH WITH BAR UNDERSCORE ARRAY_KW
%token PLUS MINUS AST SLASH PERCENT
%token EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%token AMPAMP BARBAR
%token LPAREN RPAREN COMMA SEMICOLON DOT LESS_MINUS ARROW
%token EOF

%right prec_let prec_match
%right SEMICOLON
%right prec_if
%nonassoc ELSE
%right LESS_MINUS
%nonassoc prec_tuple
%left COMMA
%right BARBAR
%right AMPAMP
%left EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%left PLUS MINUS
%left AST SLASH PERCENT
%right prec_unary_minus
%left prec_app
%left DOT

%type <Syntax.t> program
%start program

%%

program:
  | type_decls exp EOF { $2 }

(* ------------------------------------------------------------- datatypes *)

type_decls:
  | (* empty *) { () }
  | type_decl type_decls { () }

type_decl:
  | TYPE IDENT EQUAL opt_bar constr_decls { Datatype.declare $2 $5 }

opt_bar:
  | (* empty *) { () }
  | BAR { () }

constr_decls:
  | constr_decl { [ $1 ] }
  | constr_decl BAR constr_decls { $1 :: $3 }

constr_decl:
  | UIDENT { ($1, []) }
  | UIDENT OF type_args { ($1, $3) }

(* `A of int * tree` declares a constructor of two arguments, as in OCaml. *)
type_args:
  | simple_type { [ $1 ] }
  | simple_type AST type_args { $1 :: $3 }

simple_type:
  | IDENT { base_type $1 }
  | simple_type ARRAY_KW { Types.Array $1 }
  | LPAREN type_expr RPAREN { $2 }

type_expr:
  | type_args ARROW type_expr { Types.Fun ($1, $3) }
  | type_args { match $1 with [ t ] -> t | ts -> Types.Tuple ts }

(* ----------------------------------------------------------- expressions *)

simple_exp:
  | LPAREN exp RPAREN { $2 }
  | LPAREN RPAREN { Unit }
  | BOOL { Bool $1 }
  | INT { Int $1 }
  | IDENT { Var $1 }
  | UIDENT { Constr ($1, []) }
  | simple_exp DOT LPAREN exp RPAREN { Get ($1, $4) }

exp:
  | simple_exp { $1 }
  | NOT exp %prec prec_app { Not $2 }
  | MINUS exp %prec prec_unary_minus { Neg $2 }
  | exp PLUS exp { Arith (Add, $1, $3) }
  | exp MINUS exp { Arith (Sub, $1, $3) }
  | exp AST exp { Arith (Mul, $1, $3) }
  | exp SLASH exp { Arith (Div, $1, $3) }
  | exp PERCENT exp { Arith (Rem, $1, $3) }
  | exp EQUAL exp { Cmp (Eq, $1, $3) }
  | exp LESS_GREATER exp { Cmp (Ne, $1, $3) }
  | exp LESS exp { Cmp (Lt, $1, $3) }
  | exp GREATER exp { Cmp (Gt, $1, $3) }
  | exp LESS_EQUAL exp { Cmp (Le, $1, $3) }
  | exp GREATER_EQUAL exp { Cmp (Ge, $1, $3) }
  | exp AMPAMP exp { If ($1, $3, Bool false) }
  | exp BARBAR exp { If ($1, Bool true, $3) }
  | IF exp THEN exp ELSE exp %prec prec_if { If ($2, $4, $6) }
  (* A missing `else` is `else ()`, so the branch must have type unit. *)
  | IF exp THEN exp %prec prec_if { If ($2, $4, Unit) }
  | MATCH exp WITH match_cases %prec prec_match
      { Match
          ( { scrutinee_type = Types.fresh_var (); result_type = Types.fresh_var () },
            $2, $4 ) }
  | FUN formal_args ARROW exp %prec prec_let { lambda $2 $4 }
  | LET IDENT EQUAL exp IN exp %prec prec_let { Let (typed $2, $4, $6) }
  | LET REC fundefs IN exp %prec prec_let { Let_rec ($3, $5) }
  | LET LPAREN tuple_pat RPAREN EQUAL exp IN exp %prec prec_let
      { Let_tuple ($3, $6, $8) }
  | exp actual_args %prec prec_app
      { match $1 with
        | Constr (c, []) -> Constr (c, constr_args c $2)
        | f -> App (f, $2) }
  | elems %prec prec_tuple { Tuple $1 }
  | ARRAY_MAKE simple_exp simple_exp %prec prec_app { Array ($2, $3) }
  | simple_exp DOT LPAREN exp RPAREN LESS_MINUS exp { Put ($1, $4, $7) }
  | exp SEMICOLON exp { sequence $1 $3 }

fundefs:
  | fundef { [ $1 ] }
  | fundef AND fundefs { $1 :: $3 }

fundef:
  | IDENT formal_args EQUAL exp { { name = typed $1; args = $2; body = $4 } }

formal_args:
  | formal_arg formal_args { $1 :: $2 }
  | formal_arg { [ $1 ] }

formal_arg:
  | IDENT { typed $1 }
  (* `f () = ...` names its argument something the body cannot mention. *)
  | LPAREN RPAREN { (Ident.fresh "unit", Types.Unit) }

actual_args:
  | actual_args simple_exp %prec prec_app { $1 @ [ $2 ] }
  | simple_exp %prec prec_app { [ $1 ] }

elems:
  | elems COMMA exp { $1 @ [ $3 ] }
  | exp COMMA exp { [ $1; $3 ] }

tuple_pat:
  | tuple_pat COMMA IDENT { $1 @ [ typed $3 ] }
  | IDENT COMMA IDENT { [ typed $1; typed $3 ] }

(* -------------------------------------------------------------- patterns *)

match_cases:
  | opt_bar case_list { $2 }

case_list:
  | case { [ $1 ] }
  | case BAR case_list { $1 :: $3 }

case:
  | pattern ARROW exp %prec prec_match { { pat = $1; action = $3 } }

pattern:
  | pattern_comma_list { match $1 with [ p ] -> p | ps -> Ptuple ps }

pattern_comma_list:
  | constr_pattern { [ $1 ] }
  | constr_pattern COMMA pattern_comma_list { $1 :: $3 }

constr_pattern:
  | simple_pattern { $1 }
  | UIDENT simple_pattern { Pconstr ($1, constr_pattern_args $1 $2) }

simple_pattern:
  | UNDERSCORE { Pwild (Types.fresh_var ()) }
  | IDENT { Pvar ($1, Types.fresh_var ()) }
  | INT { Pint $1 }
  | MINUS INT { Pint (- $2) }
  | BOOL { Pbool $1 }
  | LPAREN RPAREN { Punit }
  | UIDENT { Pconstr ($1, []) }
  | LPAREN pattern RPAREN { $2 }
