{
(* The lexer resolves two things the grammar leaves to the implementation.

   Qualified names.  "qualified-value = module-path '.' lower-ident" and
   "postfix-expression = primary { '.' lower-ident }" both read as a dot
   between two names, so M.x is ambiguous between a value in a module and a
   field of a record.  Here a run of upper-case names joined by dots, with no
   space anywhere in it, is one token, and everything else is a projection.
   M.r.x is therefore the field x of the record M.r, which is what the longest
   match gives: '.r' extends the run only if r is upper case.

   Operators.  "char-content" and "string-char" are the two productions the
   grammar declares implementation-defined; the escapes are below.  Every
   maximal run of operator-chars is one token, and the six runs that the rest
   of the grammar uses as punctuation -- = | : -> => -- are handed back as
   themselves rather than as operators, so they cannot be redefined.  '*' and
   '-' and '::' get their own tokens because they are punctuation in types and
   patterns as well as operators in expressions. *)

open Parser

let error lexbuf fmt =
  Diag.at (Lexing.lexeme_start_p lexbuf) fmt

let keywords = [
  "val", VAL;
  "fun", FUN;
  "type", TYPE;
  "infixl", INFIXL;
  "infixr", INFIXR;
  "infix", INFIX;
  "sig", SIG;
  "end", END;
  "mod", MOD;
  "include", INCLUDE;
  "where", WHERE;
  "import", IMPORT;
  "as", AS;
  "fn", FN;
  "let", LET;
  "in", IN;
  "begin", BEGIN;
  "if", IF;
  "then", THEN;
  "else", ELSE;
  "case", CASE;
  "of", OF;
  "and", AND;
  "or", OR;
  "not", NOT;
  "true", TRUE;
  "false", FALSE;
]

(* Every identifier the lexer reads asks this, so it is a table and not a
   scan of the list above. *)
let keyword_table =
  let h = Hashtbl.create 64 in
  List.iter (fun (k, t) -> Hashtbl.add h k t) keywords;
  h

let word s = match Hashtbl.find_opt keyword_table s with Some t -> t | None -> LIDENT s

(* = | : -> => are punctuation; * - :: are punctuation and operators both. *)
let symbol lexbuf s =
  match s with
  | "=" -> EQ
  | "|" -> BAR
  | ":" -> COLON
  | "->" -> ARROW
  | "=>" -> DARROW
  | "*" -> STAR
  | "-" -> MINUS
  | "::" -> CONS
  | "" -> error lexbuf "empty operator"
  | s -> OP s

(* A.B.c is (["A"; "B"], "c").  The last component decides which token it is. *)
let qualified lexbuf s =
  match List.rev (String.split_on_char '.' s) with
  | [] | [ _ ] -> error lexbuf "malformed qualified name %s" s
  | last :: rev_path ->
    let path = List.rev rev_path in
    if last.[0] >= 'A' && last.[0] <= 'Z' then QUIDENT (path, last)
    else QLIDENT (path, last)

let escape lexbuf = function
  | 'n' -> '\n'
  | 't' -> '\t'
  | 'r' -> '\r'
  | '0' -> '\000'
  | '\\' -> '\\'
  | '"' -> '"'
  | '\'' -> '\''
  | c -> error lexbuf "unknown escape \\%c" c
}

let lower = ['a'-'z']
let upper = ['A'-'Z']
let letter = lower | upper
let digit = ['0'-'9']
let idrest = (letter | digit | '_' | '\'')*
let lower_id = lower idrest
let upper_id = upper idrest
let opchar = ['!' '$' '%' '&' '*' '+' '-' '/' ':' '<' '=' '>' '?' '@' '\\' '^' '|' '~']
let white = [' ' '\t' '\r']+

rule token = parse
  | white                 { token lexbuf }
  | '\n'                  { Lexing.new_line lexbuf; token lexbuf }
  | "(*"                  { comment 1 lexbuf; token lexbuf }
  | digit+ '.' digit+ as s { REAL (float_of_string s) }
  | digit+ as s           { INT (int_of_string s) }
  | upper_id ('.' upper_id)* '.' (lower_id | upper_id) as s { qualified lexbuf s }
  | lower_id as s         { word s }
  | upper_id as s         { UIDENT s }
  | '\'' ([^ '\'' '\\' '\n'] as c) '\'' { CHAR c }
  | '\'' '\\' (_ as c) '\''             { CHAR (escape lexbuf c) }
  | '\'' (lower_id as s)  { TYVAR s }
  | '"'                   { STRING (string_body (Buffer.create 16) lexbuf) }
  | '('                   { LPAREN }
  | ')'                   { RPAREN }
  | '['                   { LBRACK }
  | ']'                   { RBRACK }
  | '{'                   { LBRACE }
  | '}'                   { RBRACE }
  | ','                   { COMMA }
  | ';'                   { SEMI }
  | '.'                   { DOT }
  | '_'                   { UNDERSCORE }
  | opchar+ as s          { symbol lexbuf s }
  | eof                   { EOF }
  | _ as c                { error lexbuf "unexpected character %C" c }

(* Comments nest, as the grammar file itself does not need but ML expects. *)
and comment depth = parse
  | "(*"   { comment (depth + 1) lexbuf }
  | "*)"   { if depth > 1 then comment (depth - 1) lexbuf }
  | '\n'   { Lexing.new_line lexbuf; comment depth lexbuf }
  | eof    { error lexbuf "unterminated comment" }
  | _      { comment depth lexbuf }

and string_body buf = parse
  | '"'            { Buffer.contents buf }
  | '\\' (_ as c)  { Buffer.add_char buf (escape lexbuf c); string_body buf lexbuf }
  | '\n'           { error lexbuf "newline in a string literal" }
  | eof            { error lexbuf "unterminated string literal" }
  | _ as c         { Buffer.add_char buf c; string_body buf lexbuf }
