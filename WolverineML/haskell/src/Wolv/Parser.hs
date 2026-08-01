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
import Control.Monad (void)
import Control.Monad.State (lift)
import Text.Parsec hiding (parse)
import Text.Parsec.Pos (newPos)
import Wolv.Ast
import Wolv.Diag
import Wolv.Lexer

-- | The left binding power and the power the right side is read at.  Left <
-- right is left-associative; left > right is right-associative, which only @:=@
-- is.
bindingPower :: Tok -> Maybe (Int, Int)
bindingPower t = case t of
  ASSIGN -> Just (2, 1)
  ORELSE -> Just (4, 5)
  ANDALSO -> Just (6, 7)
  EQ_ -> Just (8, 9); NE -> Just (8, 9); LT_ -> Just (8, 9)
  LE -> Just (8, 9); GT_ -> Just (8, 9); GE -> Just (8, 9)
  CARET -> Just (10, 11)
  PLUS -> Just (12, 13); MINUS -> Just (12, 13)
  STAR -> Just (14, 15); SLASH -> Just (14, 15); MOD -> Just (14, 15)
  _ -> Nothing

unaryBP :: Int
unaryBP = 16

binop :: Tok -> String
binop t = case t of
  PLUS -> "+"; MINUS -> "-"; STAR -> "*"; SLASH -> "/"; MOD -> "mod"
  CARET -> "^"; EQ_ -> "="; NE -> "<>"; LT_ -> "<"; LE -> "<="
  GT_ -> ">"; GE -> ">="
  _ -> error "not a binary operator"

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

parse :: String -> Either WolvError Program
parse source = lexAll source >>= run program

-- | Parse a single expression — the tests use it, the compiler does not.
parseExp :: String -> Either WolvError Exp
parseExp source = lexAll source >>= run single
  where
    single = do
      e <- expression 0
      t <- peek
      if tokKind t == EOF
        then pure e
        else bad (tokAt t) ("unexpected " ++ showToken t ++ " after the expression")

program :: P Program
program = whileKind (/= EOF) decl

decl :: P Decl
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

typeDecl :: P Decl
typeDecl = DType . tokAt <$> expect TYPE <*> group typeBind

typeBind :: P TypeBind
typeBind = do
  name <- expectIdent
  void (expect EQ_)
  TypeBind (tokText name) <$> ty <*> pure (tokAt name)

