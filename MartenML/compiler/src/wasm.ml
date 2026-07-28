(* The WebAssembly back end: the closure-converted tree straight into wat.

   This pass replaces Linear, Selection, Liveness, Regalloc, Peephole and Emit
   -- six passes and about fifteen hundred lines -- with one, and it does so by
   not needing any of them.

   Linear exists because machine code is a graph and the tree Closure hands
   over is not: an `if` carries its two arms inside it, and somebody has to
   turn that into blocks that end in a terminator.  WebAssembly is not machine
   code.  Its control flow is structured -- `if`/`else`/`end`, nested, with no
   way to jump into the middle of anything -- so an `if` with two arms is
   already what the target spells, and the tree survives all the way to the
   output.  There is nothing to linearize, so there is no control-flow graph
   and nothing to check for cycles.

   Register allocation goes the same way.  A wasm function declares as many
   locals as it likes and the engine assigns the real registers, so every value
   Closure names becomes a local and the interference graph never gets built.
   What the allocator bought -- values in registers, callee-saved registers
   saved only when used, moves coalesced away -- is the engine's problem now.

   (The eight-argument limit stays, even though nothing here needs it: it is
   checked in Typing, in terms of `Riscv.max_args`, so that a program is
   accepted or rejected for the same reasons whichever target it is headed
   for.  A wasm function may take as many parameters as it likes.)

   What does not change is the shape of the data.  Every value is still one
   64-bit word: an integer, or an address.  Tuples, constructor blocks, strings
   and closures have byte-for-byte the layout doc/emit.md describes, in linear
   memory instead of a process heap.  Addresses are 32 bits wide here and the
   words that hold them are 64, which is why loads and stores wrap.

   Three things do have to be spelled differently.

   - A code pointer is not an address.  wasm functions are not values in linear
     memory, so a closure's first word holds an index into the module's
     function table, and a call through a closure is `call_indirect`.

   - Every function takes its environment as an extra first parameter.  The
     RISC-V back end hands the closure over in `t6`, a register outside the
     argument sequence, and can therefore leave the parameter list alone.
     `call_indirect` checks the callee's whole type against the one written at
     the call site, so the environment has to be in that type -- and it has to
     be there for every function, since the call site cannot know whether the
     one it reaches captures anything.  A direct call passes 0.

   - There is no linker.  runtime/martenml_runtime.wat is a fragment rather
     than a module, and this pass copies it into every module it emits -- which
     is the whole of what linking means here.  Where the RISC-V driver hands
     the runtime to `gcc`, this one hands its path to `-runtime`.

   The output is the text format, which is to wasm what assembly is to a
   machine, and is what `emit.ml` prints for the other target. *)

exception Error of string

let word = 8
let page = 65536

(* The runtime owns everything below this; see runtime/martenml_runtime.wat. *)
let static_base = 4096

let out = ref stdout

(* Where each read-only block ended up, and which table slot each function
   went into.  Both are filled in before a single instruction is emitted. *)
let statics : (Ident.label, int) Hashtbl.t = Hashtbl.create 32
let table_slots : (Ident.label, int) Hashtbl.t = Hashtbl.create 32
let program_labels : (Ident.label, unit) Hashtbl.t = Hashtbl.create 32

let static_address label =
  match Hashtbl.find_opt statics label with
  | Some address -> address
  | None -> failwith (Printf.sprintf "Wasm: no read-only block named `%s'" label)

let table_slot label =
  match Hashtbl.find_opt table_slots label with
  | Some slot -> slot
  | None -> failwith (Printf.sprintf "Wasm: `%s' is not a function of this module" label)

(* A call to something this module defines takes the environment; a call to the
   runtime does not. *)
let is_runtime label = not (Hashtbl.mem program_labels label)

(* ------------------------------------------------------------------ names *)

(* wat's identifiers accept nearly everything a MartenML name can contain,
   including the `.` that [Ident.fresh] appends and the ML prime, so a local
   keeps the name the earlier dumps show it under. *)
let is_idchar = function
  | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' -> true
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '/' | ':' | '<'
  | '=' | '>' | '?' | '@' | '\\' | '^' | '_' | '`' | '|' | '~' ->
    true
  | _ -> false

