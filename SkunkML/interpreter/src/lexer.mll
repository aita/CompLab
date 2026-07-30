{
(* The scanner.  Standard ML's lexical conventions, with two of them doing
   real work for the parser:

     * A qualified name is *one* token.  `List.map` is not `List`, `.`, `map`:
       the dot never appears in the grammar, so nothing has to disambiguate a
       path from a record selection -- and there is no record selection to
       confuse it with, because SML spells that `#x r`.
     * `#x` is one token too, for the same reason. *)

open Parser

let keywords =
  [ ("val", VAL); ("fun", FUN); ("fn", FN);
    ("let", LET); ("in", IN); ("end", END);
    ("if", IF); ("then", THEN); ("else", ELSE);
    ("case", CASE); ("of", OF); ("as", AS);
    ("datatype", DATATYPE); ("type", TYPE); ("and", AND);
    ("andalso", ANDALSO); ("orelse", ORELSE);
    ("div", DIV); ("mod", MOD); ("open", OPEN);
    ("structure", STRUCTURE); ("signature", SIGNATURE); ("functor", FUNCTOR);
    ("struct", STRUCT); ("sig", SIG); ("where", WHERE); ("include", INCLUDE) ]

let word s = match List.assoc_opt s keywords with Some t -> t | None -> LID s

let here lexbuf = Loc.of_lexing (Lexing.lexeme_start_p lexbuf)
let error lexbuf fmt = Loc.syntax_error (here lexbuf) fmt

(* `A.B.name` -> (["A"; "B"], "name").  The lexer knows the qualifiers are
   capitalised because that is the only way it matched them. *)
let split_path s =
  match List.rev (String.split_on_char '.' s) with
  | base :: rev_quals -> (List.rev rev_quals, base)
  | [] -> assert false

let buf = Buffer.create 64
}

let digit = ['0'-'9']
let lower = ['a'-'z' '_']
let upper = ['A'-'Z']
let idchar = ['A'-'Z' 'a'-'z' '0'-'9' '_' '\'']
let lid = lower idchar*
let uid = upper idchar*
let qual = (upper idchar* '.')+

rule token = parse
  | [' ' '\t' '\r']+      { token lexbuf }
  | '\n'                  { Lexing.new_line lexbuf; token lexbuf }
  | "(*"                  { comment 1 lexbuf }
  | digit+ as s           { INT (int_of_string s) }
  (* `'a` is a type variable; `x'` is an identifier.  The quote decides which
     by where it stands, as in SML. *)
  | '\'' (idchar+ as s)   { TYVAR ("'" ^ s) }
  | qual (lid | uid) as s { let q, b = split_path s in QID (q, b) }
  | '#' (lid as s)        { SELECT s }
  | '#' (digit+ as s)     { SELECT s }
  | "_"                   { UNDERSCORE }
  | lid as s              { word s }
  | uid as s              { UID s }
  | '"'                   { Buffer.clear buf; string lexbuf }
  | "=>"                  { DARROW }
  | "->"                  { ARROW }
  | "::"                  { CONS }
  | ":>"                  { COLONGT }
  | "<>"                  { NE }
  | "<="                  { LE }
  | ">="                  { GE }
  | "..."                 { DOTS }
  | ':'                   { COLON }
  | '='                   { EQ }
  | '<'                   { LT }
  | '>'                   { GT }
  | '+'                   { PLUS }
  | '-'                   { MINUS }
  | '*'                   { STAR }
  | '^'                   { CARET }
  | '@'                   { AT }
  | '~'                   { TILDE }
  | '|'                   { BAR }
  | ','                   { COMMA }
  | ';'                   { SEMI }
  | '('                   { LPAREN }
  | ')'                   { RPAREN }
  | '['                   { LBRACK }
  | ']'                   { RBRACK }
  | '{'                   { LBRACE }
  | '}'                   { RBRACE }
  | eof                   { EOF }
  | _ as c                { error lexbuf "unexpected character %C" c }

(* Comments nest, so commenting out a block that already contains a comment
   ends where it looks like it ends. *)
and comment depth = parse
  | "*)"    { if depth = 1 then token lexbuf else comment (depth - 1) lexbuf }
  | "(*"    { comment (depth + 1) lexbuf }
  | '\n'    { Lexing.new_line lexbuf; comment depth lexbuf }
  | eof     { error lexbuf "unterminated comment" }
  | _       { comment depth lexbuf }

(* Four escapes and no more; a string cannot cross a newline. *)
and string = parse
  | '"'           { STRING (Buffer.contents buf) }
  | "\\n"         { Buffer.add_char buf '\n'; string lexbuf }
  | "\\t"         { Buffer.add_char buf '\t'; string lexbuf }
  | "\\\\"        { Buffer.add_char buf '\\'; string lexbuf }
  | "\\\""        { Buffer.add_char buf '"'; string lexbuf }
  | "\\" (_ as c) { error lexbuf "unknown escape \\%c" c }
  | '\n'          { error lexbuf "a string cannot cross a line" }
  | eof           { error lexbuf "unterminated string" }
  | _ as c        { Buffer.add_char buf c; string lexbuf }
