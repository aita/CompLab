(* The built-in predicates.

   A built-in has the same shape as the engine's own [solve]: it is handed its
   arguments and a continuation, and calls the continuation once per solution.
   Most call it at most once and are written through [det]; the interesting
   ones -- between/3, clause/2, sub_atom/5 -- call it many times, and undo the
   trail to their own mark before each attempt, exactly as a predicate with
   several clauses does.

   Control constructs are not here: `,` `;` `->` `!` and `\+` are in Solve,
   because they need the caller's cut barrier.  Everything here is opaque to
   cut, which is why call/1 belongs on this side. *)

type builtin = Db.t -> Term.term array -> Engine.cont -> unit

let table : (string * int, builtin) Hashtbl.t = Hashtbl.create 256
let def name arity fn = Hashtbl.replace table (name, arity) fn

(* For the majority: return whether it succeeded. *)
let det name arity fn = def name arity (fun db args sk -> if fn db args then sk ())

let find key = Hashtbl.find_opt table key
let is_builtin key = Hashtbl.mem table key

(* Control constructs live in Solve but must still be refused as clause heads. *)
let control =
  [ (",", 2); (";", 2); ("->", 2); ("*->", 2); ("!", 0); ("\\+", 1); ("true", 0); ("fail", 0); ("false", 0) ]

let protected key = is_builtin key || List.mem key control

(* ------------------------------------------------------------------- text *)

(* A code list or a char list as a string, when it is one. *)
let string_of_text_list t =
  match Term.list_of_term t with
  | None -> None
  | Some items ->
      let b = Buffer.create 16 in
      let ok =
        List.for_all
          (fun item ->
            match Term.deref item with
            | Term.Int c when c >= 0 && c < 256 ->
                Buffer.add_char b (Char.chr c);
                true
            | Term.Atom s when String.length s = 1 ->
                Buffer.add_char b s.[0];
                true
            | _ -> false)
          items
      in
      if ok then Some (Buffer.contents b) else None

(* Anything that can stand for text: an atom, a number, or a list of codes or
   characters.  atom_length/2 and friends take all three, as they do
   everywhere else. *)
let text_of t who =
  match Term.deref t with
  | Term.Atom name -> name
  | (Term.Int _ | Term.Float _) as n -> Write.number_string n
  | Term.Var _ -> Term.instantiation_error who
  | (Term.Struct (".", [| _; _ |]) as l) -> (
      match string_of_text_list l with Some s -> s | None -> Term.type_error "atom" t who)
  | t -> Term.type_error "atom" t who

let number_of_string s =
  match try Read.term_of_string (s ^ " .") with Tok.Syntax_error _ -> None with
  | None -> None
  | Some { Read.clause; _ } -> (
      let signed sign t =
        match Term.deref t with
        | Term.Int n -> Some (Term.Int (sign * n))
        | Term.Float f -> Some (Term.Float (float_of_int sign *. f))
        | _ -> None
      in
      match Term.deref clause with
      | (Term.Int _ | Term.Float _) as n -> Some n
      | Term.Struct ("-", [| x |]) -> signed (-1) x
      | Term.Struct ("+", [| x |]) -> signed 1 x
      | _ -> None)

(* ------------------------------------------------------------- unification *)

let () =
  det "=" 2 (fun _ args -> if !Flags.occurs_check then Term.unify_oc args.(0) args.(1) else Term.unify args.(0) args.(1));
  det "\\=" 2 (fun _ args ->
      let m = Term.mark () in
      let unified = Term.unify args.(0) args.(1) in
      Term.undo_to m;
      not unified);
  det "unify_with_occurs_check" 2 (fun _ args -> Term.unify_oc args.(0) args.(1))

(* ------------------------------------------------------------- type tests *)

let () =
  let test name f = det name 1 (fun _ args -> f (Term.deref args.(0))) in
  test "var" (function Term.Var _ -> true | _ -> false);
  test "nonvar" (function Term.Var _ -> false | _ -> true);
  test "atom" (function Term.Atom _ -> true | _ -> false);
  test "number" (function Term.Int _ | Term.Float _ -> true | _ -> false);
  test "integer" (function Term.Int _ -> true | _ -> false);
  test "float" (function Term.Float _ -> true | _ -> false);
  test "atomic" (function Term.Atom _ | Term.Int _ | Term.Float _ -> true | _ -> false);
  test "compound" (function Term.Struct _ -> true | _ -> false);
  test "callable" (function Term.Atom _ | Term.Struct _ -> true | _ -> false);
  test "is_list" (fun t -> Term.list_of_term t <> None);
  test "ground" Term.is_ground

(* --------------------------------------------------- comparison and order *)

let () =
  det "==" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) = 0);
  det "\\==" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) <> 0);
  det "@<" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) < 0);
  det "@>" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) > 0);
  det "@=<" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) <= 0);
  det "@>=" 2 (fun _ args -> Term.compare_terms args.(0) args.(1) >= 0);
  det "=@=" 2 (fun _ args -> Term.variant args.(0) args.(1));
  det "\\=@=" 2 (fun _ args -> not (Term.variant args.(0) args.(1)));
  det "compare" 3 (fun _ args ->
      let order =
        match Term.compare_terms args.(1) args.(2) with n when n < 0 -> "<" | 0 -> "=" | _ -> ">"
      in
      (match Term.deref args.(0) with
      | Term.Var _ | Term.Atom ("<" | "=" | ">") -> ()
      | Term.Atom _ -> Term.domain_error "order" args.(0) "compare/3"
      | t -> Term.type_error "atom" t "compare/3");
      Term.unify args.(0) (Term.Atom order))

(* ------------------------------------------------------------- arithmetic *)