let name x = "$" ^ String.map (fun c -> if is_idchar c then c else '_') x

(* The two names this pass introduces: the environment every function takes,
   and the address of a block while its fields are being stored.  A source name
   cannot look like either -- α-conversion only ever appends `.` and digits --
   so neither collides with anything the program named. *)
let env_local = "$wasm.env"
let block_local = "$wasm.block"

(* ------------------------------------------------------------ static data *)

let little_endian n =
  String.init 8 (fun i -> Char.chr ((n asr (i * 8)) land 0xff))

(* Printable text as itself; everything else as \XX, which is what a wat data
   segment spells. *)
let escape text =
  let b = Buffer.create (String.length text + 8) in
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | c when c >= ' ' && c <= '~' -> Buffer.add_char b c
      | c -> Buffer.add_string b (Printf.sprintf "\\%02x" (Char.code c)))
    text;
  Buffer.contents b

(* Lay the read-only blocks out from [static_base] up, eight-aligned, and hand
   back where they end: that is where the heap begins. *)
let layout_statics () =
  Hashtbl.reset statics;
  let address = ref static_base in
  let segments = ref [] in
  let place label comment bytes =
    Hashtbl.replace statics label !address;
    segments := (!address, comment, bytes) :: !segments;
    address := !address + ((String.length bytes + 7) / 8 * 8)
  in
  place Datatype.nil_label "the empty list" (little_endian 0);
  List.iter
    (fun (d : Datatype.decl) ->
      List.iter
        (fun (c : Datatype.constr) ->
          place (Datatype.const_label c)
            (Printf.sprintf "%s.%s" (Ident.display c.owner) (Ident.display c.cname))
            (little_endian c.tag))
        (List.filter Datatype.is_constant d.constrs))
    (Datatype.all_decls ());
  List.iter
    (fun (label, text) ->
      place label (Printf.sprintf "%S" text) (little_endian (String.length text) ^ text))
    (Literals.all ());
  (List.rev !segments, !address)

(* --------------------------------------------------------- the instructions *)

type ctx = {
  body : Buffer.t;
  mutable depth : int;
  mutable consts : int Ident.Map.t; (* only to skip a divisor test, as in Linear *)
  mutable uses_block_local : bool;
}

let emit ctx fmt =
  Printf.ksprintf
    (fun text ->
      Buffer.add_string ctx.body (String.make (ctx.depth * 2) ' ');
      Buffer.add_string ctx.body text;
      Buffer.add_char ctx.body '\n')
    fmt

let get ctx x = emit ctx "local.get %s" (name x)

(* An address in a 64-bit word, ready for a load or a store. *)
let address ctx x =
  get ctx x;
  emit ctx "i32.wrap_i64"

let binop = function
  | Knormal.Add -> "i64.add"
  | Knormal.Sub -> "i64.sub"
  | Knormal.Mul -> "i64.mul"
  | Knormal.Div -> "i64.div_s"
  | Knormal.Rem -> "i64.rem_s"

(* The arms of a comparison that K-normalization turned into a value.  wasm
   compares into an i32 0 or 1, so this is the whole of it: no branch, and no
   diamond of blocks for the peephole pass this back end does not have. *)
let is_boolean_pair a b = (a = 1 && b = 0) || (a = 0 && b = 1)

(* Division by zero is a language-level error with a message of its own, and
   wasm's own trap would report something else and unwind differently.  A
   constant divisor that is not zero needs no test -- the same case Linear
   tracks constants for. *)
let check_divisor ctx y =
  match Ident.Map.find_opt y ctx.consts with
  | Some n when n <> 0 -> ()
  | _ ->
    get ctx y;
    emit ctx "i64.eqz";
    emit ctx "if";
    ctx.depth <- ctx.depth + 1;
    emit ctx "call $martenml_division_by_zero";
    emit ctx "unreachable";
    ctx.depth <- ctx.depth - 1;
    emit ctx "end"

(* Allocate [bytes] and leave the address in [block_local], as an i32. *)
let allocate ctx bytes =
  ctx.uses_block_local <- true;
  emit ctx "i64.const %d" bytes;
  emit ctx "call $martenml_alloc";
  emit ctx "i32.wrap_i64";
  emit ctx "local.set %s" block_local

