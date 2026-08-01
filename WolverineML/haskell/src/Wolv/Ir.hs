-- | The three-address IR, and the control flow graph both IRs are written in.
--
-- There are two instruction sets in this compiler.  This file has the first:
-- three-address code over virtual registers, which is what lowering produces,
-- what "Wolv.Ssa" puts into SSA and what "Wolv.Opt" rewrites.  The second is
-- 'Machine', whose forms and meaning are "Wolv.Mach"'s.
--
-- What the two sets share is everything else — the registers, the blocks, the
-- graph, the frame — so the passes that only care about the shape of a function
-- work on either.  That is what 'defs', 'uses', 'mapUses', 'withDef' and
-- 'hasEffect' are for: an instruction says which register it writes and which it
-- reads, and nothing outside this file asks what it is.
module Wolv.Ir
  ( Reg,
    Label,
    Instr (..),
    Phi (..),
    Block (..),
    Func (..),
    Module (..),
    Allocation (..),
    unallocated,
    word,
    argumentRegisters,
    slotOffset,
    defs,
    uses,
    mapUses,
    withDef,
    hasEffect,
    renameTarget,
    newFunc,
    blockOf,
    addBlock,
    walk,
    setBlock,
    mapBlocks,
    terminator,
    succs,
    recomputePreds,
    reachable,
    dropUnreachable,
    rpo,
    regName,
    showInstr,
    showPhi,
    showFunc,
    showModule,
    converge,
  )
where

