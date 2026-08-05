(* The static data the generated code refers to, and the module it goes into.

   Descriptors, string literals, nullary constructors, the closures the basis is
   made of, and one word per global.  All of it is interned: two records with the
   same labels share a descriptor, and the same string written twice is one
   block.  Interning is by the text of the thing, so the same program always
   produces the same module and two dumps can be diffed.

   Three decisions here are about LLVM rather than about SkunkML.

   *A block's value is the address after its descriptor word*, and LLVM will not
   put a symbol in the middle of a global.  It does not have to: a constant
   `getelementptr` is a constant, so a block is one global and its value is
   `ptrtoint (getelementptr (i8, ptr @g, i64 8) to i64)`.  Everything static goes
   through [Ir.block_value], and the eight is written once.

   *Everything the compiler emits goes into one section*, `skunk_data`, because
   that is how the collector is told where the roots are: the linker defines
   `__start_skunk_data` and `__stop_skunk_data` around any section whose name is
   a C identifier, and the runtime scans between them.  The compiler emits no
   symbols of its own for this and the runtime needs no help finding them.

   *Nothing is marked constant*, and that is not laziness.  Two constructors are
   equal only when their descriptors are the same pointer, so descriptors that
   happen to hold the same six words must still be two addresses -- and
   `constmerge`, which runs at `-O2`, merges constant globals with equal
   contents.  Two nullary constructors of two datatypes, both the first of
   theirs, are exactly that case; `tests/nullary.sk` is the program that would
   start printing the wrong name. *)

type t = {
  ir : Ir.t;
  interned : (string, Ir.value) Hashtbl.t;
  codes : (string, string) Hashtbl.t;
  globals : (string, string) Hashtbl.t;
}

let create () =
  {
    ir = Ir.create ();
    interned = Hashtbl.create 256;
    codes = Hashtbl.create 64;
    globals = Hashtbl.create 64;
  }

(* Every code block in the program has this shape: a closure, an argument, and a
   value back.  One signature for all of them is what lets a call go through a
   word read out of a closure, and what lets a tail call be `musttail`. *)
let closure_param = "%clos"
let argument_param = "%arg"
let code_params = [ (Ir.i64, closure_param); (Ir.i64, argument_param) ]

(* A name from the source, in a form a symbol can carry.  Anything that is not a
   letter, a digit or an underscore becomes its hex code, so `^` and `<=` get
   names and two different names never collide. *)
let mangle s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' then
        Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "_%02x" (Char.code c)))
    s;
  Buffer.contents b

(* ---- what the runtime provides -------------------------------------------- *)

let extern t name = Ir.extern t.ir name
let extern_addr t name = Ir.addr (extern t name)

let routine t name arity =
  Ir.declare t.ir name ~ret:Ir.i64 ~args:(List.init arity (fun _ -> Ir.i64))

let call t name args = Ir.call t.ir (routine t name (List.length args)) args

let call_void t name args =
  Ir.call_void t.ir
    (Ir.declare t.ir name ~ret:Ir.void ~args:(List.map (fun _ -> Ir.i64) args))
    args

(* ---- interning ------------------------------------------------------------ *)

let intern t key make =
  match Hashtbl.find_opt t.interned key with
  | Some v -> v
  | None ->
      let v = make () in
      Hashtbl.replace t.interned key v;
      v

(* A code block of the program, by its Flat label.  Named the first time it is
   mentioned, which is what lets a closure hold the address of a function whose
   body has not been written yet. *)
let code t label =
  match Hashtbl.find_opt t.codes label with
  | Some sym -> sym
  | None ->
      let sym = "@code_" ^ mangle label in
      Hashtbl.replace t.codes label sym;
      sym

(* ---- strings -------------------------------------------------------------- *)

(* [descriptor][length][bytes][NUL], with the value naming the length word.  The
   NUL is not counted; it is there so that a string can be handed to a syscall
   without copying. *)
let str t s =
  intern t ("s:" ^ s) (fun () ->
      let n = String.length s in
      let chars = Ir.array_ty (n + 1) Ir.i8 in
      let ty = Ir.struct_ty [ Ir.i64; Ir.i64; chars ] in
      let init =
        Ir.struct_const
          [
            (Ir.i64, extern_addr t "skunk_string_desc");
            (Ir.i64, Ir.int n);
            (chars, Ir.bytes s);
          ]
      in
      Ir.block_value (Ir.define_global t.ir "str_" ~ty ~init))

(* One string block per field, for a record that has labels.  A descriptor holds
   the address of the array, not a value, so this one is not a block. *)
let labels t ls =
  intern t ("l:" ^ String.concat "\000" ls) (fun () ->
      let vals = List.map (str t) ls in
      let ty = Ir.array_ty (List.length vals) Ir.i64 in
      Ir.addr (Ir.define_global t.ir "labels_" ~ty ~init:(Ir.array_const Ir.i64 vals)))

(* ---- descriptors ---------------------------------------------------------- *)

let k_record = 0
let k_con = 1
let k_closure = 3

let descriptor t key prefix ~kind ~nfields ~con ~labels ~list ~tag =
  intern t key (fun () ->
      let words =
        [ Ir.int kind; Ir.int nfields; con; labels; Ir.int list; Ir.int tag ]
      in
      Ir.addr
        (Ir.define_global t.ir prefix
           ~ty:(Ir.array_ty 6 Ir.i64)
           ~init:(Ir.array_const Ir.i64 words)))

