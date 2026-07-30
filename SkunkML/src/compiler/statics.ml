(* The static data the generated code refers to.

   Descriptors, string literals, nullary constructors, the closures the basis is
   made of, and one word per global.  All of it is interned: two records with the
   same labels share a descriptor, and the same string written twice is one
   block.  Interning is by the text of the thing, so the same program always
   produces the same data section and a dump can be diffed.

   Some of these names are fixed by the runtime rather than chosen here.  `nil`,
   `::`, `true`, `false` and `ref` are built-in constructors, and two
   constructors are equal only when their descriptors are the same pointer, so
   the code generator has to use the runtime's descriptors for them and not make
   its own. *)

module A = Asm

type datum =
  | Desc of { kind : int; nfields : int; con : string option; labels : string option; list : int; tag : int }
  | Labels of string list (* an array of pointers to string blocks *)
  | Str of string
  | Block of string * string option list (* descriptor, then one field per word *)
  | Word of string option (* a global slot: empty, or filled in by the linker *)

let table : (string, string) Hashtbl.t = Hashtbl.create 256 (* key -> label *)
let items : (string * datum) list ref = ref []
let counter = ref 0

let reset () =
  Hashtbl.reset table;
  items := [];
  counter := 0

let intern key prefix make =
  match Hashtbl.find_opt table key with
  | Some label -> label
  | None ->
      let label = Printf.sprintf "%s%d" prefix !counter in
      incr counter;
      Hashtbl.replace table key label;
      (* The name is registered before [make] runs, so that a datum which interns
         another datum cannot loop, and the datum is added after, so that
         whatever it interned is already in the list.  Writing this as one
         expression would drop the nested item: the right-hand side of the cons
         is read before [make] mutates it. *)
      let d = make () in
      items := (label, d) :: !items;
      label

(* A name from the source, in a form the assembler can carry.  Anything that is
   not a letter, a digit or an underscore becomes its hex code, so `^` and `<=`
   get labels and two different names never collide. *)
let mangle s =
  let b = Buffer.create (String.length s + 8) in
  String.iter
    (fun c ->
      if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_' then
        Buffer.add_char b c
      else Buffer.add_string b (Printf.sprintf "_%02x" (Char.code c)))
    s;
  Buffer.contents b

(* A code block's label.  Prefixed, so that a name from the source can never
   collide with one of the runtime's. *)
let code_label s = "code_" ^ mangle s

let str s = intern ("s:" ^ s) "str_" (fun () -> Str s)

let labels ls =
  intern ("l:" ^ String.concat "\000" ls) "labels_" (fun () -> Labels (List.map str ls))

let k_record = 0
let k_con = 1
let k_closure = 3

(* A record's descriptor.  Labels 1, 2, ... n mean a tuple, and a tuple prints
   without them, so it does not need the array at all. *)
let record_desc ls =
  let n = List.length ls in
  let tuple = List.for_all2 (fun i l -> l = string_of_int i) (List.init n (fun i -> i + 1)) ls in
  let ls_label = if tuple then None else Some (labels ls) in
  intern
    (Printf.sprintf "dr:%d:%s" n (match ls_label with None -> "" | Some l -> l))
    "desc_rec_"
    (fun () ->
      Desc { kind = k_record; nfields = n; con = None; labels = ls_label; list = 0; tag = 0 })

let closure_desc ncaps =
  intern (Printf.sprintf "dc:%d" ncaps) "desc_clos_" (fun () ->
      Desc { kind = k_closure; nfields = ncaps + 1; con = None; labels = None; list = 0; tag = 0 })

(* Which built-in constructor this is, if it is one: its descriptor, and the
   static block for it when it carries nothing. *)
let builtin (c : Types.constr) =
  let tid = c.Types.cres.Types.tid in
  if tid = Types.list_tc.Types.tid then
    Some (if c.Types.cidx = 0 then ("skunk_nil_desc", Some "skunk_nil") else ("skunk_cons_desc", None))
  else if tid = Types.bool_tc.Types.tid then
    Some
      (if c.Types.cidx = 0 then ("skunk_false_desc", Some "skunk_false")
       else ("skunk_true_desc", Some "skunk_true"))
  else if tid = Types.ref_tc.Types.tid then Some ("skunk_ref_desc", None)
  else None

let con_desc (c : Types.constr) =
  match builtin c with
  | Some (d, _) -> d
  | None ->
      let nfields = match c.Types.carg with None -> 0 | Some _ -> 1 in
      intern
        (Printf.sprintf "dk:%d:%d" c.Types.cres.Types.tid c.Types.cidx)
        "desc_con_"
        (fun () ->
          Desc
            {
              kind = k_con;
              nfields;
              con = Some (str c.Types.cname);
              labels = None;
              list = 0;
              tag = c.Types.cidx;
            })

(* A constructor that carries nothing is the same value every time, so it is
   static rather than allocated. *)
let nullary (c : Types.constr) =
  match builtin c with
  | Some (_, Some block) -> block
  | _ ->
      let d = con_desc c in
      intern
        (Printf.sprintf "nk:%d:%d" c.Types.cres.Types.tid c.Types.cidx)
        "con_"
        (fun () -> Block (d, []))

(* A closure that captures nothing is static too, which is what makes the whole
   basis static data: a name like `print` is a global whose word the linker
   fills in with the address of a block that was assembled, not built. *)
let static_closure code =
  intern ("sc:" ^ code) "clos_" (fun () -> Block (closure_desc 0, [ Some code ]))

let static_record ls fields =
  intern
    (Printf.sprintf "sr:%s:%s" (String.concat "\000" ls) (String.concat "\000" fields))
    "rec_"
    (fun () -> Block (record_desc ls, List.map (fun f -> Some f) fields))

(* A global's label is its name, not a number, because two compilations of the
   same program have to agree on it and because a dump is easier to read. *)
let global name init =
  let key = "g:" ^ name and label = "skunk_g_" ^ mangle name in
  if not (Hashtbl.mem table key) then begin
    Hashtbl.replace table key label;
    items := (label, Word init) :: !items
  end;
  label

(* ---- writing it out ------------------------------------------------------- *)

let write st =
  List.iter
    (fun (label, d) ->
      match d with
      | Desc { kind; nfields; con; labels; list; tag } ->
          Rt.descriptor st label ~kind ~nfields ~con ~labels ~list ~tag
      | Labels ls ->
          A.align st 8;
          A.label st label;
          List.iter (fun l -> A.dq_sym st l) ls
      | Str s -> Rt.string_block st label s
      | Block (desc, fields) ->
          A.align st 8;
          A.dq_sym st desc;
          A.label st label;
          List.iter (function None -> A.dq st 1 | Some s -> A.dq_sym st s) fields
      | Word init ->
          A.align st 8;
          A.label st label;
          (* Tagged zero, so that a global read before it is written is at least
             a well-formed value. *)
          (match init with None -> A.dq st 1 | Some s -> A.dq_sym st s))
    (List.rev !items)
