(* The linker.

   Two sections come in with symbols and holes; one file goes out.  There are
   three steps and no object format in between, because there is only ever one
   translation unit: the compiler assembles everything it needs, including the
   runtime, into a single text section and a single data section.

     1. Give the sections addresses.  `elf.ml` decides where, because the
        constraint is the file format's: a segment's virtual address has to
        agree with its file offset modulo the page size.
     2. Resolve the symbols.  A label's address is its section's address plus
        its offset.
     3. Patch the holes.  Every reference the assembler left behind is
        `S + A - P` for a relative one and `S + A` for an absolute one, where S
        is the symbol, A the addend and P the address of the hole itself.

   That is what a linker is, with everything a real one also has to do -- many
   objects, sections that merge, symbols that are weak or undefined, dynamic
   loading -- absent because nothing here needs it. *)

module A = Asm

let patch (b : Bytes.t) at n width =
  for i = 0 to width - 1 do
    Bytes.set b (at + i) (Char.chr ((n asr (8 * i)) land 0xff))
  done

let link ~path ~(text : A.t) ~(data : A.t) ~entry =
  let text_addr, data_addr, data_offset = Elf.layout ~text:(A.contents text) in
  (* One namespace: a label is in the text or in the data, and nothing is in
     both -- the assembler would have refused a duplicate. *)
  let resolve sym =
    match Hashtbl.find_opt text.A.syms sym with
    | Some off -> text_addr + off
    | None -> (
        match Hashtbl.find_opt data.A.syms sym with
        | Some off -> data_addr + off
        | None -> failwith ("link: undefined symbol " ^ sym))
  in
  let apply (sec : A.t) sec_addr =
    let b = Bytes.of_string (A.contents sec) in
    List.iter
      (fun (r : A.reloc) ->
        let s = resolve r.A.sym in
        match r.A.kind with
        | A.Rel32 ->
            let p = sec_addr + r.A.at in
            patch b r.A.at (s + r.A.addend - p) 4
        | A.Abs64 -> patch b r.A.at (s + r.A.addend) 8)
      sec.A.relocs;
    Bytes.to_string b
  in
  let text_bytes = apply text text_addr and data_bytes = apply data data_addr in
  Elf.write ~path
    {
      Elf.text = text_bytes;
      data = data_bytes;
      text_addr;
      data_addr;
      entry = resolve entry;
    }
    ~data_offset
