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

(* Variables inside one `val` declaration share a name; the table is cleared
   between declarations by the sig_items rule below. *)
let signature_vars : (string, Types.t) Hashtbl.t = Hashtbl.create 8

let signature_variable name =
  match Hashtbl.find_opt signature_vars name with
  | Some t -> t
  | None ->
    let t = Types.fresh_rigid () in
    Hashtbl.replace signature_vars name t;
    t

let base_type = function
  | "int" -> Types.Int
  | "bool" -> Types.Bool
  | "unit" -> Types.Unit
  | "string" -> Types.String
  | name -> Types.Named name

(* `M`, `M.N`: a dotted run of capitalised names.  Keeping the constructor case
   and the module-path case behind one nonterminal is what stops the parser
   having to choose between them the moment it sees a dot.  Which one it is --
   and how many arguments a constructor takes -- is Modules' business, so the
   name travels as written and the arguments are left alone. *)
let dotted path = String.concat "." path

(* Diagnostics want to say where something was written.  Only the productions
   an error can be reported against carry a position; the rest would be noise
   in the tree for no gain. *)
let at position exp = At (position, exp)
%}

%token <int> INT
%token <bool> BOOL
%token <string> IDENT
%token <string> STRING
%token <string> UIDENT
%token LET IN REC AND IF THEN ELSE FUN NOT ARRAY_MAKE
%token TYPE OF MATCH WITH BAR UNDERSCORE ARRAY_KW LIST_KW
%token PLUS MINUS AST SLASH PERCENT
%token EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%token AMPAMP BARBAR
%token LPAREN RPAREN COMMA SEMICOLON DOT LESS_MINUS ARROW
%token LBRACKET RBRACKET COLONCOLON CARET STRING_LENGTH
%token BEGIN END MODULE STRUCT OPEN SIG VAL COLON
%token <string> TYPEVAR
%token EOF

%right prec_let prec_match
%right SEMICOLON
%nonassoc prec_list
%right prec_if
%nonassoc ELSE
%right LESS_MINUS
%nonassoc prec_tuple
%left COMMA
%right BARBAR
%right AMPAMP
%left EQUAL LESS_GREATER LESS GREATER LESS_EQUAL GREATER_EQUAL
%right CARET
%right COLONCOLON
%left PLUS MINUS
%left AST SLASH PERCENT
%right prec_unary_minus
%left prec_app
%left DOT

%type <Syntax.t> program
%start program

%%

program:
  | type_decls exp EOF { List.fold_right (fun d body -> Type_decl (d, body)) $1 $2 }

(* ------------------------------------------------------------- datatypes *)

type_decls:
  | (* empty *) { [] }
  | type_decl type_decls { $1 :: $2 }

type_decl:
  | TYPE IDENT EQUAL opt_bar constr_decls { { tname = $2; tconstrs = $5 } }

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

