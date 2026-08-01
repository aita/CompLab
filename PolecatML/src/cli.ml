(* The command line. *)

let usage =
  "polecat run  [--interp] [--trace] [--stats] [--no-verify] [file]\n\
   polecat emit -s <stage> [file]\n\
  \  stages: " ^ String.concat " " Driver.stage_names
  ^ "\n\nWith no file, the program is read from standard input."

let read_source = function
  | Some path ->
      let ch = open_in_bin path in
      let n = in_channel_length ch in
      let text = really_input_string ch n in
      close_in ch;
      (path, text)
  | None -> ("<stdin>", In_channel.input_all stdin)

let fail message =
  prerr_endline message;
  exit 1

type options = { flags : string list; stage : string option; file : string option }

let rec options acc = function
  | [] -> acc
  | "-s" :: name :: rest -> options { acc with stage = Some name } rest
  | arg :: rest when String.length arg > 0 && arg.[0] = '-' ->
      options { acc with flags = arg :: acc.flags } rest
  | arg :: rest ->
      options { acc with file = (match acc.file with None -> Some arg | some -> some) } rest

let main argv =
  match List.tl (Array.to_list argv) with
  | [] | [ "-h" ] | [ "--help" ] ->
      print_endline usage;
      0
  | command :: rest -> (
      let o = options { flags = []; stage = None; file = None } rest in
      let has flag = List.mem flag o.flags in
      let path, source = read_source o.file in
      try
        match command with
        | "run" ->
            if has "--interp" then print_string (Driver.interpret source)
            else (
              let text, stats =
                Driver.run_stats ~trace:(has "--trace")
                  ~check:(not (has "--no-verify"))
                  source
              in
              print_string text;
              if has "--stats" then
                Printf.eprintf "%d instructions, %d frame(s) at the deepest\n"
                  stats.Vm.steps stats.Vm.deepest);
            0
        | "emit" -> (
            match o.stage with
            | None -> fail ("emit needs -s <stage>\n" ^ usage)
            | Some name -> (
                match Driver.stage_of_string name with
                | None -> fail (Printf.sprintf "there is no stage called `%s`" name)
                | Some stage ->
                    print_string (Driver.emit stage source);
                    0))
        | other -> fail (Printf.sprintf "there is no command `%s`\n%s" other usage)
      with Diag.Error (pos, message) ->
        fail (Diag.to_string ~file:path (pos, message)))
