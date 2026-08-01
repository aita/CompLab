-- | Lowering: the typed syntax tree becomes a control flow graph.
--
-- Two things are worth knowing about this pass.
--
-- It never builds a phi.  A variable written in two branches is written to the
-- same register twice, and "Wolv.Ssa" is what turns those two writes into one
-- phi.  Lowering only has to make sure a definition reaches every use, which
-- structured control flow does for free.
--
-- It decides where a variable lives.  A variable the checker did not mark as
-- escaping becomes a register; one that escaped becomes a frame slot, reached
-- through 'LoadSlot'/'StoreSlot' in its own function and through a chain of
-- static links from a nested one.  Where each one ended up is a map from the
-- symbol's number, because a symbol is a value and cannot be told.
module Wolv.Lower (Options (..), defaultOptions, lower) where

import Control.Monad.State
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Ast
import Wolv.Ir
import Wolv.Typecheck (Checked (..))
import Wolv.Types

newtype Options = Options {optChecks :: Bool}

defaultOptions :: Options
defaultOptions = Options True

-- | Everything the pass carries: the function being built, where in it, and the
-- three things the whole module shares.
data L = L
  { lFunc :: Func,
    lCur :: Label,
    lBreaks :: [Label],
    lCounter :: !Int,
    lChildren :: !Bool,
    lHomes :: Map.Map Int Home,
    lEscapes :: Set.Set Int,
    lChecks :: !Bool,
    lSymbols :: Map.Map String String,
    lStrings :: [(String, String)],
    lFuncs :: [Func]
  }

type M a = State L a

lower :: Checked -> Options -> Module
lower (Checked prog escapes) opts =
  let start =
        L
          (newFunc "wol_main" "main" 0)
          "entry"
          []
          0
          False
          Map.empty
          escapes
          (optChecks opts)
          Map.empty
          []
          []
      final = execState (openFunction (newFunc "wol_main" "main" 0) (topLevel prog)) start
   in Module (lFuncs final) (lStrings final)

-- -- what the whole module shares ---------------------------------------------

intern :: String -> M String
intern text = do
  s <- get
  case Map.lookup text (lSymbols s) of
    Just symbol -> pure symbol
    Nothing -> do
      let symbol = ".Lstr" ++ show (Map.size (lSymbols s))
      put s {lSymbols = Map.insert text symbol (lSymbols s), lStrings = lStrings s ++ [(symbol, text)]}
      pure symbol

-- | Give the new function its place in the module before its body is lowered,
-- so that a function nested inside it comes after it, and put it back there when
-- the body is done.
openFunction :: Func -> M () -> M ()
openFunction f body = do
  outer <- get
  let at = length (lFuncs outer)
  put
    outer
      { lFunc = f,
        lCur = "entry",
        lBreaks = [],
        lCounter = 0,
        lChildren = False,
        lFuncs = lFuncs outer ++ [f]
      }
  modifyFunc (addBlock "entry")
  when (fnDepth f > 0) $ do
    slot <- newSlot
    modifyFunc (\g -> g {fnLinkSlot = slot})
  body
  inner <- get
  let done = lFunc inner
  put
    inner
      { lFunc = lFunc outer,
        lCur = lCur outer,
        lBreaks = lBreaks outer,
        lCounter = lCounter outer,
        lChildren = lChildren outer,
        lFuncs = take at (lFuncs inner) ++ [done] ++ drop (at + 1) (lFuncs inner)
      }

modifyFunc :: (Func -> Func) -> M ()
modifyFunc g = modify (\s -> s {lFunc = g (lFunc s)})

-- -- block plumbing ------------------------------------------------------------

fresh :: String -> M Label
fresh hint = do
  s <- get
  let label = hint ++ show (lCounter s + 1)
  put s {lCounter = lCounter s + 1}
  modifyFunc (addBlock label)
  pure label

emit :: Instr -> M ()
emit i = do
  cur <- gets lCur
  modifyFunc (\f -> setBlock ((blockOf f cur) {blInstrs = blInstrs (blockOf f cur) ++ [i]}) f)

terminate :: Instr -> M ()
terminate t = do
  emit t
  dead <- fresh "dead"
  modify (\s -> s {lCur = dead})

jump :: Label -> M ()
jump target = terminate (Jmp target)

