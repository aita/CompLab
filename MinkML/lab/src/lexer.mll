{
open Parser

let keywords =
  [ ("val", VAL); ("fun", FUN); ("fn", FN);
    ("let", LET); ("in", IN); ("end", END);
    ("if", IF); ("then", THEN); ("else", ELSE);
    ("case", CASE); ("of", OF); ("type", TYPE);
    ("andalso", ANDALSO); ("orelse", ORELSE);
    ("div", DIV); ("mod", MOD);
    ("forall", FORALL); ("select", SELECT); ("branch", BRANCH);
    ("true", TRUE); ("false", FALSE) ]

let ident_or_keyword s =
  match List.assoc_opt s keywords with Some t -> t | None -> IDENT s

let here lexbuf = Loc.of_lexing (Lexing.lexeme_start_p lexbuf)

let error lexbuf fmt = Loc.syntax_error (here lexbuf) fmt
}

let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z' '_']
let ident = alpha (alpha | digit | '\'')*

rule token = parse
  | [' ' '\t' '\r']+      { token lexbuf }
  | '\n'                  { Lexing.new_line lexbuf; token lexbuf }
  | "(*"                  { comment 1 lexbuf }
  (* Which type system to check the file with.  It has to be a directive
     rather than a comment: choosing the system is part of what a program
     says. *)
  | "#system" [' ' '\t']+ (ident as s) { SYSTEM s }
  | digit+ as s           { INT (int_of_string s) }
  (* 'a is a type variable and x' is an identifier; the quote decides which by
     where it stands. *)
  | '\'' ident as s       { IDENT s }
  | '`' (ident as s)      { TICK s }
  | ident as s            { ident_or_keyword s }
  | "=>"                  { DARROW }
  | "->"                  { ARROW }
  | "-o"                  { LOLLI }
  | "==>"                 { IMPLIES }
  | "=="                  { EQEQ }
  | "<>"                  { NEQ }
  | "<="                  { LE }
  | ">="                  { GE }
  | "+{"                  { PLUSBRACE }
  | "&{"                  { AMPBRACE }
  | ".."                  { DOTDOT }
  | '='                   { EQ }
  | '<'                   { LT }
  | '>'                   { GT }
  | '+'                   { PLUS }
  | '-'                   { MINUS }
  | '*'                   { STAR }
  | '!'                   { BANG }
  | '?'                   { QUERY }
  | '.'                   { DOT }
  | ','                   { COMMA }
  | ':'                   { COLON }
  | ';'                   { SEMI }
  | '|'                   { PIPE }
  | '\\'                  { BACKSLASH }
  | '('                   { LPAREN }
  | ')'                   { RPAREN }
  | '{'                   { LBRACE }
  | '}'                   { RBRACE }
  | '['                   { LBRACKET }
  | ']'                   { RBRACKET }
  | eof                   { EOF }
  | _ as c                { error lexbuf "unexpected character %C" c }

(* Comments nest, so a commented-out block that contains a comment still ends
   where it looks like it ends. *)
and comment depth = parse
  | "*)"                  { if depth = 1 then token lexbuf else comment (depth - 1) lexbuf }
  | "(*"                  { comment (depth + 1) lexbuf }
  | '\n'                  { Lexing.new_line lexbuf; comment depth lexbuf }
  | eof                   { error lexbuf "unterminated comment" }
  | _                     { comment depth lexbuf }
