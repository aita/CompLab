(* [List.map] does not promise which order it applies the function in, and here
   the function usually has an effect: it allocates a register, emits an
   instruction, or raises the first error.  Every such map goes through this one,
   which is left to right and says so. *)
let rec map_in_order f = function
  | [] -> []
  | x :: rest ->
      let y = f x in
      y :: map_in_order f rest
(* The same, where the position in the list is wanted too. *)
let mapi_in_order f list =
  let rec go at = function
    | [] -> []
    | x :: rest ->
        let y = f at x in
        y :: go (at + 1) rest
  in
  go 0 list
