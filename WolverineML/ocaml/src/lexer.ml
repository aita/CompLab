(* Tokens, and the hand-written scanner that produces them. *)

(* A token kind.  [text] is what an error message calls it. *)
type tok =
  | INT
  | STRING
  | IDENT
  | EOF
  | AND
  | ANDALSO
  | BREAK
  | DO
  | ELSE
  | END
  | FALSE
  | FOR
  | FUN
  | IF
  | IN
  | LET
  | MOD
  | NIL
  | ORELSE
  | THEN
  | TO
  | TRUE
  | TYPE
  | VAL
  | VAR
  | WHILE
  | LPAREN
  | RPAREN
  | LBRACK
  | RBRACK
  | LBRACE
  | RBRACE
  | COMMA
  | COLON
  | SEMI
  | DOT
  | ASSIGN
  | EQ
  | NE
  | LE
  | LT
  | GE
  | GT
  | PLUS
  | MINUS
  | STAR
  | SLASH
  | CARET
  | TILDE
[@@deriving show { with_path = false }]

let text = function
  | INT -> "an integer"
  | STRING -> "a string"
  | IDENT -> "an identifier"
  | EOF -> "end of input"
  | AND -> "and"
  | ANDALSO -> "andalso"
  | BREAK -> "break"
  | DO -> "do"
  | ELSE -> "else"
  | END -> "end"
  | FALSE -> "false"
  | FOR -> "for"
  | FUN -> "fun"
  | IF -> "if"
  | IN -> "in"
  | LET -> "let"
  | MOD -> "mod"
  | NIL -> "nil"
  | ORELSE -> "orelse"
  | THEN -> "then"
  | TO -> "to"
  | TRUE -> "true"
  | TYPE -> "type"
  | VAL -> "val"
  | VAR -> "var"
  | WHILE -> "while"
  | LPAREN -> "("
  | RPAREN -> ")"
  | LBRACK -> "["
  | RBRACK -> "]"
  | LBRACE -> "{"
  | RBRACE -> "}"
  | COMMA -> ","
  | COLON -> ":"
  | SEMI -> ";"
  | DOT -> "."
  | ASSIGN -> ":="
  | EQ -> "="
  | NE -> "<>"
  | LE -> "<="
  | LT -> "<"
  | GE -> ">="
  | GT -> ">"
  | PLUS -> "+"
  | MINUS -> "-"
  | STAR -> "*"
  | SLASH -> "/"
  | CARET -> "^"
  | TILDE -> "~"

