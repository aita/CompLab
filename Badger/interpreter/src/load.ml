(* Consulting: reading clauses into the database, one at a time.

   A term read from a file is a directive if it is `:- G`, a grammar rule if it
   is `H --> B`, and a clause otherwise.  Directives run as they are met, which
   is what lets `:- op(700, xfx, ===)` change how the rest of the file is
   read -- the reader and the engine take turns over the same file.  The one
   exception is initialization/1, which is held back until the file is loaded,
   because that is what it is for. *)

(* Set by Builtins, so that consulting can refuse to redefine a built-in
   predicate without this module depending on the whole table. *)
let is_protected : ((string * int) -> bool) ref = ref (fun _ -> false)

let errors = ref 0

(* Diagnostics go to standard error, but they are about a program that is
   writing to standard output, so both are flushed at every message: the
   interleaving is part of what the reader of the output is reading. *)
let diagnostic where msg =
  flush stdout;
  Printf.eprintf "%s: %s\n" where msg;
  flush stderr

let report where msg =
  incr errors;
  diagnostic where msg

let warn where msg = if !Flags.verbose_load then diagnostic where ("warning: " ^ msg)

(* An uncaught error from a directive is reported the way the toplevel reports
   one, and loading carries on with the next clause. *)
let describe_error ball =
  match Term.deref ball with
  | Term.Struct ("error", [| formal; context |]) -> (
      let formal_text = Write.to_string ~opts:Write.writeq_opts formal in
      match Term.deref context with
      | Term.Var _ -> formal_text
      | context -> Printf.sprintf "%s (%s)" formal_text (Write.to_string ~opts:Write.writeq_opts context))
  | ball -> Printf.sprintf "unhandled exception %s" (Write.to_string ~opts:Write.writeq_opts ball)

let run_goal db where goal what =
  try if not (Engine.once db goal) then warn where (Printf.sprintf "%s failed" what)
  with Term.Prolog_error ball -> report where (describe_error ball)

let add_clause db where term =
  let head, _ = Db.split_clause term in
  match Term.deref head with
  | Term.Var _ -> report where "a clause head cannot be a variable"
  | Term.Int _ | Term.Float _ -> report where "a clause head cannot be a number"
  | _ ->
      let indicator = Term.indicator_of head "consult" in
      if !is_protected indicator then
        report where
          (Printf.sprintf "cannot redefine the built-in %s"
             (Write.to_string (Term.indicator_term indicator)))
      else ignore (Db.add_clause db term)

let consult_reader db ~where:file (st : Read.t) =
  let initializations = ref [] in
  let position pos = Read.position_string pos in
  let rec loop () =
    match
      try `Read (Read.read_clause st)
      with Tok.Syntax_error (pos, msg) ->
        report (position pos) msg;
        Read.skip_to_end st;
        `Again
    with
    | `Again -> loop ()
    | `Read None -> ()
    | `Read (Some { Read.clause; vars = _; singletons }) ->
        let where = file in
        (match singletons with
        | [] -> ()
        | names -> warn where (Printf.sprintf "singleton variables: %s" (String.concat ", " names)));
        (match Term.deref clause with
        | Term.Struct ((":-" | "?-"), [| goal |]) -> (
            match Term.deref goal with
            | Term.Struct ("initialization", [| g |]) -> initializations := g :: !initializations
            | Term.Struct ("initialization", [| g; _ |]) -> initializations := g :: !initializations
            | goal -> run_goal db where goal "directive")
        | term -> (
            match Dcg.translate term with
            | Some clause -> add_clause db where clause
            | None -> add_clause db where term));
        loop ()
  in
  loop ();
  List.iter (fun g -> run_goal db file g "initialization goal") (List.rev !initializations)

let consult_string db ~where text = consult_reader db ~where (Read.of_string ~file:where text)

let resolve path =
  if Sys.file_exists path then Some path
  else
    let with_pl = path ^ ".pl" in
    if Sys.file_exists with_pl then Some with_pl else None

let consult_file db path =
  match resolve path with
  | None -> Term.existence_error "source_sink" (Term.Atom path) "consult/1"
  | Some path ->
      let channel = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () -> consult_reader db ~where:path (Read.of_channel ~file:path channel))