branch :: Reg -> Label -> Label -> M ()
branch cond yes no = terminate (CBr cond yes no Nothing)

newReg :: M Reg
newReg = do
  f <- gets lFunc
  modifyFunc (\g -> g {fnRegs = fnRegs g + 1})
  pure (Reg (fnRegs f))

newSlot :: M Int
newSlot = do
  f <- gets lFunc
  modifyFunc (\g -> g {fnSlots = fnSlots g + 1})
  pure (fnSlots f)

constant :: Integer -> M Reg
constant value = do
  r <- newReg
  emit (Const r (fromIntegral value))
  pure r

-- -- function bodies ------------------------------------------------------------

topLevel :: Program -> M ()
topLevel decls = do
  declarations decls
  terminate (Ret Nothing)
  finish

functionBody :: FunBind -> FunSym -> M ()
functionBody bind sym = do
  depth <- gets (fnDepth . lFunc)
  when (depth > 0) $ do
    link <- newReg
    modifyFunc (\f -> f {fnParams = fnParams f ++ [link]})
    slot <- gets (fnLinkSlot . lFunc)
    emit (StoreSlot slot link)
  first <- gets (length . fnParams . lFunc)
  mapM_ (parameter) (zip [first ..] (fsParams sym))
  value <- expression (fbBody bind)
  terminate (Ret (case fsResult sym of TUnit -> Nothing; _ -> value))
  finish
  where
    parameter (index, psym)
      -- The ninth argument and beyond is already in the frame when the callee
      -- starts, at a negative slot, so it never takes a register at entry.
      | index >= argumentRegisters =
          setHome (vsId psym) (InFrame (-(index - argumentRegisters + 1)))
      | otherwise = do
          r <- newReg
          modifyFunc (\f -> f {fnParams = fnParams f ++ [r]})
          escapes <- gets lEscapes
          if Set.member (vsId psym) escapes
            then do
              slot <- newSlot
              setHome (vsId psym) (InFrame slot)
              emit (StoreSlot slot r)
            else setHome (vsId psym) (InRegister r)

setHome :: Int -> Home -> M ()
setHome uid home = modify (\s -> s {lHomes = Map.insert uid home (lHomes s)})

homeOf :: VarSym -> M Home
homeOf sym = gets (fromMaybe (error "a variable with no home") . Map.lookup (vsId sym) . lHomes)

escapes :: VarSym -> M Bool
escapes sym = gets (Set.member (vsId sym) . lEscapes)

finish :: M ()
finish = do
  modifyFunc dropUnreachable
  dropUnusedLink

