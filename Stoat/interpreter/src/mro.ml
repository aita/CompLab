(* C3 linearization, the same algorithm Python uses for its MRO.

     L[C] = C :: merge(L[B1], ..., L[Bn], [B1, ..., Bn])

   [linearize] returns everything after C, so the caller builds the full MRO as
   [c :: linearize name bases]. *)

open Value

let non_empty = function [] -> false | _ :: _ -> true

(* The first head that does not appear in the tail of any sequence. *)
let pick (seqs : cls list list) : cls option =
  let in_tail c = function [] -> false | _ :: tl -> List.exists (same_class c) tl in
  let rec go = function
    | [] -> None
    | [] :: rest -> go rest
    | (head :: _) :: rest ->
        if List.exists (in_tail head) seqs then go rest else Some head
  in
  go seqs

let linearize (name : string) (bases : cls list) : cls list =
  let seqs = List.map (fun b -> b.c_mro) bases @ [ bases ] in
  let rec merge seqs =
    let seqs = List.filter non_empty seqs in
    match seqs with
    | [] -> []
    | _ -> (
        match pick seqs with
        | None ->
            error
              "cannot build a consistent method resolution order for class '%s' \
               (the bases are listed in conflicting orders)"
              name
        | Some head ->
            let drop = List.map (List.filter (fun c -> not (same_class c head))) seqs in
            head :: merge drop)
  in
  merge seqs
