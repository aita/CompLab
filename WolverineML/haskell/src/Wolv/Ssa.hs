-- | SSA construction, the textbook way.
--
-- Dominators by the iterative algorithm of Cooper, Harvey and Kennedy, dominance
-- frontiers from those, phis at the frontiers of every definition, and then one
-- walk of the dominator tree renaming as it goes.  This is minimal SSA and
-- nothing cleverer: a phi is placed wherever the frontier says, whether or not
-- the variable is live there, and the dead ones leave in "Wolv.Opt".
--
-- Only registers written more than once take part.  Everything lowering produced
-- once — a temporary — is already in SSA and is left with the name it has.
module Wolv.Ssa
  ( Dominance (..),
    dominance,
    dominates,
    construct,
    constructModule,
    splitCriticalEdges,
    verify,
  )
where

import Control.Monad.State
import Data.List (foldl', sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Ir

data Dominance = Dominance
  { domIdom :: Map.Map Label Label,
    domChildren :: Map.Map Label [Label],
    domFrontier :: Map.Map Label (Set.Set Label),
    domOrder :: [Label]
  }

dominates :: Dominance -> Label -> Label -> Bool
dominates dom a = go
  where
    go b
      | a == b = True
      | otherwise = case Map.lookup b (domIdom dom) of
          Just parent | parent /= b -> go parent
          _ -> False

dominance :: Func -> Dominance
dominance f = Dominance idom children frontier order
  where
    order = rpo f
    rank = Map.fromList (zip order [(0 :: Int) ..])
    at m k = fromMaybe (error "no rank") (Map.lookup k m)

    -- The two runners climb until they meet, each time from the deeper one.
    intersect table a b
      | a == b = a
      | otherwise =
          let a' = climb table a b
              b' = climb table b a'
           in intersect table a' b'
    climb table x y
      | at rank x > at rank y = climb table (at table x) y
      | otherwise = x

    idom = converge round' (Map.singleton (fnEntry f) (fnEntry f))
    round' table = foldl' one table (drop 1 order)
    one table label =
      case filter (`Map.member` table) (blPreds (blockOf f label)) of
        [] -> table
        (p : ps) -> Map.insert label (foldl' (\acc q -> intersect table q acc) p ps) table

    children =
      Map.fromListWith
        (flip (++))
        ([(label, []) | label <- order] ++ [(at idom label, [label]) | label <- order, at idom label /= label])

    frontier = foldl' runners (Map.fromList [(label, Set.empty) | label <- order]) order
    runners table label
      | length (blPreds (blockOf f label)) < 2 = table
      | otherwise = foldl' (climbFrom label) table (blPreds (blockOf f label))
    climbFrom label table runner
      | runner /= at idom label && Map.member runner idom =
          climbFrom label (Map.adjust (Set.insert label) runner table) (at idom runner)
      | otherwise = table

-- | Where each register is written, and how often.  A register written twice in
-- one block is as much a variable as one written in two blocks, so the count is
-- what decides, and the blocks are what the frontier walk needs.
data Defs = Defs {defSites :: Map.Map Reg (Set.Set Label), defCount :: Map.Map Reg Int}

variables :: Defs -> [Reg]
variables d = sort [r | (r, n) <- Map.toList (defCount d), n > 1]

definitions :: Func -> Defs
definitions f = foldl' note (Defs Map.empty Map.empty) written
  where
    written =
      [(r, blLabel b) | b <- walk f, i <- blInstrs b, Just r <- [defs i]]
        ++ [(p, fnEntry f) | p <- fnParams f]
    note (Defs sites count) (r, label) =
      Defs
        (Map.insertWith Set.union r (Set.singleton label) sites)
        (Map.insertWith (+) r 1 count)

-- | A phi for @v@ at every dominance frontier of a block defining @v@.  What
-- each block's phis are for is kept beside them: the renamer needs the variable,
-- and the phi itself only remembers what it was renamed to.
placePhis :: Func -> Dominance -> Defs -> (Func, Map.Map Label [Reg])
placePhis f dom d = foldl' one (f, Map.fromList [(label, []) | label <- fnOrder f]) (variables d)
  where
    one state v = go state Set.empty (sort (Set.toList (sites v)))
      where
        sites r = fromMaybe Set.empty (Map.lookup r (defSites d))
        go st _ [] = st
        go st placed work =
          let block = last work
              rest = init work
              targets =
                [ t
                  | t <- sort (Set.toList (fromMaybe Set.empty (Map.lookup block (domFrontier dom)))),
                    not (Set.member t placed)
                ]
              placed' = foldr Set.insert placed targets
              st' = foldl' (add v) st targets
              added = [t | t <- targets, not (Set.member t (sites v))]
           in go st' placed' (rest ++ added)
    add v (g, vars) target =
      let b = blockOf g target
          phi = Phi v [(p, v) | p <- blPreds b]
       in ( setBlock b {blPhis = blPhis b ++ [phi]} g,
            Map.adjust (++ [v]) target vars
          )

-- -- renaming -----------------------------------------------------------------

-- | @rStacks@ is the reaching definition of each variable, @rUndef@ the register
-- a variable read on a path that never wrote it reads from.
data R = R
  { rFunc :: Func,
    rStacks :: Map.Map Reg [Reg],
    rUndef :: Map.Map Reg Reg,
    rUndefOrder :: [Reg]
  }

type Rn a = State R a

freshReg :: Rn Reg
freshReg = do
  s <- get
  put s {rFunc = (rFunc s) {fnRegs = fnRegs (rFunc s) + 1}}
  pure (Reg (fnRegs (rFunc s)))

-- | A variable read on a path that never wrote it reads zero.
undefined' :: Reg -> Rn Reg
undefined' v = do
  s <- get
  case Map.lookup v (rUndef s) of
    Just r -> pure r
    Nothing -> do
      r <- freshReg
      modify (\t -> t {rUndef = Map.insert v r (rUndef t), rUndefOrder = rUndefOrder t ++ [v]})
      pure r

top :: Reg -> Rn Reg
top v = do
  stacks <- gets rStacks
  case Map.lookup v stacks of
    Just (r : _) -> pure r
    _ -> undefined' v

rename :: Reg -> Rn Reg
rename v = do
  r <- freshReg
  modify (\s -> s {rStacks = Map.insertWith (++) v [r] (rStacks s)})
  pure r

popDef :: Reg -> Rn ()
popDef v = modify (\s -> s {rStacks = Map.adjust (drop 1) v (rStacks s)})

plantUndefined :: Rn ()
plantUndefined = do
  s <- get
  let entry = blockOf (rFunc s) (fnEntry (rFunc s))
      zeros = [Const (fromMaybe (Reg 0) (Map.lookup v (rUndef s))) 0 | v <- rUndefOrder s]
  put s {rFunc = setBlock entry {blInstrs = reverse zeros ++ blInstrs entry} (rFunc s)}

-- | The dominator tree, walked with an explicit stack so that what a block
-- pushed comes off again when its subtree is done.
runRenamer :: Label -> Dominance -> Map.Map Label [Reg] -> Set.Set Reg -> Rn ()
runRenamer entry dom phiVars vars = loop [(entry, False)] Map.empty
  where
    loop [] _ = pure ()
    loop ((label, done) : rest) pushed
      | done = do
          mapM_ popDef (fromMaybe [] (Map.lookup label pushed))
          loop rest pushed
      | otherwise = do
          mine <- renameBlock phiVars vars label
          let kids = fromMaybe [] (Map.lookup label (domChildren dom))
          loop ([(k, False) | k <- kids] ++ [(label, True)] ++ rest) (Map.insert label mine pushed)

renameBlock :: Map.Map Label [Reg] -> Set.Set Reg -> Label -> Rn [Reg]
renameBlock phiVars vars label = do
  f0 <- gets rFunc
  let b = blockOf f0 label
      theirs = fromMaybe [] (Map.lookup label phiVars)
  phis <- mapM (\(p, v) -> do d <- rename v; pure (p {phiDst = d}, v)) (zip (blPhis b) theirs)
  let mine0 = map snd phis
  modify (\s -> s {rFunc = setBlock (blockOf (rFunc s) label) {blPhis = map fst phis} (rFunc s)})

  f1 <- gets rFunc
  (instrs, mine1) <- foldM oneInstr ([], mine0) (blInstrs (blockOf f1 label))
  modify (\s -> s {rFunc = setBlock (blockOf (rFunc s) label) {blInstrs = reverse instrs} (rFunc s)})

  f2 <- gets rFunc
  mapM_ (fill label) (succs (blockOf f2 label))
  pure mine1
  where
    oneInstr (out, mine) instr = do
      renamed <- mapUsesM (\r -> if Set.member r vars then top r else pure r) instr
      case definition renamed of
        Just (d, writing) | Set.member d vars -> do
          d' <- rename d
          pure (writing d' : out, mine ++ [d])
        _ -> pure (renamed : out, mine)
    fill from succ' = do
      f <- gets rFunc
      let target = blockOf f succ'
          theirs = fromMaybe [] (Map.lookup succ' phiVars)
      phis <- mapM (\(p, v) -> do r <- top v; pure p {phiArgs = setArg from r (phiArgs p)}) (zip (blPhis target) theirs)
      modify (\s -> s {rFunc = setBlock (blockOf (rFunc s) succ') {blPhis = phis} (rFunc s)})

-- | Keeps an argument where it was, and appends a new one at the end.
setArg :: Label -> Reg -> [(Label, Reg)] -> [(Label, Reg)]
setArg pred' r args
  | any ((== pred') . fst) args = [if p == pred' then (p, r) else (p, q) | (p, q) <- args]
  | otherwise = args ++ [(pred', r)]

-- | 'mapUses' with an effect, which renaming needs because a fresh name for an
-- undefined variable is a register the function did not have before.
mapUsesM :: (Monad m) => (Reg -> m Reg) -> Instr -> m Instr
mapUsesM f i = case i of
  Move d s -> Move d <$> f s
  Bin d op a b -> Bin d op <$> f a <*> f b
  Cmp d op a b -> Cmp d op <$> f a <*> f b
  Load d base off -> (\b -> Load d b off) <$> f base
  Store base off src -> (\b s -> Store b off s) <$> f base <*> f src
  StoreSlot slot src -> StoreSlot slot <$> f src
  Call d callee args -> Call d callee <$> mapM f args
  m@(Machine {}) -> (\srcs -> m {mSrcs = srcs}) <$> mapM f (mSrcs m)
  CBr cond t e code -> if null code then (\c -> CBr c t e code) <$> f cond else pure i
  Ret value -> Ret <$> traverse f value
  _ -> pure i

-- -- the passes ---------------------------------------------------------------

-- | Rewrite one function into SSA.
construct :: Func -> Func
construct f0 =
  let f = recomputePreds f0
      dom = dominance f
      d = definitions f
      (withPhis, phiVars) = placePhis f dom d
      vars = Set.fromList (variables d)
      start = R withPhis Map.empty Map.empty []
      renameParams = do
        f' <- gets rFunc
        params <- mapM (\p -> if Set.member p vars then rename p else pure p) (fnParams f')
        modify (\s -> s {rFunc = (rFunc s) {fnParams = params}})
   in rFunc (execState (renameParams >> runRenamer (fnEntry f) dom phiVars vars >> plantUndefined) start)

constructModule :: Module -> Module
constructModule m = m {modFuncs = map construct (modFuncs m)}

-- | Give every phi a place to put its copy in.
--
-- An edge from a block with several successors into a block with several
-- predecessors has nowhere to hold the copies a phi turns into, so it gets a
-- block of its own.  The same goes for any edge into a block that still has a
-- phi, so that the emitter only ever has to put copies before a @jmp@.
splitCriticalEdges :: Func -> Func
splitCriticalEdges f0 = recomputePreds (foldl' atBlock f0 (fnOrder f0))
  where
    atBlock f label
      | length (succs (blockOf f label)) < 2 = f
      | otherwise = foldl' (atEdge label) f (succs (blockOf f label))
    atEdge label f succ' =
      let target = blockOf f succ'
       in if length (blPreds target) < 2 && null (blPhis target)
            then f
            else
              let split = label ++ "." ++ succ'
                  withSplit = addBlock split f
                  f1 = setBlock (blockOf withSplit split) {blInstrs = [Jmp succ']} withSplit
                  b' = blockOf f1 label
                  f2 = setBlock (withTerminator (renameTarget succ' split (terminator b')) b') f1
                  t = blockOf f2 succ'
                  f3 = setBlock t {blPhis = map (move label split) (blPhis t)} f2
               in f3
    move from to p = case lookup from (phiArgs p) of
      Nothing -> p
      Just r -> p {phiArgs = filter ((/= from) . fst) (phiArgs p) ++ [(to, r)]}

-- -- what SSA promises ---------------------------------------------------------

verify :: Func -> Either String ()
verify f = do
  definition <- foldM claim Map.empty written
  let full = foldl' (\m p -> Map.insertWith (\_ old -> old) p (fnEntry f) m) definition (fnParams f)
      reaches r where' what = case Map.lookup r full of
        Nothing -> Left ("%" ++ show (unReg r) ++ " is never defined")
        Just at
          | dominates dom at where' -> Right ()
          | otherwise -> Left ("%" ++ show (unReg r) ++ " does not reach " ++ what)
  mapM_
    ( \b -> do
        mapM_
          ( \p -> do
              if sort (map fst (phiArgs p)) /= sort (blPreds b)
                then Left ("the phi in " ++ blLabel b ++ " does not name its predecessors")
                else Right ()
              mapM_ (\(pred', r) -> reaches r pred' (blLabel b ++ " through " ++ pred')) (phiArgs p)
          )
          (blPhis b)
        mapM_ (\i -> mapM_ (\r -> reaches r (blLabel b) ("its use in " ++ blLabel b)) (uses i)) (blInstrs b)
    )
    (walk f)
  where
    dom = dominance f
    written =
      [(phiDst p, blLabel b) | b <- walk f, p <- blPhis b]
        ++ [(r, blLabel b) | b <- walk f, i <- blInstrs b, Just r <- [defs i]]
    claim m (r, where')
      | Map.member r m = Left ("%" ++ show (unReg r) ++ " is defined twice")
      | otherwise = Right (Map.insert r where' m)
