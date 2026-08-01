-- | ARMv8 assembly, in AAPCS64.
--
-- The frame is the ordinary one.  @x29@ points at the saved frame record, the
-- slots an escaping variable or a spill lives in are below it, the callee-saved
-- registers this function actually used are below those, and outgoing stack
-- arguments sit at the bottom, at @sp@, where the callee expects them.
--
-- >     x29 -> | saved x29, x30 |
-- >            | slot 0         |   x29 - 8      also where a static link points
-- >            | slot 1         |   x29 - 16
-- >            | ...            |
-- >            | saved x19...   |
-- >     sp  -> | outgoing args  |
--
-- The allocator this tree keeps leaves SSA before it colours, so a phi never
-- reaches here.  The copies a phi stood for are already instructions, and the
-- only parallel copies left are the ones the ABI makes at a call and in the
-- prologue — which are still parallel, and still go through 'sequentialize':
-- when they form a cycle it borrows a register the function never used, and when
-- there is none it swaps the two ends with three @eor@s, so no register has to
-- be reserved for it.
module Wolv.Emit (emitModule, emitFunc, escape, Borrowing (..)) where

import Data.Bits (shiftR, (.&.))
import Data.Char (ord)
import Data.Int (Int64)
import Data.List (intercalate, isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Text.Printf (printf)
import Wolv.Copies
import Wolv.Ir
import Wolv.Mach (template)
import Wolv.Registers (argumentRegs, callerSaved, resultRegister, spare)

-- | Whether the emitter may borrow a register to untangle a cycle of copies.
-- Shut off, the copies swap instead — which is the path a test would never reach
-- on its own, because there is nearly always something to borrow.
data Borrowing = MayBorrow | MustSwap
  deriving (Eq)

unscaled :: String -> String
unscaled op = case op of "ldr" -> "ldur"; "str" -> "stur"; _ -> op

-- | Nothing of ours is live at the top of the prologue except the incoming
-- arguments, so a caller-saved register that is not one of them is free there.
prologueTemp :: Int
prologueTemp = 9

data Frame = Frame {frSlots :: Int, frSaved :: [Int], frSize :: Int}

frameOf :: Func -> Allocation -> Frame
frameOf f alloc = Frame (fnSlots f) saved ((raw + 15) .&. complement15)
  where
    stackArgs =
      maximum (0 : [length args - length argumentRegs | b <- walk f, Call _ _ args <- blInstrs b])
    saved = alSaved alloc
    raw = word * (fnSlots f + length saved + stackArgs)
    complement15 = -16

savedOffset :: Frame -> Int -> Int
savedOffset fr index = -word * (frSlots fr + index + 1)

-- | A line of assembly, and the two shapes that are not one.
line :: String -> String
line text = "\t" ++ text

label :: String -> String
label text = text ++ ":"

-- | A 64-bit constant, in as many @movz@/@movk@ as its non-zero halves need.
immediate :: Int -> Int64 -> [String]
immediate dst value
  | bits == 0 = [line (printf "mov x%d, #0" dst)]
  | otherwise = go True (zip [0 :: Int ..] [0, 16, 32, 48])
  where
    bits = fromIntegral value `mod` (2 ^ (64 :: Int)) :: Integer
    go _ [] = []
    go first ((i, shift) : rest)
      | chunk == 0 = go first rest
      | otherwise =
          line
            ( printf
                "%s x%d, #%d%s"
                (if first then "movz" else "movk" :: String)
                dst
                chunk
                (if i == 0 then "" else printf ", lsl #%d" (i * 16) :: String)
            )
            : go False rest
      where
        chunk = (bits `shiftR` shift) .&. 0xFFFF

-- | @ldr@/@str@, in whichever addressing mode reaches this far.
access :: String -> Int -> Int -> Int -> [String]
access op reg base offset
  | offset >= 0 && offset <= 32760 && offset `mod` word == 0 =
      [line (printf "%s x%d, [%s, #%d]" op reg where' offset)]
  | offset >= -256 && offset <= 255 =
      [line (printf "%s x%d, [%s, #%d]" (unscaled op) reg where' offset)]
  | otherwise =
      immediate spare (fromIntegral offset)
        ++ [line (printf "%s x%d, [%s, x%d]" op reg where' spare)]
  where
    where' = if base == 31 then "sp" else "x" ++ show base :: String

emitModule :: Borrowing -> Module -> Map.Map String Allocation -> String
emitModule borrowing m allocs =
  intercalate "\n" (["\t.text"] ++ concatMap one (modFuncs m) ++ strings ++ [note]) ++ "\n"
  where
    one f = emitFunc borrowing f (fromMaybe unallocated (Map.lookup (fnLabel f) allocs)) ++ [""]
    strings
      | null (modStrings m) = []
      | otherwise = "\t.section .rodata" : concatMap literal (modStrings m)
    literal (symbol, text) =
      [ "\t.p2align 3",
        symbol ++ ":",
        "\t.quad " ++ show (length text),
        "\t.ascii \"" ++ escape text ++ "\"",
        "\t.byte 0"
      ]
    note = "\t.section .note.GNU-stack,\"\",%progbits"

emitFunc :: Borrowing -> Func -> Allocation -> [String]
emitFunc borrowing f alloc = steps
  where
    fr = frameOf f alloc
    colours = alColours alloc
    epilogue = ".Lepi_" ++ fnLabel f
    steps =
      [ "\t.globl " ++ fnLabel f,
        "\t.type " ++ fnLabel f ++ ", %function",
        label (fnLabel f)
      ]
        ++ prologue
        ++ concat
          [ label (".L" ++ fnLabel f ++ "_" ++ name) : block (blockOf f name) next
            | (name, next) <- zip (fnOrder f) (map Just (drop 1 (fnOrder f)) ++ [Nothing])
          ]
        ++ [label epilogue]
        ++ restore
        ++ [ line "mov sp, x29",
             line "ldp x29, x30, [sp], #16",
             line "ret",
             "\t.size " ++ fnLabel f ++ ", .-" ++ fnLabel f
           ]

    colour r = fromMaybe (error ("%" ++ show (unReg r) ++ " was never coloured")) (Map.lookup r colours)

    mov dst src = if dst == src then [] else [line (printf "mov x%d, x%d" dst src)]

    readSomewhere =
      Set.fromList
        ( [r | b <- walk f, p <- blPhis b, (_, r) <- phiArgs p]
            ++ [r | b <- walk f, i <- blInstrs b, r <- uses i]
        )

    taken = Set.fromList (Map.elems colours)

    prologue =
      [line "stp x29, x30, [sp, #-16]!", line "mov x29, sp"]
        ++ ( if frSize fr == 0
               then []
               else
                 if frSize fr <= 4095
                   then [line (printf "sub sp, sp, #%d" (frSize fr))]
                   else immediate prologueTemp (fromIntegral (frSize fr)) ++ [line (printf "sub sp, sp, x%d" prologueTemp)]
           )
        ++ concat [access "str" reg 29 (savedOffset fr i) | (i, reg) <- zip [0 ..] (frSaved fr)]
        ++ parallel
          [ (colour p, reg)
            | (p, reg) <- zip (fnParams f) argumentRegs,
              Set.member p readSomewhere
          ]

    restore = concat [access "ldr" reg 29 (savedOffset fr i) | (i, reg) <- zip [0 ..] (frSaved fr)]

    block b next = concatMap instruction (body b) ++ terminator' b next

    terminator' b next = case terminator b of
      Jmp target ->
        edge (blLabel b) target
          ++ [line ("b " ++ block' target) | Just target /= next]
      CBr _ t e (Just code) ->
        if Just t == next
          then [line ("b." ++ showCond (opposite code) ++ " " ++ block' e)]
          else
            line ("b." ++ showCond code ++ " " ++ block' t)
              : [line ("b " ++ block' e) | Just e /= next]
      CBr cond t e Nothing
        | Just t == next -> [line (printf "cbz x%d, %s" (colour cond) (block' e))]
        | otherwise ->
            line (printf "cbnz x%d, %s" (colour cond) (block' t))
              : [line ("b " ++ block' e) | Just e /= next]
      Ret value ->
        maybe [] (mov resultRegister . colour) value
          -- The epilogue follows the last block, so the last `ret` needs no branch.
          ++ [line ("b " ++ epilogue) | next /= Nothing]
      _ -> []
      where
        block' name = ".L" ++ fnLabel f ++ "_" ++ name

    -- The copies a phi stands for, made real on this edge.  The allocator this
    -- tree keeps left SSA already, so this is only ever asked of a block with no
    -- phis.
    edge source target =
      parallel [(colour d, colour src) | (d, src) <- onEdge source (blockOf f target)]

    parallel moves = concatMap step (sequentialize moves (borrowed moves))
      where
        step (Mov d s) = mov d s
        step (Swap a b) =
          [ line (printf "eor x%d, x%d, x%d" a a b),
            line (printf "eor x%d, x%d, x%d" b a b),
            line (printf "eor x%d, x%d, x%d" a a b)
          ]

    -- A register free to clobber here, if the function left one over.
    --
    -- A caller-saved register this function never gave to a value holds nothing
    -- of ours anywhere, and one that this copy neither reads nor writes holds
    -- nothing of the copy's either.  With no such register the copies swap
    -- instead, which needs no scratch at all.
    borrowed moves
      | borrowing == MustSwap = Nothing
      | otherwise = case [reg | reg <- callerSaved, not (Set.member reg taken), reg `notElem` touched] of
          (reg : _) -> Just reg
          [] -> Nothing
      where
        touched = concat [[d, s] | (d, s) <- moves]

    instruction i = case i of
      MConst d v -> immediate (colour d) v
      MAdr d symbol ->
        let x = colour d
         in [ line (printf "adrp x%d, %s" x symbol),
              line (printf "add x%d, x%d, :lo12:%s" x x symbol)
            ]
      MLoad d base off -> access "ldr" (colour d) (colour base) (fromIntegral off)
      MStore base value off -> access "str" (colour value) (colour base) (fromIntegral off)
      Machine {} -> machine i
      Move d s -> mov (colour d) (colour s)
      LoadSlot d slot -> access "ldr" (colour d) 29 (slotOffset slot)
      StoreSlot slot s -> access "str" (colour s) 29 (slotOffset slot)
      FrameAddr d -> mov (colour d) 29
      Call d callee args -> call d callee args
      -- Anything else is an abstract instruction that selection should have
      -- replaced, which `Mach.verify` says so about before emission is reached;
      -- there is no line for it because there is no instruction for it.
      _ -> []

    -- Write down one selected instruction: the table's line with its holes
    -- filled in.
    machine i = [line (fill (template (mForm i)))]
      where
        srcs = map colour (mSrcs i)
        fill template' = case template' of
          [] -> []
          ('{' : rest) ->
            let (name, after) = span (/= '}') rest
             in value name ++ fill (drop 1 after)
          (c : rest) -> c : fill rest
        value name
          | name == "imm" = show (mImm i)
          | name == "d" = maybe "" (\d -> "x" ++ show (colour d)) (mDst i)
          | "s" `isPrefixOf` name, [(at, "")] <- reads (drop 1 name), at < length srcs =
              "x" ++ show (srcs !! at)
          | otherwise = "{" ++ name ++ "}"

    call d callee args =
      concat
        [ access "str" (colour a) 31 (word * i)
          | (i, a) <- zip [0 ..] (drop (length argumentRegs) args)
        ]
        ++ parallel [(reg, colour a) | (reg, a) <- zip argumentRegs args]
        ++ [line ("bl " ++ callee)]
        ++ maybe [] (\r -> mov (colour r) resultRegister) d

-- | One character of a literal is one byte; write the ones @.ascii@ cannot.
escape :: String -> String
escape = concatMap one
  where
    one c
      | n == 0x22 = "\\\""
      | n == 0x5C = "\\\\"
      | n >= 0x20 && n < 0x7F = [c]
      | otherwise = printf "\\%03o" n
      where
        n = ord c
