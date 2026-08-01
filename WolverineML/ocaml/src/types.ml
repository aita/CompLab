(* Semantic types, and the symbols that carry them.

   Types are monomorphic.  Records are nominal — two record types with the same
   fields are different types — and everything else is structural, which for this
   language means arrays compare by their element type. *)

type ty =
  | Int_t
  | String_t
  | Bool_t
  | Unit_t
  (* The type of [nil] before it is known which record it stands for. *)
  | Nil_t
  | Record_t of record
  | Array_t of ty

(* A record is held by its own mutable block, because a recursive type has to be
   named before its fields can be resolved, and because two records are the same
   type only when they are the same block. *)
and record = { rec_name : string; mutable fields : (string * ty) list }

let rec show = function
  | Int_t -> "int"
  | String_t -> "string"
  | Bool_t -> "bool"
  | Unit_t -> "unit"
  | Nil_t -> "nil"
  | Record_t r -> r.rec_name
  | Array_t elem -> show elem ^ " array"

let index r name =
  let rec go i = function
    | [] -> -1
    | (field, _) :: rest -> if field = name then i else go (i + 1) rest
  in
  go 0 r.fields

let field_type r name = List.assoc_opt name r.fields

(* [same] is type equality: nominal for records, structural for arrays. *)
let rec same a b =
  match (a, b) with
  | Record_t x, Record_t y -> x == y
  | Array_t x, Array_t y -> same x y
  | Int_t, Int_t | String_t, String_t | Bool_t, Bool_t -> true
  | Unit_t, Unit_t | Nil_t, Nil_t -> true
  | _ -> false

(* [compatible] is equality, but [nil] stands in for any record. *)
let compatible a b =
  match (a, b) with
  | Nil_t, (Record_t _ | Nil_t) -> true
  | Record_t _, Nil_t -> true
  | _ -> same a b

(* -- symbols --------------------------------------------------------------- *)

(* One binding occurrence of a variable.

   [depth] is the static nesting depth of the function that binds it.  A variable
   read from a deeper function escapes, and then it lives in a frame slot instead
   of a register. *)
type var_sym = {
  var_name : string;
  var_ty : ty;
  mutable mutable_ : bool;
  var_depth : int;
  mutable escapes : bool;
  mutable slot : int;
  mutable reg : int;
}

let new_var name ty mutable_ depth =
  { var_name = name; var_ty = ty; mutable_; var_depth = depth;
    escapes = false; slot = -1; reg = -1 }

(* A function.  Functions are not values, so there is no function type. *)
type fun_sym = {
  fun_name : string;
  label : string;
  params : var_sym list;
  result : ty;
  fun_depth : int;
  (* [None] unless it is one of the prelude's. *)
  builtin : string option;
}

(* What a name can be bound to. *)
type sym = Var of var_sym | Fun of fun_sym
