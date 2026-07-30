(* The runtime, in amd64.

   There is no libc to link against -- `link.ml` is the only linker and it does
   not read object files -- so everything the compiled program needs from
   outside is in here, written in the same instruction set the code generator
   emits and assembled by the same assembler.  Three syscalls are the whole of
   the outside world: `mmap` for the heap, `write` for output, `exit` at the
   end.

   The division of labour with generated code is the same one the book
   describes: the code generator only has to know how to move words, do tagged
   arithmetic and jump, and anything that needs a loop or a walk over the heap
   is a call to a routine here.

   The value representation, which the two sides have to agree on:

     an integer   2n + 1              tagged, so the low bit says "not a pointer"
     a block      a pointer, 8-aligned, whose word -1 is a descriptor pointer

   A descriptor is static, emitted by the compiler, and says what the block is:

     0   kind      0 record  1 constructor  2 string  3 closure  4 array  5 ref
     8   nfields   how many words follow (strings and arrays carry a length word)
     16  con       the constructor's name as a string block, or 0
     24  labels    an array of string blocks, one per field, or 0 for a tuple
     32  list      0 ordinary, 1 nil, 2 cons
     40  tag       which constructor of its datatype this is

   The last two words are the ones the C version did not have.  Printing a list
   as `[1, 2, 3]` is a statement about one particular datatype, and the compiler
   is where that datatype is known, so the descriptor says so outright instead
   of the runtime comparing constructor names at every step.  The tag is there
   for the generated code rather than for the runtime: a `case` over a datatype
   compares tags, and comparing a small integer is what makes a jump table
   possible later.

   A string block is [length][bytes...][NUL], with the value pointing at the
   length word.  The NUL is not counted; it is there so that a string can be
   handed to a syscall without copying.

   Two things the C version did that are gone: `@` and the array/list
   conversions are written in SkunkML in the basis now, because they were only
   in C to get at the nil and cons descriptors, and being handed three
   descriptors is a worse interface than just writing the loop in the source
   language. *)

module M = Mach
module A = Asm

(* ---- a small assembly notation ------------------------------------------- *)

(* Enough to write a few hundred instructions without the noise of a
   constructor per line.  [Br] and [Jump] are separate from [I] because a
   branch is a terminator in [Mach] and this file is one long stream of
   instructions, not a control-flow graph. *)
type item =
  | L of string
  | I of M.instr
  | Jump of string
  | Br of string * string
  | Ret
  | Cl of string (* call *)

let emit st items =
  List.iter
    (function
      | L n -> A.label st n
      | I i -> A.instr st i
      | Jump l -> A.jmp st l
      | Br (c, l) -> A.jcc st c l
      | Ret -> A.ret st
      | Cl s -> A.instr st (M.Call s))
    items

let rax = M.R 0
let rcx = M.R 1
let rdx = M.R 2
let rsi = M.R 3
let rdi = M.R 4
let r8 = M.R 5
let r9 = M.R 6
let rbx = M.R 8
let r12 = M.R 9
let r13 = M.R 10
let r14 = M.R 11
let r11 = M.R 7
let r15 = M.R 12
let r10 = M.R 13
let rsp = M.R 14
let o r = M.Reg r
let imm n = M.Imm n
let mem ?base ?index ?(scale = 1) ?(disp = 0) ?sym () = M.Mem { base; index; scale; disp; sym }

(* A global, named rip-relatively, and a field of a block. *)
let glob name = mem ~sym:name ()
let at ?(disp = 0) r = mem ~base:r ~disp ()
let idx ?(disp = 0) base index = mem ~base ~index ~scale:8 ~disp ()
let byte_at ?(disp = 0) base index = mem ~base ~index ~scale:1 ~disp ()
let mov d s = I (M.Mov (d, s))
let movr d s = mov (o d) (o s)
let movi d n = mov (o d) (imm n)
let load d s = mov (o d) s
let store d s = mov d (o s)
let lea d s = I (M.Lea (d, s))
let alu op d s = I (M.Alu (op, o d, s))
let add d s = alu "add" d s
let sub d s = alu "sub" d s
let cmp a b = I (M.Cmp (o a, b))
let sar d n = I (M.Sar (o d, n))
let shl d n = I (M.Shl (o d, n))
let neg d = I (M.Neg (o d))
let push r = I (M.Push (o r))
let pop r = I (M.Pop (o r))
let syscall = I M.Syscall
let cqo = I M.Cqo
let idiv r = I (M.Idiv r)
let loadb d s = I (M.Loadb (d, s))
let storeb d s = I (M.Storeb (d, s))
let movsb = I M.RepMovsb
let tag d = [ shl d 1; alu "or" d (imm 1) ]

(* ---- the layout both sides agree on -------------------------------------- *)

let d_kind = 0
let d_nfields = 8
let d_con = 16
let d_labels = 24
let d_list = 32
let d_tag = 40
let k_record = 0
let k_con = 1
let k_string = 2
let k_closure = 3
let k_array = 4
let k_ref = 5
let k_free = 6
let out_size = 4096

(* String literals the runtime itself needs.  They are interned so that the
   same message emitted from two places is one block. *)
let literals : (string, string) Hashtbl.t = Hashtbl.create 64
let lit_order = ref []

let lit s =
  match Hashtbl.find_opt literals s with
  | Some name -> name
  | None ->
      let name = Printf.sprintf "rt_lit_%d" (Hashtbl.length literals) in
      Hashtbl.replace literals s name;
      lit_order := (name, s) :: !lit_order;
      name

(* `bool` is an ordinary datatype in this language -- `datatype bool = false |
   true` -- so a comparison has to produce one of its two nullary constructors,
   not a tagged 0 or 1.  Nullary constructors are static blocks, and these two
   live here rather than being emitted per program, so that the code generator
   uses these labels when it needs `true` or `false`. *)
let bool_true = "skunk_true"
let bool_false = "skunk_false"

(* The idiom that occurs on nearly every line of the printer: name a literal
   and hand it to a routine that takes a string block. *)
let say s = [ lea rdi (glob (lit s)); Cl "rt_outs" ]
let complain s = [ lea rdi (glob (lit s)); Cl "skunk_fail" ]

(* ---- the two ways of reaching the outside ---------------------------------- *)

(* Freestanding, the runtime asks the kernel directly.  Linked against libc, it
   asks libc -- through a word the dynamic linker filled in, because there is no
   PLT ([dyn.ml](dyn.ml)).  The argument registers are the same either way, which
   is why only the last two instructions differ: a syscall wants its number in
   rax, a call wants an address. *)
let write_out dyn =
  if dyn then [ load rax (glob (Dyn.slot "write")); I (M.CallReg rax) ]
  else [ movi rax 1; syscall ]

let leave dyn code =
  if dyn then [ movi rdi code; load rax (glob (Dyn.slot "exit")); I (M.CallReg rax) ]
  else [ movi rax 60; movi rdi code; syscall ]

(* ---- output -------------------------------------------------------------- *)

(* stdout is buffered here rather than in the kernel, because `show` writes a
   byte at a time and a syscall per byte would be absurd.  Anything that is
   about to write to stderr flushes first, so the two streams stay in the order
   they were produced. *)
