(* Random programs whose answer is known before they are compiled.

   The other tests say what the compiler should do; these say what the program
   should print, which is the only thing a user cares about.  A program is built
   at random, worked out here in OCaml with the language's arithmetic, and then
   compiled — so any disagreement is a bug in the compiler and not in a comparison
   between two of its own configurations. *)

let size = 16
let vars = [ "v0"; "v1"; "v2"; "v3" ]

let constants =
  [ 0L; 1L; 2L; 3L; 7L; 8L; 15L; 16L; 100L; 4095L; 4096L; 65536L; -1L; -8L;
    Int64.shift_left 1L 40 ]

let arguments =
  [ (0L, 0L, 0L); (1L, 2L, 3L); (-1L, 7L, -13L); (Int64.max_int, Int64.min_int, 2L) ]

let comparisons = [ "="; "<>"; "<"; "<="; ">"; ">=" ]

(* The most negative value is the one that has to be written as its own unsigned
   magnitude, because [~] is applied to a literal that does not fit. *)
let literal value =
  if value < 0L then "~" ^ Printf.sprintf "%Lu" (Int64.neg value)
  else Int64.to_string value

let compare_values op a b =
  match op with
  | "=" -> a = b
  | "<>" -> a <> b
  | "<" -> a < b
  | "<=" -> a <= b
  | ">" -> a > b
  | _ -> a >= b

exception Divided_by_zero

type node =
  | Num of int64
  | Read of string
  | Bin of string * node * node
  | Choose of string * node * node * node * node
  (* [xs.(index e)], which only the imperative programs have. *)
  | Get of node

let pick list = List.nth list (Random.int (List.length list))

(* [+] four times as often as [/], so a program is mostly arithmetic rather than
   mostly divide-by-zero. *)
let weighted_op () =
  let ops = [ ("+", 4); ("-", 3); ("*", 3); ("/", 1); ("mod", 1) ] in
  let total = List.fold_left (fun n (_, w) -> n + w) 0 ops in
  let roll = ref (Random.int total) in
  let chosen = ref "+" in
  List.iter
    (fun (op, w) ->
      if !roll >= 0 then begin
        roll := !roll - w;
        if !roll < 0 then chosen := op
      end)
    ops;
  !chosen

let rec expression depth =
  if depth = 0 || Random.float 1.0 < 0.25 then
    if Random.float 1.0 < 0.5 then Read (pick [ "a"; "b"; "c" ]) else Num (pick constants)
  else if Random.float 1.0 < 0.1 then
    let op = pick comparisons in
    let x = expression (depth - 1) in
    let y = expression (depth - 1) in
    let then_ = expression (depth - 1) in
    let else_ = expression (depth - 1) in
    Choose (op, x, y, then_, else_)
  else
    let op = weighted_op () in
    let l = expression (depth - 1) in
    let r = expression (depth - 1) in
    Bin (op, l, r)

let rec evaluate node env =
  match node with
  | Read name -> List.assoc name env
  | Num v -> v
  | Choose (op, x, y, then_, else_) ->
      let a = evaluate x env and b = evaluate y env in
      if compare_values op a b then evaluate then_ env else evaluate else_ env
  | Bin (op, l, r) -> (
      let a = evaluate l env in
      let b = evaluate r env in
      match op with
      | "+" -> Int64.add a b
      | "-" -> Int64.sub a b
      | "*" -> Int64.mul a b
      | _ ->
          if b = 0L then raise Divided_by_zero
          else if op = "/" then Int64.div a b
          else Int64.rem a b)
  | Get _ -> failwith "an array read has no meaning here"

let rec show = function
  | Read name -> name
  | Num v -> literal v
  | Choose (op, x, y, then_, else_) ->
      Printf.sprintf "(if %s %s %s then %s else %s)" (show x) op (show y) (show then_)
        (show else_)
  | Bin (op, l, r) -> "(" ^ show l ^ " " ^ op ^ " " ^ show r ^ ")"
  | Get where -> "xs[index (" ^ show where ^ ")]"

(* [count] functions of three arguments, and what they print. *)
let arithmetic seed count =
  Random.init seed;
  let definitions = ref [] and calls = ref [] and expected = ref [] in
  let made = ref 0 in
  while !made < count do
    let tree = expression (1 + Random.int 5) in
    match
      List.map
        (fun (a, b, c) -> evaluate tree [ ("a", a); ("b", b); ("c", c) ])
        arguments
    with
    | exception Divided_by_zero -> ()
    | values ->
        definitions :=
          !definitions
          @ [ Printf.sprintf "fun f%d (a : int, b : int, c : int) : int = %s" !made (show tree) ];
        List.iter2
          (fun (a, b, c) want ->
            let written = String.concat ", " (List.map literal [ a; b; c ]) in
            calls :=
              !calls
              @ [ Printf.sprintf "val () = (printInt (f%d (%s)); print (\"\\n\"))" !made written ];
            expected := !expected @ [ Int64.to_string want ])
          arguments values;
        incr made
  done;
  (String.concat "\n" (!definitions @ !calls) ^ "\n", String.concat "\n" !expected ^ "\n")

