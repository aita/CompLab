(* Prolog tokens.

   Two details make this more than a word splitter.

   The first is that `f(` and `f (` are different: only the first is functor
   notation, and the second applies whatever operator `f` is to a
   parenthesised term.  The difference is a space, so the lexer remembers
   where the previous token ended and reports a `(` that starts exactly there
   as [OPEN_CT].

   The second is the clause terminator.  A `.` ends a clause when what follows
   is layout, a comment or the end of the file, and is an ordinary symbolic
   atom otherwise -- `1.5` and `X = '.'` and `a. ` all have to come out
   right. *)

{
open Tok

let buf = Buffer.create 64

(* Where the previous token ended, for the OPEN_CT rule above. *)
let last_end = ref (-1)

let syntax lexbuf msg = raise (Syntax_error (Lexing.lexeme_start_p lexbuf, msg))

(* Give back the character just matched, so that another rule can have it.
   Only ever one character, and never one that has moved pos_bol. *)
let rewind1 lexbuf =
  let open Lexing in
  lexbuf.lex_curr_pos <- lexbuf.lex_curr_pos - 1;
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_cnum = lexbuf.lex_curr_p.pos_cnum - 1 }

(* Codes below 256 are bytes; above that, UTF-8.  Atoms are byte strings
   throughout Badger, so this is where the two conventions meet. *)
let add_code b n =
  if n < 0 then () (* an escaped newline: a line continuation, contributing nothing *)
  else if n < 256 then Buffer.add_char b (Char.chr n)
  else Buffer.add_utf_8_uchar b (Uchar.of_int n)
}

let digit = ['0'-'9']
let lower = ['a'-'z']
let upper = ['A'-'Z' '_']
let alnum = ['a'-'z' 'A'-'Z' '0'-'9' '_']
let symbol = ['+' '-' '*' '/' '\\' '^' '<' '>' '=' '~' ':' '.' '?' '@' '#' '&' '$']
let layout = [' ' '\t' '\r' '\011' '\012']
let hex = ['0'-'9' 'a'-'f' 'A'-'F']
let octal = ['0'-'7']

(* Everything the reader cares about happens after the layout is gone, so
   dropping it is a separate pass; that way the position reported for a token
   is the token's own. *)
rule skip = parse
  | layout+ { skip lexbuf }
  | '\n' { Lexing.new_line lexbuf; skip lexbuf }
  | '%' [^ '\n']* { skip lexbuf }
  | "/*" { comment lexbuf; skip lexbuf }
  | "" { () }

and comment = parse
  | "*/" { () }
  | '\n' { Lexing.new_line lexbuf; comment lexbuf }
  | eof { syntax lexbuf "unterminated /* comment" }
  | _ { comment lexbuf }

and token = parse
  | (digit+ '.' digit+ (['e' 'E'] ['+' '-']? digit+)?) as s { FLOAT (float_of_string s) }
  | (digit+ ['e' 'E'] ['+' '-']? digit+) as s { FLOAT (float_of_string s) }
  | ("0x" hex+ | "0o" octal+ | "0b" ['0'-'1']+) as s { INT (int_of_string s) }
  | "0'" { INT (char_code lexbuf) }
  | digit+ as s
      { match int_of_string_opt s with
        | Some n -> INT n
        | None -> syntax lexbuf "integer too large" }

  | lower alnum* as s { ATOM s }
  | upper alnum* as s { VAR s }

  | '\'' { Buffer.clear buf; QUOTED (quoted '\'' lexbuf) }
  | '"' { Buffer.clear buf; STRING (quoted '"' lexbuf) }
  | '`' { Buffer.clear buf; BACKQUOTE (quoted '`' lexbuf) }

  | '(' { if Lexing.lexeme_start lexbuf = !last_end then OPEN_CT else PUNCT "(" }
  | [')' '[' ']' '{' '}' ',' '|'] as c { PUNCT (String.make 1 c) }
  | ['!' ';'] as c { ATOM (String.make 1 c) }

  | symbol+ as s { if String.equal s "." then dot_or_end lexbuf else ATOM s }

  | eof { EOF }
  | _ as c { syntax lexbuf (Printf.sprintf "unexpected character %C" c) }

(* Called with the '.' already consumed. *)
and dot_or_end = parse
  | (layout | '\n' | '%') { rewind1 lexbuf; END }
  | eof { END }
  | "" { ATOM "." }

(* The three quoted forms differ only in which character closes them, so one
   rule takes that character as an argument.  A doubled quote is a literal
   one; a doubled *other* quote is just two characters. *)
and quoted q = parse
  | "''" { Buffer.add_string buf (if q = '\'' then "'" else "''"); quoted q lexbuf }
  | "\"\"" { Buffer.add_string buf (if q = '"' then "\"" else "\"\""); quoted q lexbuf }
  | "``" { Buffer.add_string buf (if q = '`' then "`" else "``"); quoted q lexbuf }
  | ['\'' '"' '`'] as c
      { if c = q then Buffer.contents buf
        else begin Buffer.add_char buf c; quoted q lexbuf end }
  | '\\' { add_code buf (escape lexbuf); quoted q lexbuf }
  | '\n' { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; quoted q lexbuf }
  | [^ '\'' '"' '`' '\\' '\n']+ as s { Buffer.add_string buf s; quoted q lexbuf }
  | eof { syntax lexbuf "unterminated quoted token" }

(* Called with the backslash already consumed; -1 means "no character", which
   is what a backslash before a newline contributes. *)
and escape = parse
  | 'n' { 10 }
  | 't' { 9 }
  | 'r' { 13 }
  | 'b' { 8 }
  | 'f' { 12 }
  | 'v' { 11 }
  | 'a' { 7 }
  | 'e' { 27 }
  | 's' { 32 }
  | '\\' { 92 }
  | '\'' { 39 }
  | '"' { 34 }
  | '`' { 96 }
  | 'x' (hex+ as h) '\\'? { int_of_string ("0x" ^ h) }
  | (octal+ as o) '\\'? { int_of_string ("0o" ^ o) }
  | '\n' { Lexing.new_line lexbuf; -1 }
  | _ as c { syntax lexbuf (Printf.sprintf "unknown escape sequence \\%c" c) }
  | eof { syntax lexbuf "unterminated escape sequence" }

(* Called with the 0' already consumed. *)
and char_code = parse
  | "''" { 39 }
  | '\'' { 39 }
  | '\\' { let n = escape lexbuf in if n < 0 then syntax lexbuf "0' needs a character" else n }
  | _ as c { Char.code c }
  | eof { syntax lexbuf "0' needs a character" }

{
(* The reader takes tokens from here, never from [token] directly, so that
   [last_end] stays in step. *)
let next lexbuf =
  skip lexbuf;
  let start = lexbuf.Lexing.lex_curr_p in
  let tok = token lexbuf in
  last_end := Lexing.lexeme_end lexbuf;
  { Tok.tok; start; stop = lexbuf.Lexing.lex_curr_p }

let reset () = last_end := -1
}
