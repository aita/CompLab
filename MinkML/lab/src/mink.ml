(* The command line.

   One program, one system, one run: `mink file.mink` reads the `#system`
   directive at the top of the file to decide which typechecker to hand the
   program to, and `-s` overrides it.  Everything else is a dump switch. *)

let systems : System.t list =
  [ Hm.system; Poly.system; Row.system; Refine.system; Linear.system; Dep.system ]

let find_system name =
  match List.find_opt (fun (s : System.t) -> s.name = name) systems with
  | Some s -> s
  | None ->
      Printf.eprintf "mink: no system called %s; try --list\n" name;
      exit 2

let list_systems () =
  print_endline "systems:";
  List.iter
    (fun (s : System.t) -> Printf.printf "  %-8s %s\n" s.name s.blurb)
    systems

let usage () =
  print_string
    "usage: mink [options] file.mink\n\
    \n\
     options:\n\
    \  -s, --system NAME   check with this system, overriding #system\n\
    \      --list          list the systems and what each one is about\n\
    \      --dump-anf      print the A-normal form of every binding\n\
    \      --dump-vc       print every verification condition as SMT-LIB 2\n\
    \      --dump-infer    print the unifications inference performs (hm only)\n\
    \      --smt CMD       decide verification conditions with CMD, not the\n\
    \                      built-in procedure (try --smt \"z3 -in\")\n\
    \      --trace         print every step the machine takes\n\
    \  -h, --help          this\n"

let parse_file path =
  let chan = try open_in path with Sys_error m -> (
    Printf.eprintf "mink: %s\n" m;
    exit 2)
  in
  let lexbuf = Lexing.from_channel chan in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = path };
  let prog =
    try Parser.program Lexer.token lexbuf with
    | Parser.Error ->
        let loc = Loc.of_lexing lexbuf.lex_start_p in
        Loc.syntax_error loc "unexpected %s"
          (match Lexing.lexeme lexbuf with "" -> "end of file" | s -> "`" ^ s ^ "`")
  in
  close_in chan;
  prog

let name_of_decl (d : Ast.decl) =
  match d.Ast.dpat with
  | Ast.DName x -> x
  | Ast.DUnit -> "()"
  | Ast.DPair (x, y) -> Printf.sprintf "(%s, %s)" x y

let report (r : System.result) value =
  match value with
  | Some v -> Printf.printf "%s : %s = %s\n" r.System.rname r.System.rtype v
  | None -> Printf.printf "%s : %s\n" r.System.rname r.System.rtype

(* Check everything first, then run: a program that does not typecheck should
   not have printed half of its output before saying so. *)
let go (s : System.t) (prog : Ast.program) ~dump_anf ~trace =
  let results = s.System.check prog.Ast.items in
  if not s.System.runs then
    List.iter (fun r -> report r r.System.rvalue) results
  else begin
    let w = Machine.create ~trace () in
    let decls =
      List.filter_map (function Ast.TLet d -> Some d | _ -> None) prog.Ast.items
    in
    let rec drive decls results =
      match (decls, results) with
      | [], _ | _, [] -> ()
      | d :: ds, r :: rs ->
          let block = Anf.block_of_decl d in
          if dump_anf then
            Printf.printf "-- %s in A-normal form\n%s" (name_of_decl d)
              (Core.block_to_string block);
          let v = Machine.run w block in
          (match d.Ast.dpat with
          | Ast.DName x -> Machine.define w x v
          | Ast.DUnit -> ()
          | Ast.DPair (x, y) -> (
              match v with
              | Machine.VPair (a, b) ->
                  Machine.define w x a;
                  Machine.define w y b
              | _ -> ()));
          report r (Some (Machine.show v));
          drive ds rs
    in
    drive decls results
  end

let () =
  let file = ref None and sys = ref None in
  let dump_anf = ref false and trace = ref false in
  let rec args = function
    | [] -> ()
    | ("-s" | "--system") :: name :: rest ->
        sys := Some name;
        args rest
    | "--list" :: _ ->
        list_systems ();
        exit 0
    | "--dump-anf" :: rest ->
        dump_anf := true;
        args rest
    | "--trace" :: rest ->
        trace := true;
        args rest
    | "--dump-vc" :: rest ->
        Smt.dump := true;
        args rest
    | "--dump-infer" :: rest ->
        Hm.trace := true;
        args rest
    | "--smt" :: cmd :: rest ->
        Smt.backend := Smt.External cmd;
        args rest
    | ("-h" | "--help") :: _ ->
        usage ();
        exit 0
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then (
          Printf.eprintf "mink: unknown option %s\n" a;
          exit 2);
        file := Some a;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
  match !file with
  | None ->
      usage ();
      exit 2
  | Some path -> (
      try
        let prog = parse_file path in
        let name =
          match (!sys, prog.Ast.system) with
          | Some s, _ -> s
          | None, Some s -> s
          | None, None ->
              prerr_endline
                "mink: no #system directive and no -s; see --list for the \
                 systems";
              exit 2
        in
        go (find_system name) prog ~dump_anf:!dump_anf ~trace:!trace
      with Loc.Error { loc; where; msg } ->
        flush stdout;
        Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
        exit 1)
