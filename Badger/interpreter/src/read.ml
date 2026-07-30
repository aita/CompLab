(* The reader: tokens in, terms out.

   Operator priorities are climbed rather than tabulated, because op/3 can
   change them between one clause and the next.  Two numbers do all the work:
   [maxp], the highest-priority operator this position is allowed to contain,
   and the priority each parsed term reports back, which is 0 for anything
   bracketed or atomic and the operator's priority otherwise.  An infix
   operator of priority p is allowed here when p <= maxp, and it may take the
   term to its left when that term's priority fits the operator's
   associativity: p-1 on both sides for xfx, p on the left for yfx, p on the
   right for xfy. *)

type t = {
  lexbuf : Lexing.lexbuf;
  mutable ahead : Tok.located option;
  names : (string, Term.term) Hashtbl.t;
  counts : (string, int) Hashtbl.t;
  mutable order : string list; (* names, most recently introduced first *)
}

type clause = {
  clause : Term.term;
  vars : (string * Term.term) list; (* named variables, in order of first occurrence *)
  singletons : string list;
}

let create ?(file = "<stdin>") lexbuf =
  Lexing.set_filename lexbuf file;
  Lexer.reset ();
  { lexbuf; ahead = None; names = Hashtbl.create 16; counts = Hashtbl.create 16; order = [] }

let of_string ?(file = "<string>") text = create ~file (Lexing.from_string text)
let of_channel ?(file = "<stdin>") channel = create ~file (Lexing.from_channel channel)

let syntax pos msg = raise (Tok.Syntax_error (pos, msg))

let peek st =
  match st.ahead with
  | Some t -> t
  | None ->
      let t = Lexer.next st.lexbuf in
      st.ahead <- Some t;
      t

let advance st =
  match st.ahead with
  | Some t ->
      st.ahead <- None;
      t
  | None -> Lexer.next st.lexbuf

let peek_punct st p = match (peek st).tok with Tok.PUNCT q -> String.equal p q | _ -> false

let expect_punct st p =
  let la = advance st in
  match la.tok with
  | Tok.PUNCT q when String.equal p q -> ()
  | tok -> syntax la.start (Printf.sprintf "expected %S but found %s" p (Tok.describe tok))

(* Variables are per clause: the same name twice in one clause is the same
   variable, and `_` is a fresh one every time it is written. *)
let variable st name =
  if String.equal name "_" then Term.fresh_var ()
  else
    match Hashtbl.find_opt st.names name with
    | Some v ->
        Hashtbl.replace st.counts name (Hashtbl.find st.counts name + 1);
        v
    | None ->
        let v = Term.fresh_var () in
        Hashtbl.add st.names name v;
        Hashtbl.add st.counts name 1;
        st.order <- name :: st.order;
        v

let string_term s =
  match !Flags.double_quotes with
  | Flags.Codes -> Term.term_of_codes s
  | Flags.Chars -> Term.term_of_chars s
  | Flags.Atom_ -> Term.Atom s

(* An atom that names an operator carries that operator's priority when it
   stands on its own, so the loop below can tell `X = a * b` from an atom that
   merely happens to be spelt like an operator.  Quoting removes the operator
   reading entirely, which is what makes `X = ','` and `X = '|'` writable at
   all. *)
let atom_priority name =
  List.fold_left (fun acc (e : Ops.entry) -> max acc e.priority) 0 (Ops.entries name)

let starts_term st =
  match (peek st).tok with
  | Tok.INT _ | Tok.FLOAT _ | Tok.VAR _ | Tok.STRING _ | Tok.BACKQUOTE _ | Tok.OPEN_CT -> true
  | Tok.ATOM _ | Tok.QUOTED _ -> true
  | Tok.PUNCT ("(" | "[" | "{") -> true
  | Tok.PUNCT _ | Tok.END | Tok.EOF -> false

let rec parse st maxp = infix_loop st maxp (primary st maxp)

and primary st maxp =
  let la = advance st in
  match la.tok with
  | Tok.INT n -> (Term.Int n, 0)
  | Tok.FLOAT f -> (Term.Float f, 0)
  | Tok.VAR name -> (variable st name, 0)
  | Tok.STRING s -> (string_term s, 0)
  | Tok.BACKQUOTE s -> (Term.term_of_codes s, 0)
  | Tok.PUNCT "(" | Tok.OPEN_CT ->
      let t, _ = parse st 1200 in
      expect_punct st ")";
      (t, 0)
  (* An empty pair of brackets is an atom, and an atom can be a functor, so
     `[]` and `{}` go through the same path as any other name. *)
  | Tok.PUNCT "[" ->
      if peek_punct st "]" then
        let close = advance st in
        name_operand st "[]" ~quoted:true ~maxp ~stop:close.stop
      else (read_list st, 0)
  | Tok.PUNCT "{" ->
      if peek_punct st "}" then
        let close = advance st in
        name_operand st "{}" ~quoted:true ~maxp ~stop:close.stop
      else begin
        let t, _ = parse st 1200 in
        expect_punct st "}";
        (Term.Struct ("{}", [| t |]), 0)
      end
  | Tok.QUOTED name -> name_operand st name ~quoted:true ~maxp ~stop:la.stop
  | Tok.ATOM name -> name_operand st name ~quoted:false ~maxp ~stop:la.stop
  | tok -> syntax la.start (Printf.sprintf "unexpected %s" (Tok.describe tok))

