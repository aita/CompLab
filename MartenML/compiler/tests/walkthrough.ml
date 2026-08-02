(* The worked example in doc/08-regalloc.md.

   The document walks one basic block through the whole allocator, and every
   step it describes -- every simplify, the coalesce that passes and the one
   that does not, the freeze, the spill and the second round -- is printed by
   this program rather than worked out by hand.  So are the interference graph
   the figures are drawn from and the degrees written on them.

     dune exec tests/walkthrough.exe

   A real function can never have K below 8: the eight argument registers stay
   allocatable whatever `-nregs` says, because the calling convention needs
   them.  And a graph with K of 25 does not fit on a page.  So this drives the
   allocator directly, on a machine of three registers, which is a thing the
   command line cannot ask for.

   The offsets start at 64 so that the slot the spiller allocates, at 0(sp),
   cannot be confused with the block's own stack traffic. *)

let colours = [| 10; 11; 12 |] (* a0, a1, a2 *)

let shrink_machine () =
  Array.fill Riscv.is_allocatable 0 Riscv.num_physical false;
  Array.iter (fun r -> Riscv.is_allocatable.(r) <- true) colours;
  Riscv.allocatable := colours;
  (* Nothing is callee-saved here.  The point of the example is the loop, and
     the twelve copies a real prologue makes would bury it. *)
  Riscv.callee_saved := [||];
  Riscv.caller_saved := colours

let v n = Riscv.num_physical + n
let a0 = 10

(*   ld  v0, 64(sp)       four values loaded and all live at once, which is one
     ld  v1, 72(sp)       more than the machine has
     ld  v2, 80(sp)
     ld  v3, 88(sp)
     add v4, v2, v3
     mv  v5, v4           a move whose ends can be merged
     mv  v7, v0           a move whose ends cannot
     add v6, v7, v5
     sd  v6, 96(sp)
     add a0, v7, v1
     ret a0                                                                  *)
let block () : Riscv.block =
  {
    label = "L";
    body =
      [
        Riscv.Load (v 0, Riscv.sp, 64);
        Riscv.Load (v 1, Riscv.sp, 72);
        Riscv.Load (v 2, Riscv.sp, 80);
        Riscv.Load (v 3, Riscv.sp, 88);
        Riscv.Arith (Riscv.Add, v 4, v 2, v 3);
        Riscv.Move (v 5, v 4);
        Riscv.Move (v 7, v 0);
        Riscv.Arith (Riscv.Add, v 6, v 7, v 5);
        Riscv.Store (v 6, Riscv.sp, 96);
        Riscv.Arith (Riscv.Add, a0, v 7, v 1);
      ];
    terminator = Riscv.Return [ a0 ];
  }

let func () : Riscv.func =
  {
    name = "walkthrough";
    blocks = [ block () ];
    num_regs = Riscv.num_physical + 8;
    num_spill_slots = 0;
  }

let () =
  shrink_machine ();
  let fn = func () in
  print_endline "=== before";
  Riscv.print_func stdout fn;
  print_endline "=== the loop";
  Regalloc.trace := print_endline;
  let report = Regalloc.allocate fn in
  (Regalloc.trace := fun _ -> ());
  print_endline "=== after";
  Riscv.print_func stdout fn;
  Regalloc.print_report stdout fn.name report
