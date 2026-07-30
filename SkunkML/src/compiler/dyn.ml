(* Dynamic linking, without giving up our own linker.

   The static path ([14章](../doc/14-elf.md)) writes an ELF with two segments and
   nothing else: the kernel maps it and jumps in.  To call into libc there has to
   be a third party in the room -- the dynamic linker -- and the way to invite it
   is to write down, in the file, everything it needs to do its job.  So this
   file emits the tables `ld.so` reads, and `elf.ml` grows the program headers
   that point at them.

     .interp     which dynamic linker.  A PT_INTERP segment holding a path
     .dynstr     every name, as bytes: the library's, and each symbol's
     .dynsym     one entry per symbol we want, all undefined
     .hash       what *we* export, which is nothing -- but the table has to
                 exist for `ld.so` to look at
     .rela.dyn   "put the address of this symbol in this word"
     .dynamic    the array of (tag, value) that points at all of the above

   There is no PLT and no lazy binding.  A PLT exists to make the first call to a
   function cheap and every later one cheaper; getting there means a `.got.plt`
   with three reserved words, a stub per function, DT_PLTGOT, DT_JMPREL, and
   `ld.so` writing into the stubs as it goes.  The alternative is one word per
   function with an `R_X86_64_GLOB_DAT` relocation on it, filled in before the
   program starts, and a call through that word.  That is what `-z now` does to a
   PLT anyway, and it is a fraction of the machinery.

   Everything here goes in the data segment.  Convention puts the read-only
   tables with the text, but `ld.so` only reads them, the data segment is
   readable, and one place is simpler than two. *)

module A = Asm

let interp = "/lib64/ld-linux-x86-64.so.2"
let library = "libc.so.6"

(* The functions the runtime calls when it is linked this way.  Each one gets a
   word to be filled in, and the runtime calls through it. *)
let externs = [ "calloc"; "write"; "exit" ]

let slot name = "got_" ^ name

(* Tags, from the ELF specification. *)
let dt_null = 0
let dt_needed = 1
let dt_hash = 4
let dt_strtab = 5
let dt_symtab = 6
let dt_rela = 7
let dt_relasz = 8
let dt_relaent = 9
let dt_strsz = 10
let dt_syment = 11
let r_x86_64_glob_dat = 6

(* The string table, and where each name starts in it.  Index 0 is the empty
   string, which is what a symbol with no name points at. *)
let strings () =
  let buf = Buffer.create 128 in
  Buffer.add_char buf '\000';
  let at = Hashtbl.create 8 in
  List.iter
    (fun s ->
      Hashtbl.replace at s (Buffer.length buf);
      Buffer.add_string buf s;
      Buffer.add_char buf '\000')
    (library :: externs);
  (Buffer.contents buf, at)

let write st =
  let strtab, at = strings () in
  let nsyms = 1 + List.length externs in
  A.align st 8;
  A.label st "skunk_interp";
  A.ascii st interp;
  A.zeros st 1;
  A.align st 8;
  A.label st "skunk_dynstr";
  A.ascii st strtab;
  A.align st 8;
  (* .dynsym.  Every one of ours is undefined and global: a name and nothing
     else, which is exactly the request "somebody else please provide this". *)
  A.label st "skunk_dynsym";
  let sym ~name ~info =
    A.dd st name (* st_name *);
    A.db st info (* st_info: (STB_GLOBAL << 4) | STT_NOTYPE *);
    A.db st 0 (* st_other *);
    A.dw st 0 (* st_shndx: SHN_UNDEF *);
    A.dq st 0 (* st_value *);
    A.dq st 0 (* st_size *)
  in
  sym ~name:0 ~info:0;
  List.iter (fun e -> sym ~name:(Hashtbl.find at e) ~info:0x10) externs;
  A.align st 8;
  (* .hash, for the symbols this file exports.  It exports none, so one empty
     bucket is the whole table -- but a missing table and an empty one are not
     the same thing to every loader, and an empty one costs three words. *)
  A.label st "skunk_hash";
  A.dd st 1 (* nbucket *);
  A.dd st nsyms (* nchain *);
  A.dd st 0 (* bucket[0]: nothing *);
  for _ = 1 to nsyms do
    A.dd st 0
  done;
  A.align st 8;
  (* .rela.dyn.  One entry per word to fill in.  The address is a label in this
     same section, so it is our own linker that resolves it and the dynamic
     linker that uses it. *)
  A.label st "skunk_rela";
  List.iteri
    (fun i e ->
      A.dq_sym st (slot e) (* r_offset *);
      A.dq st (((i + 1) * 0x1_0000_0000) + r_x86_64_glob_dat) (* r_info *);
      A.dq st 0 (* r_addend *))
    externs;
  A.label st "skunk_rela_end";
  A.align st 8;
  (* The words themselves. *)
  List.iter
    (fun e ->
      A.label st (slot e);
      A.dq st 0)
    externs;
  A.align st 8;
  (* .dynamic.  Anything that is an address is a label, so the two linkers do
     one half of the work each. *)
  A.label st "skunk_dynamic";
  let entry tag v =
    A.dq st tag;
    A.dq st v
  in
  let entry_sym tag s =
    A.dq st tag;
    A.dq_sym st s
  in
  entry dt_needed (Hashtbl.find at library);
  entry_sym dt_strtab "skunk_dynstr";
  entry dt_strsz (String.length strtab);
  entry_sym dt_symtab "skunk_dynsym";
  entry dt_syment 24;
  entry_sym dt_hash "skunk_hash";
  entry_sym dt_rela "skunk_rela";
  entry dt_relasz (24 * List.length externs);
  entry dt_relaent 24;
  entry dt_null 0;
  A.label st "skunk_dynamic_end"
