{
open Parser
}

let white = [' ' '\t' '\r']+
let digit = ['0'-'9']

rule token = parse
  | white        { token lexbuf }                         (* skip spaces/tabs *)
  | '\n'         { Lexing.new_line lexbuf; token lexbuf }
  | digit+ as s  { INT (int_of_string s) }
  | '+'          { PLUS }
  | '-'          { MINUS }
  | '*'          { TIMES }
  | '/'          { DIV }
  | '('          { LPAREN }
  | ')'          { RPAREN }
  | eof          { EOF }
  | _ as c       { failwith (Printf.sprintf "unexpected character: %C" c) }
