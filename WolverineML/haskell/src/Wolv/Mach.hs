-- | The machine IR: what instruction selection replaces the arithmetic with.
--
-- One instruction constructor, because on this machine an instruction is a form,
-- a register it writes and some it reads — 'Machine' in "Wolv.Ir".  The form
-- names an entry in the table below, and the table is the whole instruction set
-- the compiler can choose from.
--
-- The machine IR is that plus the part of "Wolv.Ir" that was already
-- machine-level: a call, a move, a frame slot, a phi and the three terminators.
-- What it may no longer contain is the arithmetic — 'Const', 'StrConst', 'Bin',
-- 'Cmp', 'Load', 'Store' — and 'verify' is what says so, because a compiler that
-- quietly kept an abstract instruction until the emitter would only find out
-- there.
--
-- Four of the machine's instructions are not one instruction each, and the
-- emitter expands them.  They are 'MConst', 'MAdr', 'MLoad' and 'MStore' in
-- "Wolv.Ir" — constructors of their own, which is what says so, and which is why
-- this module has nothing left to check about a form.
module Wolv.Mach (template, verify, verifyModule) where

import Wolv.Ir

-- | How each form is written down, once the registers have their colours.  @d@
-- is the register written and @s0@, @s1@, @s2@ the ones read.
--
-- A total function and not a table to look a string up in: a 'Form' is one of
-- these and the compiler is what says the list is complete.
template :: Form -> String
template form = case form of
  FAdd -> "add {d}, {s0}, {s1}"
  FAddi -> "add {d}, {s0}, #{imm}"
  FAdds -> "add {d}, {s0}, {s1}, lsl #{imm}"
  FSub -> "sub {d}, {s0}, {s1}"
  FSubi -> "sub {d}, {s0}, #{imm}"
  FSubs -> "sub {d}, {s0}, {s1}, lsl #{imm}"
  FMul -> "mul {d}, {s0}, {s1}"
  FMadd -> "madd {d}, {s0}, {s1}, {s2}"
  FMsub -> "msub {d}, {s0}, {s1}, {s2}"
  FSdiv -> "sdiv {d}, {s0}, {s1}"
  FAnd -> "and {d}, {s0}, {s1}"
  FOrr -> "orr {d}, {s0}, {s1}"
  FEor -> "eor {d}, {s0}, {s1}"
  FEori -> "eor {d}, {s0}, #{imm}"
  FLsl -> "lsl {d}, {s0}, {s1}"
  FLsli -> "lsl {d}, {s0}, #{imm}"
  FAsr -> "asr {d}, {s0}, {s1}"
  FAsri -> "asr {d}, {s0}, #{imm}"
  FCmp -> "cmp {s0}, {s1}"
  FCmpi -> "cmp {s0}, #{imm}"
  FCset code -> "cset {d}, " ++ showCond code

-- | Insist that selection left nothing of the three-address IR behind.
verify :: Func -> Either String ()
verify f = mapM_ one [(blLabel b, i) | b <- walk f, i <- blInstrs b]
  where
    one (label, i)
      | abstract i = Left ("an abstract instruction survived selection in " ++ fnName f ++ ":" ++ label)
      | otherwise = Right ()
    abstract i = case i of
      Const _ _ -> True
      StrConst _ _ -> True
      Bin {} -> True
      Cmp {} -> True
      Load {} -> True
      Store {} -> True
      _ -> False

verifyModule :: Module -> Either String ()
verifyModule m = mapM_ verify (modFuncs m)