valDecl :: P Decl
valDecl = do
  keyword <- anyTok
  name <- (Nothing <$ (kindIs LPAREN >> expect RPAREN)) <|> (Just . tokText <$> expectIdent)
  written <- optionMaybe (kindIs COLON >> ty)
  void (expect EQ_)
  init' <- expression 0
  pure (DVal (tokAt keyword) name written init' (tokKind keyword == VAR) Nothing)

funDecl :: P Decl
funDecl = DFun . tokAt <$> expect FUN <*> group funBind

funBind :: P FunBind
funBind = do
  name <- expectIdent
  params <- between (expect LPAREN) (expect RPAREN) (emptyOr RPAREN (param `sepBy1` kindIs COMMA))
  result <- optionMaybe (kindIs COLON >> ty)
  void (expect EQ_)
  body <- expression 0
  pure (FunBind (tokText name) params result body (tokAt name) Nothing)

-- | Nothing between the brackets, or a list of things: which of the two is one
-- token of lookahead, and neither wants a `try`.
emptyOr :: Tok -> P [a] -> P [a]
emptyOr closer p = do
  t <- peek
  if tokKind t == closer then pure [] else p

param :: P Param
param = do
  name <- expectIdent
  void (expect COLON)
  Param (tokText name) <$> ty <*> pure (tokAt name) <*> pure Nothing

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

expression :: Int -> P Exp
expression minBP = atom >>= loop
  where
    loop left = do
      t <- peek
      case bindingPower (tokKind t) of
        Just (l, r) | l >= minBP -> do
          void anyTok
          node <- case tokKind t of
            ASSIGN -> checkLvalue left >> (EAssign left <$> expression r)
            ANDALSO -> ELogic (tokText t) left <$> expression r
            ORELSE -> ELogic (tokText t) left <$> expression r
            k -> EBin (binop k) left <$> expression r
          loop (exp0 (tokAt t) node)
        _ -> pure left

checkLvalue :: Exp -> P ()
checkLvalue e = case eNode e of
  EVar _ -> pure ()
  EIndex _ _ -> pure ()
  EField _ _ -> pure ()
  _ -> bad (eAt e) "the left of `:=` is not assignable"

atom :: P Exp
atom = do
  t <- peek
  let at = tokAt t
  case tokKind t of
    INT -> anyTok >> postfix (exp0 at (EInt (read (tokText t))))
    STRING -> anyTok >> postfix (exp0 at (EStr (tokText t)))
    TRUE -> anyTok >> pure (exp0 at (EBool True))
    FALSE -> anyTok >> pure (exp0 at (EBool False))
    NIL -> anyTok >> pure (exp0 at ENil)
    BREAK -> anyTok >> pure (exp0 at EBreak)
    TILDE -> anyTok >> (exp0 at . ENeg <$> expression unaryBP)
    MINUS -> bad at "negation is written `~`, not `-`"
    LPAREN -> parens >>= postfix
    IDENT -> named >>= postfix
    IF -> ifExp
    WHILE -> whileExp
    FOR -> forExp
    LET -> letExp
    _ -> bad at ("expected an expression, found " ++ showToken t)

parens :: P Exp
parens = do
  open <- expect LPAREN
  let at = tokAt open
  t <- peek
  if tokKind t == RPAREN
    then anyTok >> pure (exp0 at EUnit)
    else do
      items <- sequenced RPAREN
      void (expect RPAREN)
      pure (one at items)

one :: Span -> [Exp] -> Exp
one _ [e] = e
one at items = exp0 at (ESeq items)

-- | Semicolons between expressions, and one allowed before the closer.
sequenced :: Tok -> P [Exp]
sequenced final = do
  first <- expression 0
  more <- optionMaybe (kindIs SEMI)
  case more of
    Nothing -> pure [first]
    Just _ -> do
      t <- peek
      if tokKind t == final then pure [first] else (first :) <$> sequenced final

named :: P Exp
named = do
  tok <- expectIdent
  let at = tokAt tok
  t <- peek
  case tokKind t of
    LPAREN -> do
      args <-
        between (kindIs LPAREN) (expect RPAREN) (emptyOr RPAREN (expression 0 `sepBy1` kindIs COMMA))
      pure (exp0 at (ECall (tokText tok) args))
    LBRACE -> do
      fields <-
        between (kindIs LBRACE) (expect RBRACE) (emptyOr RBRACE (fieldInit `sepBy1` kindIs COMMA))
      pure (exp0 at (ERecord (tokText tok) fields))
    _ -> pure (exp0 at (EVar (tokText tok)))

fieldInit :: P FieldInit
fieldInit = do
  name <- expectIdent
  void (expect EQ_)
  FieldInit (tokText name) <$> expression 0 <*> pure (tokAt name)

postfix :: Exp -> P Exp
postfix base = do
  t <- peek
  case tokKind t of
    LBRACK -> do
      void anyTok
      index <- expression 0
      void (expect RBRACK)
      postfix (exp0 (tokAt t) (EIndex base index))
    DOT -> do
      void anyTok
      name <- expectIdent
      postfix (exp0 (tokAt t) (EField base (tokText name)))
    _ -> pure base

ifExp :: P Exp
ifExp = do
  kw <- expect IF
  cond <- expression 0
  void (expect THEN)
  then' <- expression 0
  els <- optionMaybe (kindIs ELSE >> expression 0)
  pure (exp0 (tokAt kw) (EIf cond then' els))

whileExp :: P Exp
whileExp = do
  kw <- expect WHILE
  cond <- expression 0
  void (expect DO)
  exp0 (tokAt kw) . EWhile cond <$> expression 0

forExp :: P Exp
forExp = do
  kw <- expect FOR
  name <- expectIdent
  void (expect EQ_)
  lo <- expression 0
  void (expect TO)
  hi <- expression 0
  void (expect DO)
  exp0 (tokAt kw) . EFor (tokText name) lo hi <$> expression 0

letExp :: P Exp
letExp = do
  kw <- expect LET
  let at = tokAt kw
  decls <- whileKind (`elem` declStarters) decl
  void (expect IN)
  t <- peek
  body <-
    if tokKind t == END
      then pure (exp0 at EUnit)
      else one at <$> sequenced END
  void (expect END)
  pure (exp0 at (ELet decls body))
