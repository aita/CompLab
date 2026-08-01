{-# LANGUAGE DataKinds #-}

-- | A Pratt parser, written in Parsec over the token stream.
--
-- Every expression form is either a prefix form (in 'atom') or an infix one (in
-- 'expression'), and the table below is the whole of the precedence.  The prefix
-- forms that end in an expression — @if@, @while@, @for@, @:=@ — take their tail
-- at binding power 0, so @if c then x := 1 else x := 2@ reads the way it looks.
--
-- Parsec is used for what it is good at here and no more.  It carries the token
-- stream and the position, and it gives @between@, @sepBy1@ and @option@ their
-- ordinary meanings; it does not choose between alternatives, because this
-- grammar never needs it to.  Every decision is made by looking at the kind of
-- the next token, and every failure is raised with the message the other
-- implementations raise — so the parser is a 'ParsecT' over @Either
-- WolvError@, and a definite error is a @lift (Left …)@ that no backtracking
-- can undo.
module Wolv.Parser (parse, parseExp) where

import Data.List (foldl')
import Control.Monad (void, when)
import Control.Monad.State (lift)
import Text.Parsec hiding (parse)
import Text.Parsec.Pos (newPos)
import Wolv.Ast
import Wolv.Diag
import Wolv.Lexer

-- | What an infix token means: the node it builds, its left binding power, and
-- the power its right side is read at.  Left < right is left-associative; left
-- > right is right-associative, which only @:=@ is.
--
-- One table rather than two, so no token can have a precedence and no spelling.
type Infix = (Exp 'Parsed -> Exp 'Parsed -> Node 'Parsed, Int, Int)

infixOp :: Tok -> Maybe Infix
infixOp t = case t of
  ASSIGN -> Just (EAssign, 2, 1)
  ORELSE -> Just (ELogic "orelse", 4, 5)
  ANDALSO -> Just (ELogic "andalso", 6, 7)
  EQ_ -> bin "=" 8; NE -> bin "<>" 8; LT_ -> bin "<" 8
  LE -> bin "<=" 8; GT_ -> bin ">" 8; GE -> bin ">=" 8
  CARET -> bin "^" 10
  PLUS -> bin "+" 12; MINUS -> bin "-" 12
  STAR -> bin "*" 14; SLASH -> bin "/" 14; MOD -> bin "mod" 14
  _ -> Nothing
  where
    bin name power = Just (EBin name, power, power + 1)

unaryBP :: Int
unaryBP = 16

declStarters :: [Tok]
declStarters = [VAL, VAR, FUN, TYPE]

type P = ParsecT [Token] () (Either WolvError)

-- -- token plumbing --------------------------------------------------------

-- | A token's own span is the position Parsec reports, so an error raised by
-- Parsec and one raised by this file point at the same place.
posOf :: Span -> SourcePos
posOf (Span line col) = newPos "" line col

anyTok :: P Token
anyTok = tokenPrim showToken (\_ t _ -> posOf (tokAt t)) Just

-- | The next token, without taking it.  Cheap, because the list always ends in
-- an @EOF@ token and so is never empty.
peek :: P Token
peek = lookAhead anyTok

kindIs :: Tok -> P Token
kindIs kind = tokenPrim showToken (\_ t _ -> posOf (tokAt t)) test
  where
    test t = if tokKind t == kind then Just t else Nothing

-- | Fail with the message this compiler gives, which no backtracking undoes.
bad :: Span -> String -> P a
bad at message = lift (parseError at message)

expect :: Tok -> P Token
expect kind = do
  t <- peek
  if tokKind t == kind
    then anyTok
    else bad (tokAt t) ("expected `" ++ kindText kind ++ "`, found " ++ showToken t)

expectIdent :: P Token
expectIdent = do
  t <- peek
  if tokKind t == IDENT
    then anyTok
    else bad (tokAt t) ("expected a name, found " ++ showToken t)

-- | As many of @p@ as the next token says are there.  Every list in this
-- grammar is decided by one token of lookahead, so this is the only shape of
-- repetition it needs.
whileKind :: (Tok -> Bool) -> P a -> P [a]
whileKind wanted p = go
  where
    go = do
      t <- peek
      if wanted (tokKind t) then (:) <$> p <*> go else pure []

-- -- programs and declarations ---------------------------------------------

run :: P a -> [Token] -> Either WolvError a
run p toks = do
  parsed <- runParserT p () "" toks
  case parsed of
    Right a -> Right a
    -- Everything this grammar rejects, it rejects with a message of its own, so
    -- what is left is only what Parsec itself could not read.
    Left err -> parseError (Span (sourceLine (errorPos err)) (sourceColumn (errorPos err))) "cannot read this"

parse :: String -> Either WolvError (Program 'Parsed)
parse source = lexAll source >>= run program

-- | Parse a single expression — the tests use it, the compiler does not.
parseExp :: String -> Either WolvError (Exp 'Parsed)
parseExp source = lexAll source >>= run single
  where
    single = do
      e <- expression 0
      t <- peek
      if tokKind t == EOF
        then pure e
        else bad (tokAt t) ("unexpected " ++ showToken t ++ " after the expression")

program :: P (Program 'Parsed)
program = whileKind (/= EOF) decl

decl :: P (Decl 'Parsed)
decl = do
  t <- peek
  case tokKind t of
    TYPE -> typeDecl
    VAL -> valDecl
    VAR -> valDecl
    FUN -> funDecl
    _ ->
      bad
        (tokAt t)
        ("expected a declaration (`val`, `var`, `fun`, `type`), found " ++ showToken t)

-- | One or more of the same declaration, joined by @and@.
group :: P a -> P [a]
group one = one `sepBy1` kindIs AND

typeDecl :: P (Decl 'Parsed)
typeDecl = DType . tokAt <$> expect TYPE <*> group typeBind

typeBind :: P TypeBind
typeBind = do
  name <- expectIdent
  void (expect EQ_)
  TypeBind (tokText name) <$> ty <*> pure (tokAt name)

valDecl :: P (Decl 'Parsed)
valDecl = do
  keyword <- anyTok
  bound <-
    (Nothing <$ (kindIs LPAREN >> expect RPAREN))
      <|> (Just . (`Binder` ()) . tokText <$> expectIdent)
  written <- optionMaybe (kindIs COLON >> ty)
  void (expect EQ_)
  init' <- expression 0
  pure (DVal (tokAt keyword) bound written init' (tokKind keyword == VAR))

funDecl :: P (Decl 'Parsed)
funDecl = DFun . tokAt <$> expect FUN <*> group funBind

funBind :: P (FunBind 'Parsed)
funBind = do
  name <- expectIdent
  params <- between (expect LPAREN) (expect RPAREN) (emptyOr RPAREN (param `sepBy1` kindIs COMMA))
  result <- optionMaybe (kindIs COLON >> ty)
  void (expect EQ_)
  body <- expression 0
  pure (FunBind (tokText name) params result body (tokAt name) ())

-- | Nothing between the brackets, or a list of things: which of the two is one
-- token of lookahead, and neither wants a `try`.
emptyOr :: Tok -> P [a] -> P [a]
emptyOr closer p = do
  t <- peek
  if tokKind t == closer then pure [] else p

param :: P (Param 'Parsed)
param = do
  name <- expectIdent
  void (expect COLON)
  Param (tokText name) <$> ty <*> pure (tokAt name) <*> pure ()

-- -- types ------------------------------------------------------------------

ty :: P TyExp
ty = do
  at <- tokAt <$> peek
  base <- record at <|> parens <|> (TyName at . tokText <$> expectIdent)
  arrays <- many (try arrayWord)
  pure (foldl' (\t _ -> TyArray at t) base arrays)
  where
    record at =
      TyRecord at
        <$> between (kindIs LBRACE) (expect RBRACE) (emptyOr RBRACE (tyField `sepBy1` kindIs COMMA))
    parens = between (kindIs LPAREN) (expect RPAREN) ty
    arrayWord = tokenPrim showToken (\_ t _ -> posOf (tokAt t)) test
    test t = if tokKind t == IDENT && tokText t == "array" then Just t else Nothing

tyField :: P TyField
tyField = do
  name <- expectIdent
  void (expect COLON)
  TyField (tokText name) <$> ty <*> pure (tokAt name)

-- -- expressions ------------------------------------------------------------

expression :: Int -> P (Exp 'Parsed)
expression minBP = atom >>= loop
  where
    loop left = do
      t <- peek
      case infixOp (tokKind t) of
        Just (build, l, r) | l >= minBP -> do
          void anyTok
          when (tokKind t == ASSIGN) (checkLvalue left)
          right <- expression r
          loop (parsed (tokAt t) (build left right))
        _ -> pure left

checkLvalue :: Exp 'Parsed -> P ()
checkLvalue e = case eNode e of
  EVar _ _ -> pure ()
  EIndex _ _ -> pure ()
  EField _ _ _ -> pure ()
  _ -> bad (eAt e) "the left of `:=` is not assignable"

atom :: P (Exp 'Parsed)
atom = do
  t <- peek
  let at = tokAt t
  case tokKind t of
    INT -> anyTok >> postfix (parsed at (EInt (read (tokText t))))
    STRING -> anyTok >> postfix (parsed at (EStr (tokText t)))
    TRUE -> anyTok >> pure (parsed at (EBool True))
    FALSE -> anyTok >> pure (parsed at (EBool False))
    NIL -> anyTok >> pure (parsed at ENil)
    BREAK -> anyTok >> pure (parsed at EBreak)
    TILDE -> anyTok >> (parsed at . ENeg <$> expression unaryBP)
    MINUS -> bad at "negation is written `~`, not `-`"
    LPAREN -> parens >>= postfix
    IDENT -> named >>= postfix
    IF -> ifExp
    WHILE -> whileExp
    FOR -> forExp
    LET -> letExp
    _ -> bad at ("expected an expression, found " ++ showToken t)

parens :: P (Exp 'Parsed)
parens = do
  open <- expect LPAREN
  let at = tokAt open
  t <- peek
  if tokKind t == RPAREN
    then anyTok >> pure (parsed at EUnit)
    else do
      items <- sequenced RPAREN
      void (expect RPAREN)
      pure (one at items)

one :: Span -> [Exp 'Parsed] -> Exp 'Parsed
one _ [e] = e
one at items = parsed at (ESeq items)

-- | Semicolons between expressions, and one allowed before the closer.
sequenced :: Tok -> P [Exp 'Parsed]
sequenced final = do
  first <- expression 0
  more <- optionMaybe (kindIs SEMI)
  case more of
    Nothing -> pure [first]
    Just _ -> do
      t <- peek
      if tokKind t == final then pure [first] else (first :) <$> sequenced final

named :: P (Exp 'Parsed)
named = do
  tok <- expectIdent
  let at = tokAt tok
  t <- peek
  case tokKind t of
    LPAREN -> do
      args <-
        between (kindIs LPAREN) (expect RPAREN) (emptyOr RPAREN (expression 0 `sepBy1` kindIs COMMA))
      pure (parsed at (ECall (tokText tok) args ()))
    LBRACE -> do
      fields <-
        between (kindIs LBRACE) (expect RBRACE) (emptyOr RBRACE (fieldInit `sepBy1` kindIs COMMA))
      pure (parsed at (ERecord (tokText tok) fields))
    _ -> pure (parsed at (EVar (tokText tok) ()))

fieldInit :: P (FieldInit 'Parsed)
fieldInit = do
  name <- expectIdent
  void (expect EQ_)
  FieldInit (tokText name) <$> expression 0 <*> pure (tokAt name)

postfix :: Exp 'Parsed -> P (Exp 'Parsed)
postfix base = do
  t <- peek
  case tokKind t of
    LBRACK -> do
      void anyTok
      index <- expression 0
      void (expect RBRACK)
      postfix (parsed (tokAt t) (EIndex base index))
    DOT -> do
      void anyTok
      name <- expectIdent
      postfix (parsed (tokAt t) (EField base (tokText name) ()))
    _ -> pure base

ifExp :: P (Exp 'Parsed)
ifExp = do
  kw <- expect IF
  cond <- expression 0
  void (expect THEN)
  then' <- expression 0
  els <- optionMaybe (kindIs ELSE >> expression 0)
  pure (parsed (tokAt kw) (EIf cond then' els))

whileExp :: P (Exp 'Parsed)
whileExp = do
  kw <- expect WHILE
  cond <- expression 0
  void (expect DO)
  parsed (tokAt kw) . EWhile cond <$> expression 0

forExp :: P (Exp 'Parsed)
forExp = do
  kw <- expect FOR
  name <- expectIdent
  void (expect EQ_)
  lo <- expression 0
  void (expect TO)
  hi <- expression 0
  void (expect DO)
  parsed (tokAt kw) . (\body -> EFor (tokText name) lo hi body ()) <$> expression 0

letExp :: P (Exp 'Parsed)
letExp = do
  kw <- expect LET
  let at = tokAt kw
  decls <- whileKind (`elem` declStarters) decl
  void (expect IN)
  t <- peek
  body <-
    if tokKind t == END
      then pure (parsed at EUnit)
      else one at <$> sequenced END
  void (expect END)
  pure (parsed at (ELet decls body))