let () =
  det "is" 2 (fun _ args -> Term.unify args.(0) (Arith.eval args.(1)));
  let cmp name test = det name 2 (fun _ args -> test (Arith.compare_eval args.(0) args.(1)) 0) in
  cmp "=:=" ( = );
  cmp "=\\=" ( <> );
  cmp "<" ( < );
  cmp ">" ( > );
  cmp "=<" ( <= );
  cmp ">=" ( >= );
  det "succ" 2 (fun _ args ->
      match (Term.deref args.(0), Term.deref args.(1)) with
      | Term.Int a, _ when a >= 0 -> Term.unify args.(1) (Term.Int (a + 1))
      | Term.Var _, Term.Int b when b > 0 -> Term.unify args.(0) (Term.Int (b - 1))
      | Term.Var _, Term.Int 0 -> false
      | Term.Var _, Term.Var _ -> Term.instantiation_error "succ/2"
      | (Term.Int _ as t), _ | _, (Term.Int _ as t) -> Term.type_error "not_less_than_zero" t "succ/2"
      | t, _ -> Term.type_error "integer" t "succ/2");
  det "plus" 3 (fun _ args ->
      match (Term.deref args.(0), Term.deref args.(1), Term.deref args.(2)) with
      | Term.Int a, Term.Int b, _ -> Term.unify args.(2) (Term.Int (a + b))
      | Term.Int a, _, Term.Int c -> Term.unify args.(1) (Term.Int (c - a))
      | _, Term.Int b, Term.Int c -> Term.unify args.(0) (Term.Int (c - b))
      | _ -> Term.instantiation_error "plus/3")

let () =
  def "between" 3 (fun _ args sk ->
      let low = match Arith.eval args.(0) with Term.Int n -> n | t -> Term.type_error "integer" t "between/3" in
      let high =
        match Term.deref args.(1) with
        | Term.Atom ("inf" | "infinite") -> max_int
        | t -> ( match Arith.eval t with Term.Int n -> n | t -> Term.type_error "integer" t "between/3")
      in
      match Term.deref args.(2) with
      | Term.Int x -> if x >= low && x <= high then sk ()
      | Term.Var _ ->
          let m = Term.mark () in
          let i = ref low in
          while !i <= high do
            Term.undo_to m;
            if Term.unify args.(2) (Term.Int !i) then sk ();
            incr i
          done;
          Term.undo_to m
      | t -> Term.type_error "integer" t "between/3")

(* ------------------------------------------------------- term inspection *)

let () =
  det "functor" 3 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> (
          let arity =
            match Term.deref args.(2) with
            | Term.Int n when n >= 0 -> n
            | Term.Var _ -> Term.instantiation_error "functor/3"
            | t -> Term.type_error "integer" t "functor/3"
          in
          match Term.deref args.(1) with
          | Term.Var _ -> Term.instantiation_error "functor/3"
          | (Term.Int _ | Term.Float _) as n ->
              if arity = 0 then Term.unify args.(0) n else Term.type_error "atomic" args.(1) "functor/3"
          | Term.Atom name -> Term.unify args.(0) (Term.struct_ name (Array.init arity (fun _ -> Term.fresh_var ())))
          | t -> Term.type_error "atomic" t "functor/3")
      | Term.Struct (name, fargs) ->
          Term.unify args.(1) (Term.Atom name) && Term.unify args.(2) (Term.Int (Array.length fargs))
      | atomic -> Term.unify args.(1) atomic && Term.unify args.(2) (Term.Int 0));
  def "arg" 3 (fun _ args sk ->
      let fargs =
        match Term.deref args.(1) with
        | Term.Struct (_, fargs) -> fargs
        | Term.Var _ -> Term.instantiation_error "arg/3"
        | t -> Term.type_error "compound" t "arg/3"
      in
      match Term.deref args.(0) with
      | Term.Int n -> if n >= 1 && n <= Array.length fargs then if Term.unify args.(2) fargs.(n - 1) then sk ()
      | Term.Var _ ->
          let m = Term.mark () in
          Array.iteri
            (fun i arg ->
              Term.undo_to m;
              if Term.unify args.(0) (Term.Int (i + 1)) && Term.unify args.(2) arg then sk ())
            fargs;
          Term.undo_to m
      | t -> Term.type_error "integer" t "arg/3");
  det "=.." 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> (
          match Term.expect_list args.(1) "=../2" with
          | [] -> Term.domain_error "non_empty_list" Term.nil "=../2"
          | [ single ] -> Term.unify args.(0) single
          | head :: rest -> (
              match Term.deref head with
              | Term.Atom name -> Term.unify args.(0) (Term.struct_ name (Array.of_list rest))
              | Term.Var _ -> Term.instantiation_error "=../2"
              | t -> Term.type_error "atom" t "=../2"))
      | Term.Struct (name, fargs) ->
          Term.unify args.(1) (Term.term_of_list (Term.Atom name :: Array.to_list fargs))
      | atomic -> Term.unify args.(1) (Term.term_of_list [ atomic ]));
  det "copy_term" 2 (fun _ args -> Term.unify args.(1) (Term.copy_term args.(0)));
  det "term_variables" 2 (fun _ args -> Term.unify args.(1) (Term.term_of_list (Term.term_variables args.(0))));
  det "numbervars" 3 (fun _ args ->
      let n = match Term.deref args.(1) with Term.Int n -> n | t -> Term.type_error "integer" t "numbervars/3" in
      let next = ref n in
      List.iter
        (fun v ->
          ignore (Term.unify v (Term.Struct ("$VAR", [| Term.Int !next |])));
          incr next)
        (Term.term_variables args.(0));
      Term.unify args.(2) (Term.Int !next))

(* -------------------------------------------------------- atoms and text *)

