{
open Parser

exception Lex_error of string

let error fmt = Printf.ksprintf (fun msg -> raise (Lex_error msg)) fmt

let keywords = [
  "fun", FUN;
  "fn", FN;
  "class", CLASS;
  "let", LET;
  "if", IF;
  "else", ELSE;
  "while", WHILE;
  "for", FOR;
  "in", IN;
  "return", RETURN;
  "break", BREAK;
  "continue", CONTINUE;
  "true", TRUE;
  "false", FALSE;
  "nil", NIL;
  "super", SUPER;
]

let ident_or_keyword s =
  match List.assoc_opt s keywords with Some t -> t | None -> IDENT s
}

let white = [' ' '\t' '\r']+
let digit = ['0'-'9']
let alpha = ['a'-'z' 'A'-'Z' '_']
let ident = alpha (alpha | digit)*
let exponent = ['e' 'E'] ['+' '-']? digit+

rule token = parse
  | white          { token lexbuf }
  | '\n'           { Lexing.new_line lexbuf; token lexbuf }
  | "//"           { line_comment lexbuf }
  | "/*"           { block_comment 1 lexbuf }
  | digit+ '.' digit+ exponent? as s { FLOAT (float_of_string s) }
  | digit+ exponent as s             { FLOAT (float_of_string s) }
  | digit+ as s    { INT (int_of_string s) }
  | ident as s     { ident_or_keyword s }
  | '"'            { STRING (string_body (Buffer.create 16) lexbuf) }
  | "=="           { EQEQ }
  | "!="           { BANGEQ }
  | "<="           { LE }
  | ">="           { GE }
  | "&&"           { ANDAND }
  | "||"           { OROR }
  | '<'            { LT }
  | '>'            { GT }
  | '='            { ASSIGN }
  | '!'            { BANG }
  | '+'            { PLUS }
  | '-'            { MINUS }
  | '*'            { TIMES }
  | '/'            { DIV }
  | '%'            { MOD }
  | '('            { LPAREN }
  | ')'            { RPAREN }
  | '{'            { LBRACE }
  | '}'            { RBRACE }
  | '['            { LBRACKET }
  | ']'            { RBRACKET }
  | ','            { COMMA }
  | ';'            { SEMI }
  | '.'            { DOT }
  | ':'            { COLON }
  | eof            { EOF }
  | _ as c         { error "unexpected character %C" c }

and line_comment = parse
  | '\n'           { Lexing.new_line lexbuf; token lexbuf }
  | eof            { EOF }
  | _              { line_comment lexbuf }

and block_comment depth = parse
  | "*/"           { if depth = 1 then token lexbuf else block_comment (depth - 1) lexbuf }
  | "/*"           { block_comment (depth + 1) lexbuf }
  | '\n'           { Lexing.new_line lexbuf; block_comment depth lexbuf }
  | eof            { error "unterminated comment" }
  | _              { block_comment depth lexbuf }

and string_body buf = parse
  | '"'            { Buffer.contents buf }
  | "\\n"          { Buffer.add_char buf '\n'; string_body buf lexbuf }
  | "\\t"          { Buffer.add_char buf '\t'; string_body buf lexbuf }
  | "\\r"          { Buffer.add_char buf '\r'; string_body buf lexbuf }
  | "\\0"          { Buffer.add_char buf '\000'; string_body buf lexbuf }
  | "\\\\"         { Buffer.add_char buf '\\'; string_body buf lexbuf }
  | "\\\""         { Buffer.add_char buf '"'; string_body buf lexbuf }
  | '\\' (_ as c)  { error "unknown escape sequence \\%c" c }
  | '\n'           { error "unterminated string literal" }
  | eof            { error "unterminated string literal" }
  | _ as c         { Buffer.add_char buf c; string_body buf lexbuf }
