-- | The data-flow DAG of one basic block.
--
-- Instruction selection wants to see a block as expressions, not as a list:
-- @a + (i << 3)@ is one ARM instruction and @a + b*c@ is another, and neither is
-- visible while the operands are separate lines with names in between.  So each
-- block is read into a graph — a node per instruction, an edge per operand — and
-- the selector covers that graph with instructions.
--
-- It is a graph and not a tree because a value can be read twice.  That is what
-- 'ndUsers' counts, and it is what decides whether a node may be folded into the
-- instruction that reads it or has to become an instruction of its own: a node
-- read twice would otherwise be computed twice.  A value that leaves the block
-- counts as read as well, and so does one a phi in a successor names.
--
-- Only pure nodes are ever folded, and only into a reader whose instruction
-- really absorbs them.  Both halves matter.  Folding moves a computation to
-- where it is read, which is fine for arithmetic and not fine for a load,
-- because a store in between would change what it reads; and folding a chain of
-- nodes that nothing absorbs would move a whole expression to its last line,
-- leaving every value it read alive until then.  So the selector plans first —
-- it asks, of each node with one reader, whether that reader has a tile that
-- takes it — and everything else is computed where it was written.
module Wolv.Dag (Node (..), Dag (..), nodes, build, nodeAt, rematerialisable, constant, alone, showDag) where

import Data.Int (Int64)
import Data.List (foldl', intercalate)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Text.Printf (printf)
import Wolv.Ir

-- | 'ndOperands' holds a node index for a value this block computed, and
-- 'Nothing' for one that came from outside it.  'ndReader' is the only node that
-- reads it, when there is one.
data Node = Node
  { ndIndex :: !Int,
    ndInstr :: Instr,
    ndOperands :: [Maybe Int],
    ndUsers :: !Int,
    ndReader :: Maybe Int,
    ndEscapes :: !Bool
  }

data Dag = Dag {dgNodes :: Map.Map Int Node, dgByValue :: Map.Map Reg Int}

nodes :: Dag -> [Node]
nodes = Map.elems . dgNodes

nodeValue :: Node -> Maybe Reg
nodeValue = defs . ndInstr

-- | Read exactly once, inside the block, and computable where read.
alone :: Node -> Bool
alone n = ndUsers n == 1 && not (ndEscapes n) && isBin (ndInstr n)
  where
    isBin (Bin {}) = True
    isBin _ = False

-- | Read a block into a graph.  @liveOut@ includes what the phis will read.
build :: Block -> Set.Set Reg -> Dag
build block liveOut = Dag (Map.map escaping counted) byValue
  where
    (placed, byValue) = foldl' one (Map.empty, Map.empty) (zip [0 ..] (blInstrs block))
    one (ns, seen) (i, instr) =
      let operands = [Map.lookup r seen | r <- uses instr]
          seen' = maybe seen (\d -> Map.insert d i seen) (defs instr)
       in (Map.insert i (Node i instr operands 0 Nothing False) ns, seen')

    -- Every edge, in the order the instructions make them, so that the first
    -- reader of a node is the one it remembers.
    edges = [(operand, i) | (i, n) <- Map.toAscList placed, Just operand <- ndOperands n]
    counted = foldl' count placed edges
    count ns (operand, reader) = Map.adjust bump operand ns
      where
        bump n =
          let users = ndUsers n + 1
           in n {ndUsers = users, ndReader = if users == 1 then Just reader else Nothing}

    escaping n = case nodeValue n of
      Just v | Set.member v liveOut -> n {ndEscapes = True}
      _ -> n

nodeAt :: Dag -> Maybe Int -> Maybe Node
nodeAt g index = index >>= (`Map.lookup` dgNodes g)

-- | A constant, which costs nothing to repeat and is often not an instruction at
-- all once it has become an immediate operand.
rematerialisable :: Dag -> Maybe Int -> Maybe Node
rematerialisable g index = case nodeAt g index of
  Just n | not (ndEscapes n), Const _ _ <- ndInstr n -> Just n
  _ -> Nothing

-- | The value at @index@, if it is a constant — however many read it.  Even one
-- that has to exist in a register for somebody else can be an immediate here, so
-- this asks less than 'rematerialisable' does.
constant :: Dag -> Maybe Int -> Maybe Int64
constant g index = case nodeAt g index of
  Just (Node {ndInstr = Const _ v}) -> Just v
  _ -> Nothing

showDag :: Dag -> String
showDag g = intercalate "\n" (map one (nodes g))
  where
    plain r = "%" ++ show r
    one n =
      printf
        "  %3d%-2s %-38s reads [%s]  users %d"
        (ndIndex n)
        (marks n)
        (showInstr plain (ndInstr n))
        (intercalate ", " [maybe "-" show o | o <- ndOperands n])
        (ndUsers n)
    marks n = (if ndEscapes n then "*" else "") ++ (if hasEffect (ndInstr n) then "!" else "")