let () =
  det "atom_length" 2 (fun _ args ->
      Term.unify args.(1) (Term.Int (String.length (text_of args.(0) "atom_length/2"))));
  det "atom_chars" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> Term.unify args.(0) (Term.Atom (text_of args.(1) "atom_chars/2"))
      | _ -> Term.unify args.(1) (Term.term_of_chars (text_of args.(0) "atom_chars/2")));
  det "atom_codes" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> Term.unify args.(0) (Term.Atom (text_of args.(1) "atom_codes/2"))
      | _ -> Term.unify args.(1) (Term.term_of_codes (text_of args.(0) "atom_codes/2")));
  det "char_code" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Atom s when String.length s = 1 -> Term.unify args.(1) (Term.Int (Char.code s.[0]))
      | Term.Var _ -> (
          match Term.deref args.(1) with
          | Term.Int c when c >= 0 && c < 256 -> Term.unify args.(0) (Term.Atom (String.make 1 (Char.chr c)))
          | Term.Var _ -> Term.instantiation_error "char_code/2"
          | Term.Int c -> Term.representation_error (Printf.sprintf "character_code(%d)" c) "char_code/2"
          | t -> Term.type_error "integer" t "char_code/2")
      | t -> Term.type_error "character" t "char_code/2");
  det "atom_number" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> (
          match Term.deref args.(1) with
          | Term.Int _ | Term.Float _ -> Term.unify args.(0) (Term.Atom (Write.number_string (Term.deref args.(1))))
          | Term.Var _ -> Term.instantiation_error "atom_number/2"
          | t -> Term.type_error "number" t "atom_number/2")
      | _ -> ( match number_of_string (text_of args.(0) "atom_number/2") with Some n -> Term.unify args.(1) n | None -> false));
  let number_text name to_term =
    det name 2 (fun _ args ->
        match Term.deref args.(0) with
        | Term.Int _ | Term.Float _ -> Term.unify args.(1) (to_term (Write.number_string (Term.deref args.(0))))
        | _ -> (
            let text = text_of args.(1) name in
            match number_of_string text with
            | Some n -> Term.unify args.(0) n
            | None -> Term.throw (Term.Struct ("syntax_error", [| Term.Atom "illegal_number" |])) (Term.Atom name)))
  in
  number_text "number_codes" Term.term_of_codes;
  number_text "number_chars" Term.term_of_chars;
  det "upcase_atom" 2 (fun _ args ->
      Term.unify args.(1) (Term.Atom (String.uppercase_ascii (text_of args.(0) "upcase_atom/2"))));
  det "downcase_atom" 2 (fun _ args ->
      Term.unify args.(1) (Term.Atom (String.lowercase_ascii (text_of args.(0) "downcase_atom/2"))))

(* atom_concat/3 runs backwards too, splitting an atom every possible way. *)
let () =
  def "atom_concat" 3 (fun _ args sk ->
      let bound t = match Term.deref t with Term.Var _ -> false | _ -> true in
      if bound args.(0) && bound args.(1) then begin
        let joined = text_of args.(0) "atom_concat/3" ^ text_of args.(1) "atom_concat/3" in
        if Term.unify args.(2) (Term.Atom joined) then sk ()
      end
      else begin
        (* Either half unknown: split the whole every way there is. *)
        let whole = text_of args.(2) "atom_concat/3" in
        let n = String.length whole in
        let m = Term.mark () in
        for i = 0 to n do
          Term.undo_to m;
          if
            Term.unify args.(0) (Term.Atom (String.sub whole 0 i))
            && Term.unify args.(1) (Term.Atom (String.sub whole i (n - i)))
          then sk ()
        done;
        Term.undo_to m
      end);
  def "sub_atom" 5 (fun _ args sk ->
      let whole = text_of args.(0) "sub_atom/5" in
      let n = String.length whole in
      let m = Term.mark () in
      let attempt before len =
        Term.undo_to m;
        if
          Term.unify args.(1) (Term.Int before)
          && Term.unify args.(2) (Term.Int len)
          && Term.unify args.(3) (Term.Int (n - before - len))
          && Term.unify args.(4) (Term.Atom (String.sub whole before len))
        then sk ()
      in
      (match Term.deref args.(4) with
      (* With the substring known, look for where it occurs rather than
         enumerating every split. *)
      | (Term.Atom _ | Term.Int _ | Term.Float _) as sub ->
          let sub = text_of sub "sub_atom/5" in
          let len = String.length sub in
          for before = 0 to n - len do
            if String.sub whole before len = sub then attempt before len
          done
      | _ ->
          for before = 0 to n do
            for len = 0 to n - before do
              attempt before len
            done
          done);
      Term.undo_to m)

let () =
  det "atomic_list_concat" 2 (fun _ args ->
      let parts = Term.expect_list args.(0) "atomic_list_concat/2" in
      let joined = String.concat "" (List.map (fun p -> text_of p "atomic_list_concat/2") parts) in
      Term.unify args.(1) (Term.Atom joined));
  det "atomic_list_concat" 3 (fun _ args ->
      let who = "atomic_list_concat/3" in
      let separator = text_of args.(1) who in
      match Term.list_of_term args.(0) with
      | Some parts when List.for_all (fun p -> match Term.deref p with Term.Var _ -> false | _ -> true) parts ->
          let joined = String.concat separator (List.map (fun p -> text_of p who) parts) in
          Term.unify args.(2) (Term.Atom joined)
      | _ ->
          if String.length separator = 0 then Term.instantiation_error who
          else
            let whole = text_of args.(2) who in
            let pieces = String.split_on_char separator.[0] whole in
            (* Only single-character separators split; anything longer would
               need a real search, and this is where a string library would
               go. *)
            if String.length separator > 1 then Term.instantiation_error who
            else Term.unify args.(0) (Term.term_of_list (List.map (fun p -> Term.Atom p) pieces)))

let () =
  det "term_to_atom" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> (
          let text = text_of args.(1) "term_to_atom/2" in
          match try Read.term_of_string (text ^ " .") with Tok.Syntax_error (_, msg) ->
            Term.throw (Term.Struct ("syntax_error", [| Term.Atom msg |])) (Term.Atom "term_to_atom/2")
          with
          | Some { Read.clause; _ } -> Term.unify args.(0) clause
          | None -> false)
      | t -> Term.unify args.(1) (Term.Atom (Write.to_string ~opts:Write.writeq_opts t)));
  det "atom_to_term" 3 (fun _ args ->
      let text = text_of args.(0) "atom_to_term/3" in
      match
        try Read.term_of_string (text ^ " .")
        with Tok.Syntax_error (_, msg) ->
          Term.throw (Term.Struct ("syntax_error", [| Term.Atom msg |])) (Term.Atom "atom_to_term/3")
      with
      | None -> false
      | Some { Read.clause; vars; _ } ->
          let binding (name, v) = Term.Struct ("=", [| Term.Atom name; v |]) in
          Term.unify args.(1) clause && Term.unify args.(2) (Term.term_of_list (List.map binding vars)))

