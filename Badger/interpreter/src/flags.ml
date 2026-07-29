(* The Prolog flags that change how the reader and the engine behave.  These
   are what set_prolog_flag/2 writes and current_prolog_flag/2 reads. *)

type double_quotes = Codes | Chars | Atom_

let double_quotes = ref Codes

(* true: calling an undefined predicate raises existence_error; false: it
   fails.  ISO's `unknown` flag. *)
let unknown_error = ref true

(* Whether =/2 and clause head matching check for cycles.  Off, as everywhere
   else, because it costs a walk of both terms on every unification. *)
let occurs_check = ref false

(* Whether the loader mentions singleton variables and redefined predicates. *)
let verbose_load = ref true
