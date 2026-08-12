(* Reading a program, and running it: parse, resolve fixity, desugar, check,
   evaluate.  The prelude goes through exactly the same five steps first, and
   hands its environments to the program. *)

let parse name lexbuf =
  Lexing.set_filename lexbuf name;
  try Parser.program Lexer.token lexbuf
  with Parser.Error -> Diag.at (Lexing.lexeme_start_p lexbuf) "syntax error"

let front tbl name lexbuf =
  let ds = parse name lexbuf in
  let tbl, ds = Fixity.decls tbl ds in
  (tbl, Desugar.program ds)

let types_of (sg : Typecheck.sg) =
  Typecheck.SMap.fold
    (fun n s acc -> (n, Types.show (Types.instantiate s)) :: acc)
    sg.Typecheck.sg_vals []
  |> List.rev

let run show_types path lexbuf =
  let tbl, pre = front Fixity.ladder "<prelude>" (Lexing.from_string Prelude.source) in
  let tenv, _ = Typecheck.decls Typecheck.initial pre in
  (* [] and :: are the one datatype the language does not declare *)
  let venv =
    List.fold_left
      (fun env (n, v) -> { env with Value.vals = Value.SMap.add n (ref v) env.Value.vals })
      { Value.empty_env with
        Value.cons = Value.SMap.(add "[]" 0 (add "::" 1 empty)) }
      Prims.values
  in
  let venv, _ = Eval.decls venv pre in
  let _, ds = front tbl path lexbuf in
  let _, sg = Typecheck.decls tenv ds in
  if show_types then
    List.iter (fun (n, t) -> Printf.printf "val %s : %s\n" n t) (types_of sg)
  else ignore (Eval.decls venv ds)

let main () =
  let args = List.tl (Array.to_list Sys.argv) in
  let show_types = List.mem "-t" args in
  let files = List.filter (fun a -> a <> "-t") args in
  try
    match files with
    | [] -> run show_types "<stdin>" (Lexing.from_channel stdin)
    | [ path ] ->
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in ic)
        (fun () -> run show_types path (Lexing.from_channel ic))
    | _ ->
      prerr_endline "usage: grison [-t] [file]";
      exit 2
  with
  | Diag.Error msg ->
    prerr_endline msg;
    exit 1
  | Value.Runtime msg ->
    prerr_endline ("runtime error: " ^ msg);
    exit 1
  | Sys_error msg ->
    prerr_endline msg;
    exit 1