let () =
  let char_class code ty =
    let c = Char.chr (if code >= 0 && code < 256 then code else 0) in
    let lower = c >= 'a' && c <= 'z' in
    let upper = c >= 'A' && c <= 'Z' in
    let digit = c >= '0' && c <= '9' in
    let space = c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = '\011' || c = '\012' in
    match Term.deref ty with
    | Term.Atom "alpha" -> lower || upper || digit || c = '_'
    | Term.Atom "alnum" -> lower || upper || digit
    | Term.Atom "csym" -> lower || upper || digit || c = '_'
    | Term.Atom "csymf" -> lower || upper || c = '_'
    | Term.Atom "digit" -> digit
    | Term.Atom "space" | Term.Atom "white" -> space
    | Term.Atom "upper" -> upper
    | Term.Atom "lower" -> lower
    | Term.Atom "punct" -> code > 32 && code < 128 && not (lower || upper || digit)
    | Term.Atom "graph" -> code > 32 && code < 127
    | Term.Atom "ascii" -> code < 128
    | Term.Atom "end_of_line" -> c = '\n' || c = '\r'
    | Term.Atom "newline" -> c = '\n'
    | Term.Struct ("digit", [| weight |]) -> digit && Term.unify weight (Term.Int (code - Char.code '0'))
    | Term.Struct ("upper", [| l |]) -> upper && Term.unify l (Term.Int (code + 32))
    | Term.Struct ("lower", [| u |]) -> lower && Term.unify u (Term.Int (code - 32))
    | Term.Struct ("to_lower", [| l |]) -> Term.unify l (Term.Int (if upper then code + 32 else code))
    | Term.Struct ("to_upper", [| u |]) -> Term.unify u (Term.Int (if lower then code - 32 else code))
    | Term.Var _ -> Term.instantiation_error "code_type/2"
    | t -> Term.domain_error "char_type" t "code_type/2"
  in
  det "code_type" 2 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Int code -> char_class code args.(1)
      | Term.Var _ -> Term.instantiation_error "code_type/2"
      | t -> Term.type_error "integer" t "code_type/2");
  (* char_type/2 takes a one-character atom, and the classes that report a
     character report it as one too. *)
  det "char_type" 2 (fun _ args ->
      let as_char t = match Term.deref t with Term.Int c -> Term.Atom (String.make 1 (Char.chr c)) | t -> t in
      let translated =
        match Term.deref args.(1) with
        | Term.Struct ((("upper" | "lower" | "to_lower" | "to_upper") as name), [| other |]) ->
            let bridge = Term.fresh_var () in
            Some (Term.Struct (name, [| bridge |]), bridge, other)
        | _ -> None
      in
      match Term.deref args.(0) with
      | Term.Atom s when String.length s = 1 -> (
          let code = Char.code s.[0] in
          match translated with
          | None -> char_class code args.(1)
          | Some (query, bridge, other) -> char_class code query && Term.unify other (as_char bridge))
      | Term.Var _ -> Term.instantiation_error "char_type/2"
      | t -> Term.type_error "character" t "char_type/2")

(* ------------------------------------------------------- sorting and lists *)

let () =
  def "length" 2 (fun _ args sk ->
      let rec walk t n =
        match Term.deref t with
        | Term.Atom "[]" -> `Proper n
        | Term.Struct (".", [| _; tail |]) -> walk tail (n + 1)
        | Term.Var _ -> `Partial (n, t)
        | t -> `Bad t
      in
      let fresh_list k =
        let rec go k acc = if k = 0 then acc else go (k - 1) (Term.cons (Term.fresh_var ()) acc) in
        go k Term.nil
      in
      match walk args.(0) 0 with
      | `Bad t -> Term.type_error "list" t "length/2"
      | `Proper n -> if Term.unify args.(1) (Term.Int n) then sk ()
      | `Partial (n, tail) -> (
          match Term.deref args.(1) with
          | Term.Int total ->
              if total >= n && Term.unify tail (fresh_list (total - n)) then sk ()
          | Term.Var _ ->
              (* An open list and an unbound length: every length from here up,
                 which is why length(L, N) with both open does not terminate. *)
              let m = Term.mark () in
              let extra = ref 0 in
              let continue_ = ref true in
              while !continue_ do
                Term.undo_to m;
                if Term.unify tail (fresh_list !extra) && Term.unify args.(1) (Term.Int (n + !extra)) then sk ();
                incr extra;
                if !extra > 5_000_000 then continue_ := false
              done
          | t -> Term.type_error "integer" t "length/2"));
  det "msort" 2 (fun _ args ->
      let items = Term.expect_list args.(0) "msort/2" in
      Term.unify args.(1) (Term.term_of_list (List.stable_sort Term.compare_terms items)));
  det "sort" 2 (fun _ args ->
      let items = Term.expect_list args.(0) "sort/2" in
      let sorted = List.stable_sort Term.compare_terms items in
      let rec dedupe = function
        | a :: (b :: _ as rest) -> if Term.compare_terms a b = 0 then dedupe rest else a :: dedupe rest
        | rest -> rest
      in
      Term.unify args.(1) (Term.term_of_list (dedupe sorted)));
  det "keysort" 2 (fun _ args ->
      let items = Term.expect_list args.(0) "keysort/2" in
      let key t =
        match Term.deref t with
        | Term.Struct ("-", [| k; _ |]) -> k
        | Term.Var _ -> Term.instantiation_error "keysort/2"
        | t -> Term.type_error "pair" t "keysort/2"
      in
      let compare a b = Term.compare_terms (key a) (key b) in
      Term.unify args.(1) (Term.term_of_list (List.stable_sort compare items)))

(* --------------------------------------------------------------- all solutions *)

let () =
  det "findall" 3 (fun db args ->
      Term.unify args.(2) (Term.term_of_list (Engine.collect db args.(1) args.(0))));
  det "findall" 4 (fun db args ->
      let found = Engine.collect db args.(1) args.(0) in
      Term.unify args.(2) (List.fold_left (fun tail x -> Term.cons x tail) args.(3) (List.rev found)));
  det "forall" 2 (fun db args ->
      let counterexample = Term.Struct (",", [| args.(0); Term.Struct ("\\+", [| args.(1) |]) |]) in
      not (Engine.provable db counterexample));
  def "once" 1 (fun db args sk -> if Engine.once db args.(0) then sk ());
  def "ignore" 1 (fun db args sk ->
      let m = Term.mark () in
      if not (Engine.once db args.(0)) then Term.undo_to m;
      sk ());
  def "repeat" 0 (fun _ _ sk ->
      let m = Term.mark () in
      while true do
        Term.undo_to m;
        sk ()
      done);
  (* phrase/2,3 accept a grammar body, not just a nonterminal, so they have to
     be able to run the same translation the loader applies to `-->`. *)
  det "$dcg_body" 4 (fun _ args -> Term.unify args.(3) (Dcg.body args.(0) args.(1) args.(2)));
  (* The existentially quantified variables of Template^Goal, and the goal
     with the carets stripped: bagof/3 in the prelude needs both. *)
  det "$strip_carets" 3 (fun _ args ->
      let rec strip t existential =
        match Term.deref t with
        | Term.Struct ("^", [| v; rest |]) -> strip rest (Term.cons v existential)
        | goal -> (goal, existential)
      in
      let goal, existential = strip args.(0) Term.nil in
      Term.unify args.(1) goal && Term.unify args.(2) existential)

