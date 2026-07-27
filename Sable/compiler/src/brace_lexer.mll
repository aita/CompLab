{
open Brace_parser

exception Error of string

let keywords = Hashtbl.create 32

let () =
  List.iter
    (fun (k, v) -> Hashtbl.add keywords k v)
    [
      ("val", VAL);
      ("fun", FUN);
      ("if", IF);
      ("else", ELSE);
      ("when", WHEN);
      ("is", IS);
      ("object", OBJECT);
      ("interface", INTERFACE);
      ("sealed", SEALED);
      ("class", CLASS);
      ("import", IMPORT);
      ("true", BOOL true);
      ("false", BOOL false);
      ("Array", ARRAY);
      ("listOf", LIST_OF);
      ("Nil", NIL);
      ("Cons", CONS);
    ]

let string_buffer = Buffer.create 64

let error lexbuf fmt =
  Printf.ksprintf
    (fun msg ->
      let p = Lexing.lexeme_start_p lexbuf in
      raise
        (Error
           (Printf.sprintf "%s:%d:%d: %s" p.pos_fname p.pos_lnum
              (p.pos_cnum - p.pos_bol) msg)))
    fmt
}

let space = [' ' '\t' '\r']
let digit = ['0'-'9']
let lower = ['a'-'z' '_']
let upper = ['A'-'Z']
let alnum = ['a'-'z' 'A'-'Z' '0'-'9' '_']

rule token = parse
  | space+ { token lexbuf }
  | '\n' { Lexing.new_line lexbuf; token lexbuf }
  | "//" [^ '\n']* { token lexbuf }
  | "/*" { comment 1 lexbuf; token lexbuf }
  | digit+ as n
      { match int_of_string_opt n with
        | Some v -> INT v
        | None -> error lexbuf "integer literal %s is out of range" n }
  | '"' { Buffer.clear string_buffer; string_literal lexbuf }
  | "->" { ARROW }
  | "==" { EQUAL_EQUAL }
  | "!=" { BANG_EQUAL }
  | "<=" { LESS_EQUAL }
  | ">=" { GREATER_EQUAL }
  | "&&" { AMPAMP }
  | "||" { BARBAR }
  | '<' { LESS }
  | '>' { GREATER }
  | '=' { EQUAL }
  | '!' { BANG }
  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { STAR }
  | '/' { SLASH }
  | '%' { PERCENT }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | '{' { LBRACE }
  | '}' { RBRACE }
  | '[' { LBRACKET }
  | ']' { RBRACKET }
  | ',' { COMMA }
  | ';' { SEMI }
  | ':' { COLON }
  | '.' { DOT }
  | (upper alnum*) as name
      { match Hashtbl.find_opt keywords name with
        | Some tok -> tok
        | None -> UIDENT name }
  | (lower alnum*) as name
      { match Hashtbl.find_opt keywords name with
        | Some tok -> tok
        | None -> if name = "_" then UNDERSCORE else IDENT name }
  | eof { EOF }
  | _ as c { error lexbuf "unexpected character %C" c }

and string_literal = parse
  | '"' { STRING (Buffer.contents string_buffer) }
  | "\\n" { Buffer.add_char string_buffer '\n'; string_literal lexbuf }
  | "\\t" { Buffer.add_char string_buffer '\t'; string_literal lexbuf }
  | "\\r" { Buffer.add_char string_buffer '\r'; string_literal lexbuf }
  | "\\\\" { Buffer.add_char string_buffer '\\'; string_literal lexbuf }
  | "\\\"" { Buffer.add_char string_buffer '"'; string_literal lexbuf }
  | '\\' _ as bad { error lexbuf "unknown escape %s in a string" bad }
  | '\n' { error lexbuf "a string literal may not span lines" }
  | eof { error lexbuf "unterminated string literal" }
  | _ as c { Buffer.add_char string_buffer c; string_literal lexbuf }

(* Block comments nest. *)
and comment depth = parse
  | "*/" { if depth > 1 then comment (depth - 1) lexbuf }
  | "/*" { comment (depth + 1) lexbuf }
  | '\n' { Lexing.new_line lexbuf; comment depth lexbuf }
  | eof { error lexbuf "unterminated comment" }
  | _ { comment depth lexbuf }
