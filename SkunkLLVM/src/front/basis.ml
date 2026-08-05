(* The basis: what a program can use before it defines anything.

   Two halves.  What a back end has to do itself -- arithmetic, strings, the
   store -- is named here and implemented there: the interpreter reaches it
   through [Machine.VPrim] and the compiler through a stub that calls a runtime
   routine.  Every one of those takes a single argument, a tuple where it needs
   more, which is how SML's own basis is shaped.  Everything that can be said in
   the language is said in the language, in [prelude] at the bottom of this file,
   and goes through the same parser, the same inference, the same decision-tree
   compiler and both back ends, exactly like a user's program.

   This file is in the shared front end, so it says what the names are and what
   their types are, and nothing about how either back end provides them. *)

open Types

let tv () = param_var ()
let poly1 f = let a = tv () in { qvars = [ a ]; sbody = f (Tvar a) }
let poly2 f = let a = tv () and b = tv () in { qvars = [ a; b ]; sbody = f (Tvar a) (Tvar b) }
let m t = { qvars = []; sbody = t }

let sg_of vals = { Sem.sg_tys = []; sg_cons = []; sg_vals = vals; sg_strs = [] }

(* structure Int *)
let int_sg =
  sg_of
    [
      ("toString", m (Tarrow (tint, tstring)));
      ("abs", m (Tarrow (tint, tint)));
      ("min", m (Tarrow (ttuple [ tint; tint ], tint)));
      ("max", m (Tarrow (ttuple [ tint; tint ], tint)));
      ("compare", m (Tarrow (ttuple [ tint; tint ], tint)));
    ]

(* structure Real.  `toString` is the printer specified in `types.ml`, so a
   real that goes through `Real.toString` and one that a binding reports print
   the same.  `floor` is here rather than `trunc`/`round`/`ceil` because it is
   the one that comes up, and because each of the others would want its own
   rounding rule written down. *)
let real_sg =
  sg_of
    [
      ("toString", m (Tarrow (treal, tstring)));
      ("fromInt", m (Tarrow (tint, treal)));
      ("floor", m (Tarrow (treal, tint)));
      ("compare", m (Tarrow (ttuple [ treal; treal ], tint)));
    ]

(* structure Math.  One function, and the only one the machine cannot write for
   itself. *)
let math_sg = sg_of [ ("sqrt", m (Tarrow (treal, treal))) ]

(* structure String *)
let string_sg =
  sg_of
    [
      ("size", m (Tarrow (tstring, tint)));
      ("compare", m (Tarrow (ttuple [ tstring; tstring ], tint)));
      ("substring", m (Tarrow (ttuple [ tstring; tint; tint ], tstring)));
    ]

(* structure Array.  The type `'a array` is not a component of the structure:
   it is one of the built-in type constructors, so `Array.sub` and a written
   `int array` mean the same thing without any sharing constraint. *)
let array_sg =
  sg_of
    [
      ("array", poly1 (fun a -> Tarrow (ttuple [ tint; a ], tarray a)));
      ("fromList", poly1 (fun a -> Tarrow (tlist a, tarray a)));
      ("toList", poly1 (fun a -> Tarrow (tarray a, tlist a)));
      ("length", poly1 (fun a -> Tarrow (tarray a, tint)));
      ("sub", poly1 (fun a -> Tarrow (ttuple [ tarray a; tint ], a)));
      ("update", poly1 (fun a -> Tarrow (ttuple [ tarray a; tint; a ], tunit)));
    ]

let structures =
  [
    ("Int", int_sg);
    ("Real", real_sg);
    ("Math", math_sg);
    ("String", string_sg);
    ("Array", array_sg);
  ]

let toplevel_vals =
  [
    ("print", m (Tarrow (tstring, tunit)));
    ("not", m (Tarrow (tbool, tbool)));
    ("!", poly1 (fun a -> Tarrow (tref a, a)));
  ]

let env () =
  let e = Sem.empty_env in
  let e =
    List.fold_left
      (fun e (n, tf) -> Sem.add_ty e n tf)
      e
      [
        ("int", Sem.TyName int_tc);
        ("real", Sem.TyName real_tc);
        ("bool", Sem.TyName bool_tc);
        ("string", Sem.TyName string_tc);
        ("unit", Sem.TyAlias ([], tunit));
        ("list", Sem.TyName list_tc);
        ("array", Sem.TyName array_tc);
        ("ref", Sem.TyName ref_tc);
      ]
  in
  let e = List.fold_left Sem.add_con e (list_tc.tcons @ bool_tc.tcons @ ref_tc.tcons) in
  let e =
    List.fold_left
      (fun e (n, sch) -> Sem.add_val e n sch { Sem.root = n; path = [] })
      e toplevel_vals
  in
  List.fold_left
    (fun e (n, sg) -> Sem.add_str e n sg { Sem.root = n; path = [] })
    e structures

(* The names the basis owns.  Closure conversion is told about them so that a
   function that calls `print` does not capture it. *)
let globals () =
  List.map fst toplevel_vals @ List.map fst structures

(* The half of the basis that is written in the language it belongs to. *)
let prelude =
  {sml|
datatype 'a option = NONE | SOME of 'a

structure Option = struct
  fun getOpt (SOME x, _) = x
    | getOpt (NONE, d) = d
  fun isSome (SOME _) = true
    | isSome NONE = false
  fun map f (SOME x) = SOME (f x)
    | map _ NONE = NONE
end

structure List = struct
  fun null [] = true
    | null _ = false

  fun length [] = 0
    | length (_ :: xs) = 1 + length xs

  fun rev xs =
    let fun go ([], acc) = acc
          | go (x :: xs, acc) = go (xs, x :: acc)
    in go (xs, []) end

  fun map f [] = []
    | map f (x :: xs) = f x :: map f xs

  fun app f [] = ()
    | app f (x :: xs) = (f x; app f xs)

  fun filter p [] = []
    | filter p (x :: xs) = if p x then x :: filter p xs else filter p xs

  fun foldl f init [] = init
    | foldl f init (x :: xs) = foldl f (f (x, init)) xs

  fun foldr f init [] = init
    | foldr f init (x :: xs) = f (x, foldr f init xs)

  fun exists p [] = false
    | exists p (x :: xs) = p x orelse exists p xs

  fun all p [] = true
    | all p (x :: xs) = p x andalso all p xs

  fun find p [] = NONE
    | find p (x :: xs) = if p x then SOME x else find p xs

  fun concat [] = []
    | concat (xs :: rest) = xs @ concat rest

  fun tabulate (n, f) =
    let fun go i = if i >= n then [] else f i :: go (i + 1)
    in go 0 end
end
|sml}