(* A record's descriptor.  Labels 1, 2, ... n mean a tuple, and a tuple prints
   without them, so it does not need the array at all. *)
let record_desc t ls =
  let n = List.length ls in
  let tuple = List.for_all2 (fun i l -> l = string_of_int i) (List.init n (fun i -> i + 1)) ls in
  let key = Printf.sprintf "dr:%d:%s" n (if tuple then "" else String.concat "\000" ls) in
  descriptor t key "desc_rec_" ~kind:k_record ~nfields:n ~con:(Ir.int 0)
    ~labels:(if tuple then Ir.int 0 else labels t ls)
    ~list:0 ~tag:0

let closure_desc t ncaps =
  descriptor t (Printf.sprintf "dc:%d" ncaps) "desc_clos_" ~kind:k_closure ~nfields:(ncaps + 1)
    ~con:(Ir.int 0) ~labels:(Ir.int 0) ~list:0 ~tag:0

(* Which built-in constructor this is, if it is one: the runtime's descriptor,
   and the runtime's block for it when it carries nothing. *)
let builtin (c : Types.constr) =
  let tid = c.Types.cres.Types.tid in
  if tid = Types.list_tc.Types.tid then
    Some
      (if c.Types.cidx = 0 then ("skunk_nil_desc", Some "skunk_nil_blk")
       else ("skunk_cons_desc", None))
  else if tid = Types.bool_tc.Types.tid then
    Some
      (if c.Types.cidx = 0 then ("skunk_false_desc", Some "skunk_false_blk")
       else ("skunk_true_desc", Some "skunk_true_blk"))
  else if tid = Types.ref_tc.Types.tid then Some ("skunk_ref_desc", None)
  else None

let con_desc t (c : Types.constr) =
  match builtin c with
  | Some (d, _) -> extern_addr t d
  | None ->
      let nfields = match c.Types.carg with None -> 0 | Some _ -> 1 in
      descriptor t
        (Printf.sprintf "dk:%d:%d" c.Types.cres.Types.tid c.Types.cidx)
        "desc_con_" ~kind:k_con ~nfields ~con:(str t c.Types.cname) ~labels:(Ir.int 0) ~list:0
        ~tag:c.Types.cidx

(* ---- static blocks -------------------------------------------------------- *)

(* A descriptor and n fields.  The one padding word when there are no fields is
   what keeps the value an address *inside* the object rather than one past the
   end of it -- a nullary constructor is a block whose only word is its
   descriptor. *)
let block t prefix desc fields =
  let words = desc :: (if fields = [] then [ Ir.int 1 ] else fields) in
  Ir.block_value
    (Ir.define_global t.ir prefix
       ~ty:(Ir.array_ty (List.length words) Ir.i64)
       ~init:(Ir.array_const Ir.i64 words))

(* A constructor that carries nothing is the same value every time, so it is
   static rather than allocated. *)
let nullary t (c : Types.constr) =
  match builtin c with
  | Some (_, Some blk) -> Ir.block_value (extern t blk)
  | _ ->
      intern t
        (Printf.sprintf "nk:%d:%d" c.Types.cres.Types.tid c.Types.cidx)
        (fun () -> block t "con_" (con_desc t c) [])

(* A closure that captures nothing is static too, which is what makes the whole
   basis static data: a name like `print` is a global whose word holds the
   address of a block that was emitted, not built. *)
let static_closure t code = block t "clos_" (closure_desc t 0) [ Ir.addr code ]
let static_record t ls fields = block t "rec_" (record_desc t ls) fields

(* `true` and `false`, for the one comparison that needs them: a `case` over
   strings asks the runtime whether two values are equal and gets back a value,
   not a bit. *)
let true_value t = Ir.block_value (extern t "skunk_true_blk")
let false_value t = Ir.block_value (extern t "skunk_false_blk")

(* ---- globals -------------------------------------------------------------- *)

(* A global's name is its source name, not a number, because two compilations of
   the same program have to agree on it and because a dump is easier to read.
   Tagged zero, so that a global read before it is written is at least a
   well-formed value. *)
let global t name init =
  match Hashtbl.find_opt t.globals name with
  | Some g -> g
  | None ->
      let g =
        Ir.global t.ir
          ~name:("@skunk_g_" ^ mangle name)
          ~ty:Ir.i64
          ~init:(match init with Some v -> v | None -> Ir.int 1)
      in
      Hashtbl.replace t.globals name g;
      g

(* ---- reading and writing a block ------------------------------------------ *)

(* A value is an `i64` everywhere: an integer is one, and so is the address of a
   block, and a `phi` cannot have it both ways.  Reaching a field is therefore an
   `inttoptr` and a byte-indexed `getelementptr`. *)
let word t v i =
  let p = Ir.inttoptr t.ir v in
  if i = 0 then p else Ir.gep t.ir p (8 * i)

let field t v i = Ir.load t.ir (word t v i)
let set_field t v i x = Ir.store t.ir x (word t v i)

(* Allocation is a call: the descriptor and the word count go in, the block comes
   back.  Everything that has to survive it is an argument to it or live after
   it, which is what puts those values somewhere the collector will look. *)
let alloc t desc nwords = call t "skunk_alloc" [ desc; Ir.int nwords ]

(* The one unit value everything shares.  The runtime allocates it at start-up,
   so this is a load and not a constant. *)
let unit_value t = Ir.load t.ir (extern t "skunk_the_unit")