let output dyn =
  [
    L "rt_flush";
    load rax (glob "skunk_outlen");
    cmp rax (imm 0);
    Br ("e", "rt_flush.done");
    movr rdx rax;
    lea rsi (glob "skunk_outbuf");
    movi rdi 1;
  ]
  @ write_out dyn
  @ [
    movi rax 0;
    store (glob "skunk_outlen") rax;
    L "rt_flush.done";
    Ret;
    (* out(rdi = bytes, rsi = count) *)
    L "rt_out";
    push rbx;
    push r12;
    movr rbx rdi;
    movr r12 rsi;
    cmp r12 (imm 0);
    Br ("le", "rt_out.done");
    L "rt_out.loop";
    (* n = min(left, space); the buffer is flushed the moment it fills, so
       there is always room for at least one byte here. *)
    movi rax out_size;
    load rcx (glob "skunk_outlen");
    sub rax (o rcx);
    movr rdx r12;
    cmp rdx (o rax);
    Br ("le", "rt_out.have");
    movr rdx rax;
    L "rt_out.have";
    lea rdi (glob "skunk_outbuf");
    add rdi (o rcx);
    movr rsi rbx;
    movr rcx rdx;
    movsb;
    load rcx (glob "skunk_outlen");
    add rcx (o rdx);
    store (glob "skunk_outlen") rcx;
    add rbx (o rdx);
    sub r12 (o rdx);
    cmp rcx (imm out_size);
    Br ("ne", "rt_out.more");
    Cl "rt_flush";
    L "rt_out.more";
    cmp r12 (imm 0);
    Br ("g", "rt_out.loop");
    L "rt_out.done";
    pop r12;
    pop rbx;
    Ret;
    (* outs(rdi = string block) *)
    L "rt_outs";
    load rsi (at rdi);
    add rdi (imm 8);
    Jump "rt_out";
    (* errout(rdi = bytes, rsi = count): stderr, after flushing stdout, so that
       the two streams stay in the order they were produced *)
    L "rt_errout";
    push rbx;
    push r12;
    movr rbx rdi;
    movr r12 rsi;
    Cl "rt_flush";
    movr rdx r12;
    movr rsi rbx;
    movi rdi 2;
  ]
  @ write_out dyn
  @ [
    pop r12;
    pop rbx;
    Ret;
    (* errs(rdi = string block) *)
    L "rt_errs";
    load rsi (at rdi);
    add rdi (imm 8);
    Jump "rt_errout";
  ]

(* ---- the heap ------------------------------------------------------------ *)

(* One anonymous mapping holds everything the collector needs.  The sizes are
   fixed at start-up: the heap does not grow, because growing it would mean
   growing the two maps beside it and there is nothing in the design that wants
   that badly.  Virtual address space is free -- only the pages actually touched
   become resident -- so the maps and the mark stack are generously sized rather
   than cleverly sized.

     0                     the heap
     heap_bytes            starts: one byte per heap word
     + map_bytes           marks:  one byte per heap word
     + map_bytes           the mark stack

   A byte per word rather than a bit per word is a deliberate trade.  A bit map
   is eight times smaller and needs a variable shift to address; a byte map is a
   single load or store with no arithmetic beyond the index, and the eight times
   is virtual. *)

let heap_bytes = 1 lsl 26
let heap_words = heap_bytes / 8
let map_bytes = heap_words
let mstack_bytes = heap_words / 2 * 8

