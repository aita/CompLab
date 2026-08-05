(* The compiler's command line.

   It shares everything up to Flat with the interpreter -- the same parser, the
   same inference, the same decision trees, the same closure conversion -- and
   starts where those left off.  By then the program has no modules, no patterns
   and no nested functions, so none of the back end has heard of them. *)

module F = Flat

let usage () =
  print_string
    "usage: skunkllvm [options] file.sk\n\
    \n\
     options:\n\
    \  -o FILE           write the output here (the default is a.out)\n\
    \      --emit-llvm   write LLVM IR instead of an executable\n\
    \  -S                write assembly instead of an executable\n\
    \  -c                write an object file instead of an executable\n\
    \  -O0 -O1 -O2 -O3   how hard LLVM should try (the default is -O2)\n\
    \      --dump-flat   print the A-normal form the module was built from\n\
    \  -h, --help        this\n"

type output = Executable | Llvm_ir | Assembly | Object

let out = ref None
let kind = ref Executable
let level = ref 2
let dump_flat = ref false

let parse ~file source =
  let lexbuf = Lexing.from_string source in
  lexbuf.lex_curr_p <- { lexbuf.lex_curr_p with pos_fname = file };
  try Parser.program Lexer.token lexbuf
  with Parser.Error ->
    let loc = Loc.of_lexing lexbuf.lex_start_p in
    Loc.syntax_error loc "unexpected %s"
      (match Lexing.lexeme lexbuf with "" -> "end of file" | s -> "`" ^ s ^ "`")

(* One compilation unit, as far as Flat.  The globals seen so far are threaded
   through because closure conversion has to know which names not to capture. *)
let to_flat env globals ~file ~source =
  Types.renumber ();
  let decs = parse ~file source in
  let env, items = Elab.program env decs in
  let items = Patmat.program items in
  (match Loc.take_warnings () with
  | [] -> ()
  | ws ->
      flush stdout;
      List.iter (fun (loc, msg) -> Printf.eprintf "%s: warning: %s\n" (Loc.to_string loc) msg) ws;
      flush stderr);
  let names =
    List.filter_map
      (fun (i : Core.item) -> if i.Core.iname = "" then None else Some i.Core.iname)
      items
  in
  let globals = globals @ names in
  (env, globals, Closure.program globals items)

let read path =
  try
    let ch = open_in_bin path in
    let n = in_channel_length ch in
    let s = really_input_string ch n in
    close_in ch;
    s
  with Sys_error m ->
    Printf.eprintf "skunkllvm: %s\n" m;
    exit 2

(* Everything up to the text of the module. *)
let module_text path source =
  Types.reset ();
  Core.reset ();
  (* The basis first.  Its half that is written in SkunkML is compiled exactly
     like the program -- same parser, same inference, same decision trees, same
     back end -- and its top-level bindings run first, silently: nothing prints
     while the prelude is defining `map` and `foldl`. *)
  let env, globals, basis_flat =
    to_flat (Basis.env ()) (Basis.globals ()) ~file:"<basis>" ~source:Basis.prelude
  in
  let _, globals, flat = to_flat env globals ~file:path ~source in
  if !dump_flat then print_string (Flat.program_to_string flat);
  let t = Layout.create () in
  (* The basis has to exist before anything is lowered: a program that mentions
     `print` wants the global that already holds it. *)
  Prelude.register t;
  let seen = Hashtbl.create 64 in
  List.iter (fun g -> Hashtbl.replace seen g ()) globals;
  (* Nothing prints while the basis is defining itself, so its bindings keep
     their globals and lose their labels. *)
  let basis_items =
    Lower.unit_ t seen ~prefix:"basis"
      {
        basis_flat with
        F.items = List.map (fun (i : F.item) -> { i with F.ilabel = None }) basis_flat.F.items;
      }
  in
  let items = Lower.unit_ t seen ~prefix:"main" flat in
  Lower.entry t (basis_items @ items);
  Ir.to_string t.Layout.ir

let compile path source =
  let text = module_text path source in
  let target = Option.value !out ~default:"a.out" in
  (* `--emit-llvm -O0` is the module as this compiler wrote it, and it does not
     need LLVM to produce it.  With a pass level, LLVM has to read it back. *)
  if !kind = Llvm_ir && !level = 0 then
    match !out with
    | None -> print_string text
    | Some f ->
        let ch = open_out_bin f in
        output_string ch text;
        close_out ch
  else begin
    let ll = Emit.write_temp "skunk" ".ll" text in
    (match !kind with
    | Llvm_ir -> (
        match !out with
        | Some f -> Emit.optimised_ir ~ll ~out:f ~level:!level
        | None ->
            let tmp = Filename.temp_file "skunk" ".ll" in
            Emit.optimised_ir ~ll ~out:tmp ~level:!level;
            print_string (read tmp);
            Sys.remove tmp)
    | Assembly -> Emit.assembly ~ll ~out:target ~level:!level
    | Object -> Emit.object_file ~ll ~out:target ~level:!level
    | Executable -> Emit.executable ~ll ~path:target ~level:!level);
    Sys.remove ll
  end

let () =
  let file = ref None in
  let rec args = function
    | [] -> ()
    | "-o" :: f :: rest ->
        out := Some f;
        args rest
    | "--emit-llvm" :: rest ->
        kind := Llvm_ir;
        args rest
    | "-S" :: rest ->
        kind := Assembly;
        args rest
    | "-c" :: rest ->
        kind := Object;
        args rest
    | "--dump-flat" :: rest ->
        dump_flat := true;
        args rest
    | (("-O0" | "-O1" | "-O2" | "-O3") as o) :: rest ->
        level := Char.code o.[2] - Char.code '0';
        args rest
    | ("-h" | "--help") :: _ ->
        usage ();
        exit 0
    | a :: rest ->
        if String.length a > 0 && a.[0] = '-' then begin
          Printf.eprintf "skunkllvm: unknown option %s\n" a;
          exit 2
        end;
        file := Some a;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
  match !file with
  | None ->
      usage ();
      exit 2
  | Some path -> (
      try compile path (read path) with
      | Loc.Error { loc; where; msg } ->
          flush stdout;
          Printf.eprintf "%s: %s: %s\n" (Loc.to_string loc) where msg;
          exit 1
      | Failure msg ->
          flush stdout;
          Printf.eprintf "skunkllvm: %s\n" msg;
          exit 1)
