(* Arithmetic: what is/2 and the arithmetic comparisons evaluate.

   Prolog keeps integers and floats apart and says exactly when a result
   crosses over.  The rules that matter: `/` on two integers is an integer
   when it divides exactly and a float otherwise; `**` is always float; `^` on
   two integers stays integer; and the four integer division operators differ
   in how they round and in whose sign the remainder takes. *)

let who = "is/2"

let to_float = function Term.Int n -> float_of_int n | Term.Float f -> f | _ -> assert false
let is_int = function Term.Int _ -> true | _ -> false

let want_int t = match t with Term.Int n -> n | t -> Term.type_error "integer" t who
let zero_divisor () = Term.evaluation_error "zero_divisor" who

(* `//` truncates toward zero and `div` rounds toward negative infinity; `rem`
   takes the sign of the dividend and `mod` the sign of the divisor.  OCaml's
   own `/` and `mod` are the truncating pair, so those two are free and the
   other two are corrections of them. *)
let int_quotient a b = if b = 0 then zero_divisor () else a / b
let int_rem a b = if b = 0 then zero_divisor () else a mod b

let int_div a b =
  if b = 0 then zero_divisor ()
  else if (a < 0) <> (b < 0) && a mod b <> 0 then (a / b) - 1
  else a / b

let int_mod a b =
  if b = 0 then zero_divisor ()
  else
    let r = a mod b in
    if r <> 0 && (r < 0) <> (b < 0) then r + b else r

let int_pow base exp =
  if exp < 0 then
    match base with
    | 1 -> 1
    | -1 -> if exp mod 2 = 0 then 1 else -1
    | 0 -> zero_divisor ()
    | _ -> Term.type_error "float" (Term.Int exp) who
  else
    let rec go acc base exp =
      if exp = 0 then acc
      else if exp land 1 = 1 then go (acc * base) (base * base) (exp lsr 1)
      else go acc (base * base) (exp lsr 1)
    in
    go 1 base exp

let constant name =
  match name with
  | "pi" -> Term.Float Float.pi
  | "e" -> Term.Float (Float.exp 1.0)
  | "inf" | "infinite" -> Term.Float Float.infinity
  | "nan" -> Term.Float Float.nan
  | "epsilon" -> Term.Float epsilon_float
  | "max_tagged_integer" | "max_integer" -> Term.Int max_int
  | "min_tagged_integer" | "min_integer" -> Term.Int min_int
  | "random" -> Term.Float (Random.float 1.0)
  | "cputime" -> Term.Float (Sys.time ())
  | "realtime" -> Term.Int (int_of_float (Unix.gettimeofday ()))
  | _ -> Term.type_error "evaluable" (Term.indicator_term (name, 0)) who

let float_fn name f x = ignore name; Term.Float (f (to_float x))

let rec eval t =
  match Term.deref t with
  | (Term.Int _ | Term.Float _) as n -> n
  | Term.Var _ -> Term.instantiation_error who
  | Term.Atom name -> constant name
  (* A one-element list evaluates to its element, so that `X is "a"` works
     when double_quotes is codes. *)
  | Term.Struct (".", [| x; tail |]) when Term.deref tail = Term.nil -> eval x
  | Term.Struct (name, [| a |]) -> unary name (eval a)
  | Term.Struct (name, [| a; b |]) -> binary name (eval a) (eval b)
  | t ->
      let name, arity = Term.indicator_of t who in
      Term.type_error "evaluable" (Term.indicator_term (name, arity)) who

