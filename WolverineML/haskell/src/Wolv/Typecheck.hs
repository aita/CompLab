{-# LANGUAGE MultiWayIf #-}
-- | The type checker, which also decides which variables escape.
--
-- Types are monomorphic and there is nothing to infer but the type of a @val@.
-- A @fun@ without a result type is a procedure and returns @unit@, which is what
-- makes recursion checkable without inference: every function's signature is
-- known before any body is.
--
-- The pass has a second job.  A variable read from inside a function nested more
-- deeply than the one that binds it cannot live in a register, because the inner
-- function reaches it through a static link at run time.  Every lookup that
-- crosses a function boundary marks the variable as escaping, and the lowering
-- pass gives those a frame slot instead.
--
-- Nothing is written into the tree the parser built.  What comes out is a second
-- tree with the answers in it, and beside it the set of variables that escape —
-- because a variable is marked long after the node that mentions it was made,
-- and a value cannot be changed once it exists.
module Wolv.Typecheck (check, Checked (..)) where

import Control.Monad.State
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Wolv.Ast
import Wolv.Diag
import Wolv.Types

-- | The typed tree, and what the tree cannot hold: which variables escape.
data Checked = Checked {ckProgram :: Program, ckEscapes :: Set.Set Int}

builtins :: [(String, [Type], Type, String)]
builtins =
  [ ("print", [TString], TUnit, "wol_print"),
    ("println", [TString], TUnit, "wol_println"),
    ("printInt", [TInt], TUnit, "wol_print_int"),
    ("flush", [], TUnit, "wol_flush"),
    ("getChar", [], TString, "wol_getchar"),
    ("ord", [TString], TInt, "wol_ord"),
    ("chr", [TInt], TString, "wol_chr"),
    ("size", [TString], TInt, "wol_size"),
    ("substring", [TString, TInt, TInt], TString, "wol_substring"),
    ("concat", [TString, TString], TString, "wol_concat"),
    ("intToString", [TInt], TString, "wol_int_to_string"),
    ("stringToInt", [TString], TInt, "wol_string_to_int"),
    ("exit", [TInt], TUnit, "wol_exit")
  ]

-- | The three whose types depend on their arguments, so the checker types them.
specials :: [String]
specials = ["array", "length", "not"]

arithmetic, ordering, equality :: [String]
arithmetic = ["+", "-", "*", "/", "mod"]
ordering = ["<", "<=", ">", ">="]
equality = ["=", "<>"]

-- | A scope is two tables; the stack of them is innermost first, so a lookup
-- walks outward and stops at the first hit.
data Scope = Scope {scTys :: Map.Map String Type, scVals :: Map.Map String Sym}

emptyScope :: Scope
emptyScope = Scope Map.empty Map.empty

data Checker = Checker
  { chScopes :: [Scope],
    chDepth :: !Int,
    chLoops :: !Int,
    chLabels :: Map.Map String Int,
    chNext :: !Int,
    chEscapes :: Set.Set Int,
    chRecords :: Map.Map Int [(String, Type)]
  }

type C a = StateT Checker (Either WolvError) a

failWith :: (Span -> String -> Either WolvError ()) -> Span -> String -> C a
failWith raise at message = lift (raise at message >> error "unreachable")

bad :: Span -> String -> C a
bad = failWith typeError

fresh :: C Int
fresh = do
  s <- get
  put s {chNext = chNext s + 1}
  pure (chNext s)

prelude :: Checker
prelude =
  let ground = Map.fromList [("int", TInt), ("string", TString), ("bool", TBool), ("unit", TUnit)]
      params args = [VarSym (-1) ("a" ++ show i) t False 0 | (i, t) <- zip [(0 :: Int) ..] args]
      builtin (name, args, result, label) =
        (name, SFun (FunSym name label (params args) result 0 (Just label)))
      special name = (name, SFun (FunSym name name [] TUnit 0 (Just name)))
      vals = Map.fromList (map builtin builtins ++ map special specials)
   in Checker [Scope ground vals] 0 0 Map.empty 0 Set.empty Map.empty

-- -- scopes -----------------------------------------------------------------

push :: C ()
push = modify (\s -> s {chScopes = emptyScope : chScopes s})

pop :: C ()
pop = modify (\s -> s {chScopes = drop 1 (chScopes s)})

bindVal :: String -> Sym -> C ()
bindVal name sym = modify $ \s -> case chScopes s of
  (top : rest) -> s {chScopes = top {scVals = Map.insert name sym (scVals top)} : rest}
  [] -> s

bindType :: String -> Type -> C ()
bindType name ty = modify $ \s -> case chScopes s of
  (top : rest) -> s {chScopes = top {scTys = Map.insert name ty (scTys top)} : rest}
  [] -> s

lookupIn :: (Scope -> Map.Map String a) -> String -> Span -> String -> C a
lookupIn table name at what = do
  scopes <- gets chScopes
  case [v | scope <- scopes, Just v <- [Map.lookup name (table scope)]] of
    (v : _) -> pure v
    [] -> bad at ("`" ++ name ++ "` is not " ++ what)

lookupVal :: String -> Span -> C Sym
lookupVal name at = lookupIn scVals name at "bound"

lookupType :: String -> Span -> C Type
lookupType name at = lookupIn scTys name at "a type"

-- | Two functions of the same name in one program need two labels.
uniqueLabel :: String -> C String
uniqueLabel name = do
  s <- get
  let n = fromMaybe 0 (Map.lookup name (chLabels s))
  put s {chLabels = Map.insert name (n + 1) (chLabels s)}
  pure (if n == 0 then "wol_" ++ name else "wol_" ++ name ++ "." ++ show n)

unify :: Type -> Type -> Span -> String -> C ()
unify want got at where' =
  unless (compatible want got) $
    bad at ("expected `" ++ showTy want ++ "`, found `" ++ showTy got ++ "` " ++ where')

-- -- types as they are written ------------------------------------------------

resolve :: TyExp -> C Type
resolve (TyName at name) = lookupType name at
resolve (TyArray _ elem') = TArray <$> resolve elem'
resolve (TyRecord at _) = bad at "a record type has to be given a name by `type`"

fieldsOf :: Type -> C [(String, Type)]
fieldsOf (TRecord uid _ _) = gets (fromMaybe [] . Map.lookup uid . chRecords)
fieldsOf _ = pure []

-- -- declarations -------------------------------------------------------------

check :: Program -> Either WolvError Checked
check prog = do
  (decls', s) <- runStateT (push >> mapM decl prog) prelude
  Right (Checked decls' (chEscapes s))

decl :: Decl -> C Decl
decl (DType at binds) = DType at <$> typeDecl binds
decl d@(DVal {}) = valDecl d
decl (DFun at binds) = DFun at <$> funDecl binds

-- | Records are bound before any field is resolved, so a group of @type@s may
-- name each other and itself.
typeDecl :: [TypeBind] -> C [TypeBind]
typeDecl binds = do
  records <- mapM openRecord [b | b <- binds, isRecord b]
  mapM_ (\b -> resolve (tbBound b) >>= bindType (tbName b)) [b | b <- binds, not (isRecord b)]
  mapM_ closeRecord records
  pure binds
  where
    isRecord b = case tbBound b of TyRecord _ _ -> True; _ -> False
    openRecord b = do
      uid <- fresh
      let fields = case tbBound b of TyRecord _ fs -> fs; _ -> []
      bindType (tbName b) (TRecord uid (tbName b) (length fields))
      pure (uid, fields)
    closeRecord (uid, fields) = do
      resolved <- foldM oneField [] fields
      modify (\s -> s {chRecords = Map.insert uid (reverse resolved) (chRecords s)})
    oneField seen f = do
      when (any ((== tfName f) . fst) seen) $
        bad (tfAt f) ("duplicate field `" ++ tfName f ++ "`")
      t <- resolve (tfTy f)
      pure ((tfName f, t) : seen)

valDecl :: Decl -> C Decl
valDecl d = do
  init' <- inferExp (dInit d)
  got <- case dWritten d of
    Nothing -> pure (tyOf init')
    Just written -> do
      want <- resolve written
      unify want (tyOf init') (eAt init') "in this binding"
      pure want
  case dName d of
    Nothing -> do
      unify TUnit got (eAt init') "in `val () =`"
      pure d {dInit = init'}
    Just name -> do
      case got of
        TNil -> bad (dAt d) ("`" ++ name ++ "` needs a type annotation to hold `nil`")
        _ -> pure ()
      uid <- fresh
      depth <- gets chDepth
      let sym = VarSym uid name got (dMutable d) depth
      bindVal name (SVar sym)
      pure d {dInit = init', dSym = Just sym}

-- | Every signature in the group is bound before any body is typed.
funDecl :: [FunBind] -> C [FunBind]
funDecl binds = do
  signed <- mapM signature binds
  mapM_ bindSignature signed
  mapM body signed
  where
    signature b = do
      depth <- gets chDepth
      params <- foldM (oneParam (depth + 1)) [] (fbParams b)
      result <- maybe (pure TUnit) resolve (fbResult b)
      label <- uniqueLabel (fbName b)
      let syms = [s | Just s <- map pSym (reverse params)]
      pure b {fbParams = reverse params, fbSym = Just (FunSym (fbName b) label syms result (depth + 1) Nothing)}
    oneParam depth seen p = do
      when (any ((== pName p) . pName) seen) $
        bad (pAt p) ("duplicate parameter `" ++ pName p ++ "`")
      t <- resolve (pTy p)
      uid <- fresh
      pure (p {pSym = Just (VarSym uid (pName p) t False depth)} : seen)
    bindSignature b = case fbSym b of
      Just sym -> bindVal (fbName b) (SFun sym)
      Nothing -> pure ()
    body b@(FunBind {fbSym = Just sym}) = do
      outer <- gets chLoops
      modify (\s -> s {chDepth = chDepth s + 1, chLoops = 0})
      push
      mapM_ (\p -> maybe (pure ()) (bindVal (pName p) . SVar) (pSym p)) (fbParams b)
      body' <- inferExp (fbBody b)
      unify (fsResult sym) (tyOf body') (eAt body') ("in the body of `" ++ fbName b ++ "`")
      pop
      modify (\s -> s {chDepth = chDepth s - 1, chLoops = outer})
      pure b {fbBody = body'}
    body b = pure b

-- -- expressions --------------------------------------------------------------

tyOf :: Exp -> Type
tyOf e = fromMaybe (error "the checker leaves no expression untyped") (eTy e)

typed :: Exp -> Type -> Node -> Exp
typed e ty node = e {eTy = Just ty, eNode = node}

inferExp :: Exp -> C Exp
inferExp e = case eNode e of
  EInt _ -> pure e {eTy = Just TInt}
  EStr _ -> pure e {eTy = Just TString}
  EBool _ -> pure e {eTy = Just TBool}
  ENil -> pure e {eTy = Just TNil}
  EUnit -> pure e {eTy = Just TUnit}
  EVar name -> variable e name
  ECall name args -> callExp e name args
  ERecord tyname inits -> recordLit e tyname inits
  EIndex array index -> indexExp e array index
  EField record name -> fieldExp e record name
  ENeg operand -> do
    operand' <- inferExp operand
    unify TInt (tyOf operand') (eAt e) "in a negation"
    pure (typed e TInt (ENeg operand'))
  EBin op lhs rhs -> binop e op lhs rhs
  ELogic op lhs rhs -> do
    lhs' <- inferExp lhs
    unify TBool (tyOf lhs') (eAt lhs') ("on the left of `" ++ op ++ "`")
    rhs' <- inferExp rhs
    unify TBool (tyOf rhs') (eAt rhs') ("on the right of `" ++ op ++ "`")
    pure (typed e TBool (ELogic op lhs' rhs'))
  EAssign target value -> assign e target value
  EIf cond then' els -> ifExp e cond then' els
  EWhile cond body -> do
    cond' <- inferExp cond
    unify TBool (tyOf cond') (eAt cond') "as a `while` condition"
    modify (\s -> s {chLoops = chLoops s + 1})
    body' <- inferExp body
    unify TUnit (tyOf body') (eAt body') "in a `while` body"
    modify (\s -> s {chLoops = chLoops s - 1})
    pure (typed e TUnit (EWhile cond' body'))
  EFor name lo hi body -> forExp e name lo hi body
  EBreak -> do
    loops <- gets chLoops
    when (loops == 0) $ bad (eAt e) "`break` is outside any loop"
    pure e {eTy = Just TUnit}
  ESeq items -> do
    items' <- mapM inferExp items
    pure (typed e (if null items' then TUnit else tyOf (last items')) (ESeq items'))
  ELet decls body -> do
    push
    decls' <- mapM decl decls
    body' <- inferExp body
    pop
    pure (typed e (tyOf body') (ELet decls' body'))

variable :: Exp -> String -> C Exp
variable e name = do
  sym <- lookupVal name (eAt e)
  case sym of
    SFun _ -> bad (eAt e) ("`" ++ name ++ "` is a function, and functions are not values")
    SVar v -> do
      -- Read from deeper than it was bound: it cannot live in a register.
      depth <- gets chDepth
      when (vsDepth v < depth) $
        modify (\s -> s {chEscapes = Set.insert (vsId v) (chEscapes s)})
      pure e {eTy = Just (vsTy v), eSym = Just sym}

arity :: Exp -> String -> [a] -> Int -> C ()
arity e callee args want =
  unless (length args == want) $
    bad
      (eAt e)
      ( "`" ++ callee ++ "` takes " ++ show want ++ " argument"
          ++ (if want == 1 then "" else "s")
          ++ ", given "
          ++ show (length args)
      )

callExp :: Exp -> String -> [Exp] -> C Exp
callExp e name args = do
  f <- lookupVal name (eAt e)
  case f of
    SVar _ -> bad (eAt e) ("`" ++ name ++ "` is a variable, not a function")
    SFun sym -> do
      let done ty args' = pure (Exp (eAt e) (Just ty) (Just f) (eOffset e) (ECall name args'))
      case fsBuiltin sym of
        Just "array" -> do
          arity e name args 2
          n <- inferExp (head args)
          unify TInt (tyOf n) (eAt n) "as an array length"
          init' <- inferExp (args !! 1)
          case tyOf init' of
            TNil -> bad (eAt init') "`array` cannot tell which record `nil` stands for"
            elem' -> done (TArray elem') [n, init']
        Just "length" -> do
          arity e name args 1
          arr <- inferExp (head args)
          case tyOf arr of
            TArray _ -> done TInt [arr]
            got -> bad (eAt arr) ("`length` wants an array, found `" ++ showTy got ++ "`")
        Just "not" -> do
          arity e name args 1
          arg <- inferExp (head args)
          unify TBool (tyOf arg) (eAt e) "in a call to `not`"
          done TBool [arg]
        _ -> do
          arity e name args (length (fsParams sym))
          args' <- mapM inferExp args
          mapM_
            (\(a, p) -> unify (vsTy p) (tyOf a) (eAt a) ("in a call to `" ++ name ++ "`"))
            (zip args' (fsParams sym))
          done (fsResult sym) args'

-- | The initialisers are put into declaration order, which is what lowering
-- wants.
recordLit :: Exp -> String -> [FieldInit] -> C Exp
recordLit e tyname inits = do
  found <- lookupType tyname (eAt e)
  case found of
    TRecord _ name _ -> do
      fields <- fieldsOf found
      foldM_ (given name fields) [] inits
      ordered <- mapM (inOrder) fields
      pure (Exp (eAt e) (Just found) (eSym e) (eOffset e) (ERecord tyname ordered))
    _ -> bad (eAt e) ("`" ++ tyname ++ "` is not a record type")
  where
    given name fields seen f = do
      when (fiName f `elem` seen) $
        bad (fiAt f) ("field `" ++ fiName f ++ "` is given twice")
      unless (any ((== fiName f) . fst) fields) $
        bad (fiAt f) ("`" ++ name ++ "` has no field `" ++ fiName f ++ "`")
      pure (fiName f : seen)
    inOrder (name, want) = case find ((== name) . fiName) inits of
      Nothing -> bad (eAt e) ("field `" ++ name ++ "` is missing")
      Just f -> do
        value <- inferExp (fiValue f)
        unify want (tyOf value) (fiAt f) ("in field `" ++ name ++ "`")
        pure f {fiValue = value}

indexExp :: Exp -> Exp -> Exp -> C Exp
indexExp e array index = do
  array' <- inferExp array
  case tyOf array' of
    TArray elem' -> do
      index' <- inferExp index
      unify TInt (tyOf index') (eAt index') "as an array index"
      pure (typed e elem' (EIndex array' index'))
    got -> bad (eAt e) ("`" ++ showTy got ++ "` is not an array")

fieldExp :: Exp -> Exp -> String -> C Exp
fieldExp e record name = do
  record' <- inferExp record
  case tyOf record' of
    found@(TRecord _ rname _) -> do
      fields <- fieldsOf found
      case lookup name fields of
        Nothing -> bad (eAt e) ("`" ++ rname ++ "` has no field `" ++ name ++ "`")
        Just ty ->
          pure
            e
              { eTy = Just ty,
                eOffset = length (takeWhile ((/= name) . fst) fields),
                eNode = EField record' name
              }
    got -> bad (eAt e) ("`" ++ showTy got ++ "` is not a record")

binop :: Exp -> String -> Exp -> Exp -> C Exp
binop e op lhs rhs = do
  lhs' <- inferExp lhs
  rhs' <- inferExp rhs
  let l = tyOf lhs'
      r = tyOf rhs'
      done ty = pure (typed e ty (EBin op lhs' rhs'))
  if
      | op `elem` arithmetic -> do
          unify TInt l (eAt lhs') ("on the left of `" ++ op ++ "`")
          unify TInt r (eAt rhs') ("on the right of `" ++ op ++ "`")
          done TInt
      | op == "^" -> do
          unify TString l (eAt lhs') "on the left of `^`"
          unify TString r (eAt rhs') "on the right of `^`"
          done TString
      | op `elem` ordering -> do
          unless (comparable l) $
            bad (eAt e) ("`" ++ op ++ "` compares int or string, not `" ++ showTy l ++ "`")
          unify l r (eAt rhs') ("on the right of `" ++ op ++ "`")
          done TBool
      | op `elem` equality -> do
          when (isUnit l || isUnit r) $ bad (eAt e) ("`" ++ op ++ "` cannot compare `unit`")
          unless (compatible l r) $
            bad (eAt e) ("`" ++ op ++ "` compares `" ++ showTy l ++ "` with `" ++ showTy r ++ "`")
          done TBool
      | otherwise -> bad (eAt e) ("unknown operator `" ++ op ++ "`")
  where
    comparable ty = case ty of TInt -> True; TString -> True; _ -> False
    isUnit ty = case ty of TUnit -> True; _ -> False

assign :: Exp -> Exp -> Exp -> C Exp
assign e target value = do
  target' <- inferExp target
  case (eNode target', eSym target') of
    (EVar _, Just (SVar v))
      | not (vsMutable v) ->
          bad (eAt e) ("`" ++ vsName v ++ "` is a `val`, so it cannot be assigned")
    _ -> pure ()
  value' <- inferExp value
  unify (tyOf target') (tyOf value') (eAt value') "in an assignment"
  pure (typed e TUnit (EAssign target' value'))

ifExp :: Exp -> Exp -> Exp -> Maybe Exp -> C Exp
ifExp e cond then' els = do
  cond' <- inferExp cond
  unify TBool (tyOf cond') (eAt cond') "as an `if` condition"
  then'' <- inferExp then'
  case els of
    Nothing -> do
      unify TUnit (tyOf then'') (eAt then'') "in an `if` with no `else`"
      pure (typed e TUnit (EIf cond' then'' Nothing))
    Just els' -> do
      els'' <- inferExp els'
      let t = tyOf then''
          other = tyOf els''
      unless (compatible t other) $
        bad (eAt e) ("the branches differ: `" ++ showTy t ++ "` and `" ++ showTy other ++ "`")
      pure (typed e (case t of TNil -> other; _ -> t) (EIf cond' then'' (Just els'')))

forExp :: Exp -> String -> Exp -> Exp -> Exp -> C Exp
forExp e name lo hi body = do
  lo' <- inferExp lo
  unify TInt (tyOf lo') (eAt lo') "as a `for` bound"
  hi' <- inferExp hi
  unify TInt (tyOf hi') (eAt hi') "as a `for` bound"
  uid <- fresh
  depth <- gets chDepth
  let sym = VarSym uid name TInt False depth
  push
  bindVal name (SVar sym)
  modify (\s -> s {chLoops = chLoops s + 1})
  body' <- inferExp body
  unify TUnit (tyOf body') (eAt body') "in a `for` body"
  modify (\s -> s {chLoops = chLoops s - 1})
  pop
  pure
    e
      { eTy = Just TUnit,
        eSym = Just (SVar sym),
        eNode = EFor name lo' hi' body'
      }
