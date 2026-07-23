let () =
  let lexbuf = Lexing.from_channel stdin in
  try
    let result = Parser.main Lexer.token lexbuf in
    Printf.printf "%d\n" result
  with
  | Failure msg -> prerr_endline msg; exit 1
  | Parser.Error -> prerr_endline "syntax error"; exit 1
