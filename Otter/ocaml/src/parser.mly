/* The grammar, which is the last word on the syntax.

   Alternatives are ordered from loosest to tightest binding, and the precedence
   declarations below are what turns that order into a parse.

   Three conflicts are left for the generator to settle, and it settles all of
   them by preferring the longer reading:

   - `x as name.other` and `x as name<other>` read the name as a type rather
     than ending the conversion, which is what those are for;
   - an `if` written where a statement can start is a statement, so a block that
     ends in one gives it as a value only when something asks the block for one.
     `Check.value_of_block` is where that happens. */

%{
open Ast

let at position = Diagnostics.of_position position

(* Top-level declarations arrive in one list and are sorted afterwards, so that
   a file may write them in any order. *)
type top =
  | Top_struct of struct_decl
  | Top_alias of alias_decl
  | Top_function of func_decl
  | Top_global of global_decl
%}

%token <string> IDENT
%token <int64> INT
%token <float> FLOAT
%token <string> STRING
%token <int> CHAR

%token MODULE IMPORT EXPORT STRUCT FUN VAR TYPE
%token RETURN IF ELSE WHILE FOR BREAK CONTINUE
%token NEW AS TRUE FALSE NULL

%token LPAREN RPAREN LBRACE RBRACE LBRACKET RBRACKET
%token SEMICOLON COMMA COLON DOT ARROW
%token ASSIGN EQUAL NOT_EQUAL LESS LESS_EQUAL GREATER GREATER_EQUAL
%token PLUS MINUS STAR SLASH PERCENT BANG TILDE AMPERSAND AND OR
%token EOF

%right ASSIGN
%left OR
%left AND
%left EQUAL NOT_EQUAL
%left LESS LESS_EQUAL GREATER GREATER_EQUAL
%left PLUS MINUS
%left STAR SLASH PERCENT
%left AS
%nonassoc UNARY
%left DOT LPAREN LBRACKET

%start <Ast.module_ast> program

%%

/* ------------------------------------------------------------------------- */
/* Declarations                                                               */
/* ------------------------------------------------------------------------- */

program:
  | MODULE name = IDENT SEMICOLON
    imports = list(import_declaration)
    declarations = list(top_declaration)
    EOF
      { let module_ast =
          {
            m_name = name;
            m_file = $symbolstartpos.Lexing.pos_fname;
            m_span = at $symbolstartpos;
            m_imports = imports;
            m_structs =
              List.filter_map
                (function Top_struct entry -> Some entry | _ -> None)
                declarations;
            m_aliases =
              List.filter_map
                (function Top_alias entry -> Some entry | _ -> None)
                declarations;
            m_functions =
              List.filter_map
                (function Top_function entry -> Some entry | _ -> None)
                declarations;
            m_globals =
              List.filter_map
                (function Top_global entry -> Some entry | _ -> None)
                declarations;
          }
        in
        (* Everything that resolves names later has to know where it lives. *)
        List.iter (fun entry -> entry.ad_owner <- Some module_ast) module_ast.m_aliases;
        List.iter (fun entry -> entry.fn_owner <- Some module_ast) module_ast.m_functions;
        List.iter (fun entry -> entry.g_owner <- Some module_ast) module_ast.m_globals;
        module_ast }

import_declaration:
  | IMPORT name = IDENT SEMICOLON
      { { im_name = name; im_span = at $symbolstartpos; im_target = None } }

top_declaration:
  | exported = boption(EXPORT) STRUCT name = IDENT
    LBRACE fields = list(struct_field) RBRACE
      { Top_struct
          {
            sd_name = name;
            sd_exported = exported;
            sd_span = at $symbolstartpos;
            sd_fields = fields;
            sd_structure = None;
            sd_type = None;
          } }
  | exported = boption(EXPORT) TYPE name = IDENT ASSIGN target = type_expr SEMICOLON
      { Top_alias
          {
            ad_name = name;
            ad_exported = exported;
            ad_span = at $symbolstartpos;
            ad_target = target;
            ad_owner = None;
            ad_resolved = None;
            ad_resolving = false;
          } }
  | exported = boption(EXPORT) FUN name = IDENT parameters = parameter_list
    ARROW result = type_expr body = function_body
      { Top_function
          {
            fn_definition =
              Ast.func_def ~span:(at $symbolstartpos) ~name ~parameters ~result ~body;
            fn_exported = exported;
            fn_owner = None;
          } }
  | exported = boption(EXPORT) VAR name = IDENT COLON declared = type_expr
    ASSIGN value = expr SEMICOLON
      { Top_global
          {
            g_id = Ast.fresh_id ();
            g_name = name;
            g_exported = exported;
            g_span = at $symbolstartpos;
            g_declared = declared;
            g_initializer = value;
            g_type = None;
            g_owner = None;
          } }