(* A signature's type expression.  Each `'a` is a variable of that signature
   alone, so the same spelling in two `val`s is two different variables. *)
signature_type:
  | type_expr { $1 }

simple_type:
  | TYPEVAR { signature_variable $1 }
  | IDENT { base_type $1 }
  | long_name DOT IDENT { Types.Named (dotted ($1 @ [ $3 ])) }
  | simple_type ARRAY_KW { Types.Array $1 }
  | simple_type LIST_KW { Types.List $1 }
  | LPAREN type_expr RPAREN { $2 }

type_expr:
  | type_args ARROW type_expr { Types.Fun ($1, $3) }
  | type_args { match $1 with [ t ] -> t | ts -> Types.Tuple ts }

(* ----------------------------------------------------------- expressions *)

simple_exp:
  | LPAREN exp RPAREN { $2 }
  | BEGIN exp END { $2 }
  | long_name DOT IDENT { at $startpos (Qualified ($1, $3)) }
  | LPAREN RPAREN { Unit }
  | BOOL { Bool $1 }
  | INT { Int $1 }
  | STRING { Str $1 }
  | IDENT { at $startpos (Var $1) }
  | long_name { Constr (dotted $1, []) }
  | LBRACKET RBRACKET { Nil }
  | LBRACKET list_body RBRACKET { List.fold_right (fun e rest -> Cons (e, rest)) $2 Nil }
  | simple_exp DOT LPAREN exp RPAREN { at $startpos (Get ($1, $4)) }
  | simple_exp DOT LBRACKET exp RBRACKET { at $startpos (Str_get ($1, $4)) }

exp:
  | simple_exp { $1 }
  | NOT exp %prec prec_app { at $startpos (Not $2) }
  | MINUS exp %prec prec_unary_minus { at $startpos (Neg $2) }
  | exp PLUS exp { at $startpos (Arith (Add, $1, $3)) }
  | exp MINUS exp { at $startpos (Arith (Sub, $1, $3)) }
  | exp AST exp { at $startpos (Arith (Mul, $1, $3)) }
  | exp SLASH exp { at $startpos (Arith (Div, $1, $3)) }
  | exp PERCENT exp { at $startpos (Arith (Rem, $1, $3)) }
  | exp EQUAL exp { at $startpos (Cmp (Eq, $1, $3)) }
  | exp LESS_GREATER exp { at $startpos (Cmp (Ne, $1, $3)) }
  | exp LESS exp { at $startpos (Cmp (Lt, $1, $3)) }
  | exp GREATER exp { at $startpos (Cmp (Gt, $1, $3)) }
  | exp LESS_EQUAL exp { at $startpos (Cmp (Le, $1, $3)) }
  | exp GREATER_EQUAL exp { at $startpos (Cmp (Ge, $1, $3)) }
  | exp AMPAMP exp { If ($1, $3, Bool false) }
  | exp BARBAR exp { If ($1, Bool true, $3) }
  | IF exp THEN exp ELSE exp %prec prec_if { at $startpos (If ($2, $4, $6)) }
  (* A missing `else` is `else ()`, so the branch must have type unit. *)
  | IF exp THEN exp %prec prec_if { at $startpos (If ($2, $4, Unit)) }
  | MATCH exp WITH match_cases %prec prec_match
      { at $startpos
          (Match
             ( { scrutinee_type = Types.fresh_var (); result_type = Types.fresh_var () },
               $2, $4 )) }
  | FUN formal_args ARROW exp %prec prec_let { lambda $2 $4 }
  | LET IDENT EQUAL exp IN exp %prec prec_let { at $startpos (Let (typed $2, $4, $6)) }
  | LET REC fundefs IN exp %prec prec_let { at $startpos (Let_rec ($3, $5)) }
  | MODULE UIDENT EQUAL module_exp IN exp %prec prec_let { at $startpos (Module ($2, $4, $6)) }
  | MODULE UIDENT COLON signature EQUAL module_exp IN exp %prec prec_let
      { at $startpos (Module ($2, Mod_sealed ($6, $4), $8)) }
  | MODULE UIDENT LPAREN UIDENT COLON signature RPAREN EQUAL STRUCT items END IN exp
      %prec prec_let
      { at $startpos (Functor ($2, $4, $6, $10, $13)) }
  | MODULE TYPE UIDENT EQUAL signature IN exp %prec prec_let
      { at $startpos (Module_type ($3, $5, $7)) }
  | OPEN long_name IN exp %prec prec_let { at $startpos (Open ($2, $4)) }
  | LET LPAREN tuple_pat RPAREN EQUAL exp IN exp %prec prec_let
      { Let_tuple ($3, $6, $8) }
  | exp actual_args %prec prec_app
      { match strip $1 with
        | Constr (c, []) -> at $startpos (Constr (c, $2))
        | _ -> at $startpos (App ($1, $2)) }
  | elems %prec prec_tuple { Tuple $1 }
  | ARRAY_MAKE simple_exp simple_exp %prec prec_app { at $startpos (Array ($2, $3)) }
  | STRING_LENGTH simple_exp %prec prec_app { at $startpos (Str_length $2) }
  | exp CARET exp { App (Var "string_concat", [ $1; $3 ]) }
  | simple_exp DOT LPAREN exp RPAREN LESS_MINUS exp { at $startpos (Put ($1, $4, $7)) }
  | exp COLONCOLON exp { at $startpos (Cons ($1, $3)) }
  | exp SEMICOLON exp { sequence $1 $3 }

(* `[a; b]` is a two-element list, not a one-element list of a sequence: the
   rule below outranks the sequencing operator, exactly as in OCaml. *)
list_body:
  | exp %prec prec_list { [ $1 ] }
  | list_body SEMICOLON exp %prec prec_list { $1 @ [ $3 ] }

long_name:
  | UIDENT { [ $1 ] }
  | long_name DOT UIDENT { $1 @ [ $3 ] }

module_exp:
  | STRUCT items END { Mod_struct $2 }
  | long_name { Mod_path $1 }
  | long_name LPAREN module_exp RPAREN { Mod_apply ($1, $3) }
  | LPAREN module_exp COLON signature RPAREN { Mod_sealed ($2, $4) }

signature:
  | UIDENT { Sig_name $1 }
  | SIG sig_items END { Sig_items $2 }

sig_items:
  | (* empty *) { [] }
  | TYPE IDENT sig_items { Sig_type $2 :: $3 }
  | VAL IDENT COLON start_declaration signature_type sig_items
      { Sig_val ($2, $5) :: $6 }

(* An empty rule, so that the reset runs before this declaration's type is
   parsed rather than after the whole tail of the signature. *)
start_declaration:
  | (* empty *) { Hashtbl.reset signature_vars }

items:
  | (* empty *) { [] }
  | item items { $1 :: $2 }

item:
  | LET IDENT EQUAL exp { Item_let (typed $2, $4) }
  | LET LPAREN tuple_pat RPAREN EQUAL exp { Item_let_tuple ($3, $6) }
  | LET REC fundefs { Item_let_rec $3 }
  | type_decl { Item_type $1 }
  | MODULE UIDENT EQUAL module_exp { Item_module ($2, $4) }
  | MODULE UIDENT COLON signature EQUAL module_exp
      { Item_module ($2, Mod_sealed ($6, $4)) }
  | MODULE UIDENT LPAREN UIDENT COLON signature RPAREN EQUAL STRUCT items END
      { Item_functor ($2, $4, $6, $10) }
  | MODULE TYPE UIDENT EQUAL signature { Item_module_type ($3, $5) }
  | OPEN long_name { Item_open $2 }

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
  | tuple_pat COMMA tuple_pat_name { $1 @ [ $3 ] }
  | tuple_pat_name COMMA tuple_pat_name { [ $1; $3 ] }

tuple_pat_name:
  | IDENT { typed $1 }
  | UNDERSCORE { typed (Ident.fresh "unused") }

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
  | applied_pattern { $1 }
  | applied_pattern COLONCOLON constr_pattern { Pcons ($1, $3) }

applied_pattern:
  | simple_pattern { $1 }
  | long_name simple_pattern { Pconstr (dotted $1, [ $2 ]) }

simple_pattern:
  | UNDERSCORE { Pwild (Types.fresh_var ()) }
  | IDENT { Pvar ($1, Types.fresh_var ()) }
  | INT { Pint $1 }
  | MINUS INT { Pint (- $2) }
  | BOOL { Pbool $1 }
  | LPAREN RPAREN { Punit }
  | long_name { Pconstr (dotted $1, []) }
  | LBRACKET RBRACKET { Pnil }
  | LBRACKET pattern_list RBRACKET
      { List.fold_right (fun p rest -> Pcons (p, rest)) $2 Pnil }
  | LPAREN pattern RPAREN { $2 }

pattern_list:
  | constr_pattern { [ $1 ] }
  | constr_pattern SEMICOLON pattern_list { $1 :: $3 }
