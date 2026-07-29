open Otter

let usage () =
  Printf.eprintf "usage: otter <program%s>\n" Program.source_extension;
  prerr_newline ();
  prerr_endline "Runs a program. Modules it imports are looked for beside it,";
  prerr_endline "except for the built-in io, str and math."

let () =
  if Array.length Sys.argv <> 2 then begin
    usage ();
    exit 2
  end;
  let path = Sys.argv.(1) in
  if not (Sys.file_exists path) then begin
    Printf.eprintf "otter: there is no file `%s`\n" path;
    exit 2
  end;
  let program = Program.create path in
  try
    Program.load_entry program path;
    match Check.check_program program with
    | [] -> exit (Interp.run_program program)
    | errors ->
        List.iter
          (fun (span, message) ->
            prerr_endline (Diagnostics.report span message))
          errors;
        exit 1
  with
  | Diagnostics.Compile_error (span, message) ->
      prerr_endline (Diagnostics.report span message);
      exit 1
  | Diagnostics.Runtime_error (span, message) ->
      Printf.eprintf "otter: %s\n" (Diagnostics.report span message);
      exit 1