let store_field ctx index x =
  emit ctx "local.get %s" block_local;
  get ctx x;
  emit ctx "i64.store offset=%d" (index * word)

let finish_block ctx =
  emit ctx "local.get %s" block_local;
  emit ctx "i64.extend_i32_u"

(* [tail] is the only thing that changes between a value and the value of the
   whole function, because nothing else has to: an `if` in tail position is the
   same `if`, and its result falls out of the function the way any other value
   would.  A call is different -- `return_call` is what keeps a loop written as
   tail recursion from growing the stack. *)
let rec generate ctx ~tail exp =
  match exp with
  | Closure.Let ((x, _), Closure.Int n, body) ->
    emit ctx "i64.const %d" n;
    emit ctx "local.set %s" (name x);
    ctx.consts <- Ident.Map.add x n ctx.consts;
    generate ctx ~tail body
  | Closure.Let ((x, _), value, body) ->
    generate ctx ~tail:false value;
    emit ctx "local.set %s" (name x);
    generate ctx ~tail body
  | Closure.Let_tuple (xts, tuple, body) ->
    List.iteri
      (fun i (x, _) ->
        address ctx tuple;
        emit ctx "i64.load offset=%d" (i * word);
        emit ctx "local.set %s" (name x))
      xts;
    generate ctx ~tail body
  | Closure.Make_closures (definitions, body) ->
    (* Allocate every block and bind every name first, then fill them in: a
       closure may capture itself or a sibling, and neither address exists
       until its block does. *)
    List.iter
      (fun ((x, _), (c : Closure.closure)) ->
        emit ctx "i64.const %d" ((1 + List.length c.captured) * word);
        emit ctx "call $martenml_alloc";
        emit ctx "local.set %s" (name x))
      definitions;
    List.iter
      (fun ((x, _), (c : Closure.closure)) ->
        ctx.uses_block_local <- true;
        address ctx x;
        emit ctx "local.set %s" block_local;
        emit ctx "local.get %s" block_local;
        emit ctx "i64.const %d ;; %s" (table_slot c.entry) c.entry;
        emit ctx "i64.store";
        List.iteri (fun i z -> store_field ctx (i + 1) z) c.captured)
      definitions;
    generate ctx ~tail body
  | Closure.If_eq (x, y, Closure.Int a, Closure.Int b) when is_boolean_pair a b ->
    get ctx x;
    get ctx y;
    emit ctx "%s" (if a = 1 then "i64.eq" else "i64.ne");
    emit ctx "i64.extend_i32_u"
  | Closure.If_le (x, y, Closure.Int a, Closure.Int b) when is_boolean_pair a b ->
    get ctx x;
    get ctx y;
    emit ctx "%s" (if a = 1 then "i64.le_s" else "i64.gt_s");
    emit ctx "i64.extend_i32_u"
  | Closure.If_eq (x, y, then_, else_) -> conditional ctx ~tail "i64.eq" x y then_ else_
  | Closure.If_le (x, y, then_, else_) -> conditional ctx ~tail "i64.le_s" x y then_ else_
  | Closure.Call_direct (label, args) ->
    if not (is_runtime label) then emit ctx "i64.const 0 ;; no environment";
    List.iter (get ctx) args;
    emit ctx "%s %s" (if tail then "return_call" else "call") (name label)
  | Closure.Call_closure (f, args) ->
    (* The closure is its own environment, and its first word says which
       function to enter. *)
    get ctx f;
    List.iter (get ctx) args;
    address ctx f;
    emit ctx "i64.load";
    emit ctx "i32.wrap_i64";
    emit ctx "%s (type $fn%d)"
      (if tail then "return_call_indirect" else "call_indirect")
      (List.length args)
  | Closure.Int n -> emit ctx "i64.const %d" n
  | Closure.Var x -> get ctx x
  | Closure.Neg x ->
    emit ctx "i64.const 0";
    get ctx x;
    emit ctx "i64.sub"
  | Closure.Static label -> emit ctx "i64.const %d ;; %s" (static_address label) label
  | Closure.Bin (op, x, y) ->
    (match op with Knormal.Div | Knormal.Rem -> check_divisor ctx y | _ -> ());
    get ctx x;
    get ctx y;
    emit ctx "%s" (binop op)
  | Closure.Field (x, i) ->
    address ctx x;
    emit ctx "i64.load offset=%d" (i * word)
  | Closure.Byte (s, i) ->
    (* The bytes start one word into the block, so the length word is the
       offset and the index is added to the base. *)
    address ctx s;
    address ctx i;
    emit ctx "i32.add";
    emit ctx "i32.load8_u offset=%d" word;
    emit ctx "i64.extend_i32_u"
  | Closure.Tuple xs ->
    allocate ctx (List.length xs * word);
    List.iteri (fun i x -> store_field ctx i x) xs;
    finish_block ctx
  | Closure.Block (tag, xs) ->
    allocate ctx ((1 + List.length xs) * word);
    emit ctx "local.get %s" block_local;
    emit ctx "i64.const %d" tag;
    emit ctx "i64.store";
    List.iteri (fun i x -> store_field ctx (i + 1) x) xs;
    finish_block ctx
  | Closure.Array (size, init) ->
    get ctx size;
    get ctx init;
    emit ctx "call $martenml_make_array"
  | Closure.Get (arr, index) ->
    element_address ctx arr index;
    emit ctx "i64.load"
  | Closure.Put (arr, index, v) ->
    element_address ctx arr index;
    get ctx v;
    emit ctx "i64.store";
    emit ctx "i64.const 0"

