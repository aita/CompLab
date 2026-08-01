-- | The syntax tree.
--
-- Every expression is a span, the node itself, and the three things the checker
-- works out — the type, what a name resolved to, and which word of a record a
-- field access reads.  The parser leaves those empty and the checker answers
-- with a tree that has them filled in: nothing is written into the tree the
-- parser built, because nothing in Haskell can be.
module Wolv.Ast
  ( Exp (..),
    Node (..),
    FieldInit (..),
    TyExp (..),
    TyField (..),
    Decl (..),
    TypeBind (..),
    Param (..),
    FunBind (..),
    Program,
    exp0,
    tyAt,
    declAt,
  )
where

import Wolv.Diag (Span)
import Wolv.Types

-- -- types as they are written ------------------------------------------------

data TyExp
  = TyName Span String
  | TyArray Span TyExp
  | TyRecord Span [TyField]
  deriving (Show)

data TyField = TyField {tfName :: String, tfTy :: TyExp, tfAt :: Span}
  deriving (Show)

tyAt :: TyExp -> Span
tyAt (TyName at _) = at
tyAt (TyArray at _) = at
tyAt (TyRecord at _) = at

-- -- expressions ---------------------------------------------------------------

data Exp = Exp
  { eAt :: Span,
    eTy :: Maybe Type,
    eSym :: Maybe Sym,
    eOffset :: !Int,
    eNode :: Node
  }
  deriving (Show)

-- | What the parser always wants: a node with its span and nothing known yet.
exp0 :: Span -> Node -> Exp
exp0 at node = Exp at Nothing Nothing (-1) node

data Node
  = EInt Integer
  | EStr String
  | EBool Bool
  | ENil
  | EUnit
  | EVar String
  | ECall String [Exp]
  | -- | The initialisers are put into declaration order by the checker.
    ERecord String [FieldInit]
  | EIndex Exp Exp
  | EField Exp String
  | ENeg Exp
  | EBin String Exp Exp
  | -- | @andalso@ and @orelse@, which are control flow and not operators.
    ELogic String Exp Exp
  | EAssign Exp Exp
  | EIf Exp Exp (Maybe Exp)
  | EWhile Exp Exp
  | EFor String Exp Exp Exp
  | EBreak
  | ESeq [Exp]
  | ELet [Decl] Exp
  deriving (Show)

data FieldInit = FieldInit {fiName :: String, fiValue :: Exp, fiAt :: Span}
  deriving (Show)

-- -- declarations ---------------------------------------------------------------

data Decl
  = DType Span [TypeBind]
  | DVal
      { dAt :: Span,
        dName :: Maybe String,
        dWritten :: Maybe TyExp,
        dInit :: Exp,
        dMutable :: !Bool,
        dSym :: Maybe VarSym
      }
  | DFun Span [FunBind]
  deriving (Show)

data TypeBind = TypeBind {tbName :: String, tbBound :: TyExp, tbAt :: Span}
  deriving (Show)

data Param = Param {pName :: String, pTy :: TyExp, pAt :: Span, pSym :: Maybe VarSym}
  deriving (Show)

data FunBind = FunBind
  { fbName :: String,
    fbParams :: [Param],
    fbResult :: Maybe TyExp,
    fbBody :: Exp,
    fbAt :: Span,
    fbSym :: Maybe FunSym
  }
  deriving (Show)

type Program = [Decl]

declAt :: Decl -> Span
declAt (DType at _) = at
declAt d@(DVal {}) = dAt d
declAt (DFun at _) = at