import Data.Int (Int64)
import Data.List (foldl', intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set

type Reg = Int

type Label = String

-- | Run to a fixed point.
--
-- Dominance, liveness and the optimiser are all "do it again until it stops
-- moving", and the other ports say so by threading a @changed@ flag out of every
-- step.  Here the answer is a value, so asking whether it moved is @==@, and the
-- flag disappears from all three.
converge :: (Eq a) => (a -> a) -> a -> a
converge step = go
  where
    go x = let y = step x in if x == y then x else go y

-- -- the frame ---------------------------------------------------------------

word :: Int
word = 8

-- | How many arguments AAPCS64 passes in registers.  The rest go on the stack,
-- and the frame layout below knows where.
argumentRegisters :: Int
argumentRegisters = 8

-- | Where a frame slot sits, relative to the frame pointer.
--
-- Slot 0 of every nested function holds its static link, so a frame chain can be
-- walked without knowing whose frame it is.  Negative slots are the arguments
-- the caller had to pass on the stack: they are already in the frame, above the
-- saved frame record, so nothing has to be copied for them.
slotOffset :: Int -> Int
slotOffset slot
  | slot < 0 = 16 + word * (-slot - 1)
  | otherwise = -word * (slot + 1)

-- -- the instructions ---------------------------------------------------------

data Instr
  = Const Reg Int64
  | StrConst Reg String
  | Move Reg Reg
  | Bin Reg String Reg Reg
  | Cmp Reg String Reg Reg
  | Load Reg Reg Int
  | Store Reg Int Reg
  | -- | Read a frame slot of this function — an escaping variable, or a spill.
    LoadSlot Reg Int
  | StoreSlot Int Reg
  | -- | The frame pointer itself, which is what a static link points at.
    FrameAddr Reg
  | Call (Maybe Reg) String [Reg]
  | Jmp Label
  | -- | An empty code means the branch tests its register.  After selection it
    -- may instead read the flags a comparison just set, and then it reads no
    -- register at all.
    CBr Reg Label Label String
  | Ret (Maybe Reg)
  | -- | The machine instruction: a form, a register it writes and some it reads.
    Machine
      { mForm :: String,
        mDst :: Maybe Reg,
        mSrcs :: [Reg],
        mImm :: Int64,
        mSymbol :: String,
        mEffect :: Bool
      }
  deriving (Eq, Show)

-- | The register it writes, or nothing.
defs :: Instr -> Maybe Reg
defs i = case i of
  Const d _ -> Just d
  StrConst d _ -> Just d
  Move d _ -> Just d
  Bin d _ _ _ -> Just d
  Cmp d _ _ _ -> Just d
  Load d _ _ -> Just d
  LoadSlot d _ -> Just d
  FrameAddr d -> Just d
  Call d _ _ -> d
  Machine {mDst = d} -> d
  _ -> Nothing

-- | The registers it reads.  A phi's arguments are read on the edges, not where
-- the phi stands, so a phi is not an instruction here at all.
uses :: Instr -> [Reg]
uses i = case i of
  Move _ s -> [s]
  Bin _ _ a b -> [a, b]
  Cmp _ _ a b -> [a, b]
  Load _ base _ -> [base]
  Store base _ src -> [base, src]
  StoreSlot _ src -> [src]
  Call _ _ args -> args
  Machine {mSrcs = srcs} -> srcs
  CBr cond _ _ code -> [cond | null code]
  Ret value -> maybe [] (: []) value
  _ -> []

-- | The same instruction with the registers it reads renamed.
mapUses :: (Reg -> Reg) -> Instr -> Instr
mapUses f i = case i of
  Move d s -> Move d (f s)
  Bin d op a b -> Bin d op (f a) (f b)
  Cmp d op a b -> Cmp d op (f a) (f b)
  Load d base off -> Load d (f base) off
  Store base off src -> Store (f base) off (f src)
  StoreSlot slot src -> StoreSlot slot (f src)
  Call d callee args -> Call d callee (map f args)
  m@(Machine {}) -> m {mSrcs = map f (mSrcs m)}
  CBr cond t e code -> if null code then CBr (f cond) t e code else i
  Ret value -> Ret (fmap f value)
  _ -> i

-- | The same instruction, writing @r@ instead.  Only asked of one that writes.
withDef :: Reg -> Instr -> Instr
withDef r i = case i of
  Const _ v -> Const r v
  StrConst _ s -> StrConst r s
  Move _ s -> Move r s
  Bin _ op a b -> Bin r op a b
  Cmp _ op a b -> Cmp r op a b
  Load _ base off -> Load r base off
  LoadSlot _ slot -> LoadSlot r slot
  FrameAddr _ -> FrameAddr r
  Call _ callee args -> Call (Just r) callee args
  m@(Machine {}) -> m {mDst = Just r}
  _ -> error "this instruction defines nothing"

-- | True when it has to be kept even if its result is dead.
hasEffect :: Instr -> Bool
hasEffect i = case i of
  Machine {mEffect = e} -> e
  Store {} -> True
  StoreSlot {} -> True
  Call {} -> True
  Jmp _ -> True
  CBr {} -> True
  Ret _ -> True
  _ -> False

-- | The same terminator, with one of its targets renamed.
renameTarget :: Label -> Label -> Instr -> Instr
renameTarget old fresh i = case i of
  Jmp target | target == old -> Jmp fresh
  CBr cond t e code -> CBr cond (swap t) (swap e) code
  _ -> i
  where
    swap l = if l == old then fresh else l

-- -- phis ---------------------------------------------------------------------

-- | The arguments are a list of @(predecessor, register)@, and a list rather
-- than a map because the order they were placed in is the order a dump has to
-- print them in.
data Phi = Phi {phiDst :: Reg, phiArgs :: [(Label, Reg)]}
  deriving (Eq, Show)

-- -- the graph ----------------------------------------------------------------

data Block = Block
  { blLabel :: Label,
    blPhis :: [Phi],
    blInstrs :: [Instr],
    blPreds :: [Label]
  }
  deriving (Eq, Show)

data Func = Func
  { fnLabel :: String,
    fnName :: String,
    fnParams :: [Reg],
    fnDepth :: !Int,
    fnEntry :: Label,
    fnBlocks :: Map.Map Label Block,
    fnOrder :: [Label],
    fnRegs :: !Int,
    fnSlots :: !Int,
    fnLinkSlot :: !Int
  }
  deriving (Eq, Show)

data Module = Module {modFuncs :: [Func], modStrings :: [(String, String)]}
  deriving (Show)

-- | What the allocator decided.  Not fields of a 'Func', because none of it is
-- part of the program: a colouring is an assignment from the program's registers
-- to the machine's, and the emitter is the only thing that reads one.
data Allocation = Allocation
  { alColours :: Map.Map Reg Int,
    alSaved :: [Int],
    alSpilled :: Map.Map Reg Int
  }
  deriving (Show)

unallocated :: Allocation
unallocated = Allocation Map.empty [] Map.empty

newFunc :: String -> String -> Int -> Func
newFunc label name depth = Func label name [] depth "entry" Map.empty [] 0 0 (-1)

blockOf :: Func -> Label -> Block
blockOf f label =
  fromMaybe (error ("no block " ++ label ++ " in " ++ fnName f)) (Map.lookup label (fnBlocks f))

addBlock :: Label -> Func -> Func
addBlock label f =
  f
    { fnBlocks = Map.insert label (Block label [] [] []) (fnBlocks f),
      fnOrder = fnOrder f ++ [label]
    }

-- | Every block, in the order they were made.
walk :: Func -> [Block]
walk f = map (blockOf f) (fnOrder f)

setBlock :: Block -> Func -> Func
setBlock b f = f {fnBlocks = Map.insert (blLabel b) b (fnBlocks f)}

-- | Put every block through @g@ and keep the answer where it came from, which is
-- what a pass that rewrites instructions does.
mapBlocks :: (Block -> Block) -> Func -> Func
mapBlocks g f = f {fnBlocks = Map.map g (fnBlocks f)}

terminator :: Block -> Instr
terminator b
  | null (blInstrs b) = error ("block " ++ blLabel b ++ " is unterminated")
  | otherwise = case last (blInstrs b) of
      i@(Jmp _) -> i
      i@(CBr {}) -> i
      i@(Ret _) -> i
      _ -> error ("block " ++ blLabel b ++ " falls through")

succs :: Block -> [Label]
succs b = case terminator b of
  Jmp target -> [target]
  CBr _ t e _ -> if t == e then [t] else [t, e]
  _ -> []

-- -- rewiring ------------------------------------------------------------------

recomputePreds :: Func -> Func
recomputePreds f =
  let edges = [(s, blLabel b) | b <- walk f, s <- succs b]
      preds = Map.fromListWith (flip (++)) [(s, [p]) | (s, p) <- edges]
   in mapBlocks (\b -> b {blPreds = fromMaybe [] (Map.lookup (blLabel b) preds)}) f

reachable :: Func -> Set.Set Label
reachable f = go Set.empty [fnEntry f]
  where
    go seen [] = seen
    go seen (label : rest)
      | Set.member label seen = go seen rest
      | otherwise = go (Set.insert label seen) (succs (blockOf f label) ++ rest)

dropUnreachable :: Func -> Func
dropUnreachable f =
  recomputePreds
    f
      { fnOrder = kept,
        fnBlocks = Map.map prune (Map.filterWithKey (\l _ -> Set.member l live) (fnBlocks f))
      }
  where
    live = reachable f
    kept = filter (`Set.member` live) (fnOrder f)
    prune b = b {blPhis = [p {phiArgs = filter ((`Set.member` live) . fst) (phiArgs p)} | p <- blPhis b]}

-- | Reverse post-order, which is the order every dataflow pass walks in.
--
-- A block goes on the front of the list once its successors are all on it, so
-- what comes back is already reversed and nothing has to reverse it.
rpo :: Func -> [Label]
rpo f = snd (go (Set.empty, []) (fnEntry f))
  where
    go (seen, post) label
      | Set.member label seen = (seen, post)
      | otherwise =
          let (seen', post') = foldl' go (Set.insert label seen, post) (succs (blockOf f label))
           in (seen', label : post')

-- -- printing -------------------------------------------------------------------

regName :: Map.Map Reg Int -> Reg -> String
regName colours r = case Map.lookup r colours of
  Nothing -> "%" ++ show r
  Just c -> "%" ++ show r ++ ":" ++ show c

showInstr :: (Reg -> String) -> Instr -> String
showInstr name i = case i of
  Const d v -> name d ++ " = " ++ show v
  StrConst d s -> name d ++ " = &" ++ s
  Move d s -> name d ++ " = " ++ name s
  Bin d op a b -> name d ++ " = " ++ name a ++ " " ++ op ++ " " ++ name b
  Cmp d op a b -> name d ++ " = " ++ name a ++ " " ++ op ++ " " ++ name b
  Load d base off -> name d ++ " = [" ++ name base ++ " + " ++ show off ++ "]"
  Store base off src -> "[" ++ name base ++ " + " ++ show off ++ "] = " ++ name src
  LoadSlot d slot -> name d ++ " = slot" ++ show slot
  StoreSlot slot src -> "slot" ++ show slot ++ " = " ++ name src
  FrameAddr d -> name d ++ " = frame"
  Call d callee args ->
    let call = callee ++ "(" ++ intercalate ", " (map name args) ++ ")"
     in maybe call (\r -> name r ++ " = " ++ call) d
  Jmp target -> "jmp " ++ target
  CBr cond t e code ->
    let test = if null code then name cond ++ " ?" else code ++ "?"
     in "br " ++ test ++ " " ++ t ++ " : " ++ e
  Ret value -> maybe "ret" (\r -> "ret " ++ name r) value
  Machine form d srcs imm symbol _ ->
    let operands =
          map name srcs
            ++ if not (null symbol)
              then [symbol]
              else ["#" ++ show imm | imm /= 0 || form == "const"]
        written = trimEnd (form ++ " " ++ intercalate ", " operands)
     in maybe written (\r -> name r ++ " = " ++ written) d
  where
    trimEnd = reverse . dropWhile (== ' ') . reverse

showPhi :: (Reg -> String) -> Phi -> String
showPhi name (Phi d args) =
  name d ++ " = phi [" ++ intercalate ", " [p ++ ": " ++ name r | (p, r) <- args] ++ "]"

showFunc :: Func -> Allocation -> String
showFunc f alloc = intercalate "\n" (header : concatMap one (walk f))
  where
    name = regName (alColours alloc)
    header =
      "fun " ++ fnLabel f ++ "(" ++ intercalate ", " (map name (fnParams f)) ++ ")"
        ++ "  ; depth " ++ show (fnDepth f) ++ ", " ++ show (fnSlots f) ++ " slots"
    one b =
      (blLabel b ++ ":" ++ (if null (blPreds b) then "" else "  ; preds: " ++ intercalate ", " (blPreds b)))
        : map (("    " ++) . showPhi name) (blPhis b)
        ++ map (("    " ++) . showInstr name) (blInstrs b)

showModule :: Module -> Map.Map String Allocation -> String
showModule m allocs = intercalate "\n\n" (parts ++ strings) ++ "\n"
  where
    parts = [showFunc f (fromMaybe unallocated (Map.lookup (fnLabel f) allocs)) | f <- modFuncs m]
    strings
      | null (modStrings m) = []
      | otherwise = [intercalate "\n" [sym ++ ": \"" ++ text ++ "\"" | (sym, text) <- modStrings m]]
