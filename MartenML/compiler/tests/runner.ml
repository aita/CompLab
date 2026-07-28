(* The golden tests.  Three ways of running the compiler over a program and
   printing what came out, in the shape the .expected files are written in.

     runner riscv  <martenmlc> <runtime.c>   <source>       one program, twice
     runner wasm   <martenmlc> <runtime.wat> <host.mjs> <source>
     runner errors <martenmlc> <source>...                  all must be rejected

   Everything an invocation writes goes into a scratch directory that is thrown
   away afterwards; the pieces are printed in a fixed order at the end so that
   warnings, output, diagnostics and exit status land in the golden file the
   same way whichever back end produced them.

   `Toolchain` does the spawning, and is the same code `martenmlc -run` uses. *)

let read path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

(* Warnings, then what the program printed, then what it complained about, then
   the status if it was not zero.  This shape is the contract with the .expected
   files, and it is why both back ends can share them. *)
let report ~warnings ~out ~err ~status =
  print_string (read warnings);
  print_string (read out);
  print_string (read err);
  if status <> 0 then Printf.printf "exit status: %d\n" status

let compile martenmlc arguments ~stderr =
  if Toolchain.run ~stderr martenmlc arguments <> 0 then begin
    (* The compiler's own message is in the file; put it where it can be seen
       before giving up. *)
    (match stderr with Toolchain.To_file path -> print_string (read path) | _ -> ());
    raise (Toolchain.Error "the compiler rejected a program the tests expect it to accept")
  end

let required target =
  match Toolchain.missing_tool target with
  | Some tool -> raise (Toolchain.Error (tool ^ " is required to run these tests"))
  | None -> ()

(* Every program is built twice: once with the whole register file and once
   with `-nregs 10`, which forces the allocator to spill.  The two builds have
   to agree, so the golden file checks the spiller as well as the program. *)
let riscv martenmlc runtime source =
  Toolchain.with_temp_dir "martenml-test" (fun dir ->
      let f name = Filename.concat dir name in
      compile martenmlc [ "-o"; f "wide.s"; source ] ~stderr:(Toolchain.To_file (f "warnings"));
      compile martenmlc
        [ "-nregs"; "10"; "-o"; f "narrow.s"; source ]
        ~stderr:(Toolchain.To_file (f "ignored"));
      let build which =
        let program =
          Toolchain.assemble ~target:Toolchain.Riscv ~runtime ~compiled:(f (which ^ ".s"))
            ~dir:(f which)
        in
        Toolchain.execute ~target:Toolchain.Riscv ~host:""
          ~stdout:(Toolchain.To_file (f (which ^ ".out")))
          ~stderr:(Toolchain.To_file (f (which ^ ".err")))
          program
      in
      List.iter (fun which -> Sys.mkdir (f which) 0o755) [ "wide"; "narrow" ];
      let wide = build "wide" in
      let narrow = build "narrow" in
      if read (f "wide.out") <> read (f "narrow.out") || wide <> narrow then begin
        print_string "the full-register and 10-register builds disagree:\n";
        Printf.printf "--- 25 registers, exit status %d\n%s" wide (read (f "wide.out"));
        Printf.printf "--- 10 registers, exit status %d\n%s" narrow (read (f "narrow.out"));
        1
      end
      else begin
        report ~warnings:(f "warnings") ~out:(f "wide.out") ~err:(f "wide.err") ~status:wide;
        0
      end)

let wasm martenmlc runtime host source =
  Toolchain.with_temp_dir "martenml-test" (fun dir ->
      let f name = Filename.concat dir name in
      compile martenmlc
        [ "-target"; "wasm"; "-runtime"; runtime; "-o"; f "program.wat"; source ]
        ~stderr:(Toolchain.To_file (f "warnings"));
      let program =
        Toolchain.assemble ~target:Toolchain.Wasm ~runtime ~compiled:(f "program.wat") ~dir
      in
      let status =
        Toolchain.execute ~target:Toolchain.Wasm ~host
          ~stdout:(Toolchain.To_file (f "out"))
          ~stderr:(Toolchain.To_file (f "err"))
          program
      in
      report ~warnings:(f "warnings") ~out:(f "out") ~err:(f "err") ~status;
      0)

(* Every program named must be rejected by the compiler.  The messages are the
   point, so both of its streams go to ours, in order. *)
let errors martenmlc sources =
  List.fold_left
    (fun status source ->
      Printf.printf "--- %s\n" (Filename.basename source);
      let accepted =
        Toolchain.run ~stderr:Toolchain.Onto_stdout martenmlc
          [ "-o"; "/dev/null"; source ]
        = 0
      in
      if accepted then begin
        print_string "!!! the compiler accepted this program\n";
        1
      end
      else status)
    0 sources

let usage () =
  prerr_endline
    "usage: runner riscv <martenmlc> <runtime.c> <source>\n\
    \       runner wasm <martenmlc> <runtime.wat> <host.mjs> <source>\n\
    \       runner errors <martenmlc> <source>...";
  exit 2

let () =
  let status =
    try
      match Array.to_list Sys.argv with
      | _ :: "riscv" :: martenmlc :: runtime :: [ source ] ->
        required Toolchain.Riscv;
        riscv martenmlc runtime source
      | _ :: "wasm" :: martenmlc :: runtime :: host :: [ source ] ->
        required Toolchain.Wasm;
        wasm martenmlc runtime host source
      | _ :: "errors" :: martenmlc :: (_ :: _ as sources) -> errors martenmlc sources
      | _ -> usage ()
    with Toolchain.Error message ->
      flush stdout;
      prerr_endline message;
      1
  in
  exit status
