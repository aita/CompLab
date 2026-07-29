(* The tokens.

   Type names are deliberately absent from the keywords: `int`, `string` and the
   rest are plain identifiers that the initial type environment happens to
   bind. *)

{
open Parser

exception Error of Diagnostics.span * string

let fail position format =
  Printf.ksprintf
    (fun message -> raise (Error (Diagnostics.of_position position, message)))
    format

let here lexbuf = Lexing.lexeme_start_p lexbuf

let keywords =
  [
    ("module", MODULE);
    ("import", IMPORT);
    ("export", EXPORT);
    ("struct", STRUCT);
    ("fun", FUN);
    ("var", VAR);
    ("type", TYPE);
    ("return", RETURN);
    ("if", IF);
    ("else", ELSE);
    ("while", WHILE);
    ("for", FOR);
    ("break", BREAK);
    ("continue", CONTINUE);
    ("new", NEW);
    ("as", AS);
    ("true", TRUE);
    ("false", FALSE);
    ("null", NULL);
  ]

let identifier text =
  match List.assoc_opt text keywords with Some token -> token | None -> IDENT text

let value_of_digit character =
  match character with
  | '0' .. '9' -> Char.code character - Char.code '0'
  | 'a' .. 'f' -> Char.code character - Char.code 'a' + 10
  | _ -> Char.code character - Char.code 'A' + 10

(* Underscores are separators, and a literal too large to be an int is rejected
   here rather than wrapping quietly. *)
let whole_number position base digits =
  let base64 = Int64.of_int base in
  let limit = Int64.div Int64.max_int base64 in
  let value = ref 0L in
  String.iter
    (fun character ->
      if character <> '_' then begin
        let digit = Int64.of_int (value_of_digit character) in
        if Int64.compare !value limit > 0 then
          fail position "`%s` does not fit in an int" digits;
        let scaled = Int64.mul !value base64 in
        if Int64.compare (Int64.sub Int64.max_int scaled) digit < 0 then
          fail position "`%s` does not fit in an int" digits;
        value := Int64.add scaled digit
      end)
    digits;
  !value

let without_underscores text =
  String.concat "" (String.split_on_char '_' text)

(* The utf-8 of one code point. *)
let add_code_point buffer code =
  let byte value = Buffer.add_char buffer (Char.chr (value land 0xFF)) in
  if code < 0x80 then byte code
  else if code < 0x800 then begin
    byte (0xC0 lor (code lsr 6));
    byte (0x80 lor (code land 0x3F))
  end
  else if code < 0x10000 then begin
    byte (0xE0 lor (code lsr 12));
    byte (0x80 lor ((code lsr 6) land 0x3F));
    byte (0x80 lor (code land 0x3F))
  end
  else begin
    byte (0xF0 lor (code lsr 18));
    byte (0x80 lor ((code lsr 12) land 0x3F));
    byte (0x80 lor ((code lsr 6) land 0x3F));
    byte (0x80 lor (code land 0x3F))
  end

(* Reads one code point starting at [index], and says where the next one
   begins. *)
let code_point_at text index =
  let byte index = Char.code text.[index] in
  let first = byte index in
  if first < 0x80 then (first, index + 1)
  else begin
    let extra = if first lsr 5 = 0b110 then 1 else if first lsr 4 = 0b1110 then 2 else 3 in
    let code = ref (first land (0x3F lsr extra)) in
    let next = ref (index + 1) in
    for _ = 1 to extra do
      if !next < String.length text then begin
        code := (!code lsl 6) lor (byte !next land 0x3F);
        incr next
      end
    done;
    (!code, !next)
  end

let one_code_point position text =
  if text = "" then fail position "a char literal needs a character";
  let code, next = code_point_at text 0 in
  if next <> String.length text then
    fail position "a char literal holds one character, not several";
  code
}

let digit = ['0'-'9']
let hex = ['0'-'9' 'a'-'f' 'A'-'F']
let binary = ['0'-'1']
let letter = ['a'-'z' 'A'-'Z' '_']
let exponent = ['e' 'E'] ['+' '-']? digit+