struct_field:
  | name = IDENT COLON declared = type_expr SEMICOLON
      { { sf_name = name; sf_declared = declared; sf_span = at $symbolstartpos } }

/* A body-less function is a binding to something the host provides. */
function_body:
  | body = block { Some body }
  | SEMICOLON { None }

parameter_list:
  | LPAREN parameters = separated_list(COMMA, parameter) RPAREN { parameters }

parameter:
  | name = IDENT COLON declared = type_expr
      { { p_name = name; p_declared = declared; p_span = at $symbolstartpos; p_type = None } }

/* ------------------------------------------------------------------------- */
/* Types                                                                      */
/* ------------------------------------------------------------------------- */

type_expr:
  | STAR target = type_expr
      { Ast.type_expr (at $symbolstartpos) (Te_pointer target) }
  | FUN LPAREN parameters = separated_list(COMMA, type_expr) RPAREN
    ARROW result = type_expr
      { Ast.type_expr (at $symbolstartpos) (Te_function (parameters, result)) }
  | path = qualified_name arguments = loption(type_arguments)
      { Ast.type_expr (at $symbolstartpos) (Te_named (path, arguments)) }

type_arguments:
  | LESS arguments = separated_nonempty_list(COMMA, type_expr) GREATER { arguments }

qualified_name:
  | path = separated_nonempty_list(DOT, IDENT) { path }

/* ------------------------------------------------------------------------- */
/* Statements                                                                 */
/*                                                                            */
/* A block is a run of statements, and then the expression it yields when it   */
/* stands for a value. An `if` written where a statement can start is read as  */
/* the statement form, so a block that ends in one gives its value only if     */
/* something asks it for one.                                                  */
/* ------------------------------------------------------------------------- */

block:
  | LBRACE contents = block_contents RBRACE
      { let statements, value = contents in
        Ast.block (at $symbolstartpos) statements value }

block_contents:
  | { ([], None) }
  | first = statement rest = block_contents
      { let statements, value = rest in (first :: statements, value) }
  | value = expr { ([], Some value) }

statement:
  | VAR name = IDENT COLON declared = type_expr ASSIGN value = expr SEMICOLON
      { Ast.stmt (at $symbolstartpos)
          (S_var
             {
               vd_name = name;
               vd_declared = declared;
               vd_initializer = value;
               vd_type = None;
             }) }
  | FUN name = IDENT parameters = parameter_list ARROW result = type_expr body = block
      { Ast.stmt (at $symbolstartpos)
          (S_fun
             (Ast.func_def ~span:(at $symbolstartpos) ~name ~parameters ~result
                ~body:(Some body))) }
  | RETURN value = option(expr) SEMICOLON
      { Ast.stmt (at $symbolstartpos) (S_return value) }
  | branch = conditional { Ast.stmt (at $symbolstartpos) (S_if branch) }
  | WHILE LPAREN condition = expr RPAREN body = block
      { Ast.stmt (at $symbolstartpos) (S_while (condition, body)) }
  | FOR LPAREN start = option(for_initializer) SEMICOLON
    condition = option(expr) SEMICOLON step = option(expr) RPAREN body = block
      { Ast.stmt (at $symbolstartpos)
          (S_for
             {
               fo_initializer = start;
               fo_condition = condition;
               fo_step = step;
               fo_body = body;
             }) }
  | BREAK SEMICOLON { Ast.stmt (at $symbolstartpos) S_break }
  | CONTINUE SEMICOLON { Ast.stmt (at $symbolstartpos) S_continue }
  | value = expr SEMICOLON { Ast.stmt (at $symbolstartpos) (S_expr value) }
  | body = block { Ast.stmt (at $symbolstartpos) (S_block body) }

for_initializer:
  | VAR name = IDENT COLON declared = type_expr ASSIGN value = expr
      { Ast.stmt (at $symbolstartpos)
          (S_var
             {
               vd_name = name;
               vd_declared = declared;
               vd_initializer = value;
               vd_type = None;
             }) }
  | value = expr { Ast.stmt (at $symbolstartpos) (S_expr value) }

