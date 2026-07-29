(* A small WebAssembly binary writer: just enough of the format to lay out
   one module with an import, one exported function and a code section.
   Everything is written straight into a Buffer -- there is no relocation
   step, because sizes are known once each part is complete. *)

type valtype = I32 | I64 | F64

let valtype_byte = function I32 -> 0x7f | I64 -> 0x7e | F64 -> 0x7c

type buf = Buffer.t

let create () = Buffer.create 256
let u8 (b : buf) n = Buffer.add_char b (Char.unsafe_chr (n land 0xff))
let bytes (b : buf) s = Buffer.add_string b s

let rec uleb (b : buf) n =
  let x = n land 0x7f and rest = n lsr 7 in
  if rest = 0 then u8 b x
  else (
    u8 b (x lor 0x80);
    uleb b rest)

let rec sleb (b : buf) n =
  let x = n land 0x7f and rest = n asr 7 in
  if (rest = 0 && x land 0x40 = 0) || (rest = -1 && x land 0x40 <> 0) then u8 b x
  else (
    u8 b (x lor 0x80);
    sleb b rest)

let f64 (b : buf) x =
  let bits = Int64.bits_of_float x in
  for i = 0 to 7 do
    u8 b (Int64.to_int (Int64.shift_right_logical bits (8 * i)) land 0xff)
  done

let name (b : buf) s =
  uleb b (String.length s);
  bytes b s

let vec (b : buf) f items =
  uleb b (List.length items);
  List.iter (f b) items

(* ------------------------------------------------------- instructions *)

let local_get b i = u8 b 0x20; uleb b i
let local_set b i = u8 b 0x21; uleb b i
let global_get b i = u8 b 0x23; uleb b i
let global_set b i = u8 b 0x24; uleb b i
let call b i = u8 b 0x10; uleb b i
let f64_const b x = u8 b 0x44; f64 b x
let i32_const b n = u8 b 0x41; sleb b n
let i64_const b n = u8 b 0x42; sleb b n
let op b code = u8 b code

let f64_add = 0xa0
let f64_sub = 0xa1
let f64_mul = 0xa2
let f64_div = 0xa3
let f64_min = 0xa4
let f64_max = 0xa5
let f64_abs = 0x99
let f64_neg = 0x9a
let f64_ceil = 0x9b
let f64_floor = 0x9c
let f64_trunc = 0x9d
let f64_nearest = 0x9e
let f64_sqrt = 0x9f
let f64_eq = 0x61
let f64_ne = 0x62
let f64_lt = 0x63
let f64_gt = 0x64
let f64_le = 0x65
let f64_ge = 0x66
let i64_add = 0x7c
let i64_sub = 0x7d
let i64_mul = 0x7e
let i64_rem_s = 0x81
let i64_eq = 0x51
let i64_ne = 0x52
let i64_lt_s = 0x53
let i64_gt_s = 0x55
let i64_le_s = 0x57
let i64_ge_s = 0x59
let i64_eqz = 0x50
let f64_convert_i64_s = 0xb9
let i32_and = 0x71
let i32_or = 0x72
let i32_eqz = 0x45
let f64_convert_i32_u = 0xb8
let i32_trunc_f64_u = 0xab
let op_drop = 0x1a
let op_select = 0x1b
let op_end = 0x0b
let op_return = 0x0f

(* ------------------------------------------------------------- module *)

type functype = { args : valtype list; result : valtype option }
type import = { imp_module : string; imp_field : string; imp_type : int }

type funcbody = {
  (* one entry per run of locals of the same type, as the format wants *)
  body_locals : (int * valtype) list;
  body_code : buf;
}

let section (out : buf) id (contents : buf) =
  u8 out id;
  uleb out (Buffer.length contents);
  Buffer.add_buffer out contents

(* What an export points at: the module has functions and, since a graph's
   state has to outlive one call, mutable globals the host can read and set. *)
type exported = Func of int | Global of int | Memory

let encode ~(types : functype list) ~(imports : import list)
    ~(funcs : int list) ~(globals : (valtype * float) list)
    ~(exports : (string * exported) list) ~(data : string)
    ~(bodies : funcbody list) : string =
  let out = create () in
  bytes out "\000asm";
  bytes out "\001\000\000\000";
  let sub f =
    let b = create () in
    f b;
    b
  in
  section out 1
    (sub (fun b ->
         vec b
           (fun b t ->
             u8 b 0x60;
             vec b (fun b v -> u8 b (valtype_byte v)) t.args;
             match t.result with
             | None -> uleb b 0
             | Some v ->
                 uleb b 1;
                 u8 b (valtype_byte v))
           types));
  if imports <> [] then
    section out 2
      (sub (fun b ->
           vec b
             (fun b i ->
               name b i.imp_module;
               name b i.imp_field;
               u8 b 0x00;
               uleb b i.imp_type)
             imports));
  section out 3 (sub (fun b -> vec b (fun b t -> uleb b t) funcs));
  (* The only thing memory is for is the text a graph says: the literals are
     laid end to end at offset 0 and never written to, so one page is more
     than a graph will ever ask for. *)
  if data <> "" then
    section out 5
      (sub (fun b ->
           uleb b 1;
           u8 b 0x00;
           uleb b 1));
  (* Every global is mutable.  A state slot starts at zero and is assigned at
     the top of main, because what it really starts at can be any expression;
     an Input starts at the default it was drawn with, which is a constant and
     so can be the init the format allows. *)
  if globals <> [] then
    section out 6
      (sub (fun b ->
           vec b
             (fun b (v, init) ->
               u8 b (valtype_byte v);
               u8 b 0x01;
               (match v with
               | I32 -> u8 b 0x41; sleb b (int_of_float init)
               | I64 -> u8 b 0x42; sleb b (int_of_float init)
               | F64 -> u8 b 0x44; f64 b init);
               op b op_end)
             globals));
  section out 7
    (sub (fun b ->
         vec b
           (fun b (n, what) ->
             name b n;
             match what with
             | Func i -> u8 b 0x00; uleb b i
             | Memory -> u8 b 0x02; uleb b 0
             | Global i -> u8 b 0x03; uleb b i)
           exports));
  section out 10
    (sub (fun b ->
         vec b
           (fun b body ->
             let f = create () in
             vec f
               (fun f (n, v) ->
                 uleb f n;
                 u8 f (valtype_byte v))
               body.body_locals;
             Buffer.add_buffer f body.body_code;
             op f op_end;
             uleb b (Buffer.length f);
             Buffer.add_buffer b f)
           bodies));
  if data <> "" then
    section out 11
      (sub (fun b ->
           uleb b 1;
           uleb b 0;
           u8 b 0x41;
           sleb b 0;
           op b op_end;
           uleb b (String.length data);
           bytes b data));
  Buffer.contents out
