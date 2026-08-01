(* The command line. *)

let usage =
  "usage: wolv <command> <file.wol> [options]\n\n\
  \  build   compile and link an executable\n\
  \  run     compile, link, and run it\n\
  \  emit    dump one stage of the pipeline\n\
  \  check   typecheck only\n\n\
  \  -o, --out PATH    where `build` writes the executable\n\
  \  -s, --stage NAME  which stage `emit` shows: %s\n\
  \  --no-checks       leave out the nil, bounds and divide-by-zero checks\n\
  \  --no-opt          do not optimise the SSA\n\
  \  --max-regs N      pretend the machine has this many registers, to force spilling\n"

exception Usage of string

type arguments = {
  mutable command : string;
  mutable file : string;
  mutable out : string;
  mutable stage : string;
  mutable no_checks : bool;
  mutable no_opt : bool;
  mutable max_regs : int;
}

let parse_arguments argv =
  let args =
    { command = ""; file = ""; out = ""; stage = "asm"; no_checks = false; no_opt = false;
      max_regs = 0 }
  in
  let positional = ref [] in
  let argv = Array.of_list argv in
  let value at flag =
    if at >= Array.length argv then raise (Usage (Printf.sprintf "`%s` wants a value" flag));
    argv.(at)
  in
  let at = ref 0 in
  while !at < Array.length argv do
    let arg = argv.(!at) in
    incr at;
    (match arg with
    | "-o" | "--out" ->
        args.out <- value !at arg;
        incr at
    | "-s" | "--stage" ->
        args.stage <- value !at arg;
        incr at
    | "--no-checks" -> args.no_checks <- true
    | "--no-opt" -> args.no_opt <- true
    | "--max-regs" ->
        (match int_of_string_opt (value !at arg) with
        | Some n -> args.max_regs <- n
        | None -> raise (Usage "`--max-regs` wants a number"));
        incr at
    | "-h" | "--help" -> raise (Usage "")
    | _ ->
        if String.length arg > 0 && arg.[0] = '-' then
          raise (Usage (Printf.sprintf "no such option as `%s`" arg))
        else positional := !positional @ [ arg ])
  done;
  (match !positional with
  | [ command; file ] ->
      args.command <- command;
      args.file <- file
  | _ -> raise (Usage "a command and a file, and nothing else"));
  if not (List.mem args.command [ "build"; "run"; "emit"; "check" ]) then
    raise (Usage (Printf.sprintf "no such command as `%s`" args.command));
  if not (List.mem args.stage Driver.stages) then
    raise (Usage (Printf.sprintf "no such stage as `%s`" args.stage));
  args

let main argv =
  match parse_arguments (List.tl argv) with
  | exception Usage msg ->
      Printf.eprintf "%s"
        (CCString.replace ~which:`All ~sub:"%s" ~by:(String.concat ", " Driver.stages) usage);
      if msg <> "" then Printf.eprintf "wolv: %s\n" msg;
      1
  | args -> (
      let opts =
        { Driver.checks = not args.no_checks; optimise = not args.no_opt;
          max_regs = args.max_regs }
      in
      match Driver.read_file args.file with
      | exception Sys_error msg ->
          Printf.eprintf "wolv: %s\n" msg;
          1
      | source -> (
          try
            match args.command with
            | "check" ->
                ignore (Driver.to_ir source opts);
                0
            | "emit" ->
                print_string (Driver.stage source args.stage opts);
                0
            | "build" ->
                let out =
                  if args.out <> "" then args.out
                  else Filename.remove_extension args.file
                in
                Driver.build source out opts;
                0
            | _ ->
                let done_ = Driver.run source opts in
                print_string done_.stdout;
                prerr_string done_.stderr;
                done_.exit_code
          with
          | Diag.Error _ as error ->
              Printf.eprintf "%s:%s\n" args.file (Diag.show error);
              1
          | Driver.Toolchain msg ->
              Printf.eprintf "wolv: %s\n" msg;
              1
          | Spill.Out_of_registers msg ->
              Printf.eprintf "wolv: %s\n" msg;
              1))
