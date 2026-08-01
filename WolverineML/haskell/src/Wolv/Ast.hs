{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}

-- | The syntax tree, in two phases.
--
-- Every expression is a span, the node itself, and the things the checker works
-- out — the type, what a name resolved to, and which word of a record a field
-- access reads.  The parser does not know any of them and the checker does, so
-- the tree is indexed by which of the two made it: 'Parsed' fills every
-- annotation with @()@, and 'Typed' fills it with the answer.
--
-- What that buys is downstream.  Lowering takes a @Program 'Typed@, so
-- @EVar name sym@ hands it a 'VarSym' and not a @Maybe VarSym@ it would have to
-- open with an error for the case the checker has already ruled out.  The other
-- ports keep one tree with holes in it and an invariant nobody checks; here the
-- invariant is the index, and the checker is the only thing that can produce a
-- tree lowering will accept.
module Wolv.Ast
  ( Phase (..),
    Ann,
    Exp (..),
    Node (..),
    Place (..),
    PNode (..),
    FieldInit (..),
    TyExp (..),
    TyField (..),
    Binder (..),
    Decl (..),
    TypeBind (..),
    Param (..),
    FunBind (..),
    Program,
    parsed,
    placed,
    tyAt,
    declAt,
  )
where

import Wolv.Diag (Span)
import Wolv.Types

-- | Which pass made this tree.
data Phase = Parsed | Typed

-- | An annotation: nothing before the checker has run, the answer after.
type family Ann (p :: Phase) a where
  Ann 'Parsed a = ()
  Ann 'Typed a = a

-- -- types as they are written ------------------------------------------------

data TyExp
  = TyName Span String
  | TyArray Span TyExp
  | TyRecord Span [TyField]

data TyField = TyField {tfName :: String, tfTy :: TyExp, tfAt :: Span}

tyAt :: TyExp -> Span
tyAt (TyName at _) = at
tyAt (TyArray at _) = at
tyAt (TyRecord at _) = at

-- -- expressions ---------------------------------------------------------------

data Exp p = Exp {eAt :: Span, eTy :: Ann p Type, eNode :: Node p}

-- | What the parser always wants: a node with its span and nothing known yet.
parsed :: Span -> Node 'Parsed -> Exp 'Parsed
parsed at = Exp at ()

placed :: Span -> PNode 'Parsed -> Exp 'Parsed
placed at node = parsed at (EPlace (Place at () node))

-- | The three shapes that can be read and written, which are the three the left
-- of @:=@ accepts.  They are their own type so that assignment can say which
-- ones it takes: the parser is where a target that is not one of them is
-- refused, and nothing after that has to ask again.
data Place p = Place {plAt :: Span, plTy :: Ann p Type, plNode :: PNode p}

data PNode p
  = -- | The symbol the name resolved to.
    PVar String (Ann p VarSym)
  | PIndex (Exp p) (Exp p)
  | -- | Which word of the record the field is.
    PField (Exp p) String (Ann p Int)

data Node p
  = EInt Integer
  | EStr String
  | EBool Bool
  | ENil
  | EUnit
  | EPlace (Place p)
  | ECall String [Exp p] (Ann p FunSym)
  | -- | The initialisers are put into declaration order by the checker.
    ERecord String [FieldInit p]
  | ENeg (Exp p)
  | EBin String (Exp p) (Exp p)
  | -- | @andalso@ and @orelse@, which are control flow and not operators.
    ELogic String (Exp p) (Exp p)
  | EAssign (Place p) (Exp p)
  | EIf (Exp p) (Exp p) (Maybe (Exp p))
  | EWhile (Exp p) (Exp p)
  | EFor String (Exp p) (Exp p) (Exp p) (Ann p VarSym)
  | EBreak
  | ESeq [Exp p]
  | ELet [Decl p] (Exp p)

data FieldInit p = FieldInit {fiName :: String, fiValue :: Exp p, fiAt :: Span}

-- -- declarations ---------------------------------------------------------------

-- | What a @val@ binds, when it binds anything: @val () = e@ binds nothing at
-- all.  The name and its symbol travel together, so there is no pair of
-- 'Maybe's that have to agree about which of the two cases this is.
data Binder p = Binder {bName :: String, bSym :: Ann p VarSym}

data Decl p
  = DType Span [TypeBind]
  | DVal
      { dAt :: Span,
        dBound :: Maybe (Binder p),
        dWritten :: Maybe TyExp,
        dInit :: Exp p,
        dMutable :: !Bool
      }
  | DFun Span [FunBind p]

data TypeBind = TypeBind {tbName :: String, tbBound :: TyExp, tbAt :: Span}

data Param p = Param {pName :: String, pTy :: TyExp, pAt :: Span, pSym :: Ann p VarSym}

data FunBind p = FunBind
  { fbName :: String,
    fbParams :: [Param p],
    fbResult :: Maybe TyExp,
    fbBody :: Exp p,
    fbAt :: Span,
    fbSym :: Ann p FunSym
  }

type Program p = [Decl p]

declAt :: Decl p -> Span
declAt (DType at _) = at
declAt d@(DVal {}) = dAt d
declAt (DFun at _) = at
