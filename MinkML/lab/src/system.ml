(* What the command line needs to know about a type system.

   A system is asked to check a whole program and to say, for each binding,
   what type it gave it.  Systems that compute values themselves -- `dep`,
   whose normaliser is its typechecker -- also fill in [rvalue]; the others
   leave it to the machine. *)

type result = { rname : string; rtype : string; rvalue : string option }

type t = {
  name : string;
  blurb : string;
  check : Ast.toplevel list -> result list;
  runs : bool; (* whether the driver should run the program afterwards *)
}
