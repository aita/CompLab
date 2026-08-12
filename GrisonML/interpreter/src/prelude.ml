(* The prelude, in GrisonML.  It is parsed, checked and evaluated by exactly
   the pipeline a program is, before the program is, so nothing in it is
   privileged: option is a type declaration, List is a mod, and the names it
   binds can be shadowed.

   Adjacent "fun" declarations are one recursive group, and a group is
   monomorphic while it is being checked, so a function that uses another at
   two types has to be written out rather than defined in terms of it -- which
   is why concat recurses instead of folding append. *)

let source =
  {gr|
type 'a option = None | Some 'a
type ('a, 'b) either = Left 'a | Right 'b

fun id x = x
fun ignore _ = ()
fun fst (a, _) = a
fun snd (_, b) = b

mod Option
  fun isSome o = case o of None => false | Some _ => true
  fun getOpt (o, d) = case o of None => d | Some v => v
  fun valOf o = case o of None => error "Option.valOf: None" | Some v => v
  fun map f o = case o of None => None | Some v => Some (f v)
end

mod List
  fun length xs = case xs of [] => 0 | _ :: t => 1 + length t

  fun append xs ys = case xs of [] => ys | h :: t => h :: append t ys

  fun rev xs =
    let fun go acc ys = case ys of [] => acc | h :: t => go (h :: acc) t
    in go [] xs end

  fun map f xs = case xs of [] => [] | h :: t => f h :: map f t

  fun filter p xs =
    case xs of
      [] => []
    | h :: t => if p h then h :: filter p t else filter p t

  fun foldl f z xs = case xs of [] => z | h :: t => foldl f (f z h) t

  fun foldr f z xs = case xs of [] => z | h :: t => f h (foldr f z t)

  fun concat xss = case xss of [] => [] | x :: t => append x (concat t)

  fun nth xs n =
    case (xs, n) of
      ([], _) => error "List.nth: out of range"
    | (h :: _, 0) => h
    | (_ :: t, k) => nth t (k - 1)

  fun take xs n =
    if n <= 0 then []
    else case xs of [] => [] | h :: t => h :: take t (n - 1)

  fun drop xs n =
    if n <= 0 then xs
    else case xs of [] => [] | _ :: t => drop t (n - 1)

  fun exists p xs = case xs of [] => false | h :: t => p h or exists p t

  fun all p xs = case xs of [] => true | h :: t => p h and all p t

  fun find p xs =
    case xs of [] => None | h :: t => if p h then Some h else find p t

  fun tabulate n f =
    let fun go i = if i >= n then [] else f i :: go (i + 1) in go 0 end

  fun zip xs ys =
    case (xs, ys) of
      (h :: t, u :: v) => (h, u) :: zip t v
    | (_, _) => []
end

fun sepBy sep xs =
  case xs of
    [] => ""
  | h :: [] => h
  | h :: t => h ^ sep ^ sepBy sep t
|gr}
