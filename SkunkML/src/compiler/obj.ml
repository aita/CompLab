(* Reading an ELF relocatable object, so that the runtime can be C.

   `link.ml` used to take two sections with labels and holes and make a file out
   of them.  That is a linker in the sense that it resolves and patches, but it
   could not accept anything it had not produced itself -- which meant the runtime
   had to be written in the same assembler.  Reading `.o` files is what turns it
   into a linker in the ordinary sense, and it is why `runtime.c` can exist.

   What an object is, for our purposes:

     section headers   named blocks of bytes, with an alignment and flags.  The
                       ones marked SHF_ALLOC are the ones that end up in memory
     .symtab/.strtab   which name is at which offset in which section
     .rela.X           "at this offset in section X, put the address of this
                       symbol, plus this addend, in this form"

   Three things have to happen, and all three are the same three the static path
   already did -- only now the input comes from somebody else.

     1. *Place* each allocated section.  Executable ones go with our text, the
        rest with our data, each at its required alignment.  `.bss` has no bytes
        in the file, so it becomes that many zeros.
     2. *Publish* the symbols.  A defined symbol becomes a label at its section's
        place plus its offset, which puts it in the same table our own labels are
        in -- so generated code calling `skunk_alloc` resolves like anything else,
        and the object's reference to `skunk_program` resolves to the code we
        emitted.
     3. *Translate* the relocations into ours.  There are only five kinds in the
        object, and they are two of ours: PC32 and PLT32 are relative, 64 and 32
        and 32S are absolute.

   Relocations can also name a *section* rather than a symbol -- that is how a
   reference to a string literal in `.rodata` is expressed -- so every placed
   section gets a label of its own to be the target of those. *)

module A = Asm

let u8 s i = Char.code s.[i]
let u16 s i = u8 s i lor (u8 s (i + 1) lsl 8)
let u32 s i = u16 s i lor (u16 s (i + 2) lsl 16)

let u64 s i =
  (* Values in an object are addresses and sizes, never anywhere near 2^62. *)
  u32 s i lor (u32 s (i + 4) lsl 32)

let i32 s i =
  let v = u32 s i in
  if v land 0x8000_0000 <> 0 then v - 0x1_0000_0000 else v

let cstr s i =
  let j = ref i in
  while s.[!j] <> '\000' do
    incr j
  done;
  String.sub s i (!j - i)

type section = {
  index : int;
  name : string;
  stype : int;
  flags : int;
  offset : int;
  size : int;
  align : int;
  link : int;
  info : int;
  entsize : int;
}

let sections obj =
  let shoff = u64 obj 0x28 and shentsize = u16 obj 0x3a and shnum = u16 obj 0x3c in
  let shstrndx = u16 obj 0x3e in
  let raw i =
    let b = shoff + (i * shentsize) in
    {
      index = i;
      name = "";
      stype = u32 obj (b + 4);
      flags = u64 obj (b + 8);
      offset = u64 obj (b + 0x18);
      size = u64 obj (b + 0x20);
      align = max 1 (u64 obj (b + 0x30));
      link = u32 obj (b + 0x28);
      info = u32 obj (b + 0x2c);
      entsize = u64 obj (b + 0x38);
    }
  in
  let names = raw shstrndx in
  List.init shnum (fun i ->
      let s = raw i in
      { s with name = cstr obj (names.offset + u32 obj (shoff + (i * shentsize))) })

let sh_alloc = 0x2
let sh_execinstr = 0x4
let sht_nobits = 8
let sht_rela = 4
let sht_symtab = 2

(* Where a symbol's name comes from, and what section it is defined in. *)
type sym = { sname : string; sshndx : int; svalue : int; sinfo : int }

let symbols obj secs =
  match List.find_opt (fun s -> s.stype = sht_symtab) secs with
  | None -> [||]
  | Some tab ->
      let strs = List.find (fun s -> s.index = tab.link) secs in
      let n = tab.size / tab.entsize in
      Array.init n (fun i ->
          let b = tab.offset + (i * tab.entsize) in
          {
            sname = cstr obj (strs.offset + u32 obj b);
            sinfo = u8 obj (b + 4);
            sshndx = u16 obj (b + 6);
            svalue = u64 obj (b + 8);
          })

let section_label i = Printf.sprintf "objsec_%d" i

(* Place the object into our two sections, and return the relocations it wants,
   already in our form. *)
let load ~(text : A.t) ~(data : A.t) (obj : string) =
  let secs = sections obj in
  let syms = symbols obj secs in
  let placed = Hashtbl.create 16 in
  (* Which of our sections a section of theirs belongs in, and where it landed. *)
  List.iter
    (fun s ->
      if s.flags land sh_alloc <> 0 && s.size > 0 then begin
        let into = if s.flags land sh_execinstr <> 0 then text else data in
        A.align into (min 16 s.align);
        let at = A.here into in
        A.label into (section_label s.index);
        if s.stype = sht_nobits then A.zeros into s.size
        else A.ascii into (String.sub obj s.offset s.size);
        Hashtbl.replace placed s.index (into, at)
      end)
    secs;
  (* Every defined symbol becomes a label of ours, at its section's place plus
     its own offset.  Locals are published too, under a name nothing else can
     collide with, because a relocation may name one. *)
  Array.iteri
    (fun i (sy : sym) ->
      match Hashtbl.find_opt placed sy.sshndx with
      | None -> ()
      | Some (into, at) ->
          let binding = sy.sinfo lsr 4 in
          let name =
            if sy.sname = "" then section_label sy.sshndx
            else if binding = 0 then Printf.sprintf "objlocal_%d_%s" i sy.sname
            else sy.sname
          in
          if not (Hashtbl.mem into.A.syms name) then
            Hashtbl.replace into.A.syms name (at + sy.svalue))
    syms;
  (* And the relocations.  A relocation against a local or section symbol has to
     name the same label we just published for it. *)
  let target (sy : sym) =
    let binding = sy.sinfo lsr 4 and stype = sy.sinfo land 0xf in
    if stype = 3 (* STT_SECTION *) || sy.sname = "" then (section_label sy.sshndx, 0)
    else if binding = 0 && Hashtbl.mem placed sy.sshndx then
      let i = ref 0 in
      Array.iteri (fun k s -> if s == sy then i := k) syms;
      (Printf.sprintf "objlocal_%d_%s" !i sy.sname, 0)
    else (sy.sname, 0)
  in
  List.iter
    (fun s ->
      if s.stype = sht_rela then
        match Hashtbl.find_opt placed s.info with
        | None -> ()
        | Some (into, at) ->
            let n = s.size / s.entsize in
            for k = 0 to n - 1 do
              let b = s.offset + (k * s.entsize) in
              let r_offset = u64 obj b in
              let r_type = u32 obj (b + 8) in
              let r_sym = u32 obj (b + 12) in
              let addend = i32 obj (b + 16) in
              let sy = syms.(r_sym) in
              let name, extra = target sy in
              let addend = addend + extra + if (sy.sinfo land 0xf) = 3 then 0 else 0 in
              let kind =
                match r_type with
                | 2 (* PC32 *) | 4 (* PLT32 *) -> A.Rel32
                | 1 (* 64 *) -> A.Abs64
                | 10 (* 32 *) | 11 (* 32S *) -> A.Abs32
                | t -> failwith (Printf.sprintf "obj: relocation type %d is not handled" t)
              in
              into.A.relocs <-
                { A.at = at + r_offset; kind; sym = name; addend } :: into.A.relocs
            done)
    secs
