(* Runs every program that has a transcript beside it, and compares what it
   wrote against the transcript.

       run_tests <otter> <directory>:<stream>:<status> ...

   The program is named relative to its own directory, so that the file names in
   diagnostics do not depend on where the build tree sits. *)

let read path =
  let channel = open_in_bin path in
  let text = really_input_string channel (in_channel_length channel) in
  close_in channel;
  text

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
  else path

(* What the program wrote, and how it ended. *)
let run otter directory name =
  let output = Filename.temp_file "otter" ".out" in
  let errors = Filename.temp_file "otter" ".err" in
  let command =
    Filename.quote_command otter [ name ] ~stdout:output ~stderr:errors
  in
  let here = Sys.getcwd () in
  Sys.chdir directory;
  let status = Sys.command command in
  Sys.chdir here;
  let written = (read output, read errors) in
  Sys.remove output;
  Sys.remove errors;
  (written, status)

let failures = ref 0

let check otter directory stream expected_status name =
  let expected = read (Filename.concat directory (name ^ ".expected")) in
  let (output, errors), status = run otter directory (name ^ ".otter") in
  let actual = if stream = "stderr" then errors else output in
  if actual <> expected then begin
    incr failures;
    Printf.printf
      "%s wrote something else.\n---- expected ----\n%s---- actual ----\n%s"
      name expected actual;
    Printf.printf "---- exit status %d ----\n" status
  end
  else if status <> expected_status then begin
    incr failures;
    Printf.printf "%s exited with %d, not %d\n" name status expected_status
  end
  else Printf.printf "ok %s\n" name

(* A test exists for every transcript, so adding one is a matter of writing the
   program and recording what it should say. *)
let transcripts directory =
  Sys.readdir directory |> Array.to_list
  |> List.filter (fun entry -> Filename.check_suffix entry ".expected")
  |> List.map Filename.remove_extension
  |> List.sort compare

let () =
  let otter = absolute Sys.argv.(1) in
  for index = 2 to Array.length Sys.argv - 1 do
    match String.split_on_char ':' Sys.argv.(index) with
    | [ directory; stream; status ] ->
        List.iter
          (check otter (absolute directory) stream (int_of_string status))
          (transcripts directory)
    | _ -> failwith "a suite is written <directory>:<stream>:<status>"
  done;
  if !failures > 0 then begin
    Printf.printf "%d test(s) failed\n" !failures;
    exit 1
  end