and unary name x =
  match name with
  | "-" -> ( match x with Term.Int n -> Term.Int (-n) | x -> Term.Float (-.to_float x))
  | "+" -> x
  | "abs" -> ( match x with Term.Int n -> Term.Int (abs n) | x -> Term.Float (Float.abs (to_float x)))
  | "sign" -> ( match x with Term.Int n -> Term.Int (compare n 0) | x -> Term.Float (float_of_int (compare (to_float x) 0.0)))
  | "min" | "max" -> Term.type_error "evaluable" (Term.indicator_term (name, 1)) who
  | "sqrt" -> float_fn name sqrt x
  | "sin" -> float_fn name sin x
  | "cos" -> float_fn name cos x
  | "tan" -> float_fn name tan x
  | "asin" -> float_fn name asin x
  | "acos" -> float_fn name acos x
  | "atan" -> float_fn name atan x
  | "sinh" -> float_fn name sinh x
  | "cosh" -> float_fn name cosh x
  | "tanh" -> float_fn name tanh x
  | "exp" -> float_fn name exp x
  | "log" ->
      let v = to_float x in
      if v <= 0.0 then Term.evaluation_error "undefined" who else Term.Float (log v)
  | "log2" -> float_fn name (fun v -> log v /. log 2.0) x
  | "float" -> Term.Float (to_float x)
  | "integer" -> ( match x with Term.Int _ -> x | x -> Term.Int (int_of_float (Float.round (to_float x))))
  | "float_integer_part" -> Term.Float (Float.trunc (to_float x))
  | "float_fractional_part" -> let v = to_float x in Term.Float (v -. Float.trunc v)
  | "truncate" -> Term.Int (int_of_float (Float.trunc (to_float x)))
  | "round" -> Term.Int (int_of_float (Float.round (to_float x)))
  | "ceiling" -> Term.Int (int_of_float (Float.ceil (to_float x)))
  | "floor" -> Term.Int (int_of_float (Float.floor (to_float x)))
  | "\\" -> Term.Int (lnot (want_int x))
  | "msb" ->
      let n = want_int x in
      if n <= 0 then Term.type_error "positive_integer" x who
      else
        let rec go i = if n lsr i = 0 then i - 1 else go (i + 1) in
        Term.Int (go 0)
  | "succ" -> Term.Int (want_int x + 1)
  | _ -> Term.type_error "evaluable" (Term.indicator_term (name, 1)) who

and binary name x y =
  let both_int = is_int x && is_int y in
  let floats f = Term.Float (f (to_float x) (to_float y)) in
  let ints f = Term.Int (f (want_int x) (want_int y)) in
  match name with
  | "+" -> if both_int then ints ( + ) else floats ( +. )
  | "-" -> if both_int then ints ( - ) else floats ( -. )
  | "*" -> if both_int then ints ( * ) else floats ( *. )
  | "/" ->
      if both_int then begin
        let a = want_int x and b = want_int y in
        if b = 0 then zero_divisor ()
        else if a mod b = 0 then Term.Int (a / b)
        else Term.Float (float_of_int a /. float_of_int b)
      end
      else if to_float y = 0.0 then zero_divisor ()
      else floats ( /. )
  | "//" -> ints int_quotient
  | "div" -> ints int_div
  | "mod" -> ints int_mod
  | "rem" -> ints int_rem
  | "min" -> if compare_num x y <= 0 then x else y
  | "max" -> if compare_num x y >= 0 then x else y
  | "**" -> floats Float.pow
  | "^" -> if both_int then ints int_pow else floats Float.pow
  | ">>" -> ints (fun a b -> a asr b)
  | "<<" -> ints (fun a b -> a lsl b)
  | "/\\" -> ints ( land )
  | "\\/" -> ints ( lor )
  | "xor" -> ints ( lxor )
  | "gcd" ->
      let rec gcd a b = if b = 0 then abs a else gcd b (a mod b) in
      ints gcd
  | "atan2" | "atan" -> floats Float.atan2
  | "copysign" -> floats Float.copy_sign
  | "truncate" -> Term.type_error "evaluable" (Term.indicator_term (name, 2)) who
  | _ -> Term.type_error "evaluable" (Term.indicator_term (name, 2)) who

(* Numbers compare by value here, unlike the standard order of terms, where an
   integer and a float of equal value are still distinguishable. *)
and compare_num x y =
  match (x, y) with
  | Term.Int a, Term.Int b -> compare a b
  | _ -> Float.compare (to_float x) (to_float y)

let compare_eval a b = compare_num (eval a) (eval b)
