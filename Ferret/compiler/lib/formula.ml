(* A one-line expression, typed into a node instead of wired out of a dozen.

   `x * x + y * y < 1` is four nodes and six wires drawn, or one card.  This
   is the parser for that text; the lowering turns what comes out into the
   same tree the wired-up version would have produced, so nothing downstream
   knows the difference.

   The names it finds free become the node's input ports, which is what makes
   it fit the rest of the language rather than being an escape hatch. *)

type t =
  | Num of float
  | Var of string
  | Bin of string * t * t
  | Un of string * t
  | Call of string * t list

exception Bad of string

let fail fmt = Printf.ksprintf (fun s -> raise (Bad s)) fmt

(* ---------------------------------------------------------------- lexer *)

type token =
  | TNum of float
  | TName of string
  | TOp of string
  | TOpen
  | TClose
  | TComma
  | TEnd

let is_digit c = c >= '0' && c <= '9'

let is_name_start c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'

let is_name c = is_name_start c || is_digit c

let tokens (s : string) : token list =
  let n = String.length s in
  let rec go i acc =
    if i >= n then List.rev (TEnd :: acc)
    else
      match s.[i] with
      | ' ' | '\t' | '\n' | '\r' -> go (i + 1) acc
      | '(' -> go (i + 1) (TOpen :: acc)
      | ')' -> go (i + 1) (TClose :: acc)
      | ',' -> go (i + 1) (TComma :: acc)
      | c when is_digit c || (c = '.' && i + 1 < n && is_digit s.[i + 1]) ->
          let j = ref i in
          while !j < n && (is_digit s.[!j] || s.[!j] = '.') do
            incr j
          done;
          let text = String.sub s i (!j - i) in
          let v =
            match float_of_string_opt text with
            | Some v -> v
            | None -> fail "%s is not a number" text
          in
          go !j (TNum v :: acc)
      | c when is_name_start c ->
          let j = ref i in
          while !j < n && is_name s.[!j] do
            incr j
          done;
          go !j (TName (String.sub s i (!j - i)) :: acc)
      | _ ->
          (* the two-character operators first, so < does not eat <= *)
          let two = if i + 1 < n then String.sub s i 2 else "" in
          if List.mem two [ "<="; ">="; "=="; "!="; "&&"; "||" ] then
            go (i + 2) (TOp two :: acc)
          else
            let one = String.make 1 s.[i] in
            if List.mem one [ "+"; "-"; "*"; "/"; "%"; "<"; ">"; "!"; "=" ] then
              go (i + 1) (TOp (if one = "=" then "==" else one) :: acc)
            else fail "%s does not mean anything here" one
  in
  go 0 []

(* --------------------------------------------------------------- parser *)

(* Ordinary precedence, loosest first, so that a * b + 1 groups the way it
   reads. *)
let levels =
  [ [ "||" ]; [ "&&" ]; [ "<"; "<="; ">"; ">="; "=="; "!=" ]; [ "+"; "-" ];
    [ "*"; "/"; "%" ] ]

let parse (text : string) : t =
  let ts = ref (tokens text) in
  let peek () = match !ts with t :: _ -> t | [] -> TEnd in
  let eat () = match !ts with t :: rest -> ts := rest; t | [] -> TEnd in
  let expect t what =
    if eat () <> t then fail "%s is missing" what
  in
  let rec binary level =
    if level >= List.length levels then unary ()
    else
      let ops = List.nth levels level in
      let rec more left =
        match peek () with
        | TOp o when List.mem o ops ->
            ignore (eat ());
            let right = binary (level + 1) in
            more (Bin (o, left, right))
        | _ -> left
      in
      more (binary (level + 1))
  and unary () =
    match peek () with
    | TOp "-" ->
        ignore (eat ());
        Un ("-", unary ())
    | TOp "!" ->
        ignore (eat ());
        Un ("!", unary ())
    | _ -> atom ()
  and atom () =
    match eat () with
    | TNum v -> Num v
    | TOpen ->
        let e = binary 0 in
        expect TClose "a closing bracket";
        e
    | TName name -> (
        match peek () with
        | TOpen ->
            ignore (eat ());
            let rec args acc =
              if peek () = TClose then (
                ignore (eat ());
                List.rev acc)
              else
                let a = binary 0 in
                match eat () with
                | TComma -> args (a :: acc)
                | TClose -> List.rev (a :: acc)
                | _ -> fail "a comma or a closing bracket is missing"
            in
            Call (name, args [])
        | _ -> Var name)
    | TEnd -> fail "the expression stops early"
    | TOp o -> fail "%s needs something before it" o
    | TClose -> fail "there is a closing bracket with nothing to close"
    | TComma -> fail "there is a stray comma"
  in
  let e = binary 0 in
  if peek () <> TEnd then fail "there is more after the expression than it needs";
  e

(* The names the text leaves free, in the order they first appear: those are
   the node's inputs. *)
let variables (e : t) : string list =
  let seen = Hashtbl.create 8 in
  let out = ref [] in
  let rec go = function
    | Num _ -> ()
    | Var v ->
        if not (Hashtbl.mem seen v) then (
          Hashtbl.replace seen v ();
          out := v :: !out)
    | Bin (_, a, b) -> go a; go b
    | Un (_, a) -> go a
    | Call (_, args) -> List.iter go args
  in
  go e;
  List.rev !out

let of_string text =
  match parse text with e -> Ok e | exception Bad m -> Error m

(* The same names, read off the tokens rather than off the parse.  The editor
   asks for these to know which ports to draw, and it asks on every keystroke:
   a formula that is halfway typed has no tree yet but does have ports. *)
let free_names (text : string) : string list =
  match tokens text with
  | exception Bad _ -> []
  | ts ->
      let rec go acc = function
        | TName _ :: TOpen :: rest -> go acc (TOpen :: rest)
        | TName v :: rest -> go (if List.mem v acc then acc else v :: acc) rest
        | _ :: rest -> go acc rest
        | [] -> List.rev acc
      in
      go [] ts

(* Whether the whole thing is a condition rather than a number.  Comparison
   and the two connectives are looser than arithmetic, so it is the operator
   at the top of the tree that decides. *)
let is_condition (text : string) : bool =
  match parse text with
  | exception Bad _ -> false
  | Bin (("<" | "<=" | ">" | ">=" | "==" | "!=" | "&&" | "||"), _, _) -> true
  | Un ("!", _) -> true
  | _ -> false