rule token = parse
  | [' ' '\t' '\r']+ { token lexbuf }
  | '\n' { Lexing.new_line lexbuf; token lexbuf }
  | "//" [^ '\n']* { token lexbuf }
  | "/*" { comment (here lexbuf) lexbuf; token lexbuf }

  | '"'
      { let start = lexbuf.Lexing.lex_start_p in
        let buffer = Buffer.create 16 in
        quoted start '"' buffer lexbuf;
        lexbuf.Lexing.lex_start_p <- start;
        STRING (Buffer.contents buffer) }
  | '\''
      { let start = lexbuf.Lexing.lex_start_p in
        let buffer = Buffer.create 4 in
        quoted start '\'' buffer lexbuf;
        lexbuf.Lexing.lex_start_p <- start;
        CHAR (one_code_point start (Buffer.contents buffer)) }

  | "0x" (hex (hex | '_')* as digits) { INT (whole_number (here lexbuf) 16 digits) }
  | "0b" (binary (binary | '_')* as digits) { INT (whole_number (here lexbuf) 2 digits) }
  | digit (digit | '_')* '.' digit (digit | '_')* exponent? as text
      { FLOAT (float_of_string (without_underscores text)) }
  | digit (digit | '_')* exponent as text
      { FLOAT (float_of_string (without_underscores text)) }
  | digit (digit | '_')* as digits { INT (whole_number (here lexbuf) 10 digits) }

  | letter (letter | digit)* as text { identifier text }

  | "->" { ARROW }
  | "==" { EQUAL }
  | "!=" { NOT_EQUAL }
  | "<=" { LESS_EQUAL }
  | ">=" { GREATER_EQUAL }
  | "&&" { AND }
  | "||" { OR }
  | '(' { LPAREN }
  | ')' { RPAREN }
  | '{' { LBRACE }
  | '}' { RBRACE }
  | '[' { LBRACKET }
  | ']' { RBRACKET }
  | ';' { SEMICOLON }
  | ',' { COMMA }
  | ':' { COLON }
  | '.' { DOT }
  | '=' { ASSIGN }
  | '<' { LESS }
  | '>' { GREATER }
  | '+' { PLUS }
  | '-' { MINUS }
  | '*' { STAR }
  | '/' { SLASH }
  | '%' { PERCENT }
  | '!' { BANG }
  | '~' { TILDE }
  | '&' { AMPERSAND }
  | eof { EOF }
  | _ as character { fail (here lexbuf) "`%c` is not part of any token" character }

and comment start = parse
  | "*/" { () }
  | '\n' { Lexing.new_line lexbuf; comment start lexbuf }
  | eof { fail start "this comment is never closed" }
  | _ { comment start lexbuf }

(* The body of a quoted literal, with escapes resolved. *)
and quoted start terminator buffer = parse
  | '\\' { escape start buffer lexbuf; quoted start terminator buffer lexbuf }
  | '\n' | eof { fail start "this literal is not closed" }
  | _ as character
      { if character = terminator then ()
        else begin
          Buffer.add_char buffer character;
          quoted start terminator buffer lexbuf
        end }

and escape start buffer = parse
  | 'a' { Buffer.add_char buffer '\007' }
  | 'b' { Buffer.add_char buffer '\b' }
  | 'f' { Buffer.add_char buffer '\012' }
  | 'n' { Buffer.add_char buffer '\n' }
  | 'r' { Buffer.add_char buffer '\r' }
  | 't' { Buffer.add_char buffer '\t' }
  | 'v' { Buffer.add_char buffer '\011' }
  | '0' { Buffer.add_char buffer '\000' }
  | ['\\' '\'' '"' '?'] as character { Buffer.add_char buffer character }
  | 'x' (hex hex as digits)
      { Buffer.add_char buffer (Char.chr (int_of_string ("0x" ^ digits))) }
  | 'u' '{' (hex+ as digits) '}'
      { add_code_point buffer (int_of_string ("0x" ^ digits)) }
  | 'x' { fail start "\\x needs two hexadecimal digits" }
  | 'u' { fail start "\\u needs a braced code point, as in \\u{1F9A6}" }
  | eof { fail start "the literal ends in a backslash" }
  | _ as character { fail start "unknown escape \\%c" character }
