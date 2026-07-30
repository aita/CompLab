(* Command line driver and toplevel.

   With files, Badger consults them and exits, which means a program is a file
   whose last directive does something.  With none, it reads queries from
   standard input.  Either way there is one reader over standard input, shared
   with read/1, so a program can read the text that follows its own query. *)

let usage =
  "usage: badger [options] [file ...]\n\n\
   Consults each file, running its directives, and then exits.  With no file\n\
   and no goal, reads queries from standard input instead.\n\n\
   options:\n\
  \  -g, --goal GOAL   run GOAL once after loading (may be repeated)\n\
  \  -t, --toplevel    read queries even after loading files\n\
  \  -q, --quiet       do not report singleton variables\n\
  \  -T, --trace       report the Call/Exit/Redo/Fail of every predicate call\n\
  \  -d, --dump-db     print the stored form of every clause, and stop\n\
  \  -h, --help        show this message\n"

let db = Db.create ()

let complain message =
  flush stdout;
  prerr_endline message

let report_error ball = complain (Printf.sprintf "ERROR: %s" (Load.describe_error ball))

(* One solution, as the toplevel shows it.  Variables the query named and the
   solution left unbound are printed under their own names rather than as _G
   tags, which is what the temporary '$VAR' bindings below are for. *)
let solution_text vars =
  let mark = Term.mark () in
  List.iter
    (fun (name, v) ->
      match Term.deref v with
      | Term.Var _ -> ignore (Term.unify v (Term.Struct ("$VAR", [| Term.Atom name |])))
      | _ -> ())
    vars;
  let line (name, v) =
    match Term.deref v with
    (* A variable still standing for itself says nothing. *)
    | Term.Struct ("$VAR", [| arg |]) when Term.deref arg = Term.Atom name -> None
    | value -> Some (Printf.sprintf "%s = %s" name (Write.to_string ~opts:Write.writeq_opts ~maxp:699 value))
  in
  let shown = List.filter_map line vars in
  Term.undo_to mark;
  match shown with [] -> "true" | lines -> String.concat ",\n" lines

(* Solutions are printed one behind, because only the arrival of the next one
   says that the last was not the final answer. *)
let run_query goal vars =
  let pending = ref None in
  let release suffix = match !pending with Some text -> print_string (text ^ suffix) | None -> () in
  let outcome =
    try
      Engine.call_goal db goal (fun () ->
          release " ;\n";
          pending := Some (solution_text vars));
      `Ok
    with
    | Term.Prolog_error ball -> `Error ball
    | Stack_overflow -> `Overflow
  in
  match outcome with
  | `Ok ->
      if !pending = None then begin
        print_string "false.\n";
        false
      end
      else begin
        release ".\n";
        true
      end
  | `Error ball ->
      release ".\n";
      report_error ball;
      false
  | `Overflow ->
      release ".\n";
      complain "ERROR: stack overflow (runaway recursion, or a query too deep for the stack)";
      false

let goal_of term = match Term.deref term with Term.Struct ((":-" | "?-"), [| goal |]) -> goal | goal -> goal

(* Clauses as they are stored rather than as they were written: variables have
   become frame slots, printed as _L0, _L1, ... , and each clause carries the
   first-argument key the engine filters on before it copies anything. *)
let dump_database skip =
  let show t = Write.to_string ~opts:Write.canonical_opts t in
  List.iter
    (fun indicator ->
      match Db.find db indicator with
      | Some p when p.clauses <> [] && not (List.mem indicator skip) ->
          Printf.printf "%% %s%s\n"
            (Write.to_string ~opts:Write.writeq_opts (Term.indicator_term indicator))
            (if p.dynamic then " (dynamic)" else "");
          List.iter
            (fun (c : Db.clause) ->
              let body = match c.body with Term.Atom "true" -> "" | body -> " :- " ^ show body in
              Printf.printf "  [%s, %d vars] %s%s.\n" (Db.key_string c.key) c.nvars (show c.head) body)
            p.clauses;
          print_newline ()
      | _ -> ())
    (Db.indicators db)

