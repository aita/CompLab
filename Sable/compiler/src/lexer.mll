{
open Parser

exception Error of string

let keywords = Hashtbl.create 32

let () =
  List.iter
    (fun (k, v) -> Hashtbl.add keywords k v)
    [
      ("let", LET);
      ("in", IN);
      ("rec", REC);
      ("and", AND);
      ("if", IF);
      ("then", THEN);
      ("else", ELSE);
      ("fun", FUN);
      ("not", NOT);
      ("mod", PERCENT);
      ("type", TYPE);
      ("of", OF);
      ("match", MATCH);
      ("with", WITH);
      ("array", ARRAY_KW);
      ("begin", BEGIN);
      ("end", END);
      ("module", MODULE);
      ("struct", STRUCT);
      ("open", OPEN);
      ("true", BOOL true);
      ("false", BOOL false);
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
let alnum = ['a'-'z' 'A'-'Z' '0'-'9' '_' '\'']

rule token = parse
  | space+ { token lexbuf }
  | '\n' { Lexing.new_line lexbuf; token lexbuf }
  | "(*" { comment 1 lexbuf; token lexbuf }
  | digit+ as n
      { match int_of_string_opt n with
        | Some v -> INT v
        | None -> error lexbuf "integer literal %s is out of range" n }
  | "Array.make" | "Array.create" { ARRAY_MAKE }
  | "String.length" { STRING_LENGTH }
  (* The rest of the String module is provided by the runtime, so the source
     spelling just maps onto the name the runtime exports. *)
  | "String.concat" { IDENT "string_concat" }
  | "String.equal" { IDENT "string_equal" }
  | '^' { CARET }
  | '"' { Buffer.clear string_buffer; string_literal lexbuf }
  | "::" { COLONCOLON }
  | '[' { LBRACKET }
  | ']' { RBRACKET }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | ',' { COMMA }
  | ';' { SEMICOLON }
  | '.' { DOT }
  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { AST }
  | '/' { SLASH }
  | "->" { ARROW }
  | "<-" { LESS_MINUS }
  | "<>" { LESS_GREATER }
  | "<=" { LESS_EQUAL }
  | ">=" { GREATER_EQUAL }
  | '<' { LESS }
  | '>' { GREATER }
  | '=' { EQUAL }
  | "&&" { AMPAMP }
  | "||" { BARBAR }
  | '|' { BAR }
  | (upper alnum*) as name { UIDENT name }
  | (lower alnum*) as name
      { if name = "_" then UNDERSCORE
        else
          match Hashtbl.find_opt keywords name with
          | Some tok -> tok
          | None -> IDENT name }
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

(* Comments nest, as in OCaml. *)
and comment depth = parse
  | "*)" { if depth > 1 then comment (depth - 1) lexbuf }
  | "(*" { comment (depth + 1) lexbuf }
  | '\n' { Lexing.new_line lexbuf; comment depth lexbuf }
  | eof { error lexbuf "unterminated comment" }
  | _ { comment depth lexbuf }