let heap dyn =
  [ L "rt_heap_init" ]
  @ (if dyn then
       (* calloc rather than malloc: the two maps have to start as zeros, and
          for a request this size glibc goes to the kernel and gets that for
          free -- the same pages the freestanding path asks for itself. *)
       [
         movi rdi 1;
         movi rsi (heap_bytes + (2 * map_bytes) + mstack_bytes);
         load rax (glob (Dyn.slot "calloc"));
         I (M.CallReg rax);
       ]
     else
       [
         movi rax 9 (* mmap *);
         movi rdi 0 (* let the kernel choose *);
         movi rsi (heap_bytes + (2 * map_bytes) + mstack_bytes);
         movi rdx 3 (* PROT_READ | PROT_WRITE *);
         movi r10 0x22 (* MAP_PRIVATE | MAP_ANONYMOUS *);
         movi r8 (-1);
         movi r9 0;
         syscall;
       ])
  @ [
    cmp rax (imm 0);
    Br ("le", "rt_heap_init.fail");
    store (glob "skunk_heap_start") rax;
    store (glob "skunk_cursor") rax;
    movr rdx rax;
    add rdx (imm heap_bytes);
    store (glob "skunk_heap_end") rdx;
    store (glob "skunk_starts") rdx;
    add rdx (imm map_bytes);
    store (glob "skunk_marks") rdx;
    add rdx (imm map_bytes);
    store (glob "skunk_mstack") rdx;
    (* One free block covering the whole heap. *)
    lea rdx (glob "skunk_free_desc");
    store (at rax) rdx;
    movi rdx heap_words;
    store (at ~disp:8 rax) rdx;
    Ret;
    L "rt_heap_init.fail";
  ]
  @ complain "cannot map the heap"
  @ [
      (* block_words(rdi = a block's header) -> rax, always even.
         Every walk over the heap needs this, and the descriptor is not quite
         enough on its own: a string and an array carry their own length, so
         their size is in the block rather than in the shared descriptor. *)
      L "rt_block_words";
      load rdx (at rdi);
      lea rax (glob "skunk_free_desc");
      cmp rdx (o rax);
      Br ("ne", "rt_block_words.live");
      load rax (at ~disp:8 rdi);
      Ret;
      L "rt_block_words.live";
      load rcx (at ~disp:d_kind rdx);
      cmp rcx (imm k_string);
      Br ("e", "rt_block_words.string");
      cmp rcx (imm k_array);
      Br ("e", "rt_block_words.array");
      load rax (at ~disp:d_nfields rdx);
      add rax (imm 1);
      Jump "rt_block_words.round";
      L "rt_block_words.string";
      load rax (at ~disp:8 rdi);
      add rax (imm 8);
      sar rax 3;
      add rax (imm 2);
      Jump "rt_block_words.round";
      L "rt_block_words.array";
      load rax (at ~disp:8 rdi);
      add rax (imm 2);
      L "rt_block_words.round";
      (* Every block is an even number of words, so that a gap is never one word
         long -- a free block has to hold a marker and a size. *)
      add rax (imm 1);
      alu "and" rax (imm (-2));
      Ret;
      (* find(rdi = words wanted) -> rax = a header, or 0.
         Next-fit: walk on from where the last allocation stopped, merging
         adjacent free blocks as it goes.  Sweeping does not build a free list or
         coalesce anything; both happen here, lazily, only where allocation
         actually looks. *)
      L "rt_find";
      push rbx;
      push r12;
      push r13;
      push r14;
      movr rbx rdi;
      load r12 (glob "skunk_cursor");
      load r13 (glob "skunk_heap_end");
      lea r14 (glob "skunk_free_desc");
      L "rt_find.loop";
      cmp r12 (o r13);
      Br ("ge", "rt_find.none");
      load rax (at r12);
      cmp rax (o r14);
      Br ("e", "rt_find.free");
      movr rdi r12;
      Cl "rt_block_words";
      shl rax 3;
      add r12 (o rax);
      Jump "rt_find.loop";
      L "rt_find.free";
      load rcx (at ~disp:8 r12);
      L "rt_find.merge";
      movr rax rcx;
      shl rax 3;
      movr rdx r12;
      add rdx (o rax);
      cmp rdx (o r13);
      Br ("ge", "rt_find.merged");
      load rax (at rdx);
      cmp rax (o r14);
      Br ("ne", "rt_find.merged");
      load rax (at ~disp:8 rdx);
      add rcx (o rax);
      store (at ~disp:8 r12) rcx;
      Jump "rt_find.merge";
      L "rt_find.merged";
      cmp rcx (o rbx);
      Br ("l", "rt_find.skip");
      (* Carve.  The remainder is even, because everything here is, so it is
         either nothing or big enough to be a free block of its own. *)
      movr rax rbx;
      shl rax 3;
      movr rdx r12;
      add rdx (o rax);
      movr r8 rcx;
      sub r8 (o rbx);
      cmp r8 (imm 0);
      Br ("e", "rt_find.exact");
      store (at rdx) r14;
      store (at ~disp:8 rdx) r8;
      L "rt_find.exact";
      store (glob "skunk_cursor") rdx;
      movr rax r12;
      pop r14;
      pop r13;
      pop r12;
      pop rbx;
      Ret;
      L "rt_find.skip";
      movr rax rcx;
      shl rax 3;
      add r12 (o rax);
      Jump "rt_find.loop";
      L "rt_find.none";
      movi rax 0;
      pop r14;
      pop r13;
      pop r12;
      pop rbx;
      Ret;
      (* alloc(rdi = descriptor, rsi = words after the header) -> rax *)
      L "skunk_alloc";
      push rbx;
      push r12;
      movr rbx rdi;
      movr r12 rsi;
      add r12 (imm 2);
      alu "and" r12 (imm (-2));
      movr rdi r12;
      Cl "rt_find";
      cmp rax (imm 0);
      Br ("ne", "skunk_alloc.got");
      Cl "rt_collect";
      movr rdi r12;
      Cl "rt_find";
      cmp rax (imm 0);
      Br ("e", "skunk_alloc.full");
      L "skunk_alloc.got";
      store (at rax) rbx;
      add rax (imm 8);
      (* Record that a block starts here.  This one byte is what makes a
         conservative scan safe: an address that is not a block's start is not a
         pointer, whatever it looks like. *)
      movr rcx rax;
      load rdx (glob "skunk_heap_start");
      sub rcx (o rdx);
      sar rcx 3;
      load rdx (glob "skunk_starts");
      movi r8 1;
      storeb (byte_at rdx rcx) r8;
      pop r12;
      pop rbx;
      Ret;
      L "skunk_alloc.full";
    ]
  @ complain "out of memory"

(* ---- the collector ------------------------------------------------------- *)

(* Mark and sweep, with conservative roots.

   The problem a collector has to solve first is *what is a root*.  Precise
   answers are expensive: either the compiler emits a map of the live registers
   and frame slots at every allocation site, or the generated code maintains a
   shadow stack.  The cheap answer is to look at every word of the stack and the
   data section and ask "could this be a pointer?" -- and the reason it is safe
   here is that nothing moves.  A word that looks like a pointer but is not one
   keeps an object alive that could have been freed; it never breaks anything.

   Two things make the guess good.  An integer is 2n + 1, so an integer can
   never be mistaken for a pointer.  And the starts map says where blocks
   actually begin, so a word that lands in the heap but not on a block's start
   is rejected outright rather than followed into nonsense.

   The registers are roots too.  The allocator's caller may be holding a pointer
   in a callee-saved register -- register allocation puts anything live across a
   call there or in a frame slot ([13章](../doc/13-regalloc.md)) -- so the
   collector pushes all of them and lets the stack scan find them.

   Partly built objects are safe for the same reason nothing else has to be
   careful: a recursive group of closures is allocated before its captures are
   filled in, so tracing one can read whatever the free block used to hold.  It
   is checked against the starts map like anything else. *)
let collector =
  [
    (* mark(rdi = a candidate) *)
    L "rt_mark";
    movr rax rdi;
    alu "and" rax (imm 7);
    cmp rax (imm 0);
    Br ("ne", "rt_mark.no");
    load rcx (glob "skunk_heap_start");
    cmp rdi (o rcx);
    Br ("le", "rt_mark.no");
    load rdx (glob "skunk_heap_end");
    cmp rdi (o rdx);
    Br ("ge", "rt_mark.no");
    movr rax rdi;
    sub rax (o rcx);
    sar rax 3;
    load rcx (glob "skunk_starts");
    loadb rdx (byte_at rcx rax);
    cmp rdx (imm 0);
    Br ("e", "rt_mark.no");
    load rcx (glob "skunk_marks");
    loadb rdx (byte_at rcx rax);
    cmp rdx (imm 0);
    Br ("ne", "rt_mark.no");
    movi rdx 1;
    storeb (byte_at rcx rax) rdx;
    load rcx (glob "skunk_mstack");
    load rdx (glob "skunk_mtop");
    store (idx rcx rdx) rdi;
    add rdx (imm 1);
    store (glob "skunk_mtop") rdx;
    L "rt_mark.no";
    Ret;
    (* scan(rdi = from, rsi = to): every word, conservatively *)
    L "rt_scan";
    push rbx;
    push r12;
    movr rbx rdi;
    movr r12 rsi;
    L "rt_scan.loop";
    cmp rbx (o r12);
    Br ("ge", "rt_scan.done");
    load rdi (at rbx);
    Cl "rt_mark";
    add rbx (imm 8);
    Jump "rt_scan.loop";
    L "rt_scan.done";
    pop r12;
    pop rbx;
    Ret;
    (* trace(rdi = a marked value): mark what it points at.
       Which words are pointers is exactly what the descriptor says.  Three
       kinds have a word that is not a value: a string's length, an array's
       length, and a closure's code address -- and that last one matters,
       because a code address is 8-aligned and would otherwise be followed. *)
    L "rt_trace";
    push rbx;
    push r12;
    push r13;
    push r14;
    movr rbx rdi;
    load r12 (at ~disp:(-8) rbx);
    load rax (at ~disp:d_kind r12);
    cmp rax (imm k_string);
    Br ("e", "rt_trace.done");
    cmp rax (imm k_array);
    Br ("e", "rt_trace.array");
    cmp rax (imm k_closure);
    Br ("e", "rt_trace.closure");
    load r13 (at ~disp:d_nfields r12);
    movi r14 0;
    Jump "rt_trace.field";
    L "rt_trace.closure";
    load r13 (at ~disp:d_nfields r12);
    movi r14 1;
    Jump "rt_trace.field";
    L "rt_trace.array";
    load r13 (at rbx);
    add r13 (imm 1);
    movi r14 1;
    L "rt_trace.field";
    cmp r14 (o r13);
    Br ("ge", "rt_trace.done");
    load rdi (idx rbx r14);
    Cl "rt_mark";
    add r14 (imm 1);
    Jump "rt_trace.field";
    L "rt_trace.done";
    pop r14;
    pop r13;
    pop r12;
    pop rbx;
    Ret;
    (* The mark stack has room for one entry per smallest possible block, so it
       cannot overflow and there is no overflow path to get wrong. *)
    L "rt_drain";
    load rdx (glob "skunk_mtop");
    cmp rdx (imm 0);
    Br ("le", "rt_drain.done");
    sub rdx (imm 1);
    store (glob "skunk_mtop") rdx;
    load rcx (glob "skunk_mstack");
    load rdi (idx rcx rdx);
    Cl "rt_trace";
    Jump "rt_drain";
    L "rt_drain.done";
    Ret;
    (* One linear pass.  A live block loses its mark and stays; a dead one loses
       its start byte and becomes a free block.  Adjacent free blocks are left
       adjacent -- merging them is the allocator's job, and it only does it where
       it looks. *)
    L "rt_sweep";
    push rbx;
    push r12;
    push r13;
    load rbx (glob "skunk_heap_start");
    load r12 (glob "skunk_heap_end");
    lea r13 (glob "skunk_free_desc");
    L "rt_sweep.loop";
    cmp rbx (o r12);
    Br ("ge", "rt_sweep.done");
    load rax (at rbx);
    cmp rax (o r13);
    Br ("e", "rt_sweep.free");
    movr rdi rbx;
    Cl "rt_block_words";
    push rax;
    movr rax rbx;
    add rax (imm 8);
    load rcx (glob "skunk_heap_start");
    sub rax (o rcx);
    sar rax 3;
    load rcx (glob "skunk_marks");
    loadb rdx (byte_at rcx rax);
    cmp rdx (imm 0);
    Br ("e", "rt_sweep.dead");
    movi rdx 0;
    storeb (byte_at rcx rax) rdx;
    pop rax;
    Jump "rt_sweep.next";
    L "rt_sweep.dead";
    load rcx (glob "skunk_starts");
    movi rdx 0;
    storeb (byte_at rcx rax) rdx;
    pop rax;
    store (at rbx) r13;
    store (at ~disp:8 rbx) rax;
    L "rt_sweep.next";
    shl rax 3;
    add rbx (o rax);
    Jump "rt_sweep.loop";
    L "rt_sweep.free";
    load rax (at ~disp:8 rbx);
    shl rax 3;
    add rbx (o rax);
    Jump "rt_sweep.loop";
    L "rt_sweep.done";
    load rax (glob "skunk_heap_start");
    store (glob "skunk_cursor") rax;
    pop r13;
    pop r12;
    pop rbx;
    Ret;
    L "rt_collect";
    (* Every register, so that the stack scan sees them. *)
    push rax;
    push rcx;
    push rdx;
    push rsi;
    push rdi;
    push r8;
    push r9;
    push r10;
    push r11;
    push rbx;
    push r12;
    push r13;
    push r14;
    push r15;
    lea rdi (glob "skunk_data_start");
    lea rsi (glob "skunk_data_end");
    Cl "rt_scan";
    movr rdi rsp;
    load rsi (glob "skunk_stack_top");
    Cl "rt_scan";
    Cl "rt_drain";
    Cl "rt_sweep";
    pop r15;
    pop r14;
    pop r13;
    pop r12;
    pop rbx;
    pop r11;
    pop r10;
    pop r9;
    pop r8;
    pop rdi;
    pop rsi;
    pop rdx;
    pop rcx;
    pop rax;
    Ret;
  ]

(* ---- failing ------------------------------------------------------------- *)

(* The two ways a program stops early.  Neither returns, so there is no
   epilogue and no need to restore anything. *)
let failures dyn =
  [ L "skunk_fail"; push rbx; movr rbx rdi ]
  @ [ lea rdi (glob (lit "?: runtime error: ")); Cl "rt_errs" ]
  @ [ movr rdi rbx; Cl "rt_errs" ]
  @ [ lea rdi (glob (lit "\n")); Cl "rt_errs" ]
  @ leave dyn 1
  (* An out-of-range index, with the numbers in it, because "index 5 out of
     0..1" is the difference between a message and a shrug. *)
  @ [ L "skunk_fail_index"; push rbx; push r12; push r13 ]
  @ [ movr rbx rdi; movr r12 rsi; movr r13 rdx ]
  @ [ lea rdi (glob (lit "?: runtime error: ")); Cl "rt_errs" ]
  @ [ movr rdi rbx; Cl "rt_errs" ]
  @ [ lea rdi (glob (lit ": index ")); Cl "rt_errs" ]
  @ [ movr rdi r12; Cl "rt_errnum" ]
  @ [ lea rdi (glob (lit " out of 0..")); Cl "rt_errs" ]
  @ [ movr rdi r13; sub rdi (imm 1); Cl "rt_errnum" ]
  @ [ lea rdi (glob (lit "\n")); Cl "rt_errs" ]
  @ leave dyn 1
  @ [ L "rt_errnum"; push rbx; movr rbx rdi ]
  @ [ cmp rbx (imm 0); Br ("ge", "rt_errnum.pos") ]
  @ [ lea rdi (glob (lit "~")); Cl "rt_errs"; neg rbx ]
  @ [ L "rt_errnum.pos"; movr rdi rbx; Cl "rt_digits" ]
  @ [ movr rdi rax; movr rsi rdx; Cl "rt_errout"; pop rbx; Ret ]
  @ [ L "skunk_match_fail"; push rbx; movr rbx rdi ]
  @ [ movr rdi rbx; Cl "rt_errs" ]
  @ [ lea rdi (glob (lit ": match failure: no pattern matched\n")); Cl "rt_errs" ]
  @ leave dyn 1

(* ---- strings ------------------------------------------------------------- *)

let strings =
  [
    (* make_string(rdi = bytes, rsi = count) -> rax *)
    L "rt_make_string";
    push rbx;
    push r12;
    movr rbx rdi;
    movr r12 rsi;
    movr rax r12;
    add rax (imm 8);
    sar rax 3;
    add rax (imm 1);
    lea rdi (glob "skunk_string_desc");
    movr rsi rax;
    Cl "skunk_alloc";
    store (at rax) r12;
    push rax;
    lea rdi (at ~disp:8 rax);
    movr rsi rbx;
    movr rcx r12;
    movsb;
    movi rcx 0;
    storeb (at rdi) rcx;
    pop rax;
    pop r12;
    pop rbx;
    Ret;
    (* digits(rdi = a non-negative integer) -> rax = bytes, rdx = count.  The
       buffer is static and shared, so the caller has to be done with it before
       the next call; both callers are. *)
    L "rt_digits";
    lea r8 (glob "skunk_intbuf");
    add r8 (imm 32);
    movr r9 rdi;
    movi rcx 10;
    L "rt_digits.loop";
    movr rax r9;
    cqo;
    idiv rcx;
    add rdx (imm 48);
    sub r8 (imm 1);
    storeb (at r8) rdx;
    movr r9 rax;
    cmp r9 (imm 0);
    Br ("ne", "rt_digits.loop");
    lea rax (glob "skunk_intbuf");
    add rax (imm 32);
    movr rdx rax;
    sub rdx (o r8);
    movr rax r8;
    Ret;
    (* concat(rdi, rsi) -> rax *)
    L "skunk_concat";
    push rbx;
    push r12;
    push r13;
    push r14;
    movr rbx rdi;
    movr r12 rsi;
    load r13 (at rbx);
    load r14 (at r12);
    movr rax r13;
    add rax (o r14);
    push rax;
    add rax (imm 8);
    sar rax 3;
    add rax (imm 1);
    lea rdi (glob "skunk_string_desc");
    movr rsi rax;
    Cl "skunk_alloc";
    pop rcx;
    store (at rax) rcx;
    push rax;
    lea rdi (at ~disp:8 rax);
    movr rsi rbx;
    add rsi (imm 8);
    movr rcx r13;
    movsb;
    movr rsi r12;
    add rsi (imm 8);
    movr rcx r14;
    movsb;
    movi rcx 0;
    storeb (at rdi) rcx;
    pop rax;
    pop r14;
    pop r13;
    pop r12;
    pop rbx;
    Ret;
    L "skunk_size";
    load rax (at rdi);
  ]
  @ tag rax
  @ [
      Ret;
      L "skunk_print";
      Cl "rt_outs";
      load rax (glob "skunk_the_unit");
      Ret;
      (* substring(rdi = s, rsi = start, rdx = length) *)
      L "skunk_substring";
      push rbx;
      movr rbx rdi;
      movr rcx rsi;
      sar rcx 1;
      movr r8 rdx;
      sar r8 1;
      cmp rcx (imm 0);
      Br ("l", "skunk_substring.bad");
      cmp r8 (imm 0);
      Br ("l", "skunk_substring.bad");
      movr rax rcx;
      add rax (o r8);
      load rdx (at rbx);
      cmp rax (o rdx);
      Br ("g", "skunk_substring.bad");
      movr rdi rbx;
      add rdi (imm 8);
      add rdi (o rcx);
      movr rsi r8;
      Cl "rt_make_string";
      pop rbx;
      Ret;
      L "skunk_substring.bad";
    ]
  @ complain "String.substring: out of range"
  @ [
      (* int_to_string(rdi = a tagged integer) *)
      L "skunk_int_to_string";
      push rbx;
      push r12;
      movr rbx rdi;
      sar rbx 1;
      movi r12 0;
      cmp rbx (imm 0);
      Br ("ge", "skunk_int_to_string.pos");
      movi r12 1;
      neg rbx;
      L "skunk_int_to_string.pos";
      movr rdi rbx;
      Cl "rt_digits";
      cmp r12 (imm 0);
      Br ("e", "skunk_int_to_string.make");
      sub rax (imm 1);
      movi rcx 126 (* '~' *);
      storeb (at rax) rcx;
      add rdx (imm 1);
      L "skunk_int_to_string.make";
      movr rdi rax;
      movr rsi rdx;
      Cl "rt_make_string";
      pop r12;
      pop rbx;
      Ret;
    ]

(* ---- equality ------------------------------------------------------------ *)

(* The same rules as the interpreter's `equal`: structural everywhere except
   that arrays and refs are compared by identity, and functions are an error
   the type checker should already have caught. *)
let equality =
  [
    L "rt_equal";
    cmp rdi (o rsi);
    Br ("e", "rt_equal.true");
    movr rax rdi;
    alu "or" rax (o rsi);
    alu "and" rax (imm 1);
    cmp rax (imm 0);
    Br ("ne", "rt_equal.false");
    push rbx;
    push r12;
    push r13;
    push r14;
    movr rbx rdi;
    movr r12 rsi;
    load rax (at ~disp:(-8) rbx);
    load rdx (at ~disp:(-8) r12);
    load rcx (at ~disp:d_kind rax);
    load r8 (at ~disp:d_kind rdx);
    cmp rcx (o r8);
    Br ("ne", "rt_equal.pop_false");
    cmp rcx (imm k_closure);
    Br ("e", "rt_equal.fn");
    cmp rcx (imm k_array);
    Br ("e", "rt_equal.pop_false");
    cmp rcx (imm k_ref);
    Br ("e", "rt_equal.pop_false");
    cmp rcx (imm k_string);
    Br ("e", "rt_equal.string");
    cmp rcx (imm k_con);
    Br ("ne", "rt_equal.fields");
    (* Two constructors of the same datatype are equal only if they are the
       same constructor, and the descriptor is what says which. *)
    cmp rax (o rdx);
    Br ("ne", "rt_equal.pop_false");
    L "rt_equal.fields";
    load r14 (at ~disp:d_nfields rax);
    load rcx (at ~disp:d_nfields rdx);
    cmp r14 (o rcx);
    Br ("ne", "rt_equal.pop_false");
    movi r13 0;
    L "rt_equal.field";
    cmp r13 (o r14);
    Br ("ge", "rt_equal.pop_true");
    load rdi (idx rbx r13);
    load rsi (idx r12 r13);
    Cl "rt_equal";
    cmp rax (imm 0);
    Br ("e", "rt_equal.pop_false");
    add r13 (imm 1);
    Jump "rt_equal.field";
    L "rt_equal.string";
    load r14 (at rbx);
    load rcx (at r12);
    cmp r14 (o rcx);
    Br ("ne", "rt_equal.pop_false");
    movi r13 0;
    L "rt_equal.byte";
    cmp r13 (o r14);
    Br ("ge", "rt_equal.pop_true");
    loadb rax (byte_at ~disp:8 rbx r13);
    loadb rdx (byte_at ~disp:8 r12 r13);
    cmp rax (o rdx);
    Br ("ne", "rt_equal.pop_false");
    add r13 (imm 1);
    Jump "rt_equal.byte";
    L "rt_equal.fn";
  ]
  @ complain "functions cannot be compared"
  @ [
      L "rt_equal.pop_true";
      pop r14;
      pop r13;
      pop r12;
      pop rbx;
      L "rt_equal.true";
      movi rax 1;
      Ret;
      L "rt_equal.pop_false";
      pop r14;
      pop r13;
      pop r12;
      pop rbx;
      L "rt_equal.false";
      movi rax 0;
      Ret;
      L "skunk_equal";
      Cl "rt_equal";
      cmp rax (imm 0);
      Br ("ne", "rt_bool.true");
      Jump "rt_bool.false";
      L "skunk_noteq";
      Cl "rt_equal";
      cmp rax (imm 0);
      Br ("e", "rt_bool.true");
      Jump "rt_bool.false";
      L "skunk_not";
      lea rax (glob bool_false);
      cmp rdi (o rax);
      Br ("e", "rt_bool.true");
      Jump "rt_bool.false";
    ]

(* ---- order --------------------------------------------------------------- *)

(* `<` and friends are overloaded over int and string, and which one it is was
   decided by the type checker and then erased.  So the value decides, exactly
   as the interpreter's `order` does.  For integers the tagged representation is
   monotone, so they can be compared without untagging. *)
let order =
  [
    L "rt_order";
    movr rax rdi;
    alu "and" rax (imm 1);
    cmp rax (imm 0);
    Br ("e", "rt_order.string");
    cmp rdi (o rsi);
    Br ("l", "rt_order.lt");
    Br ("g", "rt_order.gt");
    movi rax 0;
    Ret;
    L "rt_order.lt";
    movi rax (-1);
    Ret;
    L "rt_order.gt";
    movi rax 1;
    Ret;
    L "rt_order.string";
    movi rcx 0;
    load r8 (at rdi);
    load r9 (at rsi);
    L "rt_order.loop";
    cmp rcx (o r8);
    Br ("ge", "rt_order.a_end");
    cmp rcx (o r9);
    Br ("ge", "rt_order.gt");
    loadb rax (byte_at ~disp:8 rdi rcx);
    loadb rdx (byte_at ~disp:8 rsi rcx);
    cmp rax (o rdx);
    Br ("l", "rt_order.lt");
    Br ("g", "rt_order.gt");
    add rcx (imm 1);
    Jump "rt_order.loop";
    L "rt_order.a_end";
    cmp rcx (o r9);
    Br ("l", "rt_order.lt");
    movi rax 0;
    Ret;
  ]
  @ List.concat_map
      (fun (name, c) ->
        [ L name; Cl "rt_order"; cmp rax (imm 0); Br (c, "rt_bool.true"); Jump "rt_bool.false" ])
      [ ("skunk_lt", "l"); ("skunk_le", "le"); ("skunk_gt", "g"); ("skunk_ge", "ge") ]
  @ [
      L "rt_bool.true";
      lea rax (glob bool_true);
      Ret;
      L "rt_bool.false";
      lea rax (glob bool_false);
      Ret;
    ]
  (* `Int.compare` and `String.compare` are the same routine: which comparison
     it is was decided by the type checker and then erased, so the value
     decides. *)
  @ [ L "skunk_compare"; Cl "rt_order" ]
  @ tag rax
  @ [ Ret ]

(* ---- arithmetic ---------------------------------------------------------- *)

(* Only the two that can fail are routines; the code generator does add, sub
   and mul itself. *)
let arithmetic =
  [
    L "skunk_div";
    movr rcx rsi;
    sar rcx 1;
    cmp rcx (imm 0);
    Br ("e", "rt_div.zero");
    movr rax rdi;
    sar rax 1;
    cqo;
    idiv rcx;
  ]
  @ tag rax
  @ [
      Ret;
      L "skunk_mod";
      movr rcx rsi;
      sar rcx 1;
      cmp rcx (imm 0);
      Br ("e", "rt_div.zero");
      movr rax rdi;
      sar rax 1;
      cqo;
      idiv rcx;
      movr rax rdx;
    ]
  @ tag rax
  @ [ Ret; L "rt_div.zero" ]
  @ complain "division by zero"

(* ---- arrays and refs ----------------------------------------------------- *)

let arrays =
  [
    L "skunk_array";
    push rbx;
    push r12;
    movr rbx rdi;
    sar rbx 1;
    movr r12 rsi;
    cmp rbx (imm 0);
    Br ("l", "skunk_array.bad");
    lea rdi (glob "skunk_array_desc");
    movr rsi rbx;
    add rsi (imm 1);
    Cl "skunk_alloc";
    store (at rax) rbx;
    movi rcx 0;
    L "skunk_array.fill";
    cmp rcx (o rbx);
    Br ("ge", "skunk_array.done");
    store (idx ~disp:8 rax rcx) r12;
    add rcx (imm 1);
    Jump "skunk_array.fill";
    L "skunk_array.done";
    pop r12;
    pop rbx;
    Ret;
    L "skunk_array.bad";
  ]
  @ complain "Array.array: negative size"
  @ [ L "skunk_array_length"; load rax (at rdi) ]
  @ tag rax
  @ [
      Ret;
      L "skunk_array_sub";
      movr rcx rsi;
      sar rcx 1;
      load rdx (at rdi);
      cmp rcx (imm 0);
      Br ("l", "skunk_array_sub.bad");
      cmp rcx (o rdx);
      Br ("ge", "skunk_array_sub.bad");
      load rax (idx ~disp:8 rdi rcx);
      Ret;
      L "skunk_array_sub.bad";
      movr rsi rcx;
      lea rdi (glob (lit "Array.sub"));
      Cl "skunk_fail_index";
    ]
  @ [
      L "skunk_array_update";
      movr rcx rsi;
      sar rcx 1;
      load r8 (at rdi);
      cmp rcx (imm 0);
      Br ("l", "skunk_array_update.bad");
      cmp rcx (o r8);
      Br ("ge", "skunk_array_update.bad");
      store (idx ~disp:8 rdi rcx) rdx;
      load rax (glob "skunk_the_unit");
      Ret;
      L "skunk_array_update.bad";
      movr rsi rcx;
      movr rdx r8;
      lea rdi (glob (lit "Array.update"));
      Cl "skunk_fail_index";
    ]
  @ [
      L "skunk_ref";
      push rbx;
      movr rbx rdi;
      lea rdi (glob "skunk_ref_desc");
      movi rsi 1;
      Cl "skunk_alloc";
      store (at rax) rbx;
      pop rbx;
      Ret;
      L "skunk_deref";
      load rax (at rdi);
      Ret;
      L "skunk_setref";
      store (at rdi) rsi;
      load rax (glob "skunk_the_unit");
      Ret;
    ]

(* ---- lists ---------------------------------------------------------------- *)

(* `nil`, `::`, `true`, `false` and `ref` are built-in constructors, so their
   descriptors are fixed and live here.  The code generator has to use these
   labels rather than emitting its own, because two constructors are equal only
   if their descriptors are the same pointer.

   A cons cell carries one field, a pair, so building a list means three
   descriptors.  That is why these three routines are here and not in the basis
   written in SkunkML: `@` is a primitive, and a primitive cannot be given the
   descriptors as arguments without making the interface worse than the loop. *)
let lists =
  [
    (* append(rdi, rsi) -> rax *)
    L "skunk_append";
    load rax (at ~disp:(-8) rdi);
    load rax (at ~disp:d_list rax);
    cmp rax (imm 2);
    Br ("ne", "skunk_append.b");
    push rbx;
    push r12;
    load rbx (at rdi) (* the pair *);
    movr r12 rsi;
    load rdi (at ~disp:8 rbx);
    movr rsi r12;
    Cl "skunk_append";
    push rax;
    lea rdi (glob "skunk_pair_desc");
    movi rsi 2;
    Cl "skunk_alloc";
    pop rcx;
    load rdx (at rbx);
    store (at rax) rdx;
    store (at ~disp:8 rax) rcx;
    push rax;
    lea rdi (glob "skunk_cons_desc");
    movi rsi 1;
    Cl "skunk_alloc";
    pop rcx;
    store (at rax) rcx;
    pop r12;
    pop rbx;
    Ret;
    L "skunk_append.b";
    movr rax rsi;
    Ret;
    (* fromList(rdi) -> rax: one pass to count, one to fill *)
    L "skunk_array_from_list";
    push rbx;
    push r12;
    push r13;
    movr rbx rdi;
    movi r12 0;
    movr rcx rbx;
    L "skunk_array_from_list.count";
    load rax (at ~disp:(-8) rcx);
    load rax (at ~disp:d_list rax);
    cmp rax (imm 2);
    Br ("ne", "skunk_array_from_list.counted");
    add r12 (imm 1);
    load rcx (at rcx);
    load rcx (at ~disp:8 rcx);
    Jump "skunk_array_from_list.count";
    L "skunk_array_from_list.counted";
    lea rdi (glob "skunk_array_desc");
    movr rsi r12;
    add rsi (imm 1);
    Cl "skunk_alloc";
    store (at rax) r12;
    movr r13 rax;
    movi rcx 0;
    L "skunk_array_from_list.fill";
    load rax (at ~disp:(-8) rbx);
    load rax (at ~disp:d_list rax);
    cmp rax (imm 2);
    Br ("ne", "skunk_array_from_list.done");
    load rdx (at rbx);
    load r8 (at rdx);
    store (idx ~disp:8 r13 rcx) r8;
    load rbx (at ~disp:8 rdx);
    add rcx (imm 1);
    Jump "skunk_array_from_list.fill";
    L "skunk_array_from_list.done";
    movr rax r13;
    pop r13;
    pop r12;
    pop rbx;
    Ret;
    (* toList(rdi) -> rax, built back to front *)
    L "skunk_array_to_list";
    push rbx;
    push r12;
    push r13;
    movr rbx rdi;
    load r12 (at rbx);
    lea r13 (glob "skunk_nil");
    L "skunk_array_to_list.loop";
    cmp r12 (imm 0);
    Br ("le", "skunk_array_to_list.done");
    sub r12 (imm 1);
    lea rdi (glob "skunk_pair_desc");
    movi rsi 2;
    Cl "skunk_alloc";
    load rdx (idx ~disp:8 rbx r12);
    store (at rax) rdx;
    store (at ~disp:8 rax) r13;
    push rax;
    lea rdi (glob "skunk_cons_desc");
    movi rsi 1;
    Cl "skunk_alloc";
    pop rcx;
    store (at rax) rcx;
    movr r13 rax;
    Jump "skunk_array_to_list.loop";
    L "skunk_array_to_list.done";
    movr rax r13;
    pop r13;
    pop r12;
    pop rbx;
    Ret;
    (* The small integer routines the basis exposes. *)
    L "skunk_abs";
    movr rax rdi;
    sar rax 1;
    cmp rax (imm 0);
    Br ("ge", "skunk_abs.done");
    neg rax;
    L "skunk_abs.done";
  ]
  @ tag rax
  @ [
      Ret;
      L "skunk_min";
      movr rax rdi;
      cmp rdi (o rsi);
      Br ("le", "skunk_min.done");
      movr rax rsi;
      L "skunk_min.done";
      Ret;
      L "skunk_max";
      movr rax rdi;
      cmp rdi (o rsi);
      Br ("ge", "skunk_max.done");
      movr rax rsi;
      L "skunk_max.done";
      Ret;
    ]

(* ---- printing ------------------------------------------------------------ *)

(* Prints a value the way the interpreter prints it, which is what makes the
   differential test possible: a compiled program's output has to match `skunk`
   byte for byte.  The walk is recursive, and the callee-saved registers hold
   what has to survive the recursion -- rbx the value, r12 its descriptor, r13
   the field index, r14 the field count. *)
let printing =
  [
    L "rt_show_int";
    push rbx;
    movr rbx rdi;
    cmp rbx (imm 0);
    Br ("ge", "rt_show_int.pos");
  ]
  @ say "~"
  @ [
      neg rbx;
      L "rt_show_int.pos";
      movr rdi rbx;
      Cl "rt_digits";
      movr rdi rax;
      movr rsi rdx;
      Cl "rt_out";
      pop rbx;
      Ret;
      L "skunk_show";
      push rbx;
      push r12;
      push r13;
      push r14;
      movr rbx rdi;
      movr rax rdi;
      alu "and" rax (imm 1);
      cmp rax (imm 0);
      Br ("e", "rt_show.block");
      movr rdi rbx;
      sar rdi 1;
      Cl "rt_show_int";
      Jump "rt_show.ret";
      L "rt_show.block";
      load r12 (at ~disp:(-8) rbx);
      load rax (at ~disp:d_kind r12);
      cmp rax (imm k_string);
      Br ("e", "rt_show.string");
      cmp rax (imm k_closure);
      Br ("e", "rt_show.fn");
      cmp rax (imm k_ref);
      Br ("e", "rt_show.ref");
      cmp rax (imm k_array);
      Br ("e", "rt_show.array");
      cmp rax (imm k_con);
      Br ("e", "rt_show.con");
      (* A record.  No fields is unit, and no labels is a tuple -- the same rule
         the interpreter prints by. *)
      load r14 (at ~disp:d_nfields r12);
      cmp r14 (imm 0);
      Br ("ne", "rt_show.rec_open");
    ]
  @ say "()"
  @ [ Jump "rt_show.ret"; L "rt_show.rec_open"; load rax (at ~disp:d_labels r12); cmp rax (imm 0) ]
  @ [ Br ("ne", "rt_show.braces") ]
  @ say "("
  @ [ Jump "rt_show.rec_init"; L "rt_show.braces" ]
  @ say "{ "
  @ [
      L "rt_show.rec_init";
      movi r13 0;
      L "rt_show.rec_loop";
      cmp r13 (o r14);
      Br ("ge", "rt_show.rec_close");
      cmp r13 (imm 0);
      Br ("e", "rt_show.rec_nosep");
    ]
  @ say ", "
  @ [
      L "rt_show.rec_nosep";
      load rax (at ~disp:d_labels r12);
      cmp rax (imm 0);
      Br ("e", "rt_show.rec_field");
      load rdi (idx rax r13);
      Cl "rt_outs";
    ]
  @ say " = "
  @ [
      L "rt_show.rec_field";
      load rdi (idx rbx r13);
      Cl "skunk_show";
      add r13 (imm 1);
      Jump "rt_show.rec_loop";
      L "rt_show.rec_close";
      load rax (at ~disp:d_labels r12);
      cmp rax (imm 0);
      Br ("ne", "rt_show.close_brace");
    ]
  @ say ")"
  @ [ Jump "rt_show.ret"; L "rt_show.close_brace" ]
  @ say " }"
  @ [ Jump "rt_show.ret" ]
  (* A string, with the escapes the lexer accepts. *)
  @ [ L "rt_show.string" ]
  @ say "\""
  @ [
      load r14 (at rbx);
      movi r13 0;
      L "rt_show.str_loop";
      cmp r13 (o r14);
      Br ("ge", "rt_show.str_end");
      loadb rax (byte_at ~disp:8 rbx r13);
      cmp rax (imm 34);
      Br ("e", "rt_show.escape");
      cmp rax (imm 92);
      Br ("e", "rt_show.escape");
      cmp rax (imm 10);
      Br ("e", "rt_show.newline");
      cmp rax (imm 9);
      Br ("e", "rt_show.tab");
      L "rt_show.plain";
      lea rdi (byte_at ~disp:8 rbx r13);
      movi rsi 1;
      Cl "rt_out";
      Jump "rt_show.str_next";
      L "rt_show.escape";
    ]
  @ say "\\"
  @ [ Jump "rt_show.plain"; L "rt_show.newline" ]
  @ say "\\n"
  @ [ Jump "rt_show.str_next"; L "rt_show.tab" ]
  @ say "\\t"
  @ [
      L "rt_show.str_next";
      add r13 (imm 1);
      Jump "rt_show.str_loop";
      L "rt_show.str_end";
    ]
  @ say "\""
  @ [ Jump "rt_show.ret"; L "rt_show.fn" ]
  @ say "fn"
  @ [ Jump "rt_show.ret"; L "rt_show.ref" ]
  @ say "ref "
  @ [ load rdi (at rbx); Cl "skunk_show"; Jump "rt_show.ret"; L "rt_show.array" ]
  @ say "[|"
  @ [
      load r14 (at rbx);
      movi r13 0;
      L "rt_show.arr_loop";
      cmp r13 (o r14);
      Br ("ge", "rt_show.arr_end");
      cmp r13 (imm 0);
      Br ("e", "rt_show.arr_nosep");
    ]
  @ say ", "
  @ [
      L "rt_show.arr_nosep";
      load rdi (idx ~disp:8 rbx r13);
      Cl "skunk_show";
      add r13 (imm 1);
      Jump "rt_show.arr_loop";
      L "rt_show.arr_end";
    ]
  @ say "|]"
  @ [
      Jump "rt_show.ret";
      (* A constructor, unless the descriptor says its datatype prints as a
         list, in which case the spine is walked instead. *)
      L "rt_show.con";
      load rax (at ~disp:d_list r12);
      cmp rax (imm 0);
      Br ("ne", "rt_show.list");
      load rdi (at ~disp:d_con r12);
      Cl "rt_outs";
      load rax (at ~disp:d_nfields r12);
      cmp rax (imm 0);
      Br ("e", "rt_show.ret");
    ]
  @ say " "
  @ [ load rdi (at rbx); Cl "skunk_show"; Jump "rt_show.ret"; L "rt_show.list" ]
  @ say "["
  @ [
      movi r13 0;
      L "rt_show.list_loop";
      load rax (at ~disp:(-8) rbx);
      load rax (at ~disp:d_list rax);
      cmp rax (imm 2);
      Br ("ne", "rt_show.list_end");
      load r14 (at rbx) (* the cons cell's one field: a pair *);
      cmp r13 (imm 0);
      Br ("e", "rt_show.list_nosep");
    ]
  @ say ", "
  @ [
      L "rt_show.list_nosep";
      movi r13 1;
      load rdi (at r14);
      Cl "skunk_show";
      load rbx (at ~disp:8 r14);
      Jump "rt_show.list_loop";
      L "rt_show.list_end";
    ]
  @ say "]"
  @ [
      L "rt_show.ret";
      pop r14;
      pop r13;
      pop r12;
      pop rbx;
      Ret;
      (* One reported binding, in the interpreter's format. *)
      L "skunk_report";
      push rbx;
      movr rbx rsi;
      Cl "rt_outs";
    ]
  @ say " = "
  @ [ movr rdi rbx; Cl "skunk_show" ]
  @ say "\n"
  @ [ pop rbx; Ret; L "skunk_report_label"; Cl "rt_outs" ]
  @ say "\n"
  @ [ Ret ]

(* ---- entry --------------------------------------------------------------- *)

(* The kernel jumps straight here: no libc, so no ctors, no argv parsing, and
   nothing to do but make the heap, make the one unit value everything shares,
   and run the program. *)
let start dyn =
  [
    L "_start";
    (* The stack goes down from here, and the collector needs to know where "up"
       is: everything between the current rsp and this is a root. *)
    store (glob "skunk_stack_top") rsp;
    Cl "rt_heap_init";
    lea rdi (glob "skunk_unit_desc");
    movi rsi 0;
    Cl "skunk_alloc";
    store (glob "skunk_the_unit") rax;
    Cl "skunk_program";
    Cl "rt_flush";
  ]
  @ leave dyn 0

let text ?(dynamic = false) st =
  emit st
    (start dynamic @ output dynamic @ heap dynamic @ collector @ failures dynamic @ strings
    @ equality @ order @ arithmetic @ arrays @ lists @ printing)

(* ---- static data --------------------------------------------------------- *)

(* A string block in static data.  The label names the value, so the descriptor
   word goes down first and is at offset -8, exactly as for a heap block. *)
let string_block st name s =
  A.align st 8;
  A.dq_sym st "skunk_string_desc";
  A.label st name;
  A.dq st (String.length s);
  A.ascii st s;
  A.zeros st 1;
  A.align st 8

let descriptor st name ~kind ~nfields ~con ~labels ~list ~tag =
  A.align st 8;
  A.label st name;
  A.dq st kind;
  A.dq st nfields;
  (match con with None -> A.dq st 0 | Some s -> A.dq_sym st s);
  (match labels with None -> A.dq st 0 | Some s -> A.dq_sym st s);
  A.dq st list;
  A.dq st tag

(* The whole data section is scanned conservatively for roots, so the collector
   needs to know where it starts and ends.  Everything in it is fair game: a
   global's word really does point into the heap, and the rest -- descriptors,
   static blocks, the output buffer -- is checked and rejected. *)
let data_start st =
  A.align st 8;
  A.label st "skunk_data_start"

let data_end st =
  A.align st 8;
  A.label st "skunk_data_end"

let data st =
  descriptor st "skunk_string_desc" ~kind:k_string ~nfields:0 ~con:None ~labels:None ~list:0 ~tag:0;
  descriptor st "skunk_unit_desc" ~kind:k_record ~nfields:0 ~con:None ~labels:None ~list:0 ~tag:0;
  descriptor st "skunk_array_desc" ~kind:k_array ~nfields:0 ~con:None ~labels:None ~list:0 ~tag:0;
  descriptor st "skunk_ref_desc" ~kind:k_ref ~nfields:1 ~con:None ~labels:None ~list:0 ~tag:0;
  descriptor st "skunk_true_desc" ~kind:k_con ~nfields:0 ~con:(Some (lit "true")) ~labels:None
    ~list:0 ~tag:1;
  descriptor st "skunk_false_desc" ~kind:k_con ~nfields:0 ~con:(Some (lit "false")) ~labels:None
    ~list:0 ~tag:0;
  descriptor st "skunk_nil_desc" ~kind:k_con ~nfields:0 ~con:(Some (lit "nil")) ~labels:None
    ~list:1 ~tag:0;
  descriptor st "skunk_cons_desc" ~kind:k_con ~nfields:1 ~con:(Some (lit "::")) ~labels:None
    ~list:2 ~tag:1;
  descriptor st "skunk_pair_desc" ~kind:k_record ~nfields:2 ~con:None ~labels:None ~list:0 ~tag:0;
  (* The two blocks themselves.  A nullary constructor carries nothing, so the
     descriptor word is the whole of it. *)
  A.align st 8;
  A.dq_sym st "skunk_true_desc";
  A.label st bool_true;
  A.align st 8;
  A.dq_sym st "skunk_false_desc";
  A.label st bool_false;
  A.align st 8;
  A.dq_sym st "skunk_nil_desc";
  A.label st "skunk_nil";
  descriptor st "skunk_free_desc" ~kind:k_free ~nfields:0 ~con:None ~labels:None ~list:0 ~tag:0;
  A.align st 8;
  A.label st "skunk_heap_start";
  A.dq st 0;
  A.label st "skunk_heap_end";
  A.dq st 0;
  A.label st "skunk_cursor";
  A.dq st 0;
  A.label st "skunk_starts";
  A.dq st 0;
  A.label st "skunk_marks";
  A.dq st 0;
  A.label st "skunk_mstack";
  A.dq st 0;
  A.label st "skunk_mtop";
  A.dq st 0;
  A.label st "skunk_stack_top";
  A.dq st 0;
  A.label st "skunk_the_unit";
  A.dq st 0;
  A.label st "skunk_outlen";
  A.dq st 0;
  A.label st "skunk_outbuf";
  A.zeros st out_size;
  A.label st "skunk_intbuf";
  A.zeros st 32;
  (* The literals last, because [lit] is called while the text is being built
     and the list is only complete once it is. *)
  List.iter (fun (name, s) -> string_block st name s) (List.rev !lit_order)
