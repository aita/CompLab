(* Writing LLVM IR, as text.

   The compiler builds a module by printing it.  There is no builder object and
   no handle to a `Value`: an operand is the string it is written as, a type is
   the string it is written as, and an instruction is a line appended to the
   block being filled.

   Two things make that practical rather than merely short.

   *A block is buffered until the function is finished.*  A phi node learns
   where its values come from after its line would already have been printed --
   the jumps to a join point are in the continuation, and the continuation is
   lowered after the phi exists ([11章](../../doc/11-lower.md)).  So a block
   holds a list of phis, a buffer of instructions and a terminator, and it is
   rendered when the function ends.  That is the same shape the LLVM builder
   has, for the same reason.

   *Names are handed out here, and never taken from LLVM.*  Unnamed values in
   textual IR must be numbered in exactly the order LLVM would have numbered
   them, which is a rule with corners in it -- parameters count, unnamed blocks
   count.  So nothing here is unnamed: a temporary is `%_7`, a name from the
   program is quoted as it was written, and one table per function keeps the two
   from colliding.  Basic block labels go through the same table, because in
   LLVM a label and a local value share one namespace.

   What is written here is what `--emit-llvm -O0` prints, and it is what clang
   reads back ([10章](../../doc/10-llvm.md)).  Nothing else in this compiler
   knows LLVM's spelling. *)

type value = string
type ty = string

let i1 : ty = "i1"
let i8 : ty = "i8"
let i64 : ty = "i64"
let ptr : ty = "ptr"
let void : ty = "void"

(* ---- constants ------------------------------------------------------------ *)

let int n : value = string_of_int n

(* A byte string, as LLVM spells one: printable ASCII as itself, everything else
   in hex -- including the quote that would end the literal and the backslash
   that would start an escape. *)
let bytes s : value =
  let b = Buffer.create (String.length s + 8) in
  Buffer.add_string b "c\"";
  String.iter
    (fun c ->
      let n = Char.code c in
      if c = '"' || c = '\\' || n < 0x20 || n > 0x7e then
        Buffer.add_string b (Printf.sprintf "\\%02X" n)
      else Buffer.add_char b c)
    s;
  Buffer.add_string b "\\00\"";
  Buffer.contents b

let array_ty n (t : ty) : ty = Printf.sprintf "[%d x %s]" n t
let struct_ty (ts : ty list) : ty = Printf.sprintf "{ %s }" (String.concat ", " ts)

let array_const (t : ty) (vs : value list) : value =
  Printf.sprintf "[%s]" (String.concat ", " (List.map (fun v -> t ^ " " ^ v) vs))

let struct_const (fs : (ty * value) list) : value =
  Printf.sprintf "{ %s }" (String.concat ", " (List.map (fun (t, v) -> t ^ " " ^ v) fs))

(* The address of a global, as a word. *)
let addr (g : string) : value = Printf.sprintf "ptrtoint (ptr %s to i64)" g

(* The value of a static block: the address one word past its descriptor.  A
   constant `getelementptr` is a constant, which is what lets a block be one
   global and its value be an expression rather than a symbol in the middle of
   it. *)
let block_value (g : string) : value =
  Printf.sprintf "ptrtoint (ptr getelementptr (i8, ptr %s, i64 8) to i64)" g

(* ---- the module ----------------------------------------------------------- *)

type phi = { pv : value; pty : ty; mutable inc : (value * string) list }

type block = {
  label : string;
  mutable phis : phi list; (* newest first *)
  body : Buffer.t;
  mutable term : string;
}

type fn = {
  signature : string;
  mutable blocks : block list; (* newest first *)
  mutable cur : block option;
  taken : (string, unit) Hashtbl.t;
  mutable next : int;
}

type t = {
  head : Buffer.t;
  globals : Buffer.t;
  decls : Buffer.t;
  funcs : Buffer.t;
  declared : (string, unit) Hashtbl.t;
  mutable counter : int;
  mutable fn : fn option;
}

(* No `target triple` and no `target datalayout`.  The module is read back by
   the same LLVM that would have chosen them, and leaving them out is what keeps
   the text portable enough to hand to a different one. *)
let create () =
  let head = Buffer.create 128 in
  Buffer.add_string head "; SkunkML, lowered to LLVM IR by skunkllvm\n\n";
  {
    head;
    globals = Buffer.create 4096;
    decls = Buffer.create 512;
    funcs = Buffer.create 16384;
    declared = Hashtbl.create 64;
    counter = 0;
    fn = None;
  }

let to_string t =
  Buffer.contents t.head ^ Buffer.contents t.globals ^ "\n" ^ Buffer.contents t.decls ^ "\n"
  ^ Buffer.contents t.funcs

let fresh_symbol t prefix =
  let n = t.counter in
  t.counter <- n + 1;
  Printf.sprintf "@%s%d" prefix n

(* ---- globals and declarations --------------------------------------------- *)

let section = "skunk_data"

(* Everything the compiler emits goes into one section, because that is how the
   collector is told where the roots are; and nothing is `constant`, because
   `constmerge` would fold two descriptors that happen to hold the same six
   words and two constructors would become equal ([12章](../../doc/12-abi.md)). *)
let global t ~name ~ty ~init =
  Buffer.add_string t.globals
    (Printf.sprintf "%s = internal global %s %s, section %S, align 8\n" name ty init section);
  name

let define_global t prefix ~ty ~init = global t ~name:(fresh_symbol t prefix) ~ty ~init

(* Something the runtime defines.  `dso_local` is the whole of the difference
   between a direct reference and one through the GOT: this is a static
   executable and nothing in it is preemptible. *)
let extern t name =
  let sym = "@" ^ name in
  if not (Hashtbl.mem t.declared name) then begin
    Hashtbl.replace t.declared name ();
    Buffer.add_string t.decls (Printf.sprintf "%s = external dso_local global i64\n" sym)
  end;
  sym

let declare t name ~ret ~args =
  let sym = "@" ^ name in
  if not (Hashtbl.mem t.declared name) then begin
    Hashtbl.replace t.declared name ();
    Buffer.add_string t.decls
      (Printf.sprintf "declare dso_local %s %s(%s)\n" ret sym (String.concat ", " args))
  end;
  sym

(* ---- functions ------------------------------------------------------------ *)

let current t = match t.fn with Some f -> f | None -> failwith "ir: no function is open"

let cur_block t =
  match (current t).cur with Some b -> b | None -> failwith "ir: no block is open"

(* One table per function for every local name, because a basic block label and
   a local value share one namespace in LLVM.  A name from the program is
   quoted, so it can be anything the front end made; a temporary is `_n`, and
   the table is what keeps a program that binds `_7` from colliding with one. *)
let unique f base =
  let rec go candidate n =
    if Hashtbl.mem f.taken candidate then go (Printf.sprintf "%s.%d" base n) (n + 1)
    else begin
      Hashtbl.replace f.taken candidate ();
      candidate
    end
  in
  go base 0

let fresh_name f =
  let n = f.next in
  f.next <- n + 1;
  unique f (Printf.sprintf "_%d" n)

let fresh t : value = "%" ^ fresh_name (current t)
let named t base : value = Printf.sprintf "%%%S" (unique (current t) base)

let func t ~name ~linkage ~ret ~params =
  let args = String.concat ", " (List.map (fun (ty, v) -> ty ^ " " ^ v) params) in
  let f =
    {
      signature = Printf.sprintf "define %s%s %s(%s)" linkage ret name args;
      blocks = [];
      cur = None;
      taken = Hashtbl.create 64;
      next = 0;
    }
  in
  (* The parameters own their names before anything else can be given one. *)
  List.iter
    (fun (_, v) ->
      let n = String.length v in
      Hashtbl.replace f.taken (String.sub v 1 (n - 1)) ())
    params;
  t.fn <- Some f;
  f

let internal = "internal "
let exported = "dso_local "

let append_block t base =
  let f = current t in
  let b = { label = unique f base; phis = []; body = Buffer.create 256; term = "unreachable" } in
  f.blocks <- b :: f.blocks;
  b

let position t b = (current t).cur <- Some b
let here t = cur_block t
let label (b : block) = "%" ^ Printf.sprintf "%S" b.label

let render t =
  let f = current t in
  Buffer.add_string t.funcs (f.signature ^ " {\n");
  List.iter
    (fun b ->
      Buffer.add_string t.funcs (Printf.sprintf "%S:\n" b.label);
      List.iter
        (fun p ->
          Buffer.add_string t.funcs
            (Printf.sprintf "  %s = phi %s %s\n" p.pv p.pty
               (String.concat ", "
                  (List.rev_map (fun (v, l) -> Printf.sprintf "[ %s, %%%S ]" v l) p.inc))))
        (List.rev b.phis);
      Buffer.add_buffer t.funcs b.body;
      Buffer.add_string t.funcs ("  " ^ b.term ^ "\n"))
    (List.rev f.blocks);
  Buffer.add_string t.funcs "}\n\n";
  t.fn <- None

(* ---- instructions --------------------------------------------------------- *)

let emit t line = Buffer.add_string (cur_block t).body ("  " ^ line ^ "\n")

let assign t line =
  let v = fresh t in
  emit t (v ^ " = " ^ line);
  v

let binop t op a b = assign t (Printf.sprintf "%s i64 %s, %s" op a b)
let add t a b = binop t "add" a b
let sub t a b = binop t "sub" a b
let mul t a b = binop t "mul" a b
let shl t a b = binop t "shl" a b
let ashr t a b = binop t "ashr" a b
let or_ t a b = binop t "or" a b
let and_ t a b = binop t "and" a b
let sdiv t a b = binop t "sdiv" a b
let srem t a b = binop t "srem" a b

(* A comparison of two words, producing a bit.  The predicate is written, not
   numbered: `slt` is `slt`. *)
let icmp t pred a b = assign t (Printf.sprintf "icmp %s i64 %s, %s" pred a b)
let select t c a b = assign t (Printf.sprintf "select i1 %s, i64 %s, i64 %s" c a b)
let inttoptr t v = assign t (Printf.sprintf "inttoptr i64 %s to ptr" v)

(* Byte-indexed, and not `inbounds`: the descriptor is at word -1, which is
   outside the block the value points at. *)
let gep t p off = assign t (Printf.sprintf "getelementptr i8, ptr %s, i64 %d" p off)
let load t p = assign t (Printf.sprintf "load i64, ptr %s, align 8" p)
let store t v p = emit t (Printf.sprintf "store i64 %s, ptr %s, align 8" v p)

let args_of vs = String.concat ", " (List.map (fun v -> "i64 " ^ v) vs)
let call t sym vs = assign t (Printf.sprintf "call i64 %s(%s)" sym (args_of vs))
let call_void t sym vs = emit t (Printf.sprintf "call void %s(%s)" sym (args_of vs))

(* An indirect call through a word read out of a closure.  Every code block has
   the one type, so the signature is written and nothing has to be cast. *)
let call_ptr t ?(musttail = false) fp vs =
  assign t
    (Printf.sprintf "%scall i64 %s(%s)" (if musttail then "musttail " else "") fp (args_of vs))

(* ---- terminators ---------------------------------------------------------- *)

let terminate t s = (cur_block t).term <- s
let ret t v = terminate t (Printf.sprintf "ret i64 %s" v)
let ret_void t = terminate t "ret void"
let br t b = terminate t (Printf.sprintf "br label %s" (label b))

let cond_br t c a b =
  terminate t (Printf.sprintf "br i1 %s, label %s, label %s" c (label a) (label b))

let switch t ~ty ~on ~default cases =
  terminate t
    (Printf.sprintf "switch %s %s, label %s [%s ]" ty on (label default)
       (String.concat ""
          (List.map (fun (k, b) -> Printf.sprintf " %s %s, label %s" ty k (label b)) cases)))

let unreachable t = terminate t "unreachable"

(* ---- phi nodes ------------------------------------------------------------ *)

(* Created empty, in the block that will hold it, and filled in as the jumps to
   it are met. *)
let phi t (b : block) ~ty ~name =
  let p = { pv = named t name; pty = ty; inc = [] } in
  b.phis <- p :: b.phis;
  p

let phi_value (p : phi) = p.pv
let add_incoming (p : phi) v (b : block) = p.inc <- (v, b.label) :: p.inc