and element_address ctx arr index =
  address ctx arr;
  address ctx index;
  emit ctx "i32.const 3";
  emit ctx "i32.shl";
  emit ctx "i32.add"

and conditional ctx ~tail op x y then_ else_ =
  get ctx x;
  get ctx y;
  emit ctx "%s" op;
  emit ctx "if (result i64)";
  let saved = ctx.consts in
  ctx.depth <- ctx.depth + 1;
  generate ctx ~tail then_;
  ctx.depth <- ctx.depth - 1;
  emit ctx "else";
  ctx.consts <- saved;
  ctx.depth <- ctx.depth + 1;
  generate ctx ~tail else_;
  ctx.depth <- ctx.depth - 1;
  ctx.consts <- saved;
  emit ctx "end"

(* --------------------------------------------------------------- functions *)

(* Every name the body binds becomes a local.  α-conversion has already made
   them unique, so this is a walk and not an analysis. *)
let locals_of body =
  let seen = Hashtbl.create 64 in
  let order = ref [] in
  let add x =
    if not (Hashtbl.mem seen x) then begin
      Hashtbl.replace seen x ();
      order := x :: !order
    end
  in
  let rec walk = function
    | Closure.Let ((x, _), value, body) ->
      add x;
      walk value;
      walk body
    | Closure.Let_tuple (xts, _, body) ->
      List.iter (fun (x, _) -> add x) xts;
      walk body
    | Closure.Make_closures (definitions, body) ->
      List.iter (fun ((x, _), _) -> add x) definitions;
      walk body
    | Closure.If_eq (_, _, a, b) | Closure.If_le (_, _, a, b) ->
      walk a;
      walk b
    | _ -> ()
  in
  walk body;
  List.rev !order

let function_ (fd : Closure.fundef) =
  let ctx =
    { body = Buffer.create 1024; depth = 2; consts = Ident.Map.empty; uses_block_local = false }
  in
  (* The captured values are read out of the environment once, on entry, and
     are ordinary locals from then on. *)
  List.iteri
    (fun i (z, _) ->
      emit ctx "local.get %s" env_local;
      emit ctx "i32.wrap_i64";
      emit ctx "i64.load offset=%d" ((i + 1) * word);
      emit ctx "local.set %s" (name z))
    fd.captures;
  generate ctx ~tail:true fd.body;
  Printf.fprintf !out "\n  (func %s (param %s i64)" (name fd.label) env_local;
  List.iter (fun (x, _) -> Printf.fprintf !out " (param %s i64)" (name x)) fd.args;
  Printf.fprintf !out " (result i64)\n";
  (* The captures are locals too: they are read out of the environment on
     entry and are indistinguishable from anything the body binds after that. *)
  List.iter
    (fun x -> Printf.fprintf !out "    (local %s i64)\n" (name x))
    (List.map fst fd.captures @ locals_of fd.body);
  if ctx.uses_block_local then Printf.fprintf !out "    (local %s i32)\n" block_local;
  Buffer.output_buffer !out ctx.body;
  Printf.fprintf !out "  )\n"

