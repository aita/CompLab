%{
open Syntax
open Brace_build

(* Type variables declared by `fun <T> ...` inside an interface.  They are
   rigid, and belong to the one declaration that introduced them. *)
let type_variables : (string, Types.t) Hashtbl.t = Hashtbl.create 8
let start_declaration () = Hashtbl.reset type_variables

let declare_variable name =
  let t = Types.fresh_rigid () in
  Hashtbl.replace type_variables name t;
  t

let named_type name =
  match Hashtbl.find_opt type_variables name with
  | Some t -> t
  | None -> (
    match name with
    | "Int" -> Types.Int
    | "Boolean" -> Types.Bool
    | "String" -> Types.String
    | "Unit" -> Types.Unit
    | name -> Types.Named name)

let applied_type name args =
  match (name, args) with
  | "List", [ t ] -> Types.List t
  | "Array", [ t ] -> Types.Array t
  | _ ->
    failwith
      (Printf.sprintf "`%s` does not take type arguments (only List and Array do)" name)

(* A dotted run of capitalised names is a module path until something says
   otherwise, so both readings come out of one nonterminal and the action
   decides.  See the same trick in the ML form's parser. *)
let is_path e =
  match strip e with
  | Constr (name, []) -> Some (String.split_on_char '.' name)
  | _ -> None

(* Extending a path: `M` then `.N`.  Paths grow through the same postfix rule
   as property access, so the parser never has to decide at the dot which of
   the two it is looking at. *)
let extend owner name =
  match strip owner with
  | Constr (path, []) -> Constr (path ^ "." ^ name, [])
  | _ -> failwith (Printf.sprintf "`%s` cannot be selected from a value" name)

let select owner name =
  match is_path owner with
  | Some path -> Qualified (path, name)
  | None -> (
    match name with
    | "length" -> Str_length owner
    | _ ->
      failwith
        (Printf.sprintf "unknown property `%s` (a string has `length`)" name))

let invoke owner name args =
  match (is_path owner, name, args) with
  | Some path, _, _ -> App (Qualified (path, name), args)
  | None, "charAt", [ index ] -> Str_get (owner, index)
  | None, "plus", [ other ] -> App (Var "string_concat", [ owner; other ])
  | None, "equals", [ other ] -> App (Var "string_equal", [ owner; other ])
  | None, _, _ ->
    failwith
      (Printf.sprintf "unknown method `%s` (a string has charAt, plus and equals)" name)

(* `f()` is a call with no arguments; every function here takes at least one,
   so it is passed the unit value. *)
let at position exp = At (position, exp)

let call fn args =
  match strip fn with
  | Constr (name, []) -> Constr (name, args)
  | _ -> App (fn, (match args with [] -> [ Unit ] | args -> args))
%}

%token <int> INT
%token <bool> BOOL
%token <string> STRING
%token <string> IDENT
%token <string> UIDENT
%token VAL FUN IF ELSE WHEN IS OBJECT INTERFACE SEALED CLASS IMPORT ARRAY LIST_OF
%token NIL CONS
%token PLUS MINUS STAR SLASH PERCENT BANG
%token EQUAL EQUAL_EQUAL BANG_EQUAL LESS GREATER LESS_EQUAL GREATER_EQUAL
%token AMPAMP BARBAR ARROW UNDERSCORE
%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET COMMA SEMI COLON DOT
%token EOF

%nonassoc no_else
%nonassoc ELSE

%type <Syntax.t> program
%start program

%%

program:
  | declarations EOF { Brace_build.program $1 }


declarations:
  | (* empty *) { [] }
  | declaration declarations { $1 :: $2 }

declaration:
  | VAL IDENT opt_type EQUAL expr { Dval (typed $2, annotate $5 $3) }
  | VAL LPAREN names RPAREN EQUAL expr { Dval_tuple (List.map typed $3, $6) }
  | FUN IDENT LPAREN parameters RPAREN opt_type function_body
      { Dfun (make_function $2 $4 $6 $7) }
  | SEALED CLASS UIDENT LBRACE constructors RBRACE
      { Dtype { tname = $3; tconstrs = $5 } }
  | OBJECT UIDENT LBRACE declarations RBRACE
      { Dmodule ($2, Mod_struct (to_items $4)) }
  | OBJECT UIDENT COLON UIDENT LBRACE declarations RBRACE
      { Dmodule ($2, Mod_sealed (Mod_struct (to_items $6), Sig_name $4)) }
  | OBJECT UIDENT EQUAL module_exp { Dmodule ($2, $4) }
  | OBJECT UIDENT LESS UIDENT COLON UIDENT GREATER LBRACE declarations RBRACE
      { Dfunctor ($2, $4, Sig_name $6, to_items $9) }
  | INTERFACE UIDENT LBRACE interface_items RBRACE { Dinterface ($2, Sig_items $4) }
  | IMPORT path { Dimport $2 }

function_body:
  | EQUAL expr { $2 }
  | block { $1 }

module_exp:
  | UIDENT LESS UIDENT GREATER { Mod_apply ([ $1 ], Mod_path [ $3 ]) }
  | path { Mod_path $1 }

path:
  | UIDENT { [ $1 ] }
  | path DOT UIDENT { $1 @ [ $3 ] }

names:
  | name { [ $1 ] }
  | name COMMA names { $1 :: $3 }

name:
  | IDENT { $1 }
  | UNDERSCORE { Ident.fresh "unused" }

parameters:
  | (* empty *) { [] }
  | parameter { [ $1 ] }
  | parameter COMMA parameters { $1 :: $3 }

parameter:
  | IDENT opt_type { ($1, $2) }

opt_type:
  | (* empty *) { None }
  | COLON type_exp { Some $2 }

(* ------------------------------------------------------------ datatypes *)

constructors:
  | (* empty *) { [] }
  | OBJECT UIDENT constructors { ($2, []) :: $3 }
  | CLASS UIDENT LPAREN type_list RPAREN constructors { ($2, $4) :: $6 }

(* ----------------------------------------------------------- interfaces *)

interface_items:
  | (* empty *) { [] }
  | SEALED CLASS UIDENT interface_items { Sig_type $3 :: $4 }
  | VAL IDENT COLON reset signature_type interface_items { Sig_val ($2, $5) :: $6 }
  | FUN reset generics IDENT LPAREN type_list RPAREN COLON signature_type interface_items
      { Sig_val ($4, Types.Fun ((if $6 = [] then [ Types.Unit ] else $6), $9)) :: $10 }

reset:
  | (* empty *) { start_declaration () }

generics:
  | (* empty *) { () }
  | LESS type_parameters GREATER { () }

type_parameters:
  | UIDENT { ignore (declare_variable $1) }
  | UIDENT COMMA type_parameters { ignore (declare_variable $1) }

signature_type:
  | type_exp { $1 }

(* ---------------------------------------------------------------- types *)

type_exp:
  | LPAREN type_list RPAREN ARROW type_exp { Types.Fun ($2, $5) }
  | atom_type { $1 }

atom_type:
  | UIDENT { named_type $1 }
  | UIDENT LESS type_list GREATER { applied_type $1 $3 }
  | LPAREN type_list RPAREN
      { match $2 with [ t ] -> t | ts -> Types.Tuple ts }

type_list:
  | (* empty *) { [] }
  | type_exp { [ $1 ] }
  | type_exp COMMA type_list { $1 :: $3 }

(* ---------------------------------------------------------------- blocks *)

block:
  | LBRACE block_items RBRACE { $2 }

block_items:
  | (* empty *) { Unit }
  | expr { $1 }
  | statement SEMI block_items { to_expression [ $1 ] $3 }

statement:
  | declaration { $1 }
  | expr { Dexpression $1 }

(* ----------------------------------------------------------- expressions *)

expr:
  | IF LPAREN expr RPAREN expr %prec no_else { at $startpos (If ($3, $5, Unit)) }
  | IF LPAREN expr RPAREN expr ELSE expr { at $startpos (If ($3, $5, $7)) }
  | WHEN LPAREN expr RPAREN LBRACE cases RBRACE
      { at $startpos
          (Match
             ( { scrutinee_type = Types.fresh_var (); result_type = Types.fresh_var () },
               $3, $6 )) }
  | FUN LPAREN parameters RPAREN opt_type function_body
      { let f = Ident.fresh "lambda" in
        Let_rec ([ make_function f $3 $5 $6 ], Var f) }
  | postfix LBRACKET expr RBRACKET EQUAL expr { at $startpos (Put ($1, $3, $6)) }
  | disjunction { $1 }

disjunction:
  | disjunction BARBAR conjunction { If ($1, Bool true, $3) }
  | conjunction { $1 }

conjunction:
  | conjunction AMPAMP comparison { If ($1, $3, Bool false) }
  | comparison { $1 }

comparison:
  | sum EQUAL_EQUAL sum { at $startpos (Cmp (Eq, $1, $3)) }
  | sum BANG_EQUAL sum { at $startpos (Cmp (Ne, $1, $3)) }
  | sum LESS sum { at $startpos (Cmp (Lt, $1, $3)) }
  | sum LESS_EQUAL sum { at $startpos (Cmp (Le, $1, $3)) }
  | sum GREATER sum { at $startpos (Cmp (Gt, $1, $3)) }
  | sum GREATER_EQUAL sum { at $startpos (Cmp (Ge, $1, $3)) }
  | sum { $1 }

sum:
  | sum PLUS product { at $startpos (Arith (Add, $1, $3)) }
  | sum MINUS product { at $startpos (Arith (Sub, $1, $3)) }
  | product { $1 }

product:
  | product STAR unary { at $startpos (Arith (Mul, $1, $3)) }
  | product SLASH unary { at $startpos (Arith (Div, $1, $3)) }
  | product PERCENT unary { at $startpos (Arith (Rem, $1, $3)) }
  | unary { $1 }

unary:
  | MINUS unary { at $startpos (Neg $2) }
  | BANG unary { at $startpos (Not $2) }
  | postfix { $1 }

postfix:
  | postfix LPAREN arguments RPAREN { at $startpos (call $1 $3) }
  | postfix LBRACKET expr RBRACKET { at $startpos (Get ($1, $3)) }
  | postfix DOT UIDENT { extend $1 $3 }
  | postfix DOT IDENT { at $startpos (select $1 $3) }
  | postfix DOT IDENT LPAREN arguments RPAREN { at $startpos (invoke $1 $3 $5) }
  | primary { $1 }

primary:
  | INT { Int $1 }
  | STRING { Str $1 }
  | BOOL { Bool $1 }
  | IDENT { at $startpos (Var $1) }
  | UIDENT { Constr ($1, []) }
  | ARRAY LPAREN expr COMMA expr RPAREN { at $startpos (Array ($3, $5)) }
  | LIST_OF LPAREN arguments RPAREN { list_of $3 }
  | NIL { Nil }
  | CONS LPAREN expr COMMA expr RPAREN { at $startpos (Cons ($3, $5)) }
  | LPAREN RPAREN { Unit }
  | LPAREN arguments RPAREN { match $2 with [ e ] -> e | es -> Tuple es }
  | block { $1 }

arguments:
  | (* empty *) { [] }
  | expr { [ $1 ] }
  | expr COMMA arguments { $1 :: $3 }

(* -------------------------------------------------------------- patterns *)

cases:
  | (* empty *) { [] }
  | case SEMI cases { $1 :: $3 }
  | case { [ $1 ] }

case:
  | pattern ARROW expr { { pat = $1; action = $3 } }

pattern:
  | ELSE { Pwild (Types.fresh_var ()) }
  | UNDERSCORE { Pwild (Types.fresh_var ()) }
  | IDENT { Pvar ($1, Types.fresh_var ()) }
  | INT { Pint $1 }
  | MINUS INT { Pint (- $2) }
  | BOOL { Pbool $1 }
  | LPAREN RPAREN { Punit }
  | LPAREN patterns RPAREN { match $2 with [ p ] -> p | ps -> Ptuple ps }
  | IS NIL { Pnil }
  | IS CONS LPAREN pattern COMMA pattern RPAREN { Pcons ($4, $6) }
  | IS path { Pconstr (Brace_build.dotted $2, []) }
  | IS path LPAREN patterns RPAREN { Pconstr (Brace_build.dotted $2, $4) }

patterns:
  | pattern { [ $1 ] }
  | pattern COMMA patterns { $1 :: $3 }
