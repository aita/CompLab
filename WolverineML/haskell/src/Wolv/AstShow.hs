{-# LANGUAGE DataKinds #-}

-- | An indented dump of the typed syntax tree, for @wolv emit -s ast@.
module Wolv.AstShow (showProgram, quoted) where

import Data.Char (ord)
import qualified Data.Set as Set
import Data.List (foldl', intercalate)
import Numeric (showHex)
import Wolv.Ast
import Wolv.Typecheck (Checked (..))
import Wolv.Types

-- | A string literal, written the way the Python tree writes it, so that a dump
-- taken from either is the same dump.  Every character of one is a byte, and a
-- byte that stands for nothing printable is shown as @\\xNN@.
--
-- Python asks a Unicode database which bytes those are.  Over the range a
-- literal can hold — U+0000 to U+00FF — the answer is four fixed ranges: the C0
-- and C1 controls, no-break space, and the soft hyphen.
quoted :: String -> String
quoted text = [mark] ++ concatMap one text ++ [mark]
  where
    mark = if '\'' `elem` text && '"' `notElem` text then '"' else '\''
    one c
      | c == mark || c == '\\' = ['\\', c]
      | n == 10 = "\\n"
      | n == 13 = "\\r"
      | n == 9 = "\\t"
      | n <= 0x1F || (n >= 0x7F && n <= 0xA0) || n == 0xAD = "\\x" ++ pad (showHex n "")
      | otherwise = [c]
      where
        n = ord c
    pad s = replicate (2 - length s) '0' ++ s

-- | The lines are built in reverse, because a walk that appends to the front of
-- a list and turns it round at the end is the one that does not copy.
type Lines = [String]

showProgram :: Checked -> String
showProgram (Checked prog escapes) =
  unlines (reverse (foldl' (\out d -> showDecl escapes 0 d out) [] prog))

put :: Int -> String -> Lines -> Lines
put depth text out = (replicate (2 * depth) ' ' ++ text) : out

escaped :: Set.Set Int -> VarSym -> String
escaped escapes sym
  | Set.member (vsId sym) escapes = " (escapes)"
  | otherwise = ""

ofType :: Exp 'Typed -> String
ofType e = " : " ++ showTy (eTy e)

showDecl :: Set.Set Int -> Int -> Decl 'Typed -> Lines -> Lines
showDecl escapes depth d out = case d of
  DType _ binds -> foldl' (\o b -> put depth ("type " ++ tbName b) o) out binds
  DVal {} ->
    let keyword = if dMutable d then "var" else "val"
        bound = maybe "()" (\b -> bName b ++ escaped escapes (bSym b)) (dBound d)
     in showExp escapes (depth + 1) (dInit d) (put depth (keyword ++ " " ++ bound) out)
  DFun _ binds -> foldl' one out binds
  where
    one o b =
      let params = intercalate ", " [pName p ++ escaped escapes (pSym p) | p <- fbParams b]
          result = showTy (fsResult (fbSym b))
       in showExp escapes (depth + 1) (fbBody b) (put depth ("fun " ++ fbName b ++ "(" ++ params ++ ") : " ++ result) o)

showPlace :: Set.Set Int -> Int -> Place 'Typed -> Lines -> Lines
showPlace escapes depth p out = case plNode p of
  PVar name _ -> put depth ("var " ++ name ++ ofPlace) out
  PIndex array index -> kids [array, index] (put depth ("index" ++ ofPlace) out)
  PField record name _ -> kids [record] (put depth ("field ." ++ name ++ ofPlace) out)
  where
    ofPlace = " : " ++ showTy (plTy p)
    kids es o = foldl' (\o' k -> showExp escapes (depth + 1) k o') o es

showExp :: Set.Set Int -> Int -> Exp 'Typed -> Lines -> Lines
showExp escapes depth e out = case eNode e of
  EInt value -> put depth ("int " ++ show value) out
  EStr value -> put depth ("string " ++ quoted value) out
  EBool value -> put depth ("bool " ++ (if value then "true" else "false")) out
  ENil -> put depth "nil" out
  EUnit -> put depth "()" out
  EPlace p -> showPlace escapes depth p out
  ECall name args _ -> kids args (put depth ("call " ++ name ++ ofType e) out)
  ERecord tyname fields ->
    foldl'
      (\o f -> showExp escapes (depth + 2) (fiValue f) (put (depth + 1) (fiName f ++ " =") o))
      (put depth ("record " ++ tyname ++ ofType e) out)
      fields
  ENeg operand -> kids [operand] (put depth "neg" out)
  EBin op lhs rhs -> kids [lhs, rhs] (put depth (op ++ ofType e) out)
  ELogic op lhs rhs -> kids [lhs, rhs] (put depth (op ++ ofType e) out)
  EAssign target value ->
    kids [value] (showPlace escapes (depth + 1) target (put depth ":=" out))
  EIf cond then' els ->
    kids (cond : then' : maybe [] (: []) els) (put depth ("if" ++ ofType e) out)
  EWhile cond body -> kids [cond, body] (put depth "while" out)
  EFor name lo hi body sym ->
    kids [lo, hi, body] (put depth ("for " ++ name ++ escaped escapes sym) out)
  EBreak -> put depth "break" out
  ESeq items -> kids items (put depth ("seq" ++ ofType e) out)
  ELet decls body ->
    showExp escapes (depth + 1) body $
      put depth "in" $
        foldl' (\o d -> showDecl escapes (depth + 1) d o) (put depth ("let" ++ ofType e) out) decls
  where
    kids es o = foldl' (\o' k -> showExp escapes (depth + 1) k o') o es
