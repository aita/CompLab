(* A small WebAssembly binary writer: just enough of the format to lay out
   one module with an import, one exported function and a code section.
   Everything is written straight into a Buffer -- there is no relocation
   step, because sizes are known once each part is complete. *)

type valtype = I32 | F64

let valtype_byte = function I32 -> 0x7f | F64 -> 0x7c

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
let call b i = u8 b 0x10; uleb b i
let f64_const b x = u8 b 0x44; f64 b x
let i32_const b n = u8 b 0x41; sleb b n
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
let i32_and = 0x71
let i32_or = 0x72
let i32_eqz = 0x45
let op_block = 0x02
let op_loop = 0x03
let op_if = 0x04
let op_else = 0x05
let op_end = 0x0b
let op_br = 0x0c
let op_br_if = 0x0d
let op_return = 0x0f
let blocktype_void = 0x40

let block b f =
  op b op_block;
  u8 b blocktype_void;
  f ();
  op b op_end

let loop b f =
  op b op_loop;
  u8 b blocktype_void;
  f ();
  op b op_end

let if_else b ~then_ ~else_ =
  op b op_if;
  u8 b blocktype_void;
  then_ ();
  (match else_ with
  | None -> ()
  | Some e ->
      op b op_else;
      e ());
  op b op_end

let br b depth = op b op_br; uleb b depth
let br_if b depth = op b op_br_if; uleb b depth

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

let encode ~(types : functype list) ~(imports : import list)
    ~(funcs : int list) ~(exports : (string * int) list)
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
  section out 7
    (sub (fun b ->
         vec b
           (fun b (n, idx) ->
             name b n;
             u8 b 0x00;
             uleb b idx)
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
  Buffer.contents out