(* -- statements ------------------------------------------------------------- *)

type stmt =
  | Set of string * node
  | Put of node * node
  | Seq of stmt list
  | If of string * node * node * stmt * stmt
  | For of string * int * int * stmt

(* An expression over the variables in scope and the array. *)
let rec place scope =
  let roll = Random.float 1.0 in
  if roll < 0.35 then Read (pick scope)
  else if roll < 0.5 then Num (pick constants)
  else if roll < 0.65 then Get (place scope)
  else
    let op = pick [ "+"; "-"; "*" ] in
    let l = place scope in
    let r = place scope in
    Bin (op, l, r)

let rec statement depth scope fresh =
  let roll = Random.float 1.0 in
  if depth > 0 && roll < 0.2 then begin
    let op = pick comparisons in
    let x = place scope in
    let y = place scope in
    let then_ = statement (depth - 1) scope fresh in
    let else_ = statement (depth - 1) scope fresh in
    If (op, x, y, then_, else_)
  end
  else if depth > 0 && roll < 0.45 then begin
    incr fresh;
    let name = Printf.sprintf "i%d" !fresh in
    let lo = Random.int 3 in
    let hi = 2 + Random.int 4 in
    For (name, lo, hi, statement (depth - 1) (scope @ [ name ]) fresh)
  end
  else if depth > 0 && roll < 0.55 then begin
    let first = statement (depth - 1) scope fresh in
    let second = statement (depth - 1) scope fresh in
    Seq [ first; second ]
  end
  else if roll < 0.8 then
    let name = pick vars in
    Set (name, place scope)
  else
    let where = place scope in
    let value = place scope in
    Put (where, value)

(* [index] in the generated program: the remainder, made positive. *)
let cell value = Int64.to_int (Int64.rem (Int64.add (Int64.rem value 16L) 16L) 16L)

let rec run_place node env array =
  match node with
  | Read name -> Hashtbl.find env name
  | Num v -> v
  | Get where -> array.(cell (run_place where env array))
  | Bin (op, l, r) -> (
      let a = run_place l env array in
      let b = run_place r env array in
      match op with "+" -> Int64.add a b | "-" -> Int64.sub a b | _ -> Int64.mul a b)
  | Choose _ -> failwith "a branch is not a place"

let rec run_statement node env array =
  match node with
  | Set (name, value) -> Hashtbl.replace env name (run_place value env array)
  | Put (where, value) ->
      let at = cell (run_place where env array) in
      array.(at) <- run_place value env array
  | Seq items -> List.iter (fun item -> run_statement item env array) items
  | If (op, x, y, then_, else_) ->
      let a = run_place x env array in
      let b = run_place y env array in
      run_statement (if compare_values op a b then then_ else else_) env array
  | For (name, lo, hi, body) ->
      for i = lo to hi do
        Hashtbl.replace env name (Int64.of_int i);
        run_statement body env array
      done

let rec show_statement node indent =
  match node with
  | Set (name, value) -> indent ^ name ^ " := " ^ show value
  | Put (where, value) -> indent ^ "xs[index (" ^ show where ^ ")] := " ^ show value
  | Seq items ->
      indent ^ "(\n"
      ^ String.concat ";\n" (List.map (fun i -> show_statement i (indent ^ "  ")) items)
      ^ "\n" ^ indent ^ ")"
  | If (op, x, y, then_, else_) ->
      Printf.sprintf "%sif %s %s %s then\n%s\n%selse\n%s" indent (show x) op (show y)
        (show_statement then_ (indent ^ "  "))
        indent
        (show_statement else_ (indent ^ "  "))
  | For (name, lo, hi, body) ->
      Printf.sprintf "%sfor %s = %d to %d do\n%s" indent name lo hi
        (show_statement body (indent ^ "  "))

let preamble =
  "val xs = array (16, 0)\n\
   fun index (n : int) : int =\n\
  \  let val r = n - n / 16 * 16 in\n\
  \    if r < 0 then r + 16 else r\n\
  \  end"

(* A program of assignments, loops and branches over an array. *)
let imperative seed count =
  Random.init seed;
  let fresh = ref 0 in
  let body = List.init count (fun _ -> statement 3 vars fresh) in
  let env = Hashtbl.create 8 in
  List.iter (fun name -> Hashtbl.replace env name 0L) vars;
  let array = Array.make size 0L in
  List.iter (fun item -> run_statement item env array) body;
  let expected =
    List.map (fun name -> Int64.to_string (Hashtbl.find env name)) vars
    @ Array.to_list (Array.map Int64.to_string array)
  in
  let lines =
    [ preamble ]
    @ List.map (fun name -> "var " ^ name ^ " = 0") vars
    @ [ "val () = (" ]
    @ [ String.concat ";\n" (List.map (fun item -> show_statement item "  ") body) ]
    @ [ ")" ]
    @ List.map
        (fun name -> Printf.sprintf "val () = (printInt (%s); print (\"\\n\"))" name)
        vars
    @ [ "val () = for k = 0 to 15 do (printInt (xs[k]); print (\"\\n\"))" ]
  in
  (String.concat "\n" lines ^ "\n", String.concat "\n" expected ^ "\n")
