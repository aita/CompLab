(* The primitives, each written once with its type beside its value.

   The arithmetic and the comparisons are the reason Types carries a class at
   all: the grammar writes + and < with no way to say what they range over, so
   they range over Num and Ord and generalization defaults what is left. *)

open Types
open Value

let t2 a b r = TArrow (a, TArrow (b, r))

let poly ?(cls = NoCls) f =
  let r = ref (Unbound (next (), 0, cls)) in
  { s_vars = [ r ]; s_body = f (TVar r) }

let p1 name f = VPrim (name, f)
let p2 name f = VPrim (name, fun a -> VPrim (name, fun b -> f a b))

let arith name fi fr =
  p2 name (fun a b ->
      match (a, b) with
      | VInt x, VInt y -> VInt (fi x y)
      | VReal x, VReal y -> VReal (fr x y)
      | _ -> fail "%s wants two numbers of one type, not %s and %s" name (show a) (show b))

let cmp name test = p2 name (fun a b -> VBool (test (compare_v a b)))

let str = function VStr s -> s | v -> fail "a string was expected, not %s" (show v)
let int = function VInt n -> n | v -> fail "an int was expected, not %s" (show v)

let rec of_list = function [] -> VCon ("[]", None) | x :: xs -> VCon ("::", Some (VTuple [ x; of_list xs ]))

let rec to_list = function
  | VCon ("[]", None) -> []
  | VCon ("::", Some (VTuple [ h; t ])) -> h :: to_list t
  | v -> fail "a list was expected, not %s" (show v)

let div_int name f a b = if b = 0 then fail "%s by zero" name else f a b

(* name, type, value *)
let all =
  [ ("+", poly ~cls:Num (fun a -> t2 a a a), arith "+" ( + ) ( +. ));
    ("-", poly ~cls:Num (fun a -> t2 a a a), arith "-" ( - ) ( -. ));
    ("*", poly ~cls:Num (fun a -> t2 a a a), arith "*" ( * ) ( *. ));
    ("/", poly ~cls:Num (fun a -> t2 a a a), arith "/" (div_int "/" ( / )) ( /. ));
    ("%", mono (t2 t_int t_int t_int),
     p2 "%" (fun a b -> VInt (div_int "%" ( mod ) (int a) (int b))));
    ("^", mono (t2 t_string t_string t_string),
     p2 "^" (fun a b -> VStr (str a ^ str b)));
    ("==", poly (fun a -> t2 a a t_bool), p2 "==" (fun a b -> VBool (equal a b)));
    ("!=", poly (fun a -> t2 a a t_bool), p2 "!=" (fun a b -> VBool (not (equal a b))));
    ("<", poly ~cls:Ord (fun a -> t2 a a t_bool), cmp "<" (fun c -> c < 0));
    ("<=", poly ~cls:Ord (fun a -> t2 a a t_bool), cmp "<=" (fun c -> c <= 0));
    (">", poly ~cls:Ord (fun a -> t2 a a t_bool), cmp ">" (fun c -> c > 0));
    (">=", poly ~cls:Ord (fun a -> t2 a a t_bool), cmp ">=" (fun c -> c >= 0));
    ("print", mono (TArrow (t_string, t_unit)),
     p1 "print" (fun v -> print_string (str v); VUnit));
    ("println", mono (TArrow (t_string, t_unit)),
     p1 "println" (fun v -> print_string (str v); print_newline (); VUnit));
    ("intToString", mono (TArrow (t_int, t_string)),
     p1 "intToString" (fun v -> VStr (string_of_int (int v))));
    ("realToString", mono (TArrow (t_real, t_string)), p1 "realToString" (fun v -> VStr (show v)));
    ("charToString", mono (TArrow (t_char, t_string)),
     p1 "charToString" (fun v -> match v with VChar c -> VStr (String.make 1 c) | _ -> fail "a char was expected"));
    ("boolToString", mono (TArrow (t_bool, t_string)),
     p1 "boolToString" (fun v -> match v with VBool b -> VStr (if b then "true" else "false") | _ -> fail "a bool was expected"));
    ("intToReal", mono (TArrow (t_int, t_real)), p1 "intToReal" (fun v -> VReal (float_of_int (int v))));
    ("floor", mono (TArrow (t_real, t_int)),
     p1 "floor" (fun v -> match v with VReal r -> VInt (int_of_float (Float.floor r)) | _ -> fail "a real was expected"));
    ("ord", mono (TArrow (t_char, t_int)),
     p1 "ord" (fun v -> match v with VChar c -> VInt (Char.code c) | _ -> fail "a char was expected"));
    ("chr", mono (TArrow (t_int, t_char)),
     p1 "chr" (fun v ->
         let n = int v in
         if n < 0 || n > 255 then fail "chr is out of range: %d" n else VChar (Char.chr n)));
    ("size", mono (TArrow (t_string, t_int)), p1 "size" (fun v -> VInt (String.length (str v))));
    ("substring", mono (TArrow (TTup [ t_string; t_int; t_int ], t_string)),
     p1 "substring" (fun v ->
         match v with
         | VTuple [ s; i; n ] ->
           let s = str s and i = int i and n = int n in
           if i < 0 || n < 0 || i + n > String.length s then fail "substring is out of range"
           else VStr (String.sub s i n)
         | _ -> fail "substring wants a triple"));
    ("explode", mono (TArrow (t_string, t_list t_char)),
     p1 "explode" (fun v -> of_list (List.map (fun c -> VChar c) (List.init (String.length (str v)) (String.get (str v))))));
    ("implode", mono (TArrow (t_list t_char, t_string)),
     p1 "implode" (fun v ->
         let b = Buffer.create 16 in
         List.iter (function VChar c -> Buffer.add_char b c | _ -> fail "a char list was expected") (to_list v);
         VStr (Buffer.contents b)));
    ("error", poly (fun a -> TArrow (t_string, a)), p1 "error" (fun v -> fail "%s" (str v))) ]

let types = List.map (fun (n, t, _) -> (n, t)) all
let values = List.map (fun (n, _, v) -> (n, v)) all