(* ----------------------------------------------------------- the module *)

(* Every arity a `call_indirect` can name.  The type it names has to be written
   out, and it counts the environment. *)
let arities functions =
  let found = ref [] in
  let note n = if not (List.mem n !found) then found := n :: !found in
  let rec walk = function
    | Closure.Call_closure (_, args) -> note (List.length args)
    | Closure.Let (_, a, b) | Closure.If_eq (_, _, a, b) | Closure.If_le (_, _, a, b) ->
      walk a;
      walk b
    | Closure.Let_tuple (_, _, e) | Closure.Make_closures (_, e) -> walk e
    | _ -> ()
  in
  List.iter
    (fun (fd : Closure.fundef) ->
      note (List.length fd.args);
      walk fd.body)
    functions;
  List.sort compare !found

(* Copy the runtime in.  It is a fragment -- imports, globals, data and
   functions, with no `(module ...)` around them -- so this is a copy and not a
   parse: the two halves become one module because they are printed into one. *)
let copy_runtime path =
  let channel = try open_in_bin path with Sys_error msg -> raise (Error msg) in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () ->
      let length = in_channel_length channel in
      Printf.fprintf !out "%s" (really_input_string channel length))

let program channel ~runtime (converted : Closure.program) =
  out := channel;
  let functions =
    converted.functions
    @ [ { Closure.label = "martenml_main"; args = []; captures = []; body = converted.main } ]
  in
  Hashtbl.reset program_labels;
  Hashtbl.reset table_slots;
  List.iteri
    (fun slot (fd : Closure.fundef) ->
      Hashtbl.replace program_labels fd.label ();
      Hashtbl.replace table_slots fd.label slot)
    functions;
  let segments, static_end = layout_statics () in
  (* Enough pages for the static data, and one to start the heap in.  The
     runtime asks for more when it runs out. *)
  let pages = max 2 (((static_end + page - 1) / page) + 1) in
  Printf.fprintf !out "(module\n";
  copy_runtime runtime;
  Printf.fprintf !out "\n  ;; ------------------------------------------- the program\n\n";
  Printf.fprintf !out "  (memory (export \"memory\") %d)\n\n" pages;
  Printf.fprintf !out
    "  ;; One per arity a call through a closure can have.  The first parameter\n\
    \  ;; is the environment, which every function takes so that every function\n\
    \  ;; has a type a `call_indirect` can name.\n";
  List.iter
    (fun n ->
      Printf.fprintf !out "  (type $fn%d (func" n;
      for _ = 0 to n do
        Printf.fprintf !out " (param i64)"
      done;
      Printf.fprintf !out " (result i64)))\n")
    (arities functions);
  Printf.fprintf !out
    "\n  ;; A closure's first word is a slot in this table, not an address:\n\
    \  ;; wasm functions do not live in linear memory.\n";
  Printf.fprintf !out "  (table %d funcref)\n" (List.length functions);
  Printf.fprintf !out "  (elem (i32.const 0)\n";
  List.iter
    (fun (fd : Closure.fundef) -> Printf.fprintf !out "    %s\n" (name fd.label))
    functions;
  Printf.fprintf !out "  )\n";
  Printf.fprintf !out "\n  ;; The read-only blocks: constant constructors and string literals.\n";
  List.iter
    (fun (address, comment, bytes) ->
      Printf.fprintf !out "  (data (i32.const %d) \"%s\") ;; %s\n" address (escape bytes) comment)
    segments;
  List.iter function_ functions;
  Printf.fprintf !out
    "\n\
    \  ;; The heap starts where the static data ends, and runs to the end of\n\
    \  ;; the memory the module was given.\n\
    \  (func (export \"_start\")\n\
    \    (global.set $heap_next (i32.const %d))\n\
    \    (global.set $heap_end (i32.mul (memory.size) (i32.const %d)))\n\
    \    (drop (call $martenml_main (i64.const 0)))\n\
    \    (call $flush)\n\
    \  )\n"
    static_end page;
  Printf.fprintf !out ")\n"