(* call/N adds arguments to a goal and gives it a barrier of its own, so a cut
   inside the goal cuts only the goal. *)
let () =
  for extra = 0 to 7 do
    def "call" (extra + 1)
      (fun db args sk ->
        let goal =
          if extra = 0 then args.(0)
          else
            let added = Array.sub args 1 extra in
            match Term.deref args.(0) with
            | Term.Atom name -> Term.struct_ name added
            | Term.Struct (name, existing) -> Term.Struct (name, Array.append existing added)
            | Term.Var _ -> Term.instantiation_error "call/N"
            | t -> Term.type_error "callable" t "call/N"
        in
        Engine.call_goal db goal sk)
  done

(* ------------------------------------------------------------- exceptions *)

(* A catch/3 must not catch what its own continuation throws: an error raised
   after catch/3 has already succeeded belongs to whatever comes next, not to
   this frame.  In a continuation-passing engine the continuation runs inside
   the OCaml `try`, so the depth counter below records whether control is
   currently inside the protected goal or out in the continuation. *)
let catch_depth = ref 0

let () =
  det "throw" 1 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Var _ -> Term.instantiation_error "throw/1"
      | ball -> raise (Term.Prolog_error (Term.copy_term ball)));
  def "catch" 3 (fun db args sk ->
      let outer = !catch_depth in
      let mark = Term.mark () in
      let protected_sk () =
        catch_depth := outer;
        sk ();
        catch_depth := outer + 1
      in
      catch_depth := outer + 1;
      let outcome =
        try
          Engine.call_goal db args.(0) protected_sk;
          `Done
        with
        | Term.Prolog_error ball when !catch_depth > outer -> `Caught ball
        | e ->
            catch_depth := outer;
            raise e
      in
      catch_depth := outer;
      match outcome with
      | `Done -> ()
      | `Caught ball ->
          Term.undo_to mark;
          if Term.unify args.(1) ball then Engine.call_goal db args.(2) sk
          else raise (Term.Prolog_error ball))

(* ------------------------------------------------------------- the database *)

(* Asserting over a built-in would add clauses that can never be reached,
   since Solve consults this table first.  Refuse instead. *)
let check_assertable t who =
  let head, _ = Db.split_clause t in
  let indicator = Term.indicator_of head who in
  if protected indicator then
    Term.permission_error "modify" "static_procedure" (Term.indicator_term indicator) who

let () =
  let assert_with add name =
    det name 1 (fun db args ->
        check_assertable args.(0) (name ^ "/1");
        add db args.(0);
        true)
  in
  assert_with Db.assertz "assert";
  assert_with Db.assertz "assertz";
  assert_with Db.asserta "asserta";
  det "abolish" 1 (fun db args ->
      (match Term.deref args.(0) with
      | Term.Struct ("/", [| name; arity |]) -> (
          match (Term.deref name, Term.deref arity) with
          | Term.Atom name, Term.Int arity -> Db.abolish db (name, arity)
          | _ -> Term.instantiation_error "abolish/1")
      | t -> Term.type_error "predicate_indicator" t "abolish/1");
      true);
  det "dynamic" 1 (fun db args ->
      let rec declare t =
        match Term.deref t with
        | Term.Struct (",", [| a; b |]) ->
            declare a;
            declare b
        | Term.Struct (".", [| _; _ |]) as l -> List.iter declare (Term.expect_list l "dynamic/1")
        | Term.Struct ("/", [| name; arity |]) -> (
            match (Term.deref name, Term.deref arity) with
            | Term.Atom name, Term.Int arity -> Db.declare_dynamic db (name, arity)
            | _ -> Term.instantiation_error "dynamic/1")
        | t -> Term.type_error "predicate_indicator" t "dynamic/1"
      in
      declare args.(0);
      true);
  (* Directives that only exist to be tolerated. *)
  List.iter (fun name -> det name 1 (fun _ _ -> true)) [ "discontiguous"; "multifile"; "module"; "public"; "table"; "use_module" ];
  det "use_module" 2 (fun _ _ -> true);
  det "garbage_collect" 0 (fun _ _ -> true);
  det "trace" 0 (fun _ _ -> Engine.tracing := true; true);
  det "notrace" 0 (fun _ _ -> Engine.tracing := false; true)

let clauses_of db t who =
  let head, _ = Db.split_clause t in
  let indicator = Term.indicator_of head who in
  if protected indicator then
    Term.permission_error "access" "private_procedure" (Term.indicator_term indicator) who
  else match Db.find db indicator with None -> (None, []) | Some p -> (Some p, p.clauses)