conditional:
  | IF LPAREN condition = expr RPAREN body = block      {
        {
          if_span = at $symbolstartpos;
          if_condition = condition;
          if_then = body;
          if_else = None;
        }
      }
  | IF LPAREN condition = expr RPAREN body = block ELSE alternative = else_branch
      {
        {
          if_span = at $symbolstartpos;
          if_condition = condition;
          if_then = body;
          if_else = Some alternative;
        }
      }

else_branch:
  | branch = conditional { Else_if branch }
  | body = block { Else_block body }

/* ------------------------------------------------------------------------- */
/* Expressions                                                                */
/* ------------------------------------------------------------------------- */

expr:
  | value = INT { Ast.expr (at $symbolstartpos) (E_int value) }
  | value = FLOAT { Ast.expr (at $symbolstartpos) (E_float value) }
  | value = STRING { Ast.expr (at $symbolstartpos) (E_string value) }
  | value = CHAR { Ast.expr (at $symbolstartpos) (E_char value) }
  | TRUE { Ast.expr (at $symbolstartpos) (E_bool true) }
  | FALSE { Ast.expr (at $symbolstartpos) (E_bool false) }
  | NULL { Ast.expr (at $symbolstartpos) E_null }
  | text = IDENT { Ast.expr (at $symbolstartpos) (E_name (Ast.name text)) }
  | LPAREN inner = expr RPAREN { inner }
  | value = array_literal { value }
  | value = struct_literal { value }
  | FUN parameters = parameter_list ARROW result = type_expr body = block
      { Ast.expr (at $symbolstartpos)
          (E_fun
             (Ast.func_def ~span:(at $symbolstartpos) ~name:"" ~parameters ~result
                ~body:(Some body))) }
  | branch = conditional { Ast.expr (at $symbolstartpos) (E_if branch) }
  | callee = expr LPAREN arguments = separated_list(COMMA, expr) RPAREN
      { Ast.expr (at $symbolstartpos) (E_call (callee, arguments)) }
  | subject = expr LBRACKET index = expr RBRACKET
      { Ast.expr (at $symbolstartpos) (E_index (subject, index)) }
  | subject = expr DOT field = IDENT
      { Ast.expr (at $symbolstartpos) (E_field (Ast.field_access subject field)) }
  | op = unary_operator operand = expr %prec UNARY
      { Ast.expr (at $symbolstartpos) (E_unary (op, operand)) }
  | operand = expr AS target = type_expr
      { Ast.expr (at $symbolstartpos) (E_cast (operand, target)) }
  | left = expr op = binary_operator right = expr
      { Ast.expr (at $symbolstartpos) (E_binary (Ast.binary op left right)) }
  | target = expr ASSIGN value = expr
      { Ast.expr (at $symbolstartpos) (E_assign (target, value)) }

%inline unary_operator:
  | PLUS { Plus }
  | MINUS { Minus }
  | BANG { Not }
  | TILDE { Complement }
  | STAR { Dereference }
  | AMPERSAND { Address_of }

%inline binary_operator:
  | STAR { Multiply }
  | SLASH { Divide }
  | PERCENT { Remainder }
  | PLUS { Add }
  | MINUS { Subtract }
  | LESS { Less }
  | LESS_EQUAL { Less_equal }
  | GREATER { Greater }
  | GREATER_EQUAL { Greater_equal }
  | EQUAL { Equal }
  | NOT_EQUAL { Not_equal }
  | AND { And }
  | OR { Or }

/* Either the elements one by one, or a single element repeated a given number
   of times. */
array_literal:
  | LBRACKET RBRACKET
      { Ast.expr (at $symbolstartpos) (E_array { ar_elements = []; ar_count = None }) }
  | LBRACKET value = expr SEMICOLON count = expr RBRACKET
      { Ast.expr (at $symbolstartpos)
          (E_array { ar_elements = [ value ]; ar_count = Some count }) }
  | LBRACKET elements = separated_nonempty_list(COMMA, expr) RBRACKET
      { Ast.expr (at $symbolstartpos) (E_array { ar_elements = elements; ar_count = None }) }

struct_literal:
  | NEW path = qualified_name LBRACE fields = separated_list(COMMA, field_initializer) RBRACE
      { Ast.expr (at $symbolstartpos)
          (E_struct { sl_path = path; sl_fields = fields; sl_structure = None }) }

field_initializer:
  | name = IDENT COLON value = expr
      { { fi_name = name; fi_value = value; fi_span = at $symbolstartpos; fi_index = -1 } }
