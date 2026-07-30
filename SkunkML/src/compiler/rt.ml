(* What the compiler puts in the file beside the runtime.

   The runtime itself is `src/runtime/runtime.c`, compiled freestanding and read
   back in by `obj.ml`.  What is left here is the handful of things a C object
   cannot provide:

     * `_start`.  The kernel jumps straight to it, and its whole job is to save
       the stack pointer -- the collector needs to know where the roots end --
       and call into C.
     * The blocks for the constructors that carry nothing.  `nil`, `true` and
       `false` are the same value every time, so they are static data; but the
       value is the address *after* the descriptor word, and a C object cannot
       put a label in the middle of a struct.  The descriptors they point at do
       come from C, because two constructors are equal only when their
       descriptors are the same pointer and there has to be one owner.
     * The layout of a descriptor and of a string block, which `statics.ml` emits
       for every record, constructor and literal in the program.

   The division of labour with generated code is the one the book describes: the
   code generator only has to know how to move words, do tagged arithmetic and
   jump, and anything that needs a loop or a walk over the heap is a call into
   the runtime.

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

(* ---- the entry point ------------------------------------------------------ *)

(* Three instructions.  There is no libc, so no constructors run and there is no
   argv to parse; and `rsp` here is the top of the stack, which is where the
   collector's root scan stops. *)
let text st =
  emit st
    [
      L "_start";
      store (glob "skunk_stack_top") rsp;
      Cl "skunk_boot";
    ]

(* ---- static data --------------------------------------------------------- *)

(* A string block in static data: [length][bytes][NUL], with the label naming the
   value, so the descriptor word is at offset -8 exactly as on the heap. *)
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

(* A constructor that carries nothing, and the name the printer needs for it.
   The descriptors are in C; these are the blocks that point at them. *)
let data st =
  List.iter
    (fun (name, text) -> string_block st (name ^ "_name") text)
    [ ("skunk_true", "true"); ("skunk_false", "false"); ("skunk_nil", "nil");
      ("skunk_cons", "::") ];
  List.iter
    (fun name ->
      A.align st 8;
      A.dq_sym st (name ^ "_desc");
      A.label st name)
    [ "skunk_true"; "skunk_false"; "skunk_nil" ];
  A.align st 8