let () =
  def "clause" 2 (fun db args sk ->
      let goal = Term.Struct (":-", [| args.(0); args.(1) |]) in
      let _, clauses = clauses_of db args.(0) "clause/2" in
      let m = Term.mark () in
      List.iter
        (fun clause ->
          Term.undo_to m;
          let head, body = Db.clause_term clause in
          if Term.unify goal (Term.Struct (":-", [| head; body |])) then sk ())
        clauses;
      Term.undo_to m);
  def "retract" 1 (fun db args sk ->
      let head, body = Db.split_clause args.(0) in
      let pattern = Term.Struct (":-", [| head; body |]) in
      let p, clauses = clauses_of db args.(0) "retract/1" in
      let m = Term.mark () in
      List.iter
        (fun clause ->
          Term.undo_to m;
          let head, body = Db.clause_term clause in
          if Term.unify pattern (Term.Struct (":-", [| head; body |])) then begin
            Option.iter (fun p -> Db.remove p clause) p;
            sk ()
          end)
        clauses;
      Term.undo_to m);
  det "retractall" 1 (fun db args ->
      let indicator = Term.indicator_of args.(0) "retractall/1" in
      if protected indicator then
        Term.permission_error "modify" "static_procedure" (Term.indicator_term indicator) "retractall/1";
      let p = Db.pred db indicator in
      p.dynamic <- true;
      let m = Term.mark () in
      let survives clause =
        Term.undo_to m;
        let head, _ = Db.clause_term clause in
        not (Term.unify args.(0) head)
      in
      let kept = List.filter survives p.clauses in
      Term.undo_to m;
      p.clauses <- kept;
      true);
  (* Enough of predicate_property/2 for a meta-interpreter to tell what it may
     call directly from what it should look up clauses for. *)
  def "predicate_property" 2 (fun db args sk ->
      let indicator = Term.indicator_of args.(0) "predicate_property/2" in
      let properties =
        if protected indicator then [ Term.Atom "built_in"; Term.Atom "defined"; Term.Atom "static" ]
        else
          match Db.find db indicator with
          | None -> []
          | Some p ->
              [ Term.Atom "defined"; Term.Atom (if p.dynamic then "dynamic" else "static");
                Term.Struct ("number_of_clauses", [| Term.Int (List.length p.clauses) |]) ]
      in
      let m = Term.mark () in
      List.iter
        (fun property ->
          Term.undo_to m;
          if Term.unify args.(1) property then sk ())
        properties;
      Term.undo_to m);
  def "current_predicate" 1 (fun db args sk ->
      let pattern =
        match Term.deref args.(0) with
        | Term.Struct ("/", [| name; arity |]) -> (name, arity)
        | Term.Var _ ->
            let name = Term.fresh_var () and arity = Term.fresh_var () in
            ignore (Term.unify args.(0) (Term.Struct ("/", [| name; arity |])));
            (name, arity)
        | t -> Term.type_error "predicate_indicator" t "current_predicate/1"
      in
      let m = Term.mark () in
      List.iter
        (fun indicator ->
          match Db.find db indicator with
          | Some p when p.clauses <> [] || p.dynamic ->
              Term.undo_to m;
              let name, arity = indicator in
              if Term.unify (fst pattern) (Term.Atom name) && Term.unify (snd pattern) (Term.Int arity) then sk ()
          | _ -> ())
        (Db.indicators db);
      Term.undo_to m)

(* --------------------------------------------------------- flags and ops *)

let () =
  det "op" 3 (fun _ args ->
      let priority =
        match Term.deref args.(0) with
        | Term.Int n when n >= 0 && n <= 1200 -> n
        | Term.Int _ -> Term.domain_error "operator_priority" args.(0) "op/3"
        | Term.Var _ -> Term.instantiation_error "op/3"
        | t -> Term.type_error "integer" t "op/3"
      in
      let kind =
        match Term.deref args.(1) with
        | Term.Atom name -> (
            match Ops.kind_of_string name with
            | Some kind -> kind
            | None -> Term.domain_error "operator_specifier" args.(1) "op/3")
        | Term.Var _ -> Term.instantiation_error "op/3"
        | t -> Term.type_error "atom" t "op/3"
      in
      let names =
        match Term.list_of_term args.(2) with
        | Some names -> names
        | None -> [ args.(2) ]
      in
      List.iter
        (fun name ->
          match Term.deref name with
          | Term.Atom "," -> Term.permission_error "modify" "operator" (Term.Atom ",") "op/3"
          | Term.Atom name -> Ops.add priority kind name
          | Term.Var _ -> Term.instantiation_error "op/3"
          | t -> Term.type_error "atom" t "op/3")
        names;
      true);
  def "current_op" 3 (fun _ args sk ->
      let m = Term.mark () in
      Ops.fold
        (fun name (entry : Ops.entry) () ->
          Term.undo_to m;
          if
            Term.unify args.(0) (Term.Int entry.priority)
            && Term.unify args.(1) (Term.Atom (Ops.string_of_kind entry.kind))
            && Term.unify args.(2) (Term.Atom name)
          then sk ())
        ();
      Term.undo_to m);
  det "set_prolog_flag" 2 (fun _ args ->
      match (Term.deref args.(0), Term.deref args.(1)) with
      | Term.Atom "double_quotes", Term.Atom "codes" -> Flags.double_quotes := Flags.Codes; true
      | Term.Atom "double_quotes", Term.Atom "chars" -> Flags.double_quotes := Flags.Chars; true
      | Term.Atom "double_quotes", Term.Atom "atom" -> Flags.double_quotes := Flags.Atom_; true
      | Term.Atom "unknown", Term.Atom "error" -> Flags.unknown_error := true; true
      | Term.Atom "unknown", Term.Atom "fail" -> Flags.unknown_error := false; true
      | Term.Atom "occurs_check", Term.Atom "true" -> Flags.occurs_check := true; true
      | Term.Atom "occurs_check", Term.Atom "false" -> Flags.occurs_check := false; true
      | Term.Atom "verbose_load", Term.Atom v -> Flags.verbose_load := v = "true"; true
      | Term.Var _, _ | _, Term.Var _ -> Term.instantiation_error "set_prolog_flag/2"
      | flag, _ -> Term.domain_error "prolog_flag" flag "set_prolog_flag/2");
  def "current_prolog_flag" 2 (fun _ args sk ->
      let flags =
        [
          ("bounded", Term.Atom "true");
          ("max_integer", Term.Int max_int);
          ("min_integer", Term.Int min_int);
          ("double_quotes", Term.Atom (match !Flags.double_quotes with Flags.Codes -> "codes" | Flags.Chars -> "chars" | Flags.Atom_ -> "atom"));
          ("unknown", Term.Atom (if !Flags.unknown_error then "error" else "fail"));
          ("occurs_check", Term.Atom (if !Flags.occurs_check then "true" else "false"));
          ("dialect", Term.Atom "badger");
        ]
      in
      let m = Term.mark () in
      List.iter
        (fun (name, value) ->
          Term.undo_to m;
          if Term.unify args.(0) (Term.Atom name) && Term.unify args.(1) value then sk ())
        flags;
      Term.undo_to m)

(* ------------------------------------------------------------------ output *)

let column_of buffer_text =
  match String.rindex_opt buffer_text '\n' with
  | Some i -> String.length buffer_text - i - 1
  | None -> String.length buffer_text

(* ~w ~q ~a ~d ~s ~n ~c ~e ~f ~g ~r ~i ~t ~| ~+ ~~, which is enough for the
   output every example in this tree produces.  ~t is accepted and ignored:
   column stops pad on the left, they do not distribute fill. *)
