(* Tokens, and the one pass that produces them.

   The scanner reads the source once, left to right, and never backs up: every
   token is decided by the character that begins it, and at most one character
   after it (`<` is `<`, `<=` or `<>`).  Comments nest, which is the only place
   the scanner counts anything. *)

type kind =
  | Int of int64
  | Ident of string
  | Tyvar of string (* 'a *)
  | Hash of int (* #1, the tuple projection *)
  (* keywords *)
  | Val
  | Fun
  | And
  | Fn
  | Let
  | In
  | End
  | If
  | Then
  | Else
  | True
  | False
  | Andalso
  | Orelse
  | Mod
  | Not
  (* punctuation *)
  | Lparen
  | Rparen
  | Comma
  | Colon
  | Equal
  | Darrow (* => *)
  | Arrow (* -> *)
  | Plus
  | Minus
  | Star
  | Slash
  | Lt
  | Le
  | Gt
  | Ge
  | Ne (* <> *)
  | Tilde (* ~, negation *)
  | Underscore
  | Eof

type token = { kind : kind; pos : Diag.pos }

(* What an error message calls a token. *)
let describe = function
  | Int n -> Printf.sprintf "the integer %Ld" n
  | Ident name -> Printf.sprintf "`%s`" name
  | Tyvar name -> Printf.sprintf "`%s`" name
  | Hash n -> Printf.sprintf "`#%d`" n
  | Val -> "`val`"
  | Fun -> "`fun`"
  | And -> "`and`"
  | Fn -> "`fn`"
  | Let -> "`let`"
  | In -> "`in`"
  | End -> "`end`"
  | If -> "`if`"
  | Then -> "`then`"
  | Else -> "`else`"
  | True -> "`true`"
  | False -> "`false`"
  | Andalso -> "`andalso`"
  | Orelse -> "`orelse`"
  | Mod -> "`mod`"
  | Not -> "`not`"
  | Lparen -> "`(`"
  | Rparen -> "`)`"
  | Comma -> "`,`"
  | Colon -> "`:`"
  | Equal -> "`=`"
  | Darrow -> "`=>`"
  | Arrow -> "`->`"
  | Plus -> "`+`"
  | Minus -> "`-`"
  | Star -> "`*`"
  | Slash -> "`/`"
  | Lt -> "`<`"
  | Le -> "`<=`"
  | Gt -> "`>`"
  | Ge -> "`>=`"
  | Ne -> "`<>`"
  | Tilde -> "`~`"
  | Underscore -> "`_`"
  | Eof -> "the end of the file"

let keywords =
  [
    ("val", Val);
    ("fun", Fun);
    ("and", And);
    ("fn", Fn);
    ("let", Let);
    ("in", In);
    ("end", End);
    ("if", If);
    ("then", Then);
    ("else", Else);
    ("true", True);
    ("false", False);
    ("andalso", Andalso);
    ("orelse", Orelse);
    ("mod", Mod);
    ("not", Not);
  ]

type state = {
  src : string;
  mutable i : int;
  mutable line : int;
  mutable bol : int; (* index of the first character of the current line *)
}

let pos st = { Diag.line = st.line; col = st.i - st.bol + 1 }
let peek st = if st.i < String.length st.src then Some st.src.[st.i] else None

let advance st =
  (if st.i < String.length st.src && st.src.[st.i] = '\n' then (
     st.line <- st.line + 1;
     st.bol <- st.i + 1));
  st.i <- st.i + 1

let is_digit c = c >= '0' && c <= '9'
let is_alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_char c = is_alpha c || is_digit c || c = '\''

(* Whitespace and comments.  `(*` opens a comment even inside a comment, so the
   depth is counted rather than scanned for a first `*)`. *)
let rec skip_trivia st =
  match peek st with
  | Some (' ' | '\t' | '\r' | '\n') ->
      advance st;
      skip_trivia st
  | Some '(' when st.i + 1 < String.length st.src && st.src.[st.i + 1] = '*' ->
      let start = pos st in
      let depth = ref 0 in
      let finished = ref false in
      while not !finished do
        match peek st with
        | None -> Diag.error start "unterminated comment"
        | Some '(' when st.i + 1 < String.length st.src && st.src.[st.i + 1] = '*'
          ->
            incr depth;
            advance st;
            advance st
        | Some '*' when st.i + 1 < String.length st.src && st.src.[st.i + 1] = ')'
          ->
            decr depth;
            advance st;
            advance st;
            if !depth = 0 then finished := true
        | Some _ -> advance st
      done;
      skip_trivia st
  | _ -> ()

let take_while st f =
  let start = st.i in
  let rec go () = match peek st with Some c when f c -> advance st; go () | _ -> () in
  go ();
  String.sub st.src start (st.i - start)

let number st p =
  let text = take_while st is_digit in
  match Int64.of_string_opt text with
  | Some n -> n
  | None -> Diag.error p "the integer literal `%s` does not fit in 64 bits" text

let scan_one st =
  let p = pos st in
  let kind =
    match peek st with
    | None -> Eof
    | Some c when is_digit c -> Int (number st p)
    | Some c when is_alpha c ->
        let text = take_while st is_ident_char in
        if text = "_" then Underscore
        else (
          match List.assoc_opt text keywords with
          | Some kw -> kw
          | None -> Ident text)
    | Some '\'' ->
        advance st;
        let text = take_while st is_ident_char in
        if text = "" then Diag.error p "a type variable needs a name after `'`";
        Tyvar ("'" ^ text)
    | Some '#' ->
        advance st;
        let text = take_while st is_digit in
        if text = "" then Diag.error p "`#` must be followed by a field number";
        let n = int_of_string text in
        if n < 1 then Diag.error p "tuple fields are numbered from 1";
        Hash n
    | Some c ->
        advance st;
        (* Everything left is one character, or one character and a second: if
           the next one is [second] take it and answer [long], else [short]. *)
        let maybe second ~long ~short =
          match peek st with
          | Some c when c = second ->
              advance st;
              long
          | _ -> short
        in
        (match c with
        | '(' -> Lparen
        | ')' -> Rparen
        | ',' -> Comma
        | ':' -> Colon
        | '=' -> maybe '>' ~long:Darrow ~short:Equal
        | '-' -> maybe '>' ~long:Arrow ~short:Minus
        | '+' -> Plus
        | '*' -> Star
        | '/' -> Slash
        | '<' -> (
            match peek st with
            | Some '=' ->
                advance st;
                Le
            | Some '>' ->
                advance st;
                Ne
            | _ -> Lt)
        | '>' -> maybe '=' ~long:Ge ~short:Gt
        | '~' -> Tilde
        | _ -> Diag.error p "the character `%c` means nothing here" c)
  in
  { kind; pos = p }

(* The whole file, as an array ending in exactly one [Eof]: the parser indexes
   into it and can always look at the next token without a bounds check. *)
let tokens src =
  let st = { src; i = 0; line = 1; bol = 0 } in
  let rec go acc =
    skip_trivia st;
    let tok = scan_one st in
    if tok.kind = Eof then List.rev (tok :: acc) else go (tok :: acc)
  in
  Array.of_list (go [])
