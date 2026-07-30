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
let nphdr = 2

(* Where the text lands in the file, and so what its address has to be. *)
let text_offset = header_size + (nphdr * phentsize)

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
  u16 b 2 (* ET_EXEC *);
  u16 b 0x3e (* x86-64 *);
  u32 b 1 (* version *);
  u64 b img.entry;
  u64 b header_size (* e_phoff *);
  u64 b 0 (* e_shoff: no section headers.  The kernel does not read them. *);
  u32 b 0 (* e_flags *);
  u16 b header_size;
  u16 b phentsize;
  u16 b nphdr;
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
  phdr ~offset:0 ~vaddr:base ~size:(text_offset + String.length img.text) ~flags:5 (* r-x *);
  phdr ~offset:data_offset ~vaddr:img.data_addr ~size:(String.length img.data) ~flags:6 (* rw- *);
  Buffer.add_string b img.text;
  while Buffer.length b < data_offset do
    u8 b 0
  done;
  Buffer.add_string b img.data;
  let ch = open_out_bin path in
  output_string ch (Buffer.contents b);
  close_out ch;
  Unix.chmod path 0o755