let run_format b fmt arguments who =
  let remaining = ref arguments in
  let next () =
    match !remaining with
    | [] -> Term.domain_error "format_arguments" (Term.term_of_list arguments) who
    | a :: rest ->
        remaining := rest;
        a
  in
  let n = String.length fmt in
  let i = ref 0 in
  while !i < n do
    if fmt.[!i] = '~' && !i + 1 < n then begin
      incr i;
      let start = !i in
      while !i < n && fmt.[!i] >= '0' && fmt.[!i] <= '9' do
        incr i
      done;
      let count = if !i > start then Some (int_of_string (String.sub fmt start (!i - start))) else None in
      let count =
        if !i < n && fmt.[!i] = '*' then begin
          incr i;
          match Arith.eval (next ()) with Term.Int k -> Some k | _ -> count
        end
        else count
      in
      let repeat = Option.value count ~default:1 in
      (match fmt.[!i] with
      | 'w' -> Buffer.add_string b (Write.to_string ~opts:Write.write_opts (next ()))
      | 'p' | 'q' -> Buffer.add_string b (Write.to_string ~opts:Write.writeq_opts (next ()))
      | 'a' -> Buffer.add_string b (text_of (next ()) who)
      | 'd' -> (
          let value = match Arith.eval (next ()) with Term.Int v -> v | t -> Term.type_error "integer" t who in
          match count with
          | None | Some 0 -> Buffer.add_string b (string_of_int value)
          | Some places ->
              let digits = Printf.sprintf "%0*d" (places + 1) (abs value) in
              let cut = String.length digits - places in
              Buffer.add_string b
                (Printf.sprintf "%s%s.%s"
                   (if value < 0 then "-" else "")
                   (String.sub digits 0 cut)
                   (String.sub digits cut places)))
      | 'D' ->
          let value = match Arith.eval (next ()) with Term.Int v -> v | t -> Term.type_error "integer" t who in
          let digits = string_of_int (abs value) in
          let out = Buffer.create 16 in
          String.iteri
            (fun k c ->
              if k > 0 && (String.length digits - k) mod 3 = 0 then Buffer.add_char out ',';
              Buffer.add_char out c)
            digits;
          Buffer.add_string b (if value < 0 then "-" ^ Buffer.contents out else Buffer.contents out)
      | ('e' | 'f' | 'g') as spec ->
          let value = Arith.to_float (Arith.eval (next ())) in
          let places = Option.value count ~default:6 in
          Buffer.add_string b (Printf.sprintf (Scanf.format_from_string (Printf.sprintf "%%.%d%c" places spec) "%f") value)
      | 's' -> Buffer.add_string b (text_of (next ()) who)
      | 'n' -> Buffer.add_string b (String.make repeat '\n')
      | 'c' ->
          let code = match Arith.eval (next ()) with Term.Int c -> c | t -> Term.type_error "integer" t who in
          Buffer.add_string b (String.make repeat (Char.chr (code land 255)))
      | 'r' ->
          let value = match Arith.eval (next ()) with Term.Int v -> v | t -> Term.type_error "integer" t who in
          let radix = Option.value count ~default:8 in
          let digits = "0123456789abcdefghijklmnopqrstuvwxyz" in
          let rec go v acc = if v = 0 then acc else go (v / radix) (String.make 1 digits.[v mod radix] ^ acc) in
          Buffer.add_string b (if value = 0 then "0" else (if value < 0 then "-" else "") ^ go (abs value) "")
      | 'i' -> ignore (next ())
      | 't' -> ()
      | '|' | '+' ->
          let here = column_of (Buffer.contents b) in
          let target = match (fmt.[!i], count) with '+' , c -> here + Option.value c ~default:0 | _, c -> Option.value c ~default:here in
          if target > here then Buffer.add_string b (String.make (target - here) ' ')
      | '~' -> Buffer.add_char b '~'
      | c -> Term.domain_error "format_directive" (Term.Atom (String.make 1 c)) who);
      incr i
    end
    else begin
      Buffer.add_char b fmt.[!i];
      incr i
    end
  done

let format_arguments t =
  match Term.list_of_term t with Some items -> items | None -> [ t ]

let () =
  det "write" 1 (fun _ args -> print_string (Write.to_string ~opts:Write.write_opts args.(0)); true);
  det "print" 1 (fun _ args -> print_string (Write.to_string ~opts:Write.writeq_opts args.(0)); true);
  det "writeq" 1 (fun _ args -> print_string (Write.to_string ~opts:Write.writeq_opts args.(0)); true);
  det "write_canonical" 1 (fun _ args -> print_string (Write.to_string ~opts:Write.canonical_opts args.(0)); true);
  det "write_term" 2 (fun _ args ->
      let options = match Term.list_of_term args.(1) with Some o -> o | None -> [] in
      let opts = ref Write.write_opts in
      List.iter
        (fun option ->
          let on t = Term.deref t = Term.Atom "true" in
          match Term.deref option with
          | Term.Struct ("quoted", [| v |]) -> opts := { !opts with quoted = on v }
          | Term.Struct ("ignore_ops", [| v |]) -> opts := { !opts with ignore_ops = on v }
          | Term.Struct ("numbervars", [| v |]) -> opts := { !opts with numbervars = on v }
          | _ -> ())
        options;
      print_string (Write.to_string ~opts:!opts args.(0));
      true);
  det "nl" 0 (fun _ _ -> print_newline (); true);
  det "tab" 1 (fun _ args ->
      (match Arith.eval args.(0) with
      | Term.Int n -> print_string (String.make (max 0 n) ' ')
      | t -> Term.type_error "integer" t "tab/1");
      true);
  det "put_char" 1 (fun _ args ->
      (match Term.deref args.(0) with
      | Term.Atom s when String.length s = 1 -> print_char s.[0]
      | Term.Var _ -> Term.instantiation_error "put_char/1"
      | t -> Term.type_error "character" t "put_char/1");
      true);
  det "flush_output" 0 (fun _ _ -> flush stdout; true);
  det "format" 1 (fun _ args ->
      let b = Buffer.create 64 in
      run_format b (text_of args.(0) "format/1") [] "format/1";
      print_string (Buffer.contents b);
      true);
  det "format" 2 (fun _ args ->
      let b = Buffer.create 64 in
      run_format b (text_of args.(0) "format/2") (format_arguments args.(1)) "format/2";
      print_string (Buffer.contents b);
      true);
  (* format/3 writes to an atom or a list rather than to the output. *)
  det "format" 3 (fun _ args ->
      let b = Buffer.create 64 in
      run_format b (text_of args.(1) "format/3") (format_arguments args.(2)) "format/3";
      let text = Buffer.contents b in
      match Term.deref args.(0) with
      | Term.Struct ("atom", [| out |]) -> Term.unify out (Term.Atom text)
      | Term.Struct ("codes", [| out |]) -> Term.unify out (Term.term_of_codes text)
      | Term.Struct ("chars", [| out |]) -> Term.unify out (Term.term_of_chars text)
      | Term.Atom ("user_output" | "user_error") ->
          print_string text;
          true
      | t -> Term.domain_error "format_sink" t "format/3")

