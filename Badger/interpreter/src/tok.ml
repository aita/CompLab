(* Tokens, shared by the lexer and the reader. *)

type token =
  | ATOM of string (* a name: foo, 'hello world', +, [], ! *)
  | QUOTED of string (* 'foo' -- a name that may not be read as an operator *)
  | VAR of string (* X, _Rest, _ *)
  | INT of int
  | FLOAT of float
  | STRING of string (* "..." -- what it becomes is a flag, see Flags *)
  | BACKQUOTE of string
  | PUNCT of string (* ( ) [ ] { } , | *)
  | OPEN_CT (* a '(' with no layout before it: functor notation *)
  | END (* the '.' that ends a clause *)
  | EOF

exception Syntax_error of Lexing.position * string

(* [stop] is there for one rule: `-1` is a negative number and `- 1` is the
   negation of one, and the only difference is whether the number starts
   exactly where the minus ended. *)
type located = { tok : token; start : Lexing.position; stop : Lexing.position }

let describe = function
  | ATOM name | QUOTED name -> Printf.sprintf "atom %s" name
  | VAR name -> Printf.sprintf "variable %s" name
  | INT n -> string_of_int n
  | FLOAT f -> string_of_float f
  | STRING s -> Printf.sprintf "%S" s
  | BACKQUOTE s -> Printf.sprintf "`%s`" s
  | PUNCT s -> Printf.sprintf "%S" s
  | OPEN_CT -> "\"(\""
  | END -> "end of clause"
  | EOF -> "end of input"
