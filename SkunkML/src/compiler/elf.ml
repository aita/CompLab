(* Writing the executable.

   A static ELF64 with two segments and no dynamic linking: the kernel maps the
   file, jumps to the entry point, and that is the whole of the startup.  There
   is no libc, so everything the program needs from the outside world it asks
   for with a syscall.

   The file is as small as the format allows:

     ELF header          64 bytes, says amd64, says "an executable", and where
                         the entry point is
     2 program headers    56 bytes each: one PT_LOAD for the text, read and
                         execute; one for the data, read and write
     text
     data

   A segment's virtual address has to be congruent to its file offset modulo the
   page size, which is the one arithmetic constraint in here and the reason the
   data segment starts on a fresh page. *)

let page = 0x1000
let base = 0x400000

type image = {
  text : string;
  data : string;
  text_addr : int;
  data_addr : int;
  entry : int;
  (* When linking dynamically: the file offsets and sizes of the interpreter
     path and of the .dynamic array, both of which live in the data segment.
     A segment's address is its file offset plus the base, so one number does
     for both. *)
  dynamic : (int * int * int * int) option; (* interp offset, size, dynamic offset, size *)
}

let u8 b n = Buffer.add_char b (Char.chr (n land 0xff))

let u16 b n =
  u8 b n;
  u8 b (n asr 8)

let u32 b n =
  u16 b n;
  u16 b (n asr 16)

let u64 b n =
  u32 b n;
  u32 b (n asr 32)

let header_size = 64
let phentsize = 56

(* Two segments to be mapped, and three more headers when the dynamic linker has
   to be told things: where the headers are, which loader to use, and where the
   table of everything else is. *)
let nphdr ~dynamic = if dynamic then 5 else 2

(* Where the text lands in the file, and so what its address has to be.  It is
   the same either way, so that a program compiled both ways has the same
   layout apart from the extra headers. *)
let text_offset = header_size + (5 * phentsize)

let layout ~text =
  let text_addr = base + text_offset in
  let data_offset = (text_offset + String.length text + page - 1) / page * page in
  let data_addr = base + data_offset in
  (text_addr, data_addr, data_offset)

let write ~path (img : image) ~data_offset =
  let b = Buffer.create (String.length img.text + String.length img.data + 4096) in
  (* e_ident *)
  Buffer.add_string b "\x7fELF";
  u8 b 2 (* 64-bit *);
  u8 b 1 (* little endian *);
  u8 b 1 (* version *);
  u8 b 0 (* System V *);
  for _ = 1 to 8 do
    u8 b 0
  done;
  let nph = nphdr ~dynamic:(img.dynamic <> None) in
  u16 b 2 (* ET_EXEC *);
  u16 b 0x3e (* x86-64 *);
  u32 b 1 (* version *);
  u64 b img.entry;
  u64 b header_size (* e_phoff *);
  u64 b 0 (* e_shoff: no section headers.  The kernel does not read them. *);
  u32 b 0 (* e_flags *);
  u16 b header_size;
  u16 b phentsize;
  u16 b nph;
  u16 b 0 (* e_shentsize *);
  u16 b 0 (* e_shnum *);
  u16 b 0 (* e_shstrndx *);
  let phdr ~offset ~vaddr ~size ~flags =
    u32 b 1 (* PT_LOAD *);
    u32 b flags;
    u64 b offset;
    u64 b vaddr;
    u64 b vaddr (* p_paddr *);
    u64 b size (* p_filesz *);
    u64 b size (* p_memsz *);
    u64 b page (* p_align *)
  in
  let ptype t = t in
  (match img.dynamic with
  | None -> ()
  | Some (interp_off, interp_size, _, _) ->
      (* PT_PHDR has to come first and describe the headers themselves: the
         loader uses it to work out where the file was mapped. *)
      u32 b 6 (* PT_PHDR *);
      u32 b 4;
      u64 b header_size;
      u64 b (base + header_size);
      u64 b (base + header_size);
      u64 b (nph * phentsize);
      u64 b (nph * phentsize);
      u64 b 8;
      u32 b 3 (* PT_INTERP *);
      u32 b 4;
      u64 b interp_off;
      u64 b (base + interp_off);
      u64 b (base + interp_off);
      u64 b interp_size;
      u64 b interp_size;
      u64 b 1);
  ignore ptype;
  phdr ~offset:0 ~vaddr:base ~size:(text_offset + String.length img.text) ~flags:5 (* r-x *);
  phdr ~offset:data_offset ~vaddr:img.data_addr ~size:(String.length img.data) ~flags:6 (* rw- *);
  (match img.dynamic with
  | None -> ()
  | Some (_, _, dyn_off, dyn_size) ->
      u32 b 2 (* PT_DYNAMIC *);
      u32 b 6 (* rw- *);
      u64 b dyn_off;
      u64 b (base + dyn_off);
      u64 b (base + dyn_off);
      u64 b dyn_size;
      u64 b dyn_size;
      u64 b 8);
  (* Room for five program headers is always reserved, even when only two are
     written, so that the text is at the same offset -- and so at the same
     address -- whichever way the file was linked. *)
  while Buffer.length b < text_offset do
    u8 b 0
  done;
  Buffer.add_string b img.text;
  while Buffer.length b < data_offset do
    u8 b 0
  done;
  Buffer.add_string b img.data;
  let ch = open_out_bin path in
  output_string ch (Buffer.contents b);
  close_out ch;
  Unix.chmod path 0o755
