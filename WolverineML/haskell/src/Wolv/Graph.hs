{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Register allocation by graph colouring, with iterated coalescing.
--
-- The idea is Chaitin's: build a graph whose nodes are values and whose edges
-- join values that are live at the same time, then colour it with as many
-- colours as the machine has registers.  Colouring a graph is hard in general,
-- but Kempe's observation makes it practical: a node with fewer than K
-- neighbours can always be coloured whatever happens to the rest of the graph.
-- So remove such nodes one at a time and push them on a stack; when the graph is
-- empty, pop the stack and give each node a colour its neighbours have not
-- taken.  If every remaining node has K or more neighbours, guess that one of
-- them will not get a colour and carry on — if the guess was wrong the value is
-- rewritten to live in memory and the whole thing runs again (Briggs' optimistic
-- colouring).
--
-- On top of that sits coalescing, which is why leaving SSA first costs nothing.
-- Leaving SSA fills the predecessors of every join with copies; coalescing
-- merges the two ends of a copy so that it disappears.  Merging aggressively can
-- make a graph uncolourable, so a merge only happens when Briggs' test proves it
-- cannot: the merged node must have fewer than K neighbours of significant
-- degree.  That test is only exact enough to be useful if degrees are up to
-- date, and simplifying lowers degrees while merging raises them — so the two
-- run interleaved, with freezing (giving up on a copy so its nodes can be
-- simplified) as the way out when neither applies.  Hence "iterated" (George and
-- Appel, 1996).
--
-- This machine has no fixed registers to colour against, so the calling
-- convention is carried as a set of colours each node may not take: a value live
-- across a call may not take a caller-saved one.  A node with @f@ forbidden
-- colours and @d@ neighbours needs @d + f < K@ to be trivially colourable, so
-- that sum is what stands in for the degree everywhere below.
--
-- Every set here is a 'Data.Set', which is ordered, so "the least node in the
-- worklist" is 'Set.findMin' and "walk the neighbours in order" is
-- 'Set.toAscList'.  The ports whose sets are hash tables have to sort at each of
-- those places; here the order is the container's.
module Wolv.Graph (allocate) where

import Control.Monad.State
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Hints (preferences)
import Wolv.Ir
import Wolv.Liveness (analyse, liveOut)
import Wolv.Registers
import Wolv.Spill (costs, spill)

-- | Colour @f@, rewriting and starting again for as long as it spills.
allocate :: Machine -> Func -> Either String (Func, Allocation)
allocate machine = go Set.empty Map.empty
  where
    go protected slots f0 =
      let f = recomputePreds f0
          c = execState run (start f machine protected)
          spilled = cSpilled c
       in if Set.null spilled
            then
              Right
                ( f,
                  Allocation
                    (cColour c)
                    (Set.toAscList (Set.intersection (Set.fromList (Map.elems (cColour c))) (Set.fromList calleeSaved)))
                    slots
                )
            else foldM (rewrite f) (protected, slots, f) (Set.toAscList spilled) >>= again
      where
        again (protected', slots', f') = go protected' slots' f'
    rewrite _ (protected, slots, f) victim
      | Set.member victim protected =
          Left ("`" ++ fnName f ++ "` needs more registers at once than the machine has")
      | otherwise =
          let (f', slot, reloads) = spill victim f
           in Right (Set.union protected reloads, Map.insert victim slot slots, f')

-- | @cProtected@ holds values a previous round produced by reloading something.
-- Their live ranges are a load and its one use, so spilling one again would only
-- make another of the same, and the rewriting would never end.
data C = C
  { cFunc :: Func,
    cMachine :: Machine,
    cProtected :: Set.Set Reg,
    cAdjacent :: Map.Map Reg (Set.Set Reg),
    cDegree :: Map.Map Reg Int,
    cForbidden :: Map.Map Reg (Set.Set Int),
    cPreferred :: Map.Map Reg Int,
    cMoves :: Map.Map Int (Reg, Reg),
    cMovesOf :: Map.Map Reg (Set.Set Int),
    cWorklistMoves :: Set.Set Int,
    cActiveMoves :: Set.Set Int,
    cSimplifyWL :: Set.Set Reg,
    cFreezeWL :: Set.Set Reg,
    cSpillWL :: Set.Set Reg,
    cSelectStack :: [Reg],
    cOnStack :: Set.Set Reg,
    cCoalesced :: Set.Set Reg,
    cAlias :: Map.Map Reg Reg,
    cColour :: Map.Map Reg Int,
    cSpilled :: Set.Set Reg
  }

start :: Func -> Machine -> Set.Set Reg -> C
start f machine protected =
  C f machine protected Map.empty Map.empty Map.empty Map.empty Map.empty Map.empty
    Set.empty Set.empty Set.empty Set.empty Set.empty [] Set.empty Set.empty Map.empty
    Map.empty Set.empty

type A a = State C a

k :: A Int
k = gets (count . cMachine)

run :: A ()
run = do
  build
  makeWorklists
  loop
  assignColours
  where
    loop = do
      c <- get
      unless
        ( Set.null (cSimplifyWL c) && Set.null (cWorklistMoves c)
            && Set.null (cFreezeWL c)
            && Set.null (cSpillWL c)
        )
        $ do
          if
              | not (Set.null (cSimplifyWL c)) -> simplify
              | not (Set.null (cWorklistMoves c)) -> coalesce
              | not (Set.null (cFreezeWL c)) -> freeze
              | otherwise -> selectSpill
          loop

-- -- the graph -------------------------------------------------------------

node :: Reg -> A ()
node r = modify $ \c ->
  if Map.member r (cAdjacent c)
    then c
    else
      c
        { cAdjacent = Map.insert r Set.empty (cAdjacent c),
          cDegree = Map.insert r 0 (cDegree c),
          cForbidden = Map.insert r Set.empty (cForbidden c)
        }

adjacent :: Reg -> A (Set.Set Reg)
adjacent r = gets (fromMaybe Set.empty . Map.lookup r . cAdjacent)

forbidden :: Reg -> A (Set.Set Int)
forbidden r = gets (fromMaybe Set.empty . Map.lookup r . cForbidden)

addEdge :: Reg -> Reg -> A ()
addEdge a b = do
  neighbours <- adjacent a
  unless (a == b || Set.member b neighbours) $
    modify $ \c ->
      c
        { cAdjacent = Map.adjust (Set.insert b) a (Map.adjust (Set.insert a) b (cAdjacent c)),
          cDegree = Map.adjust (+ 1) a (Map.adjust (+ 1) b (cDegree c))
        }

-- | The degree, counting a forbidden colour as a neighbour holding it.
weight :: Reg -> A Int
weight r = do
  c <- get
  pure (fromMaybe 0 (Map.lookup r (cDegree c)) + Set.size (fromMaybe Set.empty (Map.lookup r (cForbidden c))))

build :: A ()
build = do
  f <- gets cFunc
  modify (\c -> c {cPreferred = preferences f})
  let live = analyse f
  callerSet <- gets (Set.fromList . mCaller . cMachine)
  mapM_ node [r | b <- walk f, i <- blInstrs b, r <- uses i ++ maybe [] (: []) (defs i)]
  mapM_ node (fnParams f)
  mapM_ (inBlock live callerSet) (walk f)
  where
    inBlock live callerSet b = do
      alive <- foldM (one callerSet) (liveOut live (blLabel b)) (reverse (blInstrs b))
      f <- gets cFunc
      when (blLabel b == fnEntry f) (entryEdges alive)
    one callerSet alive i = do
      alive1 <- case i of
        Move d s -> do
          index <- gets (Map.size . cMoves)
          modify $ \c ->
            c
              { cMoves = Map.insert index (d, s) (cMoves c),
                cMovesOf = foldr (Map.alter (Just . Set.insert index . fromMaybe Set.empty)) (cMovesOf c) [d, s],
                cWorklistMoves = Set.insert index (cWorklistMoves c)
              }
          pure (Set.delete s alive)
        _ -> pure alive
      let defined = defs i
          alive2 = maybe alive1 (`Set.insert` alive1) defined
      case defined of
        Just d -> mapM_ (addEdge d) (Set.toAscList alive2)
        Nothing -> pure ()
      -- A value live across a call cannot sit in a caller-saved register.
      case i of
        Call {} ->
          modify $ \c ->
            c
              { cForbidden =
                  foldr
                    (Map.alter (Just . Set.union callerSet . fromMaybe Set.empty))
                    (cForbidden c)
                    [r | r <- Set.toAscList alive2, Just r /= defined]
              }
        _ -> pure ()
      let alive3 = maybe alive2 (`Set.delete` alive2) defined
      pure (Set.union alive3 (Set.fromList (uses i)))

-- | Parameters arrive together, so they interfere with each other.
entryEdges :: Set.Set Reg -> A ()
entryEdges alive = do
  params <- gets (fnParams . cFunc)
  mapM_ (one params) (zip [0 ..] params)
  where
    one params (i, param) = do
      mapM_ (addEdge param) (Set.toAscList alive)
      mapM_ (addEdge param) (drop (i + 1) params)

-- -- the worklists ----------------------------------------------------------

makeWorklists :: A ()
makeWorklists = do
  regs <- gets (Map.keys . cAdjacent)
  mapM_ one regs
  where
    one r = do
      w <- weight r
      limit <- k
      related <- moveRelated r
      modify $ \c ->
        if w >= limit
          then c {cSpillWL = Set.insert r (cSpillWL c)}
          else
            if related
              then c {cFreezeWL = Set.insert r (cFreezeWL c)}
              else c {cSimplifyWL = Set.insert r (cSimplifyWL c)}

nodeMoves :: Reg -> A [Int]
nodeMoves r = do
  c <- get
  let mine = fromMaybe Set.empty (Map.lookup r (cMovesOf c))
  pure [i | i <- Set.toAscList mine, Set.member i (cActiveMoves c) || Set.member i (cWorklistMoves c)]

moveRelated :: Reg -> A Bool
moveRelated r = not . null <$> nodeMoves r

neighbours :: Reg -> A [Reg]
neighbours r = do
  c <- get
  ns <- adjacent r
  pure (Set.toAscList (Set.difference (Set.difference ns (cOnStack c)) (cCoalesced c)))

simplify :: A ()
simplify = do
  r <- gets (Set.findMin . cSimplifyWL)
  modify $ \c ->
    c
      { cSimplifyWL = Set.delete r (cSimplifyWL c),
        cSelectStack = r : cSelectStack c,
        cOnStack = Set.insert r (cOnStack c)
      }
  ns <- neighbours r
  mapM_ decrementDegree ns

decrementDegree :: Reg -> A ()
decrementDegree r = do
  was <- weight r
  limit <- k
  modify (\c -> c {cDegree = Map.adjust (subtract 1) r (cDegree c)})
  when (was == limit) $ do
    -- It has just become trivially colourable, so the copies around it may have
    -- become safe to merge as well.
    ns <- neighbours r
    enableMoves (ns ++ [r])
    modify (\c -> c {cSpillWL = Set.delete r (cSpillWL c)})
    related <- moveRelated r
    modify $ \c ->
      if related
        then c {cFreezeWL = Set.insert r (cFreezeWL c)}
        else c {cSimplifyWL = Set.insert r (cSimplifyWL c)}

enableMoves :: [Reg] -> A ()
enableMoves = mapM_ one
  where
    one :: Reg -> A ()
    one r = nodeMoves r >>= mapM_ activate
    activate :: Int -> A ()
    activate index =
      modify $ \c ->
        if Set.member index (cActiveMoves c)
          then
            c
              { cActiveMoves = Set.delete index (cActiveMoves c),
                cWorklistMoves = Set.insert index (cWorklistMoves c)
              }
          else c

-- -- coalescing --------------------------------------------------------------

aliasOf :: Reg -> A Reg
aliasOf r = do
  c <- get
  pure (follow c r)
  where
    follow c x
      | Set.member x (cCoalesced c) = follow c (fromMaybe x (Map.lookup x (cAlias c)))
      | otherwise = x

coalesce :: A ()
coalesce = do
  c0 <- get
  let index = Set.findMin (cWorklistMoves c0)
      (dst, src) = fromMaybe (error "no such move") (Map.lookup index (cMoves c0))
  modify (\c -> c {cWorklistMoves = Set.delete index (cWorklistMoves c)})
  u <- aliasOf dst
  v <- aliasOf src
  joined <- adjacent u
  ok <- conservative u v
  if
      | u == v -> addToWorklist u
      | Set.member v joined -> addToWorklist u >> addToWorklist v
      | ok -> combine u v >> addToWorklist u
      | otherwise -> modify (\c -> c {cActiveMoves = Set.insert index (cActiveMoves c)})

addToWorklist :: Reg -> A ()
addToWorklist r = do
  w <- weight r
  limit <- k
  related <- moveRelated r
  when (w < limit && not related) $
    modify $ \c ->
      c {cFreezeWL = Set.delete r (cFreezeWL c), cSimplifyWL = Set.insert r (cSimplifyWL c)}

-- | Briggs: the merged node must have fewer than K significant neighbours.  The
-- colours the two ends may not take add up as well, and a colour the merged node
-- is barred from is one more thing standing in its way.
conservative :: Reg -> Reg -> A Bool
conservative u v = do
  together <- Set.union <$> (Set.fromList <$> neighbours u) <*> (Set.fromList <$> neighbours v)
  barred <- Set.union <$> forbidden u <*> forbidden v
  limit <- k
  weights <- mapM weight (Set.toAscList together)
  pure (length (filter (>= limit) weights) + Set.size barred < limit)

combine :: Reg -> Reg -> A ()
combine u v = do
  movesV <- gets (fromMaybe Set.empty . Map.lookup v . cMovesOf)
  forbiddenV <- forbidden v
  preferredV <- gets (Map.lookup v . cPreferred)
  preferredU <- gets (Map.lookup u . cPreferred)
  modify $ \c ->
    c
      { cFreezeWL = Set.delete v (cFreezeWL c),
        cSpillWL = Set.delete v (cSpillWL c),
        cCoalesced = Set.insert v (cCoalesced c),
        cAlias = Map.insert v u (cAlias c),
        cMovesOf = Map.alter (Just . Set.union movesV . fromMaybe Set.empty) u (cMovesOf c),
        cForbidden = Map.alter (Just . Set.union forbiddenV . fromMaybe Set.empty) u (cForbidden c),
        cPreferred = case (preferredV, preferredU) of
          (Just colour, Nothing) -> Map.insert u colour (cPreferred c)
          _ -> cPreferred c
      }
  enableMoves [v]
  ns <- neighbours v
  mapM_ (\other -> addEdge other u >> decrementDegree other) ns
  w <- weight u
  limit <- k
  frozen <- gets (Set.member u . cFreezeWL)
  when (w >= limit && frozen) $
    modify (\c -> c {cFreezeWL = Set.delete u (cFreezeWL c), cSpillWL = Set.insert u (cSpillWL c)})

-- -- freezing and spilling ----------------------------------------------------

freeze :: A ()
freeze = do
  r <- gets (Set.findMin . cFreezeWL)
  modify $ \c ->
    c {cFreezeWL = Set.delete r (cFreezeWL c), cSimplifyWL = Set.insert r (cSimplifyWL c)}
  freezeMoves r

freezeMoves :: Reg -> A ()
freezeMoves r = do
  indices <- nodeMoves r
  mapM_ one indices
  where
    one index = do
      c0 <- get
      let (dst, src) = fromMaybe (error "no such move") (Map.lookup index (cMoves c0))
      modify $ \c ->
        c
          { cActiveMoves = Set.delete index (cActiveMoves c),
            cWorklistMoves = Set.delete index (cWorklistMoves c)
          }
      aliasDst <- aliasOf dst
      aliasR <- aliasOf r
      other <- aliasOf (if aliasDst == aliasR then src else dst)
      related <- moveRelated other
      w <- weight other
      limit <- k
      when (not related && w < limit) $
        modify $ \c ->
          c {cFreezeWL = Set.delete other (cFreezeWL c), cSimplifyWL = Set.insert other (cSimplifyWL c)}

-- | Guess that the value with the most neighbours per use will not fit.
--
-- Never a reload, though: those are cheap by that measure precisely because they
-- were made cheap, and choosing one would undo the last round's work instead of
-- the pressure.
selectSpill :: A ()
selectSpill = do
  c <- get
  let weights = costs (cFunc c)
      unprotected = [r | r <- Set.toAscList (cSpillWL c), not (Set.member r (cProtected c))]
      among = if null unprotected then Set.toAscList (cSpillWL c) else unprotected
  scored <- mapM (\r -> do w <- weight r; pure (r, fromIntegral w / (fromMaybe 0 (Map.lookup r weights) + 1.0))) among
  let chosen = fst (foldl1 (\best@(_, b) here@(_, s) -> if s > b then here else best) scored)
  modify $ \c' ->
    c' {cSpillWL = Set.delete chosen (cSpillWL c'), cSimplifyWL = Set.insert chosen (cSimplifyWL c')}
  freezeMoves chosen

-- -- handing out the colours ---------------------------------------------------

assignColours :: A ()
assignColours = do
  pop
  coalesced <- gets (Set.toAscList . cCoalesced)
  mapM_ inherit coalesced
  where
    pop = do
      c <- get
      case cSelectStack c of
        [] -> pure ()
        (r : rest) -> do
          put c {cSelectStack = rest, cOnStack = Set.delete r (cOnStack c)}
          ns <- Set.toAscList <$> adjacent r
          aliases <- mapM aliasOf ns
          colours <- gets cColour
          barred <- forbidden r
          machine <- gets cMachine
          let taken = Set.fromList [colour | a <- aliases, Just colour <- [Map.lookup a colours]]
              free = [colour | colour <- anywhere machine, not (Set.member colour taken), not (Set.member colour barred)]
          want <- gets (Map.lookup r . cPreferred)
          case free of
            [] -> modify (\c' -> c' {cSpilled = Set.insert r (cSpilled c')})
            (first : _) ->
              modify
                ( \c' ->
                    c'
                      { cColour =
                          Map.insert r (case want of Just colour | colour `elem` free -> colour; _ -> first) (cColour c')
                      }
                )
          pop
    inherit r = do
      a <- aliasOf r
      machine <- gets cMachine
      modify $ \c ->
        c {cColour = Map.insert r (fromMaybe (head (anywhere machine)) (Map.lookup a (cColour c))) (cColour c)}