and name_operand st name ~quoted ~maxp ~stop =
  if (peek st).tok = Tok.OPEN_CT then begin
    ignore (advance st);
    (Term.struct_ name (read_args st), 0)
  end
  else if quoted then (Term.Atom name, 0)
  else
    match Ops.lookup_prefix name with
    | Some { priority; kind } when priority <= maxp && starts_term st -> (
        (* `-1` is one token's worth of meaning even though it is two tokens. *)
        let la = peek st in
        let glued = la.start.pos_cnum = stop.pos_cnum in
        match (name, la.tok) with
        | "-", Tok.INT n when glued ->
            ignore (advance st);
            (Term.Int (-n), 0)
        | "-", Tok.FLOAT f when glued ->
            ignore (advance st);
            (Term.Float (-.f), 0)
        | "+", Tok.INT n when glued ->
            ignore (advance st);
            (Term.Int n, 0)
        | "+", Tok.FLOAT f when glued ->
            ignore (advance st);
            (Term.Float f, 0)
        | _ ->
            let argmax = if kind = Ops.FY then priority else priority - 1 in
            let arg, _ = parse st argmax in
            (Term.Struct (name, [| arg |]), priority))
    | _ -> (Term.Atom name, atom_priority name)

and infix_loop st maxp (left, lprec) =
  let la = peek st in
  let name =
    match la.tok with
    | Tok.ATOM name -> Some name
    | Tok.PUNCT (("," | "|") as p) -> Some p
    | _ -> None
  in
  match Option.bind name Ops.lookup_infix_postfix with
  | None -> (left, lprec)
  | Some { priority; kind } ->
      let name = Option.get name in
      if priority > maxp then (left, lprec)
      else if Ops.is_infix kind then
        let leftmax = if kind = Ops.YFX then priority else priority - 1 in
        let rightmax = if kind = Ops.XFY then priority else priority - 1 in
        if lprec > leftmax then (left, lprec)
        else begin
          ignore (advance st);
          if not (starts_term st) then
            syntax (peek st).start (Printf.sprintf "%s needs a right operand" name);
          let right, _ = parse st rightmax in
          (* A `|` used as an operator rather than as a list or clause
             separator means disjunction. *)
          let name = if String.equal name "|" && priority >= 1001 then ";" else name in
          infix_loop st maxp (Term.Struct (name, [| left; right |]), priority)
        end
      else
        let leftmax = if kind = Ops.YF then priority else priority - 1 in
        if lprec > leftmax then (left, lprec)
        else begin
          ignore (advance st);
          infix_loop st maxp (Term.Struct (name, [| left |]), priority)
        end

(* Arguments and list elements are read at 999, one below the priority of
   `,`, which is exactly why a comma can separate them at all. *)
and read_args st =
  let rec go acc =
    let t, _ = parse st 999 in
    let la = advance st in
    match la.tok with
    | Tok.PUNCT "," -> go (t :: acc)
    | Tok.PUNCT ")" -> t :: acc
    | tok -> syntax la.start (Printf.sprintf "expected , or ) in arguments but found %s" (Tok.describe tok))
  in
  let rev = go [] in
  Array.of_list (List.rev rev)

and read_list st =
  if peek_punct st "]" then begin
    ignore (advance st);
    Term.nil
  end
  else
    let close acc tail = List.fold_left (fun tl h -> Term.cons h tl) tail acc in
    let rec go acc =
      let t, _ = parse st 999 in
      let la = advance st in
      match la.tok with
      | Tok.PUNCT "," -> go (t :: acc)
      | Tok.PUNCT "]" -> close (t :: acc) Term.nil
      | Tok.PUNCT "|" ->
          let tail, _ = parse st 999 in
          expect_punct st "]";
          close (t :: acc) tail
      | tok -> syntax la.start (Printf.sprintf "expected , | or ] in list but found %s" (Tok.describe tok))
    in
    go []

(* ---------------------------------------------------------------- clauses *)

let bindings st =
  List.rev_map (fun name -> (name, Hashtbl.find st.names name)) st.order

let singletons st =
  List.filter
    (fun name -> Hashtbl.find st.counts name = 1 && not (String.length name > 0 && name.[0] = '_'))
    (List.rev st.order)

(* None at end of input.  A clause is read at priority 1200 and must be
   followed by the end token; anything else there is the reader's most common
   complaint, so it says what it found. *)
let read_clause st =
  Hashtbl.reset st.names;
  Hashtbl.reset st.counts;
  st.order <- [];
  match (peek st).tok with
  | Tok.EOF -> None
  | _ ->
      let t, _ = parse st 1200 in
      let la = advance st in
      (match la.tok with
      | Tok.END -> ()
      | tok -> syntax la.start (Printf.sprintf "operator expected before %s" (Tok.describe tok)));
      Some { clause = t; vars = bindings st; singletons = singletons st }

(* After a syntax error, consulting carries on at the next clause. *)
let skip_to_end st =
  let rec go () =
    match (advance st).tok with Tok.END | Tok.EOF -> () | _ -> go ()
  in
  try go () with Tok.Syntax_error _ -> ()

(* One term from a string, for atom_to_term/3 and the command line. *)
let term_of_string ?(file = "<string>") text =
  let st = of_string ~file text in
  match read_clause st with
  | Some c -> Some c
  | None -> None

let position_string (pos : Lexing.position) =
  Printf.sprintf "%s:%d:%d" pos.pos_fname pos.pos_lnum (pos.pos_cnum - pos.pos_bol + 1)