(* portray_clause/1 prints a clause the way a program is written: numbered
   variables instead of _G tags, one goal per line. *)
let () =
  let portray t =
    let copy = Term.copy_term t in
    let next = ref 0 in
    List.iter
      (fun v ->
        ignore (Term.unify v (Term.Struct ("$VAR", [| Term.Int !next |])));
        incr next)
      (Term.term_variables copy);
    let head, body = Db.split_clause copy in
    let text t = Write.to_string ~opts:Write.writeq_opts ~maxp:999 t in
    let rec goals t = match Term.deref t with Term.Struct (",", [| a; b |]) -> goals a @ goals b | t -> [ t ] in
    match Term.deref body with
    | Term.Atom "true" -> Printf.printf "%s.\n" (text head)
    | body ->
        Printf.printf "%s :-\n" (text head);
        let lines = List.map text (goals body) in
        let rec print = function
          | [] -> ()
          | [ last ] -> Printf.printf "    %s.\n" last
          | goal :: rest ->
              Printf.printf "    %s,\n" goal;
              print rest
        in
        print lines
  in
  det "portray_clause" 1 (fun _ args ->
      portray args.(0);
      true);
  det "listing" 1 (fun db args ->
      let wanted =
        match Term.deref args.(0) with
        | Term.Struct ("/", [| name; arity |]) -> (
            match (Term.deref name, Term.deref arity) with
            | Term.Atom name, Term.Int arity -> fun i -> i = (name, arity)
            | _ -> Term.instantiation_error "listing/1")
        | Term.Atom name -> fun (n, _) -> String.equal n name
        | t -> Term.type_error "predicate_indicator" t "listing/1"
      in
      List.iter
        (fun indicator ->
          if wanted indicator then
            match Db.find db indicator with
            | Some p ->
                if p.dynamic then
                  Printf.printf ":- dynamic %s.\n\n" (Write.to_string ~opts:Write.writeq_opts (Term.indicator_term indicator));
                List.iter
                  (fun clause ->
                    let head, body = Db.clause_term clause in
                    portray (Term.Struct (":-", [| head; body |])))
                  p.clauses;
                print_newline ()
            | None -> ())
        (Db.indicators db);
      true)

(* ------------------------------------------------------------------- input *)

(* The toplevel and read/1 share one reader over standard input, so that a
   program can read the text that follows its own query. *)
let stdin_reader = lazy (Read.of_channel ~file:"<stdin>" stdin)

let () =
  det "read" 1 (fun _ args ->
      match Read.read_clause (Lazy.force stdin_reader) with
      | None -> Term.unify args.(0) (Term.Atom "end_of_file")
      | Some { Read.clause; _ } -> Term.unify args.(0) clause);
  det "read_term" 2 (fun _ args ->
      match Read.read_clause (Lazy.force stdin_reader) with
      | None -> Term.unify args.(0) (Term.Atom "end_of_file")
      | Some { Read.clause; vars; singletons = _ } ->
          let options = match Term.list_of_term args.(1) with Some o -> o | None -> [] in
          let bind option =
            match Term.deref option with
            | Term.Struct ("variable_names", [| out |]) ->
                let pair (name, v) = Term.Struct ("=", [| Term.Atom name; v |]) in
                ignore (Term.unify out (Term.term_of_list (List.map pair vars)))
            | Term.Struct ("variables", [| out |]) ->
                ignore (Term.unify out (Term.term_of_list (List.map snd vars)))
            | _ -> ()
          in
          List.iter bind options;
          Term.unify args.(0) clause)

(* ------------------------------------------------------------------ system *)

let last_runtime = ref 0.0

let () =
  det "halt" 0 (fun _ _ -> raise (Term.Halt 0));
  det "halt" 1 (fun _ args ->
      match Term.deref args.(0) with
      | Term.Int n -> raise (Term.Halt n)
      | t -> Term.type_error "integer" t "halt/1");
  det "statistics" 2 (fun _ args ->
      let millis () = int_of_float (Sys.time () *. 1000.0) in
      let value =
        match Term.deref args.(0) with
        | Term.Atom ("runtime" | "process_cputime" | "walltime") ->
            let now = Sys.time () in
            let since = int_of_float ((now -. !last_runtime) *. 1000.0) in
            last_runtime := now;
            Term.term_of_list [ Term.Int (millis ()); Term.Int since ]
        | Term.Atom "cputime" -> Term.Float (Sys.time ())
        | Term.Atom "inferences" -> Term.Int !Engine.inferences
        | t -> Term.domain_error "statistics_key" t "statistics/2"
      in
      Term.unify args.(1) value);
  det "consult" 1 (fun db args ->
      let rec load t =
        match Term.deref t with
        | Term.Struct (".", [| _; _ |]) -> List.iter load (Term.expect_list t "consult/1")
        | Term.Atom path -> Load.consult_file db path
        | Term.Var _ -> Term.instantiation_error "consult/1"
        | t -> Term.type_error "atom" t "consult/1"
      in
      load args.(0);
      true);
  det "ensure_loaded" 1 (fun db args ->
      Load.consult_file db (text_of args.(0) "ensure_loaded/1");
      true);
  (* `:- [file].` is a list used as a goal, which is what './2' means here. *)
  det "." 2 (fun db args ->
      List.iter
        (fun t -> Load.consult_file db (text_of t "consult/1"))
        (Term.expect_list (Term.cons args.(0) args.(1)) "consult/1");
      true)

let () = Load.is_protected := protected
