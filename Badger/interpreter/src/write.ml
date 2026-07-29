(* Printing terms.

   The writer is the reader's mirror, and the property worth keeping is that
   whatever `writeq/1` prints, the reader reads back as the same term.  Two
   things threaten that.  One is priority: `a*(b+c)` needs its brackets
   because `+` binds looser than `*`.  The other is adjacency, which is
   subtler -- `-(1)` printed as `-1` comes back as an integer, and `-(','(1,2))`
   printed as `-(1,2)` comes back with the wrong arity.  Both are handled at
   the point where characters meet, by [emit] and by the two special cases in
   [prefix]. *)

type opts = {
  quoted : bool;
  ignore_ops : bool; (* write_canonical/1: no operators, no list syntax *)
  numbervars : bool; (* '$VAR'(0) prints as A *)
}

let write_opts = { quoted = false; ignore_ops = false; numbervars = true }
let writeq_opts = { quoted = true; ignore_ops = false; numbervars = true }
let canonical_opts = { quoted = true; ignore_ops = true; numbervars = false }

let symbol_char c = String.contains "+-*/\\^<>=~:.?@#&$" c

let alnum_char c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'

(* Two tokens that would merge into one need a space between them.  This is
   what turns 1 - -2 into "1- -2" rather than "1--2", which would lex as the
   symbolic atom "--". *)
let needs_sep prev next =
  (symbol_char prev && symbol_char next) || (alnum_char prev && alnum_char next)

let emit b s =
  if String.length s > 0 && Buffer.length b > 0 then begin
    let prev = Buffer.nth b (Buffer.length b - 1) in
    if needs_sep prev s.[0] then Buffer.add_char b ' '
  end;
  Buffer.add_string b s

(* ------------------------------------------------------------------- atoms *)

let is_lower_word name =
  String.length name > 0 && name.[0] >= 'a' && name.[0] <= 'z' && String.for_all alnum_char name

let is_symbol_word name = String.length name > 0 && String.for_all symbol_char name

(* `.` is all symbol characters and still needs quotes: bare, it would lex as
   the end of a clause. *)
let needs_quotes name =
  match name with
  | "[]" | "{}" | "!" | ";" -> false
  | "." -> true
  | _ -> not (is_lower_word name || is_symbol_word name)

let quote_atom name =
  let b = Buffer.create (String.length name + 2) in
  Buffer.add_char b '\'';
  String.iter
    (fun c ->
      match c with
      | '\'' -> Buffer.add_string b "\\'"
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | '\b' -> Buffer.add_string b "\\b"
      | '\011' -> Buffer.add_string b "\\v"
      | '\012' -> Buffer.add_string b "\\f"
      | '\007' -> Buffer.add_string b "\\a"
      | c when Char.code c < 32 || Char.code c = 127 -> Buffer.add_string b (Printf.sprintf "\\x%x\\" (Char.code c))
      | c -> Buffer.add_char b c)
    name;
  Buffer.add_char b '\'';
  Buffer.contents b

let atom_string opts name = if opts.quoted && needs_quotes name then quote_atom name else name

(* ----------------------------------------------------------------- numbers *)

(* Printed so that the reader gives back the same float.  Two things to get
   right: the digits have to be enough to name this float and no other, so the
   precision is raised until the text reads back equal; and the text has to
   look like a float, so "1" becomes "1.0" and "1e+20" becomes "1.0e+20". *)
let shortest_digits f =
  let rec go precision =
    if precision > 17 then Printf.sprintf "%.17g" f
    else
      let s = Printf.sprintf "%.*g" precision f in
      if float_of_string s = f then s else go (precision + 1)
  in
  go 15

let with_point s =
  if String.contains s '.' then s
  else
    match String.index_opt s 'e' with
    | Some i -> String.sub s 0 i ^ ".0" ^ String.sub s i (String.length s - i)
    | None -> s ^ ".0"

let float_string f =
  if Float.is_nan f then "nan"
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else if Float.is_integer f && Float.abs f < 1e15 then Printf.sprintf "%.1f" f
  else with_point (shortest_digits f)

let number_string t = match t with Term.Int n -> string_of_int n | Term.Float f -> float_string f | _ -> assert false

(* ------------------------------------------------------------------- terms *)

let var_name (v : Term.var) = Printf.sprintf "_G%d" v.v_id

(* '$VAR'(0) is A, '$VAR'(26) is A1, '$VAR'(foo) is foo. *)
let numbervar_name t =
  match Term.deref t with
  | Term.Int n when n >= 0 ->
      let letter = Char.chr (Char.code 'A' + (n mod 26)) in
      if n < 26 then String.make 1 letter else Printf.sprintf "%c%d" letter (n / 26)
  | Term.Atom name -> name
  | _ -> ""

