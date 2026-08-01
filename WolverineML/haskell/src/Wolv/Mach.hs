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
-- Four forms are not one instruction each, and the emitter expands them:
--
-- >     const   a constant, which is a `mov` or up to four `movz`/`movk`
-- >     adr     the address of a string, which is `adrp` and an `add`
-- >     ldr     a load, whose addressing mode depends on how far the offset reaches
-- >     str     a store, likewise
module Wolv.Mach (forms, condition, opposite, expanded, verify, verifyModule) where

import Wolv.Ir

-- | How each form is written down, once the registers have their colours.  @d@
-- is the register written and @s0@, @s1@, @s2@ the ones read.
forms :: [(String, String)]
forms =
  [ ("add", "add {d}, {s0}, {s1}"),
    ("addi", "add {d}, {s0}, #{imm}"),
    ("adds", "add {d}, {s0}, {s1}, lsl #{imm}"),
    ("sub", "sub {d}, {s0}, {s1}"),
    ("subi", "sub {d}, {s0}, #{imm}"),
    ("subs", "sub {d}, {s0}, {s1}, lsl #{imm}"),
    ("mul", "mul {d}, {s0}, {s1}"),
    ("madd", "madd {d}, {s0}, {s1}, {s2}"),
    ("msub", "msub {d}, {s0}, {s1}, {s2}"),
    ("sdiv", "sdiv {d}, {s0}, {s1}"),
    ("and", "and {d}, {s0}, {s1}"),
    ("orr", "orr {d}, {s0}, {s1}"),
    ("eor", "eor {d}, {s0}, {s1}"),
    ("eori", "eor {d}, {s0}, #{imm}"),
    ("lsl", "lsl {d}, {s0}, {s1}"),
    ("lsli", "lsl {d}, {s0}, #{imm}"),
    ("asr", "asr {d}, {s0}, {s1}"),
    ("asri", "asr {d}, {s0}, #{imm}"),
    ("cmp", "cmp {s0}, {s1}"),
    ("cmpi", "cmp {s0}, #{imm}"),
    ("cset", "cset {d}, {sym}")
  ]

-- | Which condition code each comparison sets, and which one says the opposite —
-- the emitter needs the opposite when the branch it is writing falls through to
-- the block the comparison was true for.
condition :: String -> String
condition op = case op of
  "=" -> "eq"; "<>" -> "ne"; "<" -> "lt"; "<=" -> "le"
  ">" -> "gt"; ">=" -> "ge"; "u<" -> "lo"; "u>=" -> "hs"
  _ -> error ("no condition code for " ++ op)

opposite :: String -> String
opposite code = case code of
  "eq" -> "ne"; "ne" -> "eq"; "lt" -> "ge"; "ge" -> "lt"
  "gt" -> "le"; "le" -> "gt"; "lo" -> "hs"; "hs" -> "lo"
  _ -> error ("no opposite of " ++ code)

-- | The ones the emitter writes itself, because they are not one instruction.
expanded :: [String]
expanded = ["const", "adr", "ldr", "str"]

-- | Insist that selection left nothing of the three-address IR behind.
verify :: Func -> Either String ()
verify f = mapM_ one [(blLabel b, i) | b <- walk f, i <- blInstrs b]
  where
    one (label, i)
      | abstract i = Left ("an abstract instruction survived selection in " ++ fnName f ++ ":" ++ label)
      | Machine {mForm = form} <- i,
        form `notElem` map fst forms,
        form `notElem` expanded =
          Left ("no such instruction as `" ++ form ++ "`")
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