-- | A function nobody nests inside, and that never looks outward, keeps no
-- static link: the slot goes, and every later slot moves down one.
dropUnusedLink :: M ()
dropUnusedLink = do
  s <- get
  let f = lFunc s
      slot = fnLinkSlot f
      reads' = or [True | b <- walk f, LoadSlot _ n <- blInstrs b, n == slot]
      moved n = if n > slot then n - 1 else n
      rewrite i = case i of
        StoreSlot n src -> [StoreSlot (moved n) src | n /= slot]
        LoadSlot d n -> [LoadSlot d (moved n)]
        _ -> [i]
  unless (slot < 0 || lChildren s || reads') $
    modifyFunc
      ( \g ->
          (mapBlocks (\b -> b {blInstrs = concatMap rewrite (blInstrs b)}) g)
            {fnSlots = fnSlots g - 1, fnLinkSlot = -1}
      )

-- -- declarations ----------------------------------------------------------------

declarations :: [Decl] -> M ()
declarations = mapM_ one
  where
    one (DType _ _) = pure ()
    one d@(DVal {}) = valDecl d
    one (DFun _ binds) = do
      modify (\s -> s {lChildren = True})
      mapM_ nested binds
    nested b = case fbSym b of
      Nothing -> pure ()
      Just sym ->
        openFunction (newFunc (fsLabel sym) (fsName sym) (fsDepth sym)) (functionBody b sym)

valDecl :: Decl -> M ()
valDecl d = do
  value <- expression (dInit d)
  case (dSym d, value) of
    (Just sym, Just r) | notUnit (vsTy sym) -> bind sym r
    _ -> pure ()
  where
    notUnit TUnit = False
    notUnit _ = True

-- | Give a variable its home, and put the initial value in it.
bind :: VarSym -> Reg -> M ()
bind sym value = do
  away <- escapes sym
  if away
    then do
      slot <- newSlot
      setHome (vsId sym) (InFrame slot)
      emit (StoreSlot slot value)
    else do
      r <- newReg
      setHome (vsId sym) (InRegister r)
      emit (Move r value)

-- -- reaching variables and frames --------------------------------------------

-- | A register holding the frame pointer of the function at @depth@.
frameAt :: Int -> M Reg
frameAt depth = do
  here <- gets (fnDepth . lFunc)
  r <- newReg
  if depth == here
    then do emit (FrameAddr r); pure r
    else do
      slot <- gets (fnLinkSlot . lFunc)
      emit (LoadSlot r slot)
      climb r (here - 1)
  where
    climb r here
      | here <= depth = pure r
      | otherwise = do
          next <- newReg
          emit (Load next r (slotOffset 0))
          climb next (here - 1)

readVar :: VarSym -> M Reg
readVar sym = do
  away <- escapes sym
  home <- homeOf sym
  here <- gets (fnDepth . lFunc)
  case (away, home) of
    (False, InRegister r) -> pure r
    (_, InFrame slot)
      | vsDepth sym == here -> do
          r <- newReg
          emit (LoadSlot r slot)
          pure r
      | otherwise -> do
          base <- frameAt (vsDepth sym)
          r <- newReg
          emit (Load r base (slotOffset slot))
          pure r
    _ -> error "a variable that escapes has no register"

writeVar :: VarSym -> Reg -> M ()
writeVar sym value = do
  away <- escapes sym
  home <- homeOf sym
  here <- gets (fnDepth . lFunc)
  case (away, home) of
    (False, InRegister r) -> emit (Move r value)
    (_, InFrame slot)
      | vsDepth sym == here -> emit (StoreSlot slot value)
      | otherwise -> do
          base <- frameAt (vsDepth sym)
          emit (Store base (slotOffset slot) value)
    _ -> error "a variable that escapes has no register"

-- -- expressions ----------------------------------------------------------------

value :: Exp -> M Reg
value e = fromMaybe (error "expected a value here") <$> expression e

expression :: Exp -> M (Maybe Reg)
expression e = case eNode e of
  EInt v -> Just <$> constant v
  EBool b -> Just <$> constant (if b then 1 else 0)
  ENil -> Just <$> constant 0
  EUnit -> pure Nothing
  EStr text -> do
    symbol <- intern text
    r <- newReg
    emit (StrConst r symbol)
    pure (Just r)
  EVar _ -> case eSym e of
    Just (SVar sym) -> Just <$> readVar sym
    _ -> error "a variable with no symbol"
  ECall name args -> call e name args
  ERecord _ fields -> Just <$> record e fields
  EIndex array index -> do
    addr <- elementAddress array index
    r <- newReg
    emit (Load r addr word)
    pure (Just r)
  EField record' _ -> do
    base <- value record'
    checkNotNil base
    r <- newReg
    emit (Load r base (word * eOffset e))
    pure (Just r)
  ENeg operand -> do
    zero <- constant 0
    operand' <- value operand
    Just <$> binop Sub zero operand'
  EBin op lhs rhs -> Just <$> binExp op lhs rhs
  ELogic op lhs rhs -> Just <$> logic op lhs rhs
  EAssign target v -> assign target v >> pure Nothing
  EIf cond then' els -> ifExp e cond then' els
  EWhile cond body -> whileExp cond body >> pure Nothing
  EFor _ lo hi body -> forExp e lo hi body >> pure Nothing
  EBreak -> do
    breaks <- gets lBreaks
    terminate (Jmp (head breaks))
    pure Nothing
  ESeq items -> foldM (\_ item -> expression item) Nothing items
  ELet decls body -> do
    declarations decls
    expression body

binop :: Op -> Reg -> Reg -> M Reg
binop op lhs rhs = do
  r <- newReg
  emit (Bin r op lhs rhs)
  pure r

compare' :: Rel -> Reg -> Reg -> M Reg
compare' op lhs rhs = do
  r <- newReg
  emit (Cmp r op lhs rhs)
  pure r

callRuntime :: String -> [Reg] -> M Reg
callRuntime name args = do
  r <- newReg
  emit (Call (Just r) name args)
  pure r

-- | What the surface operator means to the machine.  Everything the parser can
-- write that is not one of these is a call or a branch, and is handled above.
arithmetic :: String -> Maybe Op
arithmetic op = lookup op [("+", Add), ("-", Sub), ("*", Mul), ("/", Div), ("mod", Mod)]

comparison :: String -> Maybe Rel
comparison op =
  lookup
    op
    [ ("=", Equal), ("<>", NotEqual), ("<", Less), ("<=", LessEq),
      (">", Greater), (">=", GreaterEq)
    ]

binExp :: String -> Exp -> Exp -> M Reg
binExp op lhs rhs = do
  l <- value lhs
  r <- value rhs
  case (op, arithmetic op, comparison op) of
    ("^", _, _) -> callRuntime "wol_concat" [l, r]
    (_, Just Div, _) -> do checkNonzero r; binop Div l r
    (_, Just Mod, _) -> do
      checkNonzero r
      -- The remainder is spelled out rather than left to the emitter: the
      -- quotient it needs in between is a value like any other, and the
      -- allocator can find it a register.  The emitter fuses the last two back
      -- into one `msub`.
      q <- binop Div l r
      product' <- binop Mul q r
      binop Sub l product'
    (_, Just plain, _) -> binop plain l r
    (_, _, Just rel) -> case eTy lhs of
      Just TString -> do
        order <- callRuntime "wol_string_cmp" [l, r]
        zero <- constant 0
        compare' rel order zero
      _ -> compare' rel l r
    _ -> error ("lowering does not know the operator `" ++ op ++ "`")

-- | @andalso@ and @orelse@ are branches, so the result needs a register.
logic :: String -> Exp -> Exp -> M Reg
logic op lhs rhs = do
  result <- newReg
  rhsBlock <- fresh "logic"
  join' <- fresh "logicjoin"
  l <- value lhs
  emit (Move result l)
  if op == "andalso" then branch l rhsBlock join' else branch l join' rhsBlock
  modify (\s -> s {lCur = rhsBlock})
  r <- value rhs
  emit (Move result r)
  jump join'
  modify (\s -> s {lCur = join'})
  pure result

call :: Exp -> String -> [Exp] -> M (Maybe Reg)
call e _ args = case eSym e of
  Just (SFun sym) -> case fsBuiltin sym of
    -- The checker has already counted the arguments, so these shapes hold.
    Just "not" | [a] <- args -> do
      x <- value a
      one <- constant 1
      Just <$> binop Xor x one
    Just "array" | [count, fill] <- args -> do
      n <- value count
      init' <- value fill
      Just <$> callRuntime "wol_array" [n, init']
    Just "length" | [a] <- args -> do
      arr <- value a
      checkNotNil arr
      r <- newReg
      emit (Load r arr 0)
      pure (Just r)
    builtin -> do
      lowered <- mapM value args
      full <- case builtin of
        Just _ -> pure lowered
        Nothing -> do
          link <- frameAt (fsDepth sym - 1)
          pure (link : lowered)
      case fsResult sym of
        TUnit -> do emit (Call Nothing (fsLabel sym) full); pure Nothing
        _ -> Just <$> callRuntime (fsLabel sym) full
  _ -> error "a call with no symbol"

record :: Exp -> [FieldInit] -> M Reg
record e fields = do
  let arity = case eTy e of Just (TRecord _ _ n) -> n; _ -> 0
  size <- constant (fromIntegral (word * max arity 1))
  base <- callRuntime "wol_alloc" [size]
  mapM_ (one base) (zip [0 ..] fields)
  pure base
  where
    one base (i, f) = do
      v <- value (fiValue f)
      emit (Store base (word * i) v)

-- | The address of @a[i]@, without the length word the elements follow.
--
-- The selector turns this into one @add@ with a shifted operand, and the word is
-- the load's displacement, so the two instructions that come out are the two the
-- machine has.
elementAddress :: Exp -> Exp -> M Reg
elementAddress array index = do
  base <- value array
  idx <- value index
  checkNotNil base
  checkBounds base idx
  three <- constant 3
  shifted <- binop Shl idx three
  binop Add base shifted

assign :: Exp -> Exp -> M ()
assign target v = case eNode target of
  EVar _ -> case eSym target of
    Just (SVar sym) -> value v >>= writeVar sym
    _ -> error "an assignment with no symbol"
  EIndex array index -> do
    addr <- elementAddress array index
    v' <- value v
    emit (Store addr word v')
  EField record' _ -> do
    base <- value record'
    checkNotNil base
    v' <- value v
    emit (Store base (word * eOffset target) v')
  _ -> error "assignment to something that is not a place"

ifExp :: Exp -> Exp -> Exp -> Maybe Exp -> M (Maybe Reg)
ifExp e cond then' els = do
  result <- case eTy e of
    Just TUnit -> pure Nothing
    _ -> Just <$> newReg
  yes <- fresh "then"
  no <- fresh "else"
  join' <- fresh "join"
  c <- value cond
  branch c yes no

  modify (\s -> s {lCur = yes})
  v <- expression then'
  copy result v
  jump join'

  modify (\s -> s {lCur = no})
  case els of
    Nothing -> pure ()
    Just e' -> expression e' >>= copy result
  jump join'

  modify (\s -> s {lCur = join'})
  pure result
  where
    copy (Just r) (Just v) = emit (Move r v)
    copy _ _ = pure ()

inLoop :: Label -> M a -> M ()
inLoop done body = do
  modify (\s -> s {lBreaks = done : lBreaks s})
  _ <- body
  modify (\s -> s {lBreaks = drop 1 (lBreaks s)})

whileExp :: Exp -> Exp -> M ()
whileExp cond body = do
  test <- fresh "test"
  bodyBlock <- fresh "body"
  done <- fresh "done"
  jump test
  modify (\s -> s {lCur = test})
  c <- value cond
  branch c bodyBlock done
  modify (\s -> s {lCur = bodyBlock})
  inLoop done (expression body)
  jump test
  modify (\s -> s {lCur = done})

-- | @for i = lo to hi@ counts up, and stops before overflowing at @hi@.
forExp :: Exp -> Exp -> Exp -> Exp -> M ()
forExp e lo hi body = do
  let sym = case eSym e of Just (SVar v) -> v; _ -> error "a for with no symbol"
  lo' <- value lo
  hiValue <- value hi
  hi' <- newReg
  emit (Move hi' hiValue)
  bind sym lo'
  bodyBlock <- fresh "forbody"
  step <- fresh "forstep"
  done <- fresh "fordone"
  test <- compare' LessEq lo' hi'
  branch test bodyBlock done

  modify (\s -> s {lCur = bodyBlock})
  inLoop done (expression body)
  i <- readVar sym
  again <- compare' Less i hi'
  branch again step done

  modify (\s -> s {lCur = step})
  i' <- readVar sym
  one <- constant 1
  next <- binop Add i' one
  writeVar sym next
  jump bodyBlock

  modify (\s -> s {lCur = done})

-- -- run-time checks ---------------------------------------------------------

-- | Each of the three is the same shape: a branch to a block that calls the
-- runtime and never comes back, and a block where the program carries on.
guard' :: String -> Reg -> Bool -> Instr -> M ()
guard' hint test badFirst i = do
  bad <- fresh hint
  ok <- fresh "ok"
  if badFirst then branch test bad ok else branch test ok bad
  modify (\s -> s {lCur = bad})
  emit i
  jump ok
  modify (\s -> s {lCur = ok})

checkNotNil :: Reg -> M ()
checkNotNil base = do
  checks <- gets lChecks
  when checks $ do
    zero <- constant 0
    test <- compare' Equal base zero
    guard' "nil" test True (Call Nothing "wol_nil_error" [])

checkBounds :: Reg -> Reg -> M ()
checkBounds base idx = do
  checks <- gets lChecks
  when checks $ do
    len <- newReg
    emit (Load len base 0)
    test <- compare' Below idx len
    guard' "oob" test False (Call Nothing "wol_bounds_error" [idx, len])

checkNonzero :: Reg -> M ()
checkNonzero rhs = do
  checks <- gets lChecks
  when checks $ do
    zero <- constant 0
    test <- compare' Equal rhs zero
    guard' "divzero" test True (Call Nothing "wol_div_error" [])
