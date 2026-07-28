let usage =
  "ferretc [options] graph.json\n\n\
  \  -o FILE       write the output to FILE (default: stdout for text, \
   graph.wasm for wasm)\n\
  \  --emit KIND   wasm (default), wat, ir, or spec for the node catalogue\n"

type emit = Wasm | Wat | Ir | Spec

let () =
  let input = ref None and output = ref None and emit = ref Wasm in
  let rec args = function
    | [] -> ()
    | "-o" :: file :: rest ->
        output := Some file;
        args rest
    | "--emit" :: kind :: rest ->
        (match kind with
        | "wasm" -> emit := Wasm
        | "wat" -> emit := Wat
        | "ir" -> emit := Ir
        | "spec" -> emit := Spec
        | _ ->
            prerr_endline ("ferretc: unknown --emit " ^ kind);
            exit 2);
        args rest
    | ("-h" | "--help") :: _ ->
        print_string usage;
        exit 0
    | file :: rest ->
        if !input <> None then (
          prerr_endline "ferretc: more than one input file";
          exit 2);
        input := Some file;
        args rest
  in
  args (List.tl (Array.to_list Sys.argv));
  (* The catalogue is not about any one graph, so it takes no input file. *)
  if !emit = Spec then (
    let text = Yojson.Safe.pretty_to_string (Ferret.Spec.to_json ()) ^ "\n" in
    (match !output with
    | None -> print_string text
    | Some file ->
        let ch = open_out_bin file in
        output_string ch text;
        close_out ch);
    exit 0);
  let path =
    match !input with
    | Some p -> p
    | None ->
        print_string usage;
        exit 2
  in
  let json =
    try Yojson.Safe.from_file path
    with e ->
      Printf.eprintf "ferretc: cannot read %s: %s\n" path (Printexc.to_string e);
      exit 1
  in
  match Ferret.Compile.of_json json with
  | Error errs ->
      List.iter
        (fun (e : Ferret.Graph.error) ->
          match e.node with
          | Some id -> Printf.eprintf "ferretc: %s: %s\n" id e.msg
          | None -> Printf.eprintf "ferretc: %s\n" e.msg)
        errs;
      exit 1
  | Ok out -> (
      let write text =
        match !output with
        | None -> print_string text
        | Some file ->
            let ch = open_out_bin file in
            output_string ch text;
            close_out ch
      in
      match !emit with
      | Spec -> ()
      | Ir -> write out.ir
      | Wat -> write out.wat
      | Wasm ->
          let file =
            match !output with
            | Some f -> f
            | None -> Filename.remove_extension path ^ ".wasm"
          in
          let ch = open_out_bin file in
          output_string ch out.wasm;
          close_out ch;
          Printf.eprintf "ferretc: wrote %s (%d bytes)\n" file
            (String.length out.wasm))