let rec go b opts ~maxp ~operand t =
  match Term.deref t with
  | Term.Var v -> emit b (var_name v)
  | Term.Int n when n < 0 && operand ->
      (* A negative number as an operand of an operator needs brackets in
         canonical position but only a separator next to an operator; emit
         handles the separator, so plain digits are enough here. *)
      emit b (string_of_int n)
  | (Term.Int _ | Term.Float _) as n -> emit b (number_string n)
  | Term.Atom name ->
      (* An atom that names an operator, standing where an operand is
         expected, is bracketed: `(-) = 1` rather than `- = 1`. *)
      if operand && Ops.is_operator name then begin
        emit b "(";
        Buffer.add_string b (atom_string opts name);
        Buffer.add_string b ")"
      end
      else emit b (atom_string opts name)
  | Term.Struct ("$VAR", [| arg |]) when opts.numbervars && numbervar_name arg <> "" ->
      emit b (numbervar_name arg)
  | Term.Struct (".", [| _; _ |]) when not opts.ignore_ops -> list b opts t
  | Term.Struct ("{}", [| arg |]) when not opts.ignore_ops ->
      emit b "{";
      go b opts ~maxp:1200 ~operand:false arg;
      Buffer.add_string b "}"
  | Term.Struct (name, args) when not opts.ignore_ops && operators b opts ~maxp name args -> ()
  | Term.Struct (name, args) ->
      emit b (atom_string opts name);
      Buffer.add_string b "(";
      Array.iteri
        (fun i arg ->
          if i > 0 then Buffer.add_string b ",";
          go b opts ~maxp:999 ~operand:false arg)
        args;
      Buffer.add_string b ")"
  | Term.Local i -> emit b (Printf.sprintf "_L%d" i)

(* Returns false when the functor is not an operator of the right arity, so
   that [go] can fall back to canonical notation. *)
and operators b opts ~maxp name args =
  match Array.length args with
  | 2 -> (
      match Ops.lookup_infix_postfix name with
      | Some { priority; kind } when Ops.is_infix kind ->
          let leftmax = if kind = Ops.YFX then priority else priority - 1 in
          let rightmax = if kind = Ops.XFY then priority else priority - 1 in
          bracket b (priority > maxp) (fun () ->
              go b opts ~maxp:leftmax ~operand:true args.(0);
              (* `,` is written tight against what precedes it, like an
                 argument separator, because that is what it looks like. *)
              if String.equal name "," then Buffer.add_string b ","
              else emit b (atom_string opts name);
              go b opts ~maxp:rightmax ~operand:true args.(1));
          true
      | _ -> false)
  | 1 -> (
      match Ops.lookup_prefix name with
      | Some { priority; kind } -> prefix b opts ~maxp name args.(0) priority kind
      | None -> (
          match Ops.lookup_infix_postfix name with
          | Some { priority; kind } when Ops.is_postfix kind ->
              let leftmax = if kind = Ops.YF then priority else priority - 1 in
              bracket b (priority > maxp) (fun () ->
                  go b opts ~maxp:leftmax ~operand:true args.(0);
                  emit b (atom_string opts name));
              true
          | _ -> false))
  | _ -> false

and prefix b opts ~maxp name arg priority kind =
  let argmax = if kind = Ops.FY then priority else priority - 1 in
  let arg = Term.deref arg in
  let arg_priority =
    match arg with
    | Term.Struct (f, a) ->
        let entry =
          if Array.length a = 1 then Ops.lookup_prefix f
          else if Array.length a = 2 then Ops.lookup_infix_postfix f
          else None
        in
        (match entry with Some { priority; _ } -> priority | None -> 0)
    | Term.Atom f when Ops.is_operator f -> 1201 (* forces the brackets below *)
    | _ -> 0
  in
  bracket b (priority > maxp) (fun () ->
      emit b (atom_string opts name);
      if arg_priority > argmax then begin
        (* `- (1,2)`: without the space the reader would see functor
           notation and build a term of arity two. *)
        Buffer.add_char b ' ';
        Buffer.add_char b '(';
        go b opts ~maxp:1200 ~operand:false arg;
        Buffer.add_char b ')'
      end
      else begin
        (* `- 1`: without the space the reader would see the integer -1. *)
        (match arg with
        | (Term.Int _ | Term.Float _) when is_symbol_word name -> Buffer.add_char b ' '
        | _ -> ());
        go b opts ~maxp:argmax ~operand:true arg
      end);
  true

and bracket b needed f =
  if needed then begin
    emit b "(";
    f ();
    Buffer.add_string b ")"
  end
  else f ()

and list b opts t =
  emit b "[";
  let rec elements first t =
    match Term.deref t with
    | Term.Atom "[]" -> ()
    | Term.Struct (".", [| h; tl |]) ->
        if not first then Buffer.add_string b ",";
        go b opts ~maxp:999 ~operand:false h;
        elements false tl
    | tail ->
        Buffer.add_string b "|";
        go b opts ~maxp:999 ~operand:false tail
  in
  elements true t;
  Buffer.add_string b "]"

let to_string ?(opts = write_opts) ?(maxp = 1200) t =
  let b = Buffer.create 64 in
  go b opts ~maxp ~operand:false t;
  Buffer.contents b