(* [name] is what a token dump calls it, which is the constructor's own name. *)
(* What a token dump calls a kind, which is the constructor's own name.  The
   enum above is the table; there is no second one to keep in step with it. *)
let name = show_tok

let keywords =
  [ AND; ANDALSO; BREAK; DO; ELSE; END; FALSE; FOR; FUN; IF; IN; LET; MOD; NIL;
    ORELSE; THEN; TO; TRUE; TYPE; VAL; VAR; WHILE ]

(* Longest first, so that [:=] beats [:] and [<=] beats [<]. *)
let punctuation =
  List.stable_sort
    (fun a b -> compare (String.length (text b)) (String.length (text a)))
    [ LPAREN; RPAREN; LBRACK; RBRACK; LBRACE; RBRACE; COMMA; COLON; SEMI; DOT;
      ASSIGN; EQ; NE; LE; LT; GE; GT; PLUS; MINUS; STAR; SLASH; CARET; TILDE ]

let escapes = [ ('n', '\n'); ('t', '\t'); ('r', '\r'); ('"', '"'); ('\\', '\\') ]

(* One token, and where it started. *)
type token = { kind : tok; text : string; at : Diag.span }

let show_token t =
  match t.kind with
  | EOF -> "end of input"
  | STRING -> "\"" ^ t.text ^ "\""
  | _ -> "`" ^ t.text ^ "`"

(* The scanner reads code points and not bytes, so a character outside the basic
   plane is one character everywhere it matters: it is one column, it is a letter
   if Unicode says it is, and inside a string literal it contributes the UTF-8
   bytes of the whole of itself. *)
type scanner = { src : string; mutable pos : int; mutable line : int; mutable col : int }

let done_ s = s.pos >= String.length s.src

(* [here] is the code point under the cursor, and how many bytes it took.  The
   source is UTF-8, so a byte under 0x80 is its own character and anything else
   is decoded. *)
let here s =
  let d = String.get_utf_8_uchar s.src s.pos in
  (Uchar.to_int (Uchar.utf_decode_uchar d), Uchar.utf_decode_length d)

(* [advance] moves on by [n] bytes, counting columns in code points. *)
let advance s n =
  let stop = s.pos + n in
  while s.pos < stop do
    if s.src.[s.pos] = '\n' then begin
      s.line <- s.line + 1;
      s.col <- 1;
      s.pos <- s.pos + 1
    end
    else begin
      let _, width = here s in
      s.col <- s.col + 1;
      s.pos <- s.pos + width
    end
  done

(* [step] moves on by one code point. *)
let step s =
  let _, width = here s in
  advance s width

let at s : Diag.span = { line = s.line; col = s.col }

let starts_with s prefix =
  let n = String.length prefix in
  s.pos + n <= String.length s.src && String.sub s.src s.pos n = prefix

(* Python's [isalpha] is the letter categories and nothing else, so that is what
   a name is made of here; [uucp] is the one thing OCaml's standard library has
   no answer for. *)
let is_letter code =
  match Uucp.Gc.general_category (Uchar.of_int code) with
  | `Lu | `Ll | `Lt | `Lm | `Lo -> true
  | _ -> false

let is_digit code =
  Uucp.Gc.general_category (Uchar.of_int code) = `Nd

(* One code point written back out, as the UTF-8 it is. *)
let utf8_of_code code =
  let b = Buffer.create 4 in
  Buffer.add_utf_8_uchar b (Uchar.of_int code);
  Buffer.contents b

let keyword_of word =
  List.find_opt (fun k -> text k = word) keywords

let rec skip_trivia s =
  if not (done_ s) then
    match s.src.[s.pos] with
    | ' ' | '\t' | '\r' | '\n' ->
        advance s 1;
        skip_trivia s
    | _ ->
        if starts_with s "(*" then begin
          comment s;
          skip_trivia s
        end

and comment s =
  let start = at s in
  let depth = ref 0 in
  let finished = ref false in
  while (not !finished) && not (done_ s) do
    if starts_with s "(*" then begin
      incr depth;
      advance s 2
    end
    else if starts_with s "*)" then begin
      decr depth;
      advance s 2;
      if !depth = 0 then finished := true
    end
    else step s
  done;
  if not !finished then Diag.lex_error start "unterminated comment"

let number s start =
  let from = s.pos in
  while (not (done_ s)) && is_digit (fst (here s)) do
    step s
  done;
  let body = String.sub s.src from (s.pos - from) in
  if not (done_ s) then begin
    let code, _ = here s in
    if is_letter code || code = Char.code '_' then
      Diag.lex_error start "`%s%s` is not a number" body
        (utf8_of_code code)
  end;
  { kind = INT; text = body; at = start }

let word s start =
  let from = s.pos in
  let continues code =
    is_letter code || is_digit code || code = Char.code '_' || code = Char.code '\''
  in
  while (not (done_ s)) && continues (fst (here s)) do
    step s
  done;
  let body = String.sub s.src from (s.pos - from) in
  match keyword_of body with
  | Some kind -> { kind; text = body; at = start }
  | None -> { kind = IDENT; text = body; at = start }

(* [escape] reads what follows a backslash, and gives back the one byte it names. *)
let escape s =
  if done_ s then Diag.lex_error (at s) "unterminated escape";
  let code, _ = here s in
  if is_digit code then begin
    let value = ref 0 in
    (try
       for i = 0 to 2 do
         if s.pos + i >= String.length s.src then raise Exit;
         let ch = s.src.[s.pos + i] in
         if ch < '0' || ch > '9' then raise Exit;
         value := (!value * 10) + (Char.code ch - Char.code '0')
       done
     with Exit -> value := -1);
    if !value >= 0 && !value < 256 then begin
      advance s 3;
      Char.chr !value
    end
    else Diag.lex_error (at s) "a numeric escape is three digits, `\\065`"
  end
  else
    match List.assoc_opt (Char.chr (code land 0xff)) escapes with
    | Some ch when code < 128 ->
        step s;
        ch
    | _ -> Diag.lex_error (at s) "unknown escape `\\%s`" (utf8_of_code code)

(* [string_literal] scans a literal, which is a sequence of bytes.

   [size], [ord] and [substring] count bytes at run time, so a literal is read as
   bytes here too: source text contributes its UTF-8 encoding, and [\ddd] names
   one byte.  An OCaml string is already bytes, which is what [Emit.escape]
   writes back out. *)
let string_literal s start =
  step s;
  let out = Buffer.create 16 in
  let result = ref None in
  while !result = None do
    if done_ s then Diag.lex_error start "unterminated string";
    let code, width = here s in
    if code = Char.code '"' then begin
      step s;
      result := Some { kind = STRING; text = Buffer.contents out; at = start }
    end
    else if code = Char.code '\n' then Diag.lex_error (at s) "a string may not span lines"
    else if code = Char.code '\\' then begin
      step s;
      Buffer.add_char out (escape s)
    end
    else begin
      (* One code point, as the UTF-8 bytes it already is. *)
      Buffer.add_string out (String.sub s.src s.pos width);
      step s
    end
  done;
  Option.get !result

let next s =
  skip_trivia s;
  let start = at s in
  if done_ s then { kind = EOF; text = ""; at = start }
  else
    let code, _ = here s in
    if is_digit code then number s start
    else if is_letter code || code = Char.code '_' then word s start
    else if code = Char.code '"' then string_literal s start
    else
      match List.find_opt (fun kind -> starts_with s (text kind)) punctuation with
      | Some kind ->
          advance s (String.length (text kind));
          { kind; text = text kind; at = start }
      | None -> Diag.lex_error start "stray character `%s`" (utf8_of_code code)

(* [lex] turns source text into tokens, in one pass, no regexes. *)
let lex source =
  let s = { src = source; pos = 0; line = 1; col = 1 } in
  let rec loop acc =
    let t = next s in
    if t.kind = EOF then List.rev (t :: acc) else loop (t :: acc)
  in
  loop []