let toplevel () =
  let interactive = Unix.isatty Unix.stdin in
  let st = Lazy.force Builtins.stdin_reader in
  let rec loop () =
    if interactive then begin
      print_string "?- ";
      flush stdout
    end;
    match try `Read (Read.read_clause st) with Tok.Syntax_error (pos, msg) -> `Bad (pos, msg) with
    | `Bad (pos, msg) ->
        complain (Printf.sprintf "%s: %s" (Read.position_string pos) msg);
        Read.skip_to_end st;
        loop ()
    | `Read None -> if interactive then print_newline ()
    | `Read (Some { Read.clause; vars; _ }) ->
        ignore (run_query (goal_of clause) vars);
        flush stdout;
        loop ()
  in
  loop ()

let run_goal_text text =
  match
    try Read.term_of_string ~file:"<goal>" (text ^ " .")
    with Tok.Syntax_error (pos, msg) ->
      complain (Printf.sprintf "%s: %s" (Read.position_string pos) msg);
      None
  with
  | None -> false
  | Some { Read.clause; _ } -> (
      try
        if Engine.once db (goal_of clause) then true
        else begin
          complain (Printf.sprintf "ERROR: goal (%s) failed" text);
          false
        end
      with
      | Term.Prolog_error ball ->
          report_error ball;
          false
      | Stack_overflow ->
          complain "ERROR: stack overflow (runaway recursion?)";
          false)

let fail message =
  flush stdout;
  prerr_string message;
  exit 2

let main () =
  Solve.install ();
  Engine.show_goal := (fun t -> Write.to_string ~opts:Write.writeq_opts t);
  (* The library is a file like any other, so it is loaded like one. *)
  Flags.verbose_load := false;
  Load.consult_string db ~where:"<prelude>" Prelude.source;
  if !Load.errors > 0 then fail "badger: the prelude did not load\n";
  Flags.verbose_load := true;
  (* What --dump-db leaves out, so that a dump shows the program and not the
     library. *)
  let library = Db.indicators db in
  let files = ref [] and goals = ref [] and force_toplevel = ref false and dump = ref false in
  let rec arguments = function
    | [] -> ()
    | ("-h" | "--help") :: _ ->
        print_string usage;
        exit 0
    | ("-g" | "--goal") :: goal :: rest ->
        goals := goal :: !goals;
        arguments rest
    | [ ("-g" | "--goal") ] -> fail "badger: -g needs a goal\n"
    | ("-q" | "--quiet") :: rest ->
        Flags.verbose_load := false;
        arguments rest
    | ("-t" | "--toplevel") :: rest ->
        force_toplevel := true;
        arguments rest
    | ("-T" | "--trace") :: rest ->
        Engine.tracing := true;
        arguments rest
    | ("-d" | "--dump-db") :: rest ->
        dump := true;
        arguments rest
    | arg :: _ when String.length arg > 1 && arg.[0] = '-' ->
        fail (Printf.sprintf "badger: unknown option %s\n%s" arg usage)
    | file :: rest ->
        files := file :: !files;
        arguments rest
  in
  arguments (List.tl (Array.to_list Sys.argv));
  let files = List.rev !files and goals = List.rev !goals in
  List.iter
    (fun file ->
      try Load.consult_file db file
      with Term.Prolog_error ball ->
        report_error ball;
        incr Load.errors)
    files;
  if !dump then begin
    dump_database library;
    flush stdout;
    if !Load.errors > 0 then 1 else 0
  end
  else begin
    let goals_ok = List.for_all run_goal_text goals in
    if !force_toplevel || (files = [] && goals = []) then toplevel ();
    flush stdout;
    if !Load.errors > 0 || not goals_ok then 1 else 0
  end

let () =
  let status = try main () with Term.Halt n -> n in
  flush stdout;
  exit status
