-- | Semantic types, and the symbols that carry them.
--
-- Types are monomorphic.  Records are nominal — two record types with the same
-- fields are different types — and everything else is structural, which for this
-- language means arrays compare by their element type.
--
-- The other ports give a record type a mutable field list, because a record may
-- name itself and the fields cannot be resolved until the name exists.  Here a
-- record type carries a number instead, and that number is what nominal
-- equality compares; the fields live in a table the checker keeps and nothing
-- after it asks for.  What a later pass does want is how many there are, so the
-- arity — which is known from the syntax before any field is resolved — is on
-- the type itself.
module Wolv.Types
  ( Type (..),
    showTy,
    same,
    compatible,
    VarSym (..),
    FunSym (..),
    Sym (..),
    Home (..),
  )
where

import Wolv.Ir (Reg)

data Type
  = TInt
  | TString
  | TBool
  | TUnit
  | -- | The type of @nil@ before it is known which record it stands for.
    TNil
  | TRecord {recId :: !Int, recName :: String, recArity :: !Int}
  | TArray Type
  deriving (Show)

showTy :: Type -> String
showTy TInt = "int"
showTy TString = "string"
showTy TBool = "bool"
showTy TUnit = "unit"
showTy TNil = "nil"
showTy (TRecord _ name _) = name
showTy (TArray elem') = showTy elem' ++ " array"

-- | Type equality: nominal for records, structural for arrays.
same :: Type -> Type -> Bool
same (TRecord a _ _) (TRecord b _ _) = a == b
same (TArray a) (TArray b) = same a b
same TInt TInt = True
same TString TString = True
same TBool TBool = True
same TUnit TUnit = True
same TNil TNil = True
same _ _ = False

-- | Equality, but @nil@ stands in for any record.
compatible :: Type -> Type -> Bool
compatible TNil (TRecord {}) = True
compatible TNil TNil = True
compatible (TRecord {}) TNil = True
compatible a b = same a b

-- | Where a variable lives, once lowering has decided.  Two constructors and not
-- a slot number beside a register number: a frame slot may be negative — that is
-- an argument the caller left on the stack — so no number is free to mean "not
-- decided yet".
data Home = InRegister Reg | InFrame !Int
  deriving (Show)

-- | One binding occurrence of a variable.
--
-- @vsId@ is what stands in for the identity the other ports get from a mutable
-- object: whether a variable escapes and where it ended up living are answered
-- by maps from this number, because the answer is settled after the tree that
-- holds the symbol was built.  @vsDepth@ is the static nesting depth of the
-- function that binds it.
data VarSym = VarSym
  { vsId :: !Int,
    vsName :: String,
    vsTy :: Type,
    vsMutable :: !Bool,
    vsDepth :: !Int
  }
  deriving (Show)

-- | A function.  Functions are not values, so there is no function type.
data FunSym = FunSym
  { fsName :: String,
    fsLabel :: String,
    fsParams :: [VarSym],
    fsResult :: Type,
    fsDepth :: !Int,
    fsBuiltin :: Maybe String
  }
  deriving (Show)

data Sym = SVar VarSym | SFun FunSym
  deriving (Show)
